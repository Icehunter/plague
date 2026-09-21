#version 330 core

// Paints the bounce light over the screen.
//
// The grid is far coarser than the screen, so this reads blocky on purpose: one ray per cell is
// what a first bounce costs. Red is a record no tier answered.
//
// What the grid holds is the light ARRIVING at each cell, which is far brighter than the surface
// it lands on. Multiplying by that surface's own colour is what the frame would show, and is what
// makes this comparable with the lit picture beside it.

#define PLAGUE_GI 0 //[0 1] compile "Bounce Light (Experimental)" {0="Off" 1="On"}
#define PLAGUE_GI_VIEW 0 //[0 1] compile "Test View: Bounce Light (Experimental)" {0="Off" 1="On"}

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:tonemap.glsl>

uniform sampler2D u_GiBounce; // giBounceRaw
uniform sampler2D u_GAlbedo; // builtin.gAlbedo
uniform sampler2D u_Depth; // builtin.depth

in vec2 texCoord;
out vec4 fragColor;

void main() {
    // Sky has no surface to light, so it is left to whatever drew it rather than multiplied to
    // black by an albedo that was never written.
    if (texture(u_Depth, texCoord).r <= 0.0) {
        discard;
    }
    vec3 light = texture(u_GiBounce, texCoord).rgb;
    vec3 receiver = texture(u_GAlbedo, texCoord).rgb;
    fragColor = vec4(plagueTonemapAndGrade(light * receiver * u_Exposure), 1.0);
}
