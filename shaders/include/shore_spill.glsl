#ifndef PLAGUE_SHORE_SPILL_GLSL
#define PLAGUE_SHORE_SPILL_GLSL

#moj_import <fornax_runtime:water_interaction.glsl>
#moj_import <fornax_runtime:water_waves.glsl>

// Shoreline spill: what a wave crest leaves on the block it washed over.
//
// Two time constants, one event. One rate gives either a puddle that snaps off as the crest passes
// or a block that never dries.
//
// SILENT FAILURE: with SURFACE_FLUID_DETAIL off there is no clipmap, every record read fails, and
// the feature evaluates to zero wetness with nothing logged.

// Half-lives in seconds. Authored from the physical reading, not fitted: a wet-looking film on a
// plank is gone within a few breaths, while the dark patch under it outlasts a minute of sun.
// tools/verify_shore_spill.py re-picks both against a render at the owner's live option values.
const float PLAGUE_SHORE_FILM_HALFLIFE = 2.2;
const float PLAGUE_SHORE_SOAK_HALFLIFE = 34.0;

// Head of water over the block top, in blocks, at which the wash saturates. Under ~6cm the crest is
// grazing the top rather than crossing it, and a hard threshold there makes the wet edge crawl in
// visible steps as the crest creeps up.
const float PLAGUE_SHORE_WASH_DEPTH = 0.06;

// A frame long enough to be a hitch rather than a frame. Decay is integrated per frame, so an
// unclamped delta after a chunk-load stall would dry a shoreline instantly.
const float PLAGUE_SHORE_MAX_FRAME_SECONDS = 0.25;

// How far under the water line a solid top still counts as ground. A sandbar just under the surface
// is ground a wave washes over; a lake bed is metres down.
const float PLAGUE_SHORE_SUBMERGED_TOLERANCE = 1.0;

// Head lost per block travelled inland; run-up climbs, spreads and drains. 0.25 puts a full
// 0.5-block crest two blocks in, which is what makes the wet edge a gradient rather than a lane.
const float PLAGUE_SHORE_RUNUP_LOSS_PER_BLOCK = 0.25;

// Two covers a five-wide pier from both sides, which is where the loss above reaches zero anyway.
// Ground cells only: water bails before the search.
const int PLAGUE_SHORE_HEAD_SEARCH_RADIUS = 2;

// The span plagueApplyPuddle's three offset windows use (albedo 0.30, material 0.35, normal 0.50,
// all topping out near 0.57). Fed its raw 0..1 depth instead, a full film reads as a damp fringe.
const float PLAGUE_SHORE_FILM_COVERAGE_MIN = 0.30;
const float PLAGUE_SHORE_FILM_COVERAGE_MAX = 0.57;

// Stage codes in the field's third channel, spaced so an unwritten texel reads 0.0: without that
// gap, "never ran" and "ran and found nothing" are the same value.
const float PLAGUE_SHORE_STAGE_UNPUBLISHED = 0.1;
const float PLAGUE_SHORE_STAGE_WATER = 0.3;
const float PLAGUE_SHORE_STAGE_NO_NEIGHBOUR = 0.5;
const float PLAGUE_SHORE_STAGE_BELOW_TOP = 0.7;
const float PLAGUE_SHORE_STAGE_WASHING = 0.9;

/** Flat colour per stage code, for the debug view. Black means the pass wrote nothing at all. */
vec3 plagueShoreStageColour(float stage) {
    if (stage < 0.05) return vec3(0.0);
    if (stage < 0.2) return vec3(1.0, 0.0, 0.0);
    if (stage < 0.4) return vec3(0.0, 0.3, 1.0);
    if (stage < 0.6) return vec3(1.0, 0.45, 0.0);
    if (stage < 0.8) return vec3(1.0, 1.0, 0.0);
    return vec3(0.0, 1.0, 0.2);
}

float plagueShoreDecay(float halfLife, float seconds) {
    return exp2(-seconds / max(halfLife, 1e-3));
}

/**
 * Crest height in world Y at a point, from the still surface the column publishes plus the macro
 * swell and the interaction ripple. `pressure` is the interaction field's own cell value, already
 * image-loaded on the simulation grid rather than sampled, so it needs no reprojection of its own.
 */
float plagueShoreCrestY(sampler2D noiseTex, vec2 worldXZ, float stillY, float pressure,
                        float waveClock, float waveStrength) {
    vec3 worldAbs = vec3(worldXZ.x, stillY, worldXZ.y);
    // The MESH displacement, not the shading spectrum: this must agree with the water surface the
    // vertex stage actually raised, or the wet band sits off the crest a player can see.
    float swell = plagueWaveSurfaceDisplacement(noiseTex, worldAbs, waveClock, 0.0, waveStrength).y;
    return stillY + swell + plagueInteractionHeightFromPressure(pressure);
}

/**
 * Film and soak for one cell this frame: whatever survived decay, or the wash, whichever is wetter.
 * A wash never subtracts, so a crest that recedes leaves the patch to dry on its own clock.
 */
vec2 plagueShoreAccumulate(vec2 previous, float wash, float seconds) {
    vec2 decayed = previous * vec2(plagueShoreDecay(PLAGUE_SHORE_FILM_HALFLIFE, seconds),
                                   plagueShoreDecay(PLAGUE_SHORE_SOAK_HALFLIFE, seconds));
    return max(decayed, vec2(wash));
}

/**
 * Field lookup for a shading stage, in the same actor-centred frame the wave field uses.
 * `previousCentre` must be the value the sampled field was written against, matching every other
 * caller of plagueInteractionSample.
 */
vec4 plagueShoreSample(sampler2D shoreTexture, vec3 worldPos, vec2 previousCentre,
                       int interactionMode) {
    return plagueInteractionSample(shoreTexture, worldPos, previousCentre, interactionMode);
}

#endif
