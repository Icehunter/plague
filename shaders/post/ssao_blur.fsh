#version 330

// Spatial blur for the current raw AO buffer.
//
// This pass previously retained 88% of `ssao.history`, but its disocclusion test sampled the current
// depth texture twice and entity/block-entity motion contains camera motion only. Animated banners,
// golems and chest parts therefore always accepted stale AO and left dark wisps. Keep the stable
// current-frame spatial filter; temporal AO requires real previous depth and object motion.

uniform sampler2D u_Input0; // ssaoRaw

#define SSAO_BLUR_RADIUS 2

in vec2 texCoord;
out float fragColor;

void main() {
    vec2 texelSize = 1.0 / vec2(textureSize(u_Input0, 0));

    float sum = 0.0;
    float count = 0.0;
    for (int x = -SSAO_BLUR_RADIUS; x <= SSAO_BLUR_RADIUS; x++) {
        for (int y = -SSAO_BLUR_RADIUS; y <= SSAO_BLUR_RADIUS; y++) {
            sum += texture(u_Input0, texCoord + vec2(x, y) * texelSize).r;
            count += 1.0;
        }
    }
    float blurred = sum / count;
    fragColor = blurred;
}
