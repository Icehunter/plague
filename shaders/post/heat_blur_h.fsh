#version 330

// Horizontal half of a two-pass separable Gaussian heat-haze blur, same technique as
// underwater_blur_h.fsh. Distance-modulation and the Nether-heat toggle live in tonemap.fsh's own
// blend; this pass blurs the whole frame once at a fixed radius whenever the dimension is Nether.

#moj_import <fornax:globals.glsl>

uniform sampler2D u_Input0; // sceneHdrRefracted, full resolution

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

// 1080p-calibrated pixels, scaled to the real framebuffer. Not exposed as its own slider: strength
// and start distance are the two controls the blur needs.
const float PLAGUE_HEAT_BLUR_RADIUS_PX = 6.0;

void main() {
    // Uniform branch: skips the sampling work entirely outside the Nether.
    if (u_WorldBounds.w != 2.0) {
        fragColor = vec4(texture(u_Input0, texCoord).rgb, 1.0);
        return;
    }

    float radiusPx = PLAGUE_HEAT_BLUR_RADIUS_PX * (float(textureSize(u_Input0, 0).y) / 1080.0);
    float sigma = max(radiusPx, 1.0) / 2.0;
    float texelX = 1.0 / float(textureSize(u_Input0, 0).x);

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
}
