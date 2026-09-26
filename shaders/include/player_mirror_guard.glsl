#ifndef PLAGUE_PLAYER_MIRROR_GUARD
#define PLAGUE_PLAYER_MIRROR_GUARD

// The one place the player-mirror guard band's constant and remap formula live, forward (vertex
// stage) and inverse (resolve and trace read back), so the floor and wall wrappers, resolves and
// traces all use the same number instead of separate copies that could drift apart.
//
// Floor (axis 0): a nearby player's mirrored body can project below the main viewport's bottom
// edge under a plain projection. The fix is a pre-divide affine remap of clip.y:
// y_ndc_written = (2*y_ndc + G)/(2 + G), which renders a taller frustum, extra reach below the
// screen, without changing the target's aspect.
//
// Wall (axis 1/2): the same problem happens sideways. A wall receiver near the view's left or
// right edge can reflect a body whose image falls outside a plain projection. The fix is a
// symmetric scale of the post-divide NDC x: x_ndc' = x_ndc/(1+G), implemented pre-divide by
// scaling clip.x alone and leaving clip.w untouched (clip.x'/clip.w = (clip.x/(1+G))/clip.w =
// x_ndc/(1+G), the same result a post-divide scale gives, reached the only way a vertex shader can
// reach it).
//
// Both G values are 0.5, the same number from unrelated sources: the floor's from
// tools/verify_player_mirror.py, where 0.5 zeroed every interior miss; the wall's from
// tools/verify_player_mirror_walls.py's sweep (17 interior misses at g=0, 4 at 0.1, 1 at 0.25, 0
// at 0.5 on the edge-framed scene; the centered scene stays clean through 0.5 and degrades at
// 0.75, so 0.5 is the one value both scenes accept). The two constants are named separately, not
// shared, so a future refit of one axis cannot silently move the other.
const float PLAGUE_MIRROR_GUARD_Y = 0.5;
const float PLAGUE_MIRROR_GUARD_X = 0.5;

// Forward: applied to clip space, before the hardware perspective divide, in the vertex stage.
void plagueMirrorGuardBottom(inout vec4 clipPos) {
    clipPos.y = (2.0 * clipPos.y + PLAGUE_MIRROR_GUARD_Y * clipPos.w) / (2.0 + PLAGUE_MIRROR_GUARD_Y);
}

void plagueMirrorGuardHorizontal(inout vec4 clipPos) {
    clipPos.x = clipPos.x / (1.0 + PLAGUE_MIRROR_GUARD_X);
}

// Inverse: applied to the guarded NDC recovered from a sampled UV, in the resolve or trace pass.
float plagueMirrorUnguardBottomNdc(float yGuardedNdc) {
    return ((2.0 + PLAGUE_MIRROR_GUARD_Y) * yGuardedNdc - PLAGUE_MIRROR_GUARD_Y) / 2.0;
}

float plagueMirrorUnguardHorizontalNdc(float xGuardedNdc) {
    return xGuardedNdc * (1.0 + PLAGUE_MIRROR_GUARD_X);
}

#endif
