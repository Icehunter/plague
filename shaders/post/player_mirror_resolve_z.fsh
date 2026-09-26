#version 330

// Lights the player's own reflection, z-wall axis. The body is shared with the floor
// and x-wall resolves in shaders/include/player_mirror_resolve_body.glsl. This wrapper declares
// its own family's four samplers and selects the axis. The Mirror Debug option is not declared
// here: it lives on the floor wrapper alone.

#define PLAGUE_MIRROR_AXIS 2

uniform sampler2D u_MirrorZAlbedo; // builtin.mirrorZAlbedo: rgb = albedo (srgb), a = sky light
uniform sampler2D u_MirrorZNormal; // builtin.mirrorZNormal: xyz = real world normal
uniform sampler2D u_MirrorZMaterial; // builtin.mirrorZMaterial: r = smoothness, g = F0, b = porosity/SSS, a = block light
uniform sampler2D u_MirrorZDepth; // builtin.mirrorZDepth: reversed-Z, 0.0 = no reflection here
#define MIRROR_ALBEDO_SAMPLER u_MirrorZAlbedo
#define MIRROR_NORMAL_SAMPLER u_MirrorZNormal
#define MIRROR_MATERIAL_SAMPLER u_MirrorZMaterial
#define MIRROR_DEPTH_SAMPLER u_MirrorZDepth

#moj_import <fornax_runtime:player_mirror_resolve_body.glsl>
