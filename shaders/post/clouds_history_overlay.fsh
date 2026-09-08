#version 330
uniform sampler2D u_Input0;
in vec2 texCoord;
out vec4 fragColor;
void main() {
    // Half the viewport dimensions give a same-aspect corner panel.
    // Final output enters engine AA/scene history: this diagnostic panel can appear in reflections.
    if (any(lessThan(texCoord, vec2(0.5)))) discard;
    ivec2 size = textureSize(u_Input0, 0);
    ivec2 pixel = clamp(ivec2((texCoord * 2.0 - 1.0) * vec2(size)), ivec2(0), size - 1);
    fragColor = texelFetch(u_Input0, pixel, 0);
}
