#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:lighting_history.glsl>

// Auto-exposure measurement: writes the 1x1 exposure accumulator. Grid-samples sceneHdrRefracted
// for log-average scene luminance (Reinhard et al. 2002, "Photographic Tone Reproduction for
// Digital Images", eq. 1), then exponentially blends against last frame's value for smooth eye
// adaptation. Shaft radiance joins after this measurement and receives its resulting multiplier.
//
// Two adaptation rates, not one, matching real eyes: brightening is near-instant (cones), darkening
// is slow (rods), so a single speed slider can't fit both directions.
//
// The accumulator stores linear luma (exp2(avgLogLuma)), not the log2 average, so the frame-1
// sentinel 0.0 stays unambiguous — a linear-light scene at luma 1.0 (log2 == 0.0) is a common
// operating point, and exp2(avgLogLuma) is always > 0.

uniform sampler2D u_SceneHdrRefracted; // sceneHdrRefracted: the base signal that establishes auto exposure
uniform sampler2D u_Exposure_history; // r = smoothed linear luma (0 = empty); gba = lighting clock

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec3  u_SunDirection;
};

// Frame-rate dependent (a per-frame blend adapts faster at higher fps); accepted rather than hidden
// behind a dt correction nothing else here needs. Higher slider = faster, so main() inverts this to
// a retention factor.
#define u_ExposureAdaptSpeedDarken 0.04 //[0.0..1.0 step 0.01] runtime "Exposure Adapt Speed (Darkening)"
#define u_ExposureAdaptSpeedBrighten 0.15 //[0.0..1.0 step 0.01] runtime "Exposure Adapt Speed (Brightening)"

in vec2 texCoord;
out vec4 fragColor;

void main() {
    const int GRID = 16;
    float sumLogLuma = 0.0;
    for (int y = 0; y < GRID; y++) {
        for (int x = 0; x < GRID; x++) {
            vec2 uv = (vec2(float(x), float(y)) + 0.5) / float(GRID);
            vec3 c = texture(u_SceneHdrRefracted, uv).rgb;
            float luma = dot(c, vec3(0.2126, 0.7152, 0.0722)); // Rec. 709 luma coefficients
            // Clamp away from zero before log2 so black pixels don't drag the average to -inf; the
            // 1e-4 floor caps the darkest measurable scene luminance.
            sumLogLuma += log2(max(luma, 1e-4));
        }
    }
    float avgLogLuma = sumLogLuma / float(GRID * GRID);
    float avgLuma = exp2(avgLogLuma);

    // Frame 1: history cleared to 0.0, unreachable for a genuine measurement, so it seeds directly.
    // Direction decides the rate (darker scene -> slower, rising exposure; brighter -> faster,
    // falling exposure), compared on the measured luma so this stays independent of tonemap.fsh's
    // own exposure formula.
    vec4 history = texture(u_Exposure_history, texCoord);
    float prev = history.r;
    float speed = (avgLuma < prev) ? u_ExposureAdaptSpeedDarken : u_ExposureAdaptSpeedBrighten;
    float retention = clamp(1.0 - speed, 0.0, 0.999);
    // A commanded time change is new illumination, not eye adaptation to the old scene.
    bool valid = prev > 0.0 && plagueLightingHistoryValid(vec4(history.gba, 1.0));
    float blended = valid ? mix(avgLuma, prev, retention) : avgLuma;

    fragColor = vec4(blended, plagueLightingClock().xyz);
}
