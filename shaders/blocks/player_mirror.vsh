#version 330

// The player's own reflection, floor axis. The body is shared with the two wall wrappers in
// shaders/include/player_mirror_body_vsh.glsl. This wrapper only selects the axis. See that
// file for the reconstruction, reflection, and guard band mechanism.
#define PLAGUE_MIRROR_AXIS 0
#moj_import <fornax_runtime:player_mirror_body_vsh.glsl>
