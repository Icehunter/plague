#version 330
// Preserve the resolve's shared light/shadow input while local transport is disabled.
uniform sampler2D u_CloudShadowMask;
in vec2 texCoord;
out vec4 fragColor;
void main() { fragColor=vec4(0.0,0.0,0.0,texture(u_CloudShadowMask,texCoord).r); }
