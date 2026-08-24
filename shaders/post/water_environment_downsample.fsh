#version 330

// Builds the filtered water-environment hierarchy. Mipchain passes use a reduced binding set, so
// dimensions come from the source texture and no global scene uniforms are declared here.

uniform sampler2D u_Input0;

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    ivec2 destination = ivec2(gl_FragCoord.xy);
    ivec2 sourceSize = textureSize(u_Input0, 0);

    if (u_Param2 > 0.5) {
        fragColor = texelFetch(u_Input0, min(destination, sourceSize - 1), 0);
        return;
    }

    ivec2 base = destination * 2;
    vec4 sum = vec4(0.0);
    float count = 0.0;
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            ivec2 source = base + ivec2(x, y);
            if (all(lessThan(source, sourceSize))) {
                sum += texelFetch(u_Input0, source, 0);
                count += 1.0;
            }
        }
    }
    fragColor = sum / max(count, 1.0);
}
