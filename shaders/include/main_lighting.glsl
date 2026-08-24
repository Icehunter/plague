// Surface lighting composite: block-light curve, per-face directional shading, the reshaped
// vanilla AO term, moon-phase influence and the quadrature composite that combines them with a
// pre-shadowed specular response and a separately-radiant emission term.
//
// SCOPE: owns plagueDoLighting and its internal helpers, plus plagueHeldLighting and
// plagueMoonPhaseInfluence (each has one external caller beyond the deferred resolve; see their
// own notes). Does NOT own the underwater ambient floor or shadow-gate override — those arrive as
// plain parameters (uwAmbientFloor, uwShadowGate) so this file stays a pure function of its
// inputs. Does NOT own emitted radiance's colour construction either (plagueEmittedRadiance,
// emission.glsl) — this file only decides what luminance/albedo to hand it.

#ifndef PLAGUE_MAIN_LIGHTING_INCLUDE
#define PLAGUE_MAIN_LIGHTING_INCLUDE

#moj_import <fornax_runtime:emission.glsl>

// =================================================================================================
// Small shared helpers.

float plagueSmoothstep1(float x) {
    float t = clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Torch/lantern base colour for the Custom palette, and the luminance anchor the Physical model's
// blackbody block light gets rescaled to. A warm incandescent orange, authored against tools/out/
// renders rather than any temperature fit.
const vec3 PLAGUE_BLOCKLIGHT_COL = vec3(1.00, 0.58, 0.24);

// -------------------------------------------------------------------------------------------------
// Block-light curve (2.3): a hot, small core (steep term, near-zero until raw block light nears
// max) plus a long, soft tail (linear term), summed and reshaped by one exponent. The accessibility
// brightness driver TRADES weight between the two terms rather than scaling their sum, so raising
// it shifts weight from core to tail instead of uniformly brightening everything.
//
// Fitted to the accepted build's measured behaviour (tools/fit_lighting_parity.py, section
// block_light_curve; RMS 23.8 -> 0.108). UNCAPPED is deliberate: the hot core at full blockLight
// IS the look (a torch at point-blank range reads HDR into the quadrature bracket below, and the
// sqrt there brings it back down).
const float PLAGUE_BLOCKLIGHT_STEEP_POWER = 7.8708;
const float PLAGUE_BLOCKLIGHT_RESHAPE = 2.7907;
// Weight-trade point (same fit): keeps both the steep core and the linear tail meaningfully
// present at every vsBrightness.
const float PLAGUE_BLOCKLIGHT_WEIGHT_TRADE = 0.8175;
// Closed-form, not fitted: at blockLight=1, steep=linear=1 always regardless of the constants
// above, so curveOutput = gain there. Set to the exact measured value (48.24175078) since this is
// the single most visible point the curve produces (a torch at point-blank range).
const float PLAGUE_BLOCKLIGHT_GAIN = 48.2418;

float plagueBlockLightCurve(float blockLight, float vsBrightness) {
    float bl = clamp(blockLight, 0.0, 1.0);
    float vsb = clamp(vsBrightness, 0.0, 1.0);
    float steep = pow(bl, PLAGUE_BLOCKLIGHT_STEEP_POWER);
    float linear = bl;
    float steepWeight = mix(1.0, PLAGUE_BLOCKLIGHT_WEIGHT_TRADE, vsb);
    float linearWeight = mix(PLAGUE_BLOCKLIGHT_WEIGHT_TRADE, 1.0, vsb);
    float combined = (steep * steepWeight + linear * linearWeight) / (steepWeight + linearWeight);
    // max(combined,0.0), not clamp(...,1.0): the upper cap is gone on purpose (see above). The
    // lower guard only matters for a stray negative outside the clamped domain — pow() with a
    // negative base and non-integer exponent is undefined in GLSL.
    return pow(max(combined, 0.0), PLAGUE_BLOCKLIGHT_RESHAPE) * PLAGUE_BLOCKLIGHT_GAIN;
}

// -------------------------------------------------------------------------------------------------
// Directional shading (2.4): a brightness multiplier from the world normal alone — up brightest,
// down dimmest, north/south a small lift over horizontal, east/west a small reduction, blended
// continuously across the three zones.
//
// Fitted to the accepted build (tools/fit_lighting_parity.py, section directional_shading). The 6
// axis-aligned measurements pin these four constants exactly (zero residual — each isolates one
// constant alone). The 8 corner measurements are then over-determined by the formula's own
// single-ratio EW/NS blend and can't all be reproduced exactly: max residual 1.16% (RMS 0.79%).
const float PLAGUE_DIRSHADE_UP   = 1.00000;
const float PLAGUE_DIRSHADE_DOWN = 0.50000;
const float PLAGUE_DIRSHADE_NS   = 0.80625;
const float PLAGUE_DIRSHADE_EW   = 0.67500;

float plagueDirectionShade(vec3 normal) {
    vec3 n = normalize(normal);
    float up = clamp(n.y, 0.0, 1.0);
    float down = clamp(-n.y, 0.0, 1.0);
    float side = max(1.0 - up - down, 0.0);
    float horizSpan = max(abs(n.x) + abs(n.z), 1e-4);
    float sideShade = mix(PLAGUE_DIRSHADE_EW, PLAGUE_DIRSHADE_NS, abs(n.z) / horizSpan);
    return up * PLAGUE_DIRSHADE_UP + down * PLAGUE_DIRSHADE_DOWN + side * sideShade;
}

// -------------------------------------------------------------------------------------------------
// Vanilla AO reshaping (2.5): lift the engine's per-vertex term off its floor, curve it, then
// raise it to an exponent that grows with scene brightness, upward-facing angle, noon closeness
// and sky visibility, so AO reads deepest in bright, open, midday conditions. Applied to a
// texture-AO*SSAO stand-in from the deferred pass, not the true per-vertex signal it was written for.
//
// Fitted to the accepted build (tools/fit_lighting_parity.py, section vanilla_ao_reshaping, RMS
// 48.8% -> 3.7% across the full 936-row grid).
const float PLAGUE_AO_FLOOR = 0.230;
const float PLAGUE_AO_BASE_CURVE = 0.729;
const float PLAGUE_AO_DEPTH_GAIN = 0.328;

float plagueVanillaAO(float vanillaAO, vec3 sceneLighting, float NdotUmax0, float noonFactor,
                       float lightmapY2) {
    float lifted = clamp((vanillaAO - PLAGUE_AO_FLOOR) / max(1.0 - PLAGUE_AO_FLOOR, 1e-4), 0.0, 1.0);
    float base = pow(lifted, PLAGUE_AO_BASE_CURVE);

    float sceneLum = dot(max(sceneLighting, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
    float sceneTerm = clamp(sceneLum * sceneLum, 0.0, 1.0);
    float upTerm = clamp(NdotUmax0, 0.0, 1.0);
    float noonTerm = plagueSmoothstep1(noonFactor);
    float skyTerm = clamp(lightmapY2, 0.0, 1.0);

    float depthExponent = 1.0 + PLAGUE_AO_DEPTH_GAIN * sceneTerm * upTerm * noonTerm * skyTerm;
    return pow(base, depthExponent);
}

// -------------------------------------------------------------------------------------------------
// Moon-phase influence (2.6). Full moon (phase 0) lights at the usual night level, new moon
// (phase 4) barely at all, fading to a no-op (1.0) as sunVisibility2 climbs away from its night
// extreme, so it never touches daytime. One external caller beyond the deferred resolve: the
// water-shaft march.
//
// Scope is load-bearing: scales sceneLighting alone, before that term's own final squaring in
// plagueDoLighting — never block lighting, emission or held light. A prior version scaled the
// whole finished picture instead, which dimmed a torch as the moon waned; must not reappear.
const float PLAGUE_MOON_PHASE_FLOOR = 0.12;

float plagueMoonPhaseInfluence(float moonPhase, float sunVisibility2) {
    float phase = mod(moonPhase, 8.0);
    float distFromFull = min(phase, 8.0 - phase);       // 0 at full (phase 0), 4 at new (phase 4)
    float illumination = 1.0 - distFromFull / 4.0;       // 1 at full, 0 at new
    float phaseInf = mix(PLAGUE_MOON_PHASE_FLOOR, 1.0, clamp(illumination, 0.0, 1.0));
    return mix(1.0, phaseInf, 1.0 - clamp(sunVisibility2, 0.0, 1.0));
}

// -------------------------------------------------------------------------------------------------
// Held light (2.7). The stronger of the two hands selects one strength; the light sits at a small
// fixed offset below the eye and falls off as inverse-square distance, floored so the near field
// can't blow out. Coloured identically to placed block light, taking that colour as a parameter
// (not a bare internal constant) so a Custom-palette or Physical-model choice reaches a held torch
// the same way it reaches a placed one.
const vec3 PLAGUE_HELD_LIGHT_EYE_OFFSET = vec3(0.0, -0.18, 0.0);
const float PLAGUE_HELD_LIGHT_DIST_FLOOR = 1.2;

vec3 plagueHeldLighting(vec3 toFragment, float mainLevel, float offLevel, vec3 blockLightColour) {
    float level = clamp(max(mainLevel, offLevel), 0.0, 1.0);
    vec3 lightToFragment = toFragment - PLAGUE_HELD_LIGHT_EYE_OFFSET;
    float dist = length(lightToFragment) + PLAGUE_HELD_LIGHT_DIST_FLOOR;
    float falloff = 1.0 / max(dist * dist, 1e-4);
    return blockLightColour * level * falloff;
}

// =================================================================================================
// The composite.

struct PlagueLitResult {
    vec3 diffuse;    // multiply albedo by this
    vec3 highlight;  // add after
    vec3 emitted;    // radiance, already coloured; do not multiply by albedo again
    float vanillaAO; // instrumentation only, for a debug readback elsewhere
};

// Side-shadowing (2.2 step 1): a small wrap past the geometric terminator so faces angled away
// from the light still read a sliver instead of terminating abruptly on cube geometry.
// Fitted to the accepted build across all 24 full_composite_probes rows including the 3 torch
// scenarios (tools/fit_lighting_parity.py, RMS 0.000207). Deliberately keeps the round 0.400 over
// the fit's raw 0.399596.
const float PLAGUE_SIDE_WRAP = 0.400;

// Sky-gated shadow (2.2 step 2): a very steep function of sky access, so a fragment with no sky
// line takes essentially no direct light regardless of the shadow map — what keeps shadow-map
// light from leaking into sealed interiors. uwShadowGate overrides it per-fragment when >= 0.
// Left at its prior authored value: unfittable from the measured data, which only ever samples
// skyLight at exactly 0 or 1 (0^p=0, 1^p=1 for any positive power).
const float PLAGUE_SKY_GATE_POWER = 6.0;

// The sky-competition floor (2.2 step 3, see plagueDoLighting's call site): the value
// competitionFactor's Hermite descent settles on at skyLight=1 for a non-emissive fragment.
//
// SHADOW-AWARE: two probe pairs at skyLight=1 back out two DIFFERENT MEASURED values depending on
// whether the sun actually reaches the fragment (shadowTerm==1: LIT, 0.7039) or the fragment is
// fully shadowed (shadowTerm==0: SHADE, 0.8895) — the old build's competition factor is not a pure
// function of skyLight. What happens between the two is unmeasured, so plagueDoLighting linearly
// interpolates by shadowTerm as the minimal honest model.
const float PLAGUE_SKY_COMPETITION_RESIDUAL_LIT = 0.7039;
const float PLAGUE_SKY_COMPETITION_RESIDUAL_SHADE = 0.8895;

// Weather light-fog tweak (2.2 step 4): only the rain component; the night/distance component
// needs a view-distance input this composite doesn't receive and is left as a documented hook
// (mirrors the biome-precipitation hook in light_and_ambient_colors.glsl).
// Fitted to the accepted build (tools/fit_lighting_parity.py, section full_composite_probes).
const float PLAGUE_RAIN_FOG_DIM = 0.10;

// Directional shading's second, distinct effect (2.2 step 5): a matching brightness boost to the
// direct-light colour on east/west-facing surfaces (plagueDirectionShade only returns the
// multiplier).
// Left at its prior authored value: unconstrained by the measured data, whose probes all use a
// straight-up normal (sideFraction = 0 in every row).
const float PLAGUE_DIRSHADE_LIGHT_EW_BOOST = 0.12;

// Ambient-toward-direct bounce on north/south faces under open sky: a cheap stand-in for bounced
// light that keeps shadowed faces from reading flat blue.
// Left at its prior authored value, unconstrained for the same reason as
// PLAGUE_DIRSHADE_LIGHT_EW_BOOST above.
const float PLAGUE_AMBIENT_BOUNCE_STRENGTH = 0.35;

// Small additional face-dependent contrast boost that only applies very close to true noon.
// PLAGUE_NOON_CONTRAST_START is left at its prior authored value: unconstrained by the measured
// data, which only ever sits at noonFactor exactly 0 or 1.
// PLAGUE_NOON_CONTRAST_STRENGTH IS fitted (tools/fit_lighting_parity.py): backs out within 0.1% of
// 0.0, so the old build's noon contrast lift measures as negligible here.
const float PLAGUE_NOON_CONTRAST_START = 0.85;
const float PLAGUE_NOON_CONTRAST_STRENGTH = 0.0;

PlagueLitResult plagueDoLighting(
        vec3 lightColor, vec3 ambientColor, vec3 normal, vec3 lightVec,
        float shadowIn, float blockLight, float skyLight,
        float vanillaAOIn, float emitterLum, vec3 albedoLinear,
        vec3 specular, vec3 blockLightColour,
        float noonFactor, float sunVisibility2, float rainFactor, float vsBrightness,
        float moonPhaseInf, vec3 lightColorMult,
        float uwShadowGate, vec3 uwAmbientFloor) {
    vec3 n = normalize(normal);
    vec3 l = normalize(lightVec);

    // 1. Side-shadowing.
    float NdotL = dot(n, l);
    float ndotlTerm = clamp((NdotL + PLAGUE_SIDE_WRAP) / (1.0 + PLAGUE_SIDE_WRAP), 0.0, 1.0);

    // 2. Sky-gated shadow, overridable for submerged geometry.
    float defaultSkyGate = pow(clamp(skyLight, 0.0, 1.0), PLAGUE_SKY_GATE_POWER);
    float skyGate = uwShadowGate >= 0.0 ? uwShadowGate : defaultSkyGate;
    float shadowTerm = clamp(shadowIn, 0.0, 1.0) * skyGate * ndotlTerm;

    // 3. Block light: curved, tinted, then reshaped by the sky-competition rule — pushed down as
    // the fragment is already sky-lit, back up as sky light fades, switched off entirely for a
    // fragment carrying its own emission. The Hermite descent settles on a shadow-aware floor
    // rather than 0 (see PLAGUE_SKY_COMPETITION_RESIDUAL_LIT/_SHADE), interpolated by shadowTerm.
    float blockCurve = plagueBlockLightCurve(blockLight, vsBrightness);
    float hasEmission = step(1e-4, emitterLum);
    float competitionResidual = mix(PLAGUE_SKY_COMPETITION_RESIDUAL_SHADE,
                                     PLAGUE_SKY_COMPETITION_RESIDUAL_LIT, shadowTerm);
    float noEmissionCompetition = mix(1.0, competitionResidual,
                                       plagueSmoothstep1(clamp(skyLight, 0.0, 1.0)));
    float competitionFactor = mix(noEmissionCompetition, 1.0, hasEmission);
    vec3 blockLighting = blockLightColour * blockCurve * competitionFactor;

    // 4. Weather light-fog tweak (rain component only; see this file's own const note).
    float rainFogDim = 1.0 - clamp(rainFactor, 0.0, 1.0) * PLAGUE_RAIN_FOG_DIM;
    vec3 directColor = lightColor * rainFogDim;

    // 5. Directional shading: the brightness multiplier, the direct-colour east/west boost, the
    // ambient-toward-direct north/south bounce under open sky, and the close-to-noon contrast lift.
    float dirShade = plagueDirectionShade(n);
    float horizSpan = max(abs(n.x) + abs(n.z), 1e-4);
    float sideFraction = max(1.0 - abs(n.y), 0.0);
    float ewWeight = sideFraction * (abs(n.x) / horizSpan);
    directColor *= 1.0 + PLAGUE_DIRSHADE_LIGHT_EW_BOOST * ewWeight;

    float nsWeight = sideFraction * (abs(n.z) / horizSpan);
    float bounceAmount = clamp(PLAGUE_AMBIENT_BOUNCE_STRENGTH * nsWeight * clamp(skyLight, 0.0, 1.0),
                                0.0, 1.0);
    vec3 ambientColorShaded = mix(ambientColor, directColor, bounceAmount);

    float noonCloseness = plagueSmoothstep1(
            (clamp(noonFactor, 0.0, 1.0) - PLAGUE_NOON_CONTRAST_START)
            / max(1.0 - PLAGUE_NOON_CONTRAST_START, 1e-4));
    directColor *= max(1.0 + PLAGUE_NOON_CONTRAST_STRENGTH * noonCloseness * (dirShade - 0.5), 0.0);

    // 6. Composite.
    float ambientTerm = plagueSmoothstep1(clamp(skyLight, 0.0, 1.0)) * rainFogDim;
    vec3 sceneLighting = directColor * shadowTerm + ambientColorShaded * ambientTerm;

    // 7. Colour-multiplier layer.
    sceneLighting *= lightColorMult;

    // 8. Moon-phase influence: sceneLighting only, after colour-mult, before the final squaring
    // in step 10 (see plagueMoonPhaseInfluence's own note on why this scope is load-bearing).
    sceneLighting *= moonPhaseInf;

    // 9. Underwater ambient floor: additive, on top of everything above. vec3(0) on a dry fragment.
    sceneLighting += uwAmbientFloor;

    // 10. Quadrature composite: vanilla AO times directional shading forms a combined shade term;
    // that shade term, squared, multiplies the sum of block lighting and squared sceneLighting;
    // the whole thing is square-rooted back. Two sources each independently at their own maximum
    // do not sum to double: they add in quadrature.
    float lightmapY2 = clamp(skyLight, 0.0, 1.0);
    lightmapY2 *= lightmapY2;
    float vanillaAOOut = plagueVanillaAO(vanillaAOIn, sceneLighting, max(n.y, 0.0), noonFactor,
                                          lightmapY2);
    float combinedShade = clamp(vanillaAOOut * dirShade, 0.0, 1.0);
    vec3 quadratureSum = max(blockLighting, vec3(0.0)) + sceneLighting * sceneLighting;
    vec3 diffuse = sqrt(max(combinedShade * combinedShade * quadratureSum, vec3(0.0)));

    // 11. Emission: a genuine radiance, never re-multiplied by albedo, entirely outside the
    // bracket above.
    PlagueLitResult result;
    result.diffuse = diffuse;
    // Passed through untouched: specular arrives ALREADY shadowed and light-coloured (brdf.glsl's
    // contract). Multiplying again here would tint every highlight toward lightColor squared —
    // over-red and under-blue at sunset on every glossy surface.
    result.highlight = specular;
    result.emitted = plagueEmittedRadiance(albedoLinear, emitterLum);
    result.vanillaAO = vanillaAOOut;
    return result;
}

#endif // PLAGUE_MAIN_LIGHTING_INCLUDE
