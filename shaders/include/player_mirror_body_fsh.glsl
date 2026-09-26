// The player's own reflection, fragment stage body. Shared by all three axis wrappers
// (shaders/blocks/player_mirror.fsh, player_mirror_x.fsh, player_mirror_z.fsh), each of which
// #defines PLAGUE_MIRROR_AXIS (0 floor, 1 X wall, 2 Z wall) before importing this file. Writes
// PlayerMirrorTargets' three colour lanes, in the engine's attachment order
// (DeferredGeometryPipelines.buildMirror's location 0/1/2): normal, albedo plus sky light, material
// plus block light. No AO, no motion lane: the mirror is composited fresh from a single still
// frame each time its resolve samples it, so it carries no history to reproject, and the resolve's
// own AO comes from the sampling pixel's G-buffer, not from here.

#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:color.glsl>

uniform sampler2D Sampler0;

in vec4 vertexColor;
in vec2 texCoord0;
in vec3 v_PlagueRealNormal;
in vec3 v_PlagueRealWorldPos;
in float v_PlagueBlockLight;
in float v_PlagueSkyLight;

layout(location = 0) out vec4 gNormalOut;
layout(location = 1) out vec4 gAlbedoOut;
layout(location = 2) out vec4 gMaterialOut;

void main() {
    vec4 color = texture(Sampler0, texCoord0);
    // Fixed threshold, not the engine's per-pipeline ALPHA_CUTOUT: mirrorVariantOf sets no blend
    // state for any base pipeline, so a translucent skin layer that would normally blend instead
    // paints solid wherever alpha is nonzero. Discarding low-alpha texels outright follows
    // entities.fsh's own cutout convention, applied here unconditionally instead of through a
    // variable threshold.
    if (color.a < 0.1) {
        discard;
    }

    // The real world position on this axis, not the mirrored copy gl_Position used to project.
    // A fragment test here replaces an oblique near-plane clip, which fails silently under this
    // MRT's reversed-Z convention: it follows the main camera's depth convention, not the shadow
    // map's forward-Z one.
#if PLAGUE_MIRROR_AXIS == 0
    // Floor: 0.02 anti-flicker margin, picked in design review. The render plane is the standing
    // plane, so the soles sit right on it, not on a wave-displaced surface with margin to spare.
    // Without the margin, interpolation and depth precision put some sole texels a hair below
    // their own plane and lose them to this discard every other frame.
    if ((v_PlagueRealWorldPos.y + u_CameraAbs.y) < u_PlayerMirrorState.y - 0.02) {
        discard;
    }
#elif PLAGUE_MIRROR_AXIS == 1
    // X wall: v_PlagueRealWorldPos.x and u_PlayerMirrorWalls.y are both already camera-relative,
    // so there is no u_CameraAbs term here, unlike the floor. facing (u_PlayerMirrorWalls.x, +/-1)
    // decides which side of the plane counts as behind it: a wall's normal can point either +X or
    // -X, while the floor's standing plane only ever has one valid up. Same 0.02 anti-flicker
    // margin, and the same rule that a body pressed into the plane keeps part but never all of
    // itself, checked in tools/verify_player_mirror_walls.py.
    if ((v_PlagueRealWorldPos.x - u_PlayerMirrorWalls.y) * u_PlayerMirrorWalls.x < -0.02) {
        discard;
    }
#else
    // Z wall: same rule as the X wall, using its own plane and facing lanes.
    if ((v_PlagueRealWorldPos.z - u_PlayerMirrorWalls.w) * u_PlayerMirrorWalls.z < -0.02) {
        discard;
    }
#endif

    color.rgb = plagueLinearToSrgb(
            plagueSrgbToLinear(color.rgb)
                    * plagueSrgbToLinear(vertexColor.rgb)
                    * plagueSrgbToLinear(ColorModulator.rgb));
    color.a *= vertexColor.a * ColorModulator.a;

    // No labPBR here: mirrorVariantOf's bind groups carry only u_Globals, and the mirror
    // setPipeline branch binds nothing else, so u_NormalTex or u_MaterialTex would either fail
    // precompile or run with nothing bound. The interpolated real vertex normal stands in directly: the
    // resolve reflects the sampled position back across the plane and lights the real surface at
    // that point, so the normal it reads must describe the real surface, not its mirror image, but
    // it does not need to be normal-mapped yet. labPBR here waits until the engine binds those
    // samplers for this variant.
    gNormalOut   = vec4(normalize(v_PlagueRealNormal), 1.0);
    gAlbedoOut   = vec4(color.rgb, v_PlagueSkyLight);
    // Neutral material: smoothness 0, F0 0, porosity/SSS 0. The resolve never decodes labPBR from
    // this lane (it only reads block light out of .a), so these three are unused, not wrong.
    gMaterialOut = vec4(0.0, 0.0, 0.0, v_PlagueBlockLight);
}
