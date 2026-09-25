#version 330

// Median-of-five luma filter: fills single-pixel holes the noisy bokeh gather leaves inside
// large discs, without softening disc edges the way a tent blur would (median fill per Jimenez
// 2014, "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH course).

uniform sampler2D u_DofGather; // rgb bokeh colour, a composite blend factor

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec2 texel = 1.0 / vec2(textureSize(u_DofGather, 0));
    // Rec. 709 luma coefficients.
    const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
    vec4 c[5];
    float luma[5];
    c[0] = texture(u_DofGather, texCoord);
    c[1] = texture(u_DofGather, texCoord - vec2(texel.x, 0.0));
    c[2] = texture(u_DofGather, texCoord + vec2(texel.x, 0.0));
    c[3] = texture(u_DofGather, texCoord - vec2(0.0, texel.y));
    c[4] = texture(u_DofGather, texCoord + vec2(0.0, texel.y));
    for (int i = 0; i < 5; ++i) {
        luma[i] = dot(c[i].rgb, LUMA);
    }
    // Selection by counting; the index tie-break makes the order strict, so exactly
    // one tap has two others below it.
    int medianIdx = 0;
    for (int i = 0; i < 5; ++i) {
        int below = 0;
        for (int j = 0; j < 5; ++j) {
            if (j != i && (luma[j] < luma[i] || (luma[j] == luma[i] && j < i))) {
                below++;
            }
        }
        if (below == 2) {
            medianIdx = i;
        }
    }
    fragColor = c[medianIdx];
}
