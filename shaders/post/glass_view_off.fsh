#version 330 core
uniform sampler2D u_Input0;
in vec2 texCoord;
out vec4 fragColor;
void main() {
    fragColor=vec4(texture(u_Input0,texCoord).rgb,-1.0);
}
