// The player's own reflection, vertex stage body. Shared by all three axis wrappers
// (shaders/blocks/player_mirror.vsh, player_mirror_x.vsh, player_mirror_z.vsh), each of which
// #defines PLAGUE_MIRROR_AXIS (0 floor, 1 X wall, 2 Z wall) before importing this file. The vertex
// input list lives here once, so it cannot drift between the three the way three separately typed
// copies would. verify_entity_vertex_inputs.py pins all three flattened wrappers against
// entities.vsh's own ordered list for this reason.
//
// The engine's PlayerMirrorCaster submits the player under the same camera the replayed shadow
// draws use. This program reconstructs a camera-relative world position the same way
// shadow_entities.vsh does, then reflects a copy of it across the axis's own plane for projection
// only. The real position and real normal pass through unreflected, for the fragment stage's
// below-plane discard and for gNormal: the resolve reflects the sampled position back and lights
// the real surface, so the normal it reads must describe that real surface, not its mirror image.

#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>
#moj_import <fornax_runtime:player_mirror_guard.glsl>

in vec3 Position;
in vec4 Color;
in vec2 UV0;
// UV1 (overlay lane) is declared but unused: this list must match entities.vsh and
// shadow_entities.vsh's ordered input list byte for byte. Attribute locations are positional, so a
// missing input here silently shifts every later one: UV2 would read UV1's overlay coordinates and
// Normal would read UV2's light lane, with no error anywhere. See
// tools/verify_entity_vertex_inputs.py.
in ivec2 UV1;
in ivec2 UV2;
in vec3 Normal;

out vec4 vertexColor;
out vec2 texCoord0;
out vec3 v_PlagueRealNormal;
out vec3 v_PlagueRealWorldPos;
out float v_PlagueBlockLight;
out float v_PlagueSkyLight;

void main() {
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    vec3 worldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;

    vec3 mirrored = worldPos;
#if PLAGUE_MIRROR_AXIS == 0
    // Floor: y' = 2*(planeY - cameraY) - y. The plane height converts to camera-relative space
    // first because worldPos is camera-relative throughout this pass, but u_PlayerMirrorState.y is
    // an absolute world height.
    mirrored.y = 2.0 * (u_PlayerMirrorState.y - u_CameraAbs.y) - worldPos.y;
#elif PLAGUE_MIRROR_AXIS == 1
    // X wall: x' = 2*planeXRel - x. u_PlayerMirrorWalls.y is already camera-relative
    // (WallPlaneProbe's publish contract is why that lane exists; see its own doc), unlike the
    // floor's absolute height above, so there is no camera term here.
    mirrored.x = 2.0 * u_PlayerMirrorWalls.y - worldPos.x;
#else
    // Z wall: z' = 2*planeZRel - z, the same reasoning as the X wall, using u_PlayerMirrorWalls.w.
    mirrored.z = 2.0 * u_PlayerMirrorWalls.w - worldPos.z;
#endif
    gl_Position = ProjMat * u_ModelViewMatrix * vec4(mirrored, 1.0);

    // Guard band: the floor keeps its bottom remap, because a nearby body's mirrored image can
    // project below the main viewport. The walls use the horizontal remap instead, because a wall
    // receiver near the view's left or right edge can reflect a body whose image falls outside a
    // plain projection. See player_mirror_guard.glsl's own doc for both derivations. The consuming
    // resolve and trace shaders apply the identical inverse remap when reading this MRT back, from
    // the same include.
#if PLAGUE_MIRROR_AXIS == 0
    plagueMirrorGuardBottom(gl_Position);
#else
    plagueMirrorGuardHorizontal(gl_Position);
#endif

    vertexColor = Color;
    texCoord0 = UV0;
    v_PlagueBlockLight = clamp(float(UV2.x) / 240.0, 0.0, 1.0);
    v_PlagueSkyLight = clamp(float(UV2.y) / 240.0, 0.0, 1.0);

    v_PlagueRealWorldPos = worldPos;
    vec3 viewNormal = mat3(transpose(inverse(ModelViewMat))) * Normal;
    v_PlagueRealNormal = normalize(mat3(inverse(u_ModelViewMatrix)) * viewNormal);
}
