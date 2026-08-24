#version 330

// Vertical half of the two-pass separable Gaussian underwater blur; see underwater_blur_h.fsh for
// the full rationale. Reads that pass's own output (underwaterBlurH), not sceneHdrRefracted
// directly, so the two convolutions compose into one genuine 2D Gaussian. u_Input1/u_Input2 stay
// wired below purely for ordinal parity with graph.toml; neither is sampled here.

#moj_import <fornax:globals.glsl>
// For PLAGUE_UNDERWATER and WATER_BLUR: see underwater_blur_h.fsh's own comment on this same
// import for the full account (this pass ships the exact same #if gate).
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:underwater.glsl>

uniform sampler2D u_Input0; // underwaterBlurH: the horizontal pass's own output
uniform sampler2D u_Input1; // builtin.depth, full resolution; ordinal parity only, unused (see header)
uniform sampler2D u_Input2; // builtin.waterDepth, full resolution; ordinal parity only, unused (see header)

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
    // Dry eye: same uniform-branch skip as underwater_blur_h.fsh. See that file's own comment.
    if (u_WaterState.x <= 0.5 || u_UwBlurRadius <= 0.0) {
        fragColor = texture(u_Input0, texCoord);
        return;
    }

    float radiusPx = u_UwBlurRadius * (float(textureSize(u_Input0, 0).y) / 1080.0);
    float sigma = max(radiusPx, 1.0) / 2.0;
    float texelY = 1.0 / float(textureSize(u_Input0, 0).y);

    // NINE taps at sigma/2 spacing. See underwater_blur_h.fsh's own comment on this same
    // constant for why 1-sigma spacing (five taps) undersamples into a visible dot pattern.
    const int TAPS = 4;
    vec3 sum = vec3(0.0);
    float weightSum = 0.0;
    for (int i = -TAPS; i <= TAPS; i++) {
        float offsetPx = float(i) * (radiusPx / float(TAPS));
        float w = exp(-0.5 * (offsetPx / sigma) * (offsetPx / sigma));
        vec2 tapUv = clamp(texCoord + vec2(0.0, offsetPx * texelY), vec2(0.0), vec2(1.0));
        vec3 tap = texture(u_Input0, tapUv).rgb;
        if (!any(isnan(tap)) && !any(isinf(tap))) {
            sum += max(tap, vec3(0.0)) * w;
            weightSum += w;
        }
    }
    fragColor = vec4(sum / max(weightSum, 1e-5), 1.0);
#else
    fragColor = texture(u_Input0, texCoord);
#endif
}
