#version 330

// Median-of-five on luma fills single-pixel holes the noisy bokeh gather leaves inside
// large discs, without softening disc rims. Colour only: the alpha is near-field
// coverage, smooth by construction, and a median vote across a bright silhouette strips
// it in a band, cutting the bleed and leaving an unblurred strip. It averages instead.

uniform sampler2D u_DofGather; // rgb bokeh colour, a = near-field coverage

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec2 texel = 1.0 / vec2(textureSize(u_DofGather, 0));
    vec4 c[5];
    c[0] = texture(u_DofGather, texCoord);
    c[1] = texture(u_DofGather, texCoord - vec2(texel.x, 0.0));
    c[2] = texture(u_DofGather, texCoord + vec2(texel.x, 0.0));
    c[3] = texture(u_DofGather, texCoord - vec2(0.0, texel.y));
    c[4] = texture(u_DofGather, texCoord + vec2(0.0, texel.y));

    // Rec. 709 luma coefficients.
    float luma[5];
    for (int i = 0; i < 5; ++i) {
        luma[i] = dot(c[i].rgb, vec3(0.2126, 0.7152, 0.0722));
    }

    // Selection by counting; the index tie-break makes the order strict, so exactly one
    // tap has two others below it.
    int median = 0;
    for (int i = 0; i < 5; ++i) {
        int below = 0;
        for (int j = 0; j < 5; ++j) {
            if (luma[j] < luma[i] || (luma[j] == luma[i] && j < i)) {
                ++below;
            }
        }
        if (below == 2) median = i;
    }

    float avgA = (c[0].a + c[1].a + c[2].a + c[3].a + c[4].a) * 0.2;
    fragColor = vec4(c[median].rgb, avgA);
}
