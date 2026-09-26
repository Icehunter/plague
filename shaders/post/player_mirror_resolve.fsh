#version 330

// Lights the player's own reflection, floor axis. The body is shared with the two wall
// resolves in shaders/include/player_mirror_resolve_body.glsl. This wrapper declares its own
// family's four samplers and selects the axis. The debug view lives here only. See the body
// file for why one instance covers all three families.

#define PLAGUE_MIRROR_AXIS 0

uniform sampler2D u_MirrorAlbedo; // builtin.mirrorAlbedo: rgb = albedo (srgb), a = sky light
uniform sampler2D u_MirrorNormal; // builtin.mirrorNormal: xyz = real world normal
uniform sampler2D u_MirrorMaterial; // builtin.mirrorMaterial: r = smoothness, g = F0, b = porosity/SSS, a = block light
uniform sampler2D u_MirrorDepth; // builtin.mirrorDepth: reversed-Z, 0.0 = no reflection here
#define MIRROR_ALBEDO_SAMPLER u_MirrorAlbedo
#define MIRROR_NORMAL_SAMPLER u_MirrorNormal
#define MIRROR_MATERIAL_SAMPLER u_MirrorMaterial
#define MIRROR_DEPTH_SAMPLER u_MirrorDepth

// The mirror's own lighting has nowhere else on screen to be read back. This reflection is the
// only place any of these terms ever reaches a pixel, so it doubles as its own scope for all three
// mirror families, since the body they share is identical. Off leaves every pass lit normally.
#define u_MirrorDebug 0 //[0 1 2 3 4 5 6 7] runtime "Mirror Debug" {0="Off" 1="Sun Visibility" 2="Albedo" 3="Sky Light" 4="Block Light" 5="Sun Probe" 6="Real Height" 7="Shadow Chain"}

#moj_import <fornax_runtime:player_mirror_resolve_body.glsl>
