#version 330

// Converges photo-still depth of field: while parked, each frame is rendered from a different
// lens-aperture point; this pass keeps their running average (the thin-lens integral), giving
// true occlusion and bokeh. u_Param2 = aperture frame index, u_Param3 = active flag. When the
// camera moves the pass copies the current frame with zero confidence so the composite ignores
// it the same frame.

uniform sampler2D u_SceneHdrGlare; // this frame's scene with glare baked in, one aperture point
uniform sampler2D u_DofAccum_history; // last frame's running average, rgb; a = confidence

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec3 current = texture(u_SceneHdrGlare, texCoord).rgb;
    if (any(isnan(current)) || any(isinf(current))) current = vec3(0.0);

    float index = u_Param2;
    bool apertureActive = u_Param3 > 0.5;

    vec4 hist = texture(u_DofAccum_history, texCoord);
    // Frame zero of a still seeds the average directly; inactive frames keep the chain warm
    // but claim no confidence. The 0.004 floor marks "aperture live" for the composite's
    // base switch even at frame zero, well above rgba16f quantization.
    if (!apertureActive || index < 0.5 || any(isnan(hist.rgb))) {
        fragColor = vec4(current, apertureActive ? max(min(index / 32.0, 1.0), 0.004) : 0.0);
        return;
    }

    // A sub-frame firefly hundreds of times the running average would stay visible for
    // dozens of frames at 1/(n+1) weight; against a converging mean, light that bright is
    // trace noise, not signal. Four times the average plus one keeps real highlights.
    current = min(current, hist.rgb * 4.0 + vec3(1.0));

    // The weight cap turns the average into a long exposure rather than a freeze, so water
    // and flames keep their tripod-camera motion blur instead of locking mid-wave.
    float n = min(index, 255.0);
    vec3 average = mix(current, hist.rgb, n / (n + 1.0));
    // 32 frames is where the aperture disc is half sampled and the picture reads converged;
    // the composite fades the post-process blur out by this ramp, floored so the live flag
    // survives.
    float a = max(min(index / 32.0, 1.0), 0.004);
    fragColor = vec4(average, a);
}
