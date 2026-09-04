#version 330

// Vertical half of the two-pass separable Gaussian heat-haze blur; see heat_blur_h.fsh. Reads
// that pass's own output (heatBlurH) so the two convolutions compose into one 2D Gaussian.

#moj_import <fornax:globals.glsl>

uniform sampler2D u_Input0; // heatBlurH: the horizontal pass's own output

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

const float PLAGUE_HEAT_BLUR_RADIUS_PX = 6.0;

void main() {
    if (u_WorldBounds.w != 2.0) {
        fragColor = texture(u_Input0, texCoord);
        return;
    }

    float radiusPx = PLAGUE_HEAT_BLUR_RADIUS_PX * (float(textureSize(u_Input0, 0).y) / 1080.0);
    float sigma = max(radiusPx, 1.0) / 2.0;
    float texelY = 1.0 / float(textureSize(u_Input0, 0).y);

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
}
