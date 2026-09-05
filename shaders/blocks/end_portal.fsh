#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <fornax:globals.glsl>

// Bound by vanilla. Not sampled: this draws flat black.
uniform sampler2D Sampler0;
uniform sampler2D Sampler1;

in vec4 texProj0;
in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec2 v_PlagueMotion;

layout(location = 0) out vec4 gNormalOut;
layout(location = 1) out vec4 gAlbedoOut;
layout(location = 2) out vec4 gMaterialOut;
layout(location = 3) out vec4 gAoOut;
layout(location = 4) out vec2 gMotionOut;

// A flat black hole, on purpose.
//
// What this program writes does not land where it says. Flat colours sent to the albedo and the
// normal come back in each other's debug views, and swapping the two does not help. The cause is in
// how this pipeline binds its outputs, so any picture drawn here goes somewhere unpredictable.
//
// Both writes read as black whichever buffer they reach. The albedo is black. The normal points
// down: a real direction to shade with, facing away from the sky so it catches no light, and black
// if read as a colour. Block light is zero so nothing lifts it.
void main() {
    gAlbedoOut = vec4(0.0, 0.0, 0.0, 1.0);
    gNormalOut = vec4(0.0, -1.0, 0.0, 1.0);

    // Rough, non-metal, no porosity, no block light. The last lane is what would make it glow.
    gMaterialOut = vec4(0.0, 0.0, 0.0, 0.0);
    gAoOut = vec4(1.0, 0.0, 1.0, 0.25);
    gMotionOut = v_PlagueMotion;
}
