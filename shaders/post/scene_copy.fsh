#version 330

// Passthrough copy of the linear HDR scene into sceneHdrComposited, worth the full-res cost only to
// break a GraphValidator cycle: water_composite would otherwise write sceneHdr while ssr_trace_water
// reads it, and the validator can't express "reads the earlier-declared version". Water writes here
// instead so sceneHdr stays single-writer.
//
// Ungated: bloom/tonemap read sceneHdrComposited unconditionally, so with water off this must still
// hand them an unmodified scene.

uniform sampler2D u_Input0; // sceneHdr

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    fragColor = texture(u_Input0, texCoord);
}
