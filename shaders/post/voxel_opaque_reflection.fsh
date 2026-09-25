#version 330
// Opaque misses share water's world/material lighting; the entry selects the receiver only.
#define PLAGUE_OPAQUE_REFLECTION
#moj_import <fornax_runtime:voxel_water_reflection_pass.glsl>
