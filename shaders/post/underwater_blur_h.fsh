#version 330

// Horizontal half of a two-pass separable Gaussian underwater blur (see tonemap.fsh for the
// unchanged blend logic that is the other half). Separable passes give a genuinely continuous 2D
// Gaussian from two 1D convolutions, replacing a scattered-disc kernel whose discrete sample points
// were visible as circles around bright features at the radii this slider reaches.
//
// A progressive lens filter, not a denoiser: this kernel ignores depth entirely, so it smears
// across silhouettes rather than preserving edges — that is the brief, not a bug. u_Input1/u_Input2
// stay wired below purely so this pass's input ordinals match graph.toml; neither is sampled here.
//
// Fixed radius, not distance-modulated: the distance ramp lives in tonemap.fsh's own blend
// (uwAmount/uwBlurBlend), so this pass blurs the whole frame once at u_UwBlurRadius.

#moj_import <fornax:globals.glsl>
// Imported solely for PLAGUE_UNDERWATER/WATER_BLUR (GLSL has no cross-file #define sharing):
// without it the #if below silently evaluates both as 0 and this pass compiles to a passthrough.
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:underwater.glsl>

uniform sampler2D u_Input0; // sceneHdrRefracted, full resolution
uniform sampler2D u_Input1; // builtin.depth, full resolution: ordinal parity only, unused (see header)
uniform sampler2D u_Input2; // builtin.waterDepth, full resolution: ordinal parity only, unused (see header)

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

#moj_import <fornax_runtime:water_options.glsl>
in vec2 texCoord;
out vec4 fragColor;

void main() {
#if PLAGUE_UNDERWATER && WATER_BLUR
    // Uniform branch: skips the sampling work entirely when dry, same as the single-pass version.
    if (u_WaterState.x <= 0.5 || u_UwBlurRadius <= 0.0) {
        fragColor = vec4(texture(u_Input0, texCoord).rgb, 1.0);
        return;
    }

    // RADIUS IN 1080p-CALIBRATED PIXELS, scaled to the real framebuffer: same reasoning as the
    // single-pass version this replaces (a fixed texel-space radius changed look with window size).
    float radiusPx = u_UwBlurRadius * (float(textureSize(u_Input0, 0).y) / 1080.0);
    float sigma = max(radiusPx, 1.0) / 2.0;
    float texelX = 1.0 / float(textureSize(u_Input0, 0).x);

    // Nine taps at sigma/2 spacing: the previous 5-tap, 1-sigma version undersampled enough that an
    // impulse through H then V came out as a dot grid instead of a single lobe.
    const int TAPS = 4;
    vec3 sum = vec3(0.0);
    float weightSum = 0.0;
    for (int i = -TAPS; i <= TAPS; i++) {
        float offsetPx = float(i) * (radiusPx / float(TAPS));
        float w = exp(-0.5 * (offsetPx / sigma) * (offsetPx / sigma));
        vec2 tapUv = clamp(texCoord + vec2(offsetPx * texelX, 0.0), vec2(0.0), vec2(1.0));
        vec3 tap = texture(u_Input0, tapUv).rgb;
        // A NaN/Inf tap would poison the sum through every add below it.
        if (!any(isnan(tap)) && !any(isinf(tap))) {
            sum += max(tap, vec3(0.0)) * w;
            weightSum += w;
        }
    }
    fragColor = vec4(sum / max(weightSum, 1e-5), 1.0);
#else
    // This arm keeps the shader valid when either compile option is disabled.
    fragColor = texture(u_Input0, texCoord);
#endif
}
