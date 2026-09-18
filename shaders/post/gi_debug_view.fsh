#version 330 core

// Paints the bounce light over the screen.
//
// The grid is far coarser than the screen, so this reads blocky on purpose: one ray per cell is
// what a first bounce costs. Red is a record no tier answered.
//
// The result carries real sun and sky radiance, which is far brighter than a screen can show, so
// it goes through the pack's own exposure and curve rather than out raw.

#define PLAGUE_GI_DEBUG 0 //[0 1] compile "Test View: Bounce Light" {0="Off" 1="On"}

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:tonemap.glsl>

uniform sampler2D u_Input0; // giBounceRaw

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec3 light = texture(u_Input0, texCoord).rgb;
    fragColor = vec4(plagueTonemapAndGrade(light * u_Exposure), 1.0);
}
