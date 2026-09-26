#version 330

// Lights the player's own reflection, x-wall axis. The body is shared with the floor
// and z-wall resolves in shaders/include/player_mirror_resolve_body.glsl. This wrapper declares
// its own family's four samplers and selects the axis. The Mirror Debug option is not declared
// here: it lives on the floor wrapper alone. See that file for why one instance covers all three.

#define PLAGUE_MIRROR_AXIS 1

uniform sampler2D u_MirrorXAlbedo; // builtin.mirrorXAlbedo: rgb = albedo (srgb), a = sky light
uniform sampler2D u_MirrorXNormal; // builtin.mirrorXNormal: xyz = real world normal
uniform sampler2D u_MirrorXMaterial; // builtin.mirrorXMaterial: r = smoothness, g = F0, b = porosity/SSS, a = block light
uniform sampler2D u_MirrorXDepth; // builtin.mirrorXDepth: reversed-Z, 0.0 = no reflection here
#define MIRROR_ALBEDO_SAMPLER u_MirrorXAlbedo
#define MIRROR_NORMAL_SAMPLER u_MirrorXNormal
#define MIRROR_MATERIAL_SAMPLER u_MirrorXMaterial
#define MIRROR_DEPTH_SAMPLER u_MirrorXDepth

#moj_import <fornax_runtime:player_mirror_resolve_body.glsl>
