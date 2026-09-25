#version 330
#moj_import <fornax_runtime:dof.glsl>

// One level of the blur pyramid: a 2x2 box reduce of the level above, colour in rgb (HDR),
// signed circle of confusion in alpha. The luma weighting below is what keeps glints alive;
// a plain average erases exactly the highlights that give a lens its bokeh texture.

uniform sampler2D u_Input0; // the level above: rgb HDR colour, a = signed CoC in half-res px

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec2 srcTexel = 1.0 / vec2(textureSize(u_Input0, 0));
    vec4 tap[4];
    for (int i = 0; i < 4; ++i) {
        int x = (i & 1) * 2 - 1;
        int y = ((i >> 1) & 1) * 2 - 1;
        tap[i] = texture(u_Input0, texCoord + vec2(float(x), float(y)) * 0.5 * srcTexel);
        if (any(isnan(tap[i].rgb))) {
            tap[i] = vec4(0.0);
        }
    }
    // Bounded so a hot tap can lead by at most nine to one at full boost; 8 picked off the
    // offline disc render as the gain where a lone glint still reads two levels down
    // without flicker under motion. On a uniform field every weight is equal and the
    // average is exact.
    vec3 colour = vec3(0.0);
    float wSum = 0.0;
    float cocSum = 0.0;
    for (int i = 0; i < 4; ++i) {
        float luma = dot(tap[i].rgb, vec3(0.2126, 0.7152, 0.0722));
        float w = 1.0 + u_DofHighlightBoost * 8.0 * luma / (1.0 + luma);
        colour += tap[i].rgb * w;
        wSum += w;
        cocSum += tap[i].a;
    }
    // The CoC channel stays the plain average of the four alphas: weighting depth by
    // brightness would bend geometry.
    fragColor = vec4(colour / wSum, cocSum / 4.0);
}
