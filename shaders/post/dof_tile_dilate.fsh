#version 330

// 9x9 maximum over the tile map so a large disc up to four tiles away still widens this tile's
// gather radius; without it a blurred foreground object hard-clips at tile borders (Jimenez 2014,
// "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH course). Radius 4
// because one tile is 8 half-res px and u_DofMaxBlur's slider cap is 32 half-res px: 4 tiles of
// reach covers the largest disc any setting can ask for. 81 fetches on a 1/16-scale target.

uniform sampler2D u_DofTile; // r = max abs CoC in the tile, half-res px

in vec2 texCoord;
out vec4 fragColor;

void main() {
    ivec2 c = ivec2(gl_FragCoord.xy);
    ivec2 size = textureSize(u_DofTile, 0);
    float acc = 0.0;
    for (int y = -4; y <= 4; ++y) {
        for (int x = -4; x <= 4; ++x) {
            // Clamp to bounds so edge tiles do not read outside the texture.
            ivec2 p = clamp(c + ivec2(x, y), ivec2(0), size - 1);
            acc = max(acc, texelFetch(u_DofTile, p, 0).r);
        }
    }
    fragColor = vec4(acc, 0.0, 0.0, 1.0);
}
