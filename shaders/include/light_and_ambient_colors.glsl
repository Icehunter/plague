// Overworld light/ambient colour supply: the Custom palette table, its day/night/rain drivers, and
// the colour-grading layer. Owns PlagueLighting, the struct every downstream consumer (fog, clouds,
// forward terrain, underwater, water compositing, the deferred resolve) reads. Only active once
// CUSTOM_LIGHT_COLORS is switched on; the default is the physically-derived model in atmosphere.glsl.
//
// terrain.fsh's two forward-lit call sites have no options buffer, so plagueOverworldLighting has a
// small-arity fallback baking the shipped defaults as compile constants (same shape as
// underwater.glsl's own two-overload pair) — live palette edits don't reach them.

#ifndef PLAGUE_LIGHT_AND_AMBIENT_COLORS_INCLUDE
#define PLAGUE_LIGHT_AND_AMBIENT_COLORS_INCLUDE

// =================================================================================================
// PlagueLighting: the entire consumer contract. Every field here is read by at least one
// consumer outside this file; see each call site for which.

struct PlagueLighting {
    vec3  light;          // Direct sun/moon colour, before N.L and shadowing.
    vec3  ambient;        // Sky-dome fill colour.
    float vsBrightness;   // Accessibility brightness driver, carried through raw (see below).
    float noonFactor;     // Day-progress driver, plateaued at noon and at night, fast at the edges.
    float sunVisibility2; // Squared day/night crossfade weight, narrow band, biased toward night.
    float rainFactor;     // Passed through unchanged from the caller's own rain input.
    float sunVisibility;  // Unsquared sibling of sunVisibility2, same band, no bias.
    float sunFactor;      // Asymmetric crossfade: wide below the horizon, narrow above it.
    float nightFactor;    // Inverse-signed driver, peaks at true solar midnight.
};

// =================================================================================================
// Day/rain drivers.

const float PLAGUE_TAU = 6.283185307179586;

// The engine's sun angle is zero at true noon; rotated a quarter turn here so the curve below can
// start at zero at sunrise instead. An API fact, not a design choice — must run before any of the
// curve's own arithmetic.
float plagueTimeAngle(float sunAngleRadians) {
    float sunriseAngle = sunAngleRadians + PLAGUE_TAU * 0.25;
    float dayPhase = fract(sunriseAngle / PLAGUE_TAU); // 0 = sunrise, 0.5 = sunset, wraps at 1.0

    // Wraparound-safe triangular distance from true noon: 0 at noon, 0.25 at either horizon
    // crossing, 0.5 at true midnight.
    float distFromNoon = abs(dayPhase - 0.25);
    distFromNoon = min(distFromNoon, 1.0 - distFromNoon);

    // Re-timed into a plateau-then-fast-turnover shape via smoothstep across two breakpoints
    // straddling the horizon crossing. Fitted to the accepted build (tools/fit_lighting_parity.py,
    // group RMS 28.9% -> 4.4%); a real shape gap remains near the horizon that this construction
    // can't fully close, left as measured rather than forced closer.
    const float PLAGUE_NOON_TRANSITION_INNER = 0.058;
    const float PLAGUE_NOON_TRANSITION_OUTER = 0.268;
    float turnover = smoothstep(PLAGUE_NOON_TRANSITION_INNER, PLAGUE_NOON_TRANSITION_OUTER,
                                 distFromNoon);
    return 1.0 - turnover;
}

// Horizon-straddling band sunVisibility/sunVisibility2 transition across. Fitted to the accepted
// build (tools/fit_lighting_parity.py, group RMS 7.0% -> 3.1%); matches it to floating-point noise
// at this value.
const float PLAGUE_HORIZON_BAND_HALF = 0.082;

// sunFactor's asymmetric band: wider below the horizon than above, so residual sky glow lingers
// into evening twilight while "fully day" saturates almost as soon as the sun clears it. Fitted
// with PLAGUE_HORIZON_BAND_HALF (RMS 7.0% -> 3.1%); the old build's below-horizon falloff is
// closer to linear than this smoothstep band can reach, left as a known shape gap.
const float PLAGUE_SUN_FACTOR_BAND_BELOW = 0.354;
const float PLAGUE_SUN_FACTOR_BAND_ABOVE = 0.211;

struct PlagueDayDrivers {
    float sunVisibility;
    float sunVisibility2;
    float sunFactor;
    float nightFactor;
};

PlagueDayDrivers plagueDayDrivers(float sunElevation) {
    PlagueDayDrivers d;
    d.sunVisibility = smoothstep(-PLAGUE_HORIZON_BAND_HALF, PLAGUE_HORIZON_BAND_HALF, sunElevation);
    d.sunVisibility2 = d.sunVisibility * d.sunVisibility;
    d.sunFactor = smoothstep(-PLAGUE_SUN_FACTOR_BAND_BELOW, PLAGUE_SUN_FACTOR_BAND_ABOVE,
                              sunElevation);
    // Bare clamp of elevation, no constant to fit. Measured against the accepted build anyway
    // (RMS 9.9%, max 19.9% at the horizon) — a real shape difference, left as-is.
    d.nightFactor = clamp(-sunElevation, 0.0, 1.0);
    return d;
}

// =================================================================================================
// The Custom palette: authored fresh against this repo's own render-and-compare tooling, tuned to
// this pack's look by BEHAVIOR only — never against, or derived from, any prior table's numbers.
// Raw, pre-tonemap, linear values, not inflated to compensate for missing bloom/exposure.
//
// The 31 defaults below are additionally fitted (tools/fit_custom_palette.py) so CUSTOM_LIGHT_COLORS-on
// reads as close as this palette's own shape can get to CUSTOM_LIGHT_COLORS-off (an explicit owner
// requirement); see each constant's own note for its target and residual. The palette's SHAPE (a
// two-colour mix per arm) is authored and untouched — only these 31 numbers move.

struct PlagueCustomPalette {
    float ambientNoonExponent;  // Shaping curve on the live sky-colour attribute (noon ambient).
    float ambientNoonMagnitude; // Overall gain on that same shaping curve.
    vec3  ambientSunsetTint;    // Relative tint multiplied onto noon ambient, not an independent colour.
    vec3  ambientNight;         // Independent flat colour.
    vec3  ambientRainDay;       // Independent flat colour.
    vec3  ambientRainNight;     // Independent flat colour.
    vec3  lightNoon;            // Independent flat colour.
    vec3  lightSunset;          // Base colour; warms further as noonFactor falls (see below).
    float lightSunsetWarmth;    // Strength of that warm-walk.
    vec3  lightNight;           // Independent flat colour.
    vec3  lightRainDay;         // Independent flat colour (also shifts slightly with noonFactor).
    vec3  lightRainNight;       // Independent flat colour.
    float lightRainMagnitude;   // Single overall-brightness knob for the whole rain pair.
};

// Shipped defaults for every field above (also baked into the compile-time fallback below).
//
// LIGHT arms fitted against atmosphere.glsl's own plagueSunColor/plagueMoonColor across a 41-point
// elevation grid (tools/fit_custom_palette.py, section "LIGHT arms"): RMS 0.090, max abs 0.354 — a
// genuine shape gap, since the Physical chain's magnitude changes by orders of magnitude near the
// horizon and a two-colour mix can't track that regardless of which colours are chosen. lightNight
// is the moon's antipodal transmittance, a genuine constant across the night grid (atmosphere.glsl
// clamps at the horizon), not a compromise.
const vec3  PLAGUE_LIGHT_NOON_DEFAULT           = vec3(1.3998, 1.1976, 1.0075);
const vec3  PLAGUE_LIGHT_SUNSET_DEFAULT         = vec3(0.6782, 0.4953, 0.2458);
// Fitted to exactly 0.0 (its floor): the Physical target's channels all rise together near the
// horizon, so WARM_TILT's trade-off direction has nothing to gain here — an unconstrained fit
// wanted negative before being bounded.
const float PLAGUE_LIGHT_SUNSET_WARMTH_DEFAULT  = 0.0;
const vec3  PLAGUE_LIGHT_NIGHT_DEFAULT          = vec3(0.0321, 0.0462, 0.0777);
// RAIN arms: atmosphere.glsl has no rain response of its own, so these are the fitted Physical
// clear value at that slice times the accepted build's own measured rain/clear ratio at the same
// slice (tools/fixtures/lighting-behavior-50033de.json) — a behavior fact, not an invented
// expression.
const vec3  PLAGUE_LIGHT_RAIN_DAY_DEFAULT       = vec3(0.3598, 0.3268, 0.4920);
const vec3  PLAGUE_LIGHT_RAIN_NIGHT_DEFAULT     = vec3(0.4699, 0.7939, 1.2417);
const float PLAGUE_LIGHT_RAIN_MAGNITUDE_DEFAULT = 1.0;

// AMBIENT arms: atmosphere.glsl has no ambient/in-scattering term yet, so these are fitted against
// sky.glsl's own zenith/hemisphere blend across the same elevation grid (tools/fit_custom_palette.py,
// section "AMBIENT arms"). RMS 0.096, max abs 0.444 — another shape gap: the real sky's near-horizon
// hue shift is non-monotonic in a way one fixed sunset-tint ratio can't reproduce everywhere.
const float PLAGUE_AMBIENT_NOON_EXPONENT_DEFAULT  = 1.2294;
const float PLAGUE_AMBIENT_NOON_MAGNITUDE_DEFAULT = 1.3615;
const vec3  PLAGUE_AMBIENT_SUNSET_TINT_DEFAULT    = vec3(1.5868, 0.6909, 0.5900);
const vec3  PLAGUE_AMBIENT_NIGHT_DEFAULT          = vec3(0.0589, 0.0289, 0.0609);
const vec3  PLAGUE_AMBIENT_RAIN_DAY_DEFAULT       = vec3(0.4650, 0.4341, 0.6637);
const vec3  PLAGUE_AMBIENT_RAIN_NIGHT_DEFAULT     = vec3(0.0280, 0.0445, 0.1532);

const PlagueCustomPalette PLAGUE_CUSTOM_PALETTE_DEFAULT = PlagueCustomPalette(
    PLAGUE_AMBIENT_NOON_EXPONENT_DEFAULT, PLAGUE_AMBIENT_NOON_MAGNITUDE_DEFAULT,
    PLAGUE_AMBIENT_SUNSET_TINT_DEFAULT, PLAGUE_AMBIENT_NIGHT_DEFAULT,
    PLAGUE_AMBIENT_RAIN_DAY_DEFAULT, PLAGUE_AMBIENT_RAIN_NIGHT_DEFAULT,
    PLAGUE_LIGHT_NOON_DEFAULT, PLAGUE_LIGHT_SUNSET_DEFAULT, PLAGUE_LIGHT_SUNSET_WARMTH_DEFAULT,
    PLAGUE_LIGHT_NIGHT_DEFAULT, PLAGUE_LIGHT_RAIN_DAY_DEFAULT, PLAGUE_LIGHT_RAIN_NIGHT_DEFAULT,
    PLAGUE_LIGHT_RAIN_MAGNITUDE_DEFAULT);

// Warm-walk direction for the sunset/dawn direct-light arm: pulls R up, B down as the day driver
// falls, so hue shifts rather than just brightness. Authored direction, scaled by the
// warmth-strength slider.
const vec3 PLAGUE_LIGHT_SUNSET_WARM_TILT = vec3(0.55, -0.08, -0.30);

// How far the rain-day direct arm shifts toward noon-neutral as noonFactor climbs, small on
// purpose: a secondary shift on a colour the player already chose, not an independently-tunable
// arm.
const vec3 PLAGUE_LIGHT_RAIN_DAY_NOON_SHIFT = vec3(0.08, 0.06, 0.03);

// Maximum lift the accessibility brightness slider adds to the night/rain floors — a floor, never
// a daytime scale, same contract as underwater.glsl's own night-lift constant.
const vec3 PLAGUE_VSBRIGHTNESS_LIGHT_LIFT  = vec3(0.028, 0.030, 0.034);
const vec3 PLAGUE_VSBRIGHTNESS_AMBIENT_LIFT = vec3(0.020, 0.022, 0.026);

// -------------------------------------------------------------------------------------------------
// Full palette-parameterized form; every option-having call site builds its own PlagueCustomPalette
// from its own runtime options and calls this directly.
PlagueLighting plagueOverworldLighting(vec3 skyColor, float sunElevation, float sunAngleRadians,
                                        float rainFactor, float vsBrightness,
                                        PlagueCustomPalette palette) {
    float noonFactor = plagueTimeAngle(sunAngleRadians);
    PlagueDayDrivers day = plagueDayDrivers(sunElevation);
    float rain = clamp(rainFactor, 0.0, 1.0);
    float vsb = clamp(vsBrightness, 0.0, 1.0);

    // --- Direct light -----------------------------------------------------------------------
    float warmK = smoothstep(0.0, 1.0, 1.0 - clamp(noonFactor, 0.0, 1.0));
    vec3 sunsetArm = palette.lightSunset
                    + PLAGUE_LIGHT_SUNSET_WARM_TILT * warmK * palette.lightSunsetWarmth;
    vec3 clearDayLight = mix(sunsetArm, palette.lightNoon, clamp(noonFactor, 0.0, 1.0));
    vec3 nightLight = palette.lightNight + vsb * PLAGUE_VSBRIGHTNESS_LIGHT_LIFT;
    vec3 clearLight = mix(nightLight, clearDayLight, day.sunVisibility2);

    vec3 rainDayLight = palette.lightRainDay
                       + PLAGUE_LIGHT_RAIN_DAY_NOON_SHIFT * clamp(noonFactor, 0.0, 1.0)
                       + vsb * PLAGUE_VSBRIGHTNESS_LIGHT_LIFT;
    vec3 rainNightLight = palette.lightRainNight + vsb * PLAGUE_VSBRIGHTNESS_LIGHT_LIFT;
    vec3 rainLight = mix(rainNightLight, rainDayLight, day.sunVisibility2)
                    * max(palette.lightRainMagnitude, 0.0);

    vec3 light = mix(clearLight, rainLight, rain);

    // --- Ambient ------------------------------------------------------------------------------
    vec3 skyAttr = max(skyColor, vec3(0.0));
    vec3 noonAmbient = pow(skyAttr, vec3(max(palette.ambientNoonExponent, 1e-3)))
                      * max(palette.ambientNoonMagnitude, 0.0);
    vec3 sunsetAmbient = noonAmbient * palette.ambientSunsetTint;
    vec3 clearDayAmbient = mix(sunsetAmbient, noonAmbient, clamp(noonFactor, 0.0, 1.0));
    vec3 nightAmbient = palette.ambientNight + vsb * PLAGUE_VSBRIGHTNESS_AMBIENT_LIFT;
    vec3 clearAmbient = mix(nightAmbient, clearDayAmbient, day.sunVisibility2);

    vec3 rainDayAmbient = palette.ambientRainDay + vsb * PLAGUE_VSBRIGHTNESS_AMBIENT_LIFT;
    vec3 rainNightAmbient = palette.ambientRainNight + vsb * PLAGUE_VSBRIGHTNESS_AMBIENT_LIFT;
    vec3 rainAmbient = mix(rainNightAmbient, rainDayAmbient, day.sunVisibility2);

    vec3 ambient = mix(clearAmbient, rainAmbient, rain);

    PlagueLighting result;
    result.light = light;
    result.ambient = ambient;
    result.vsBrightness = vsb;
    result.noonFactor = noonFactor;
    result.sunVisibility2 = day.sunVisibility2;
    result.rainFactor = rain;
    result.sunVisibility = day.sunVisibility;
    result.sunFactor = day.sunFactor;
    result.nightFactor = day.nightFactor;
    return result;
}

// Fallback for the two call sites with no options buffer (terrain.fsh's forward-lit arms): bakes
// the shipped defaults as compile constants and delegates. Live palette edits don't reach terrain
// through this path.
PlagueLighting plagueOverworldLighting(vec3 skyColor, float sunElevation, float sunAngleRadians,
                                        float rainFactor, float vsBrightness) {
    return plagueOverworldLighting(skyColor, sunElevation, sunAngleRadians, rainFactor, vsBrightness,
                                    PLAGUE_CUSTOM_PALETTE_DEFAULT);
}

// =================================================================================================
// Colour-multiplier grading layer: four time-of-day arms, already combined by the caller into
// colour*intensity vec3s (this file compiles before the resolve's own option block exists, so a
// bare option reference here would be a forward reference), blended by the same weights the base
// table above computed. At every arm's neutral vec3(1.0) the whole chain collapses to the identity
// multiplier exactly.

vec3 plagueLightColorMult(float noonFactor, float sunVisibility2, float rainFactor,
                           vec3 morningLightMult, vec3 noonLightMult,
                           vec3 nightLightMult, vec3 rainLightMult) {
    vec3 clearMult = mix(morningLightMult, noonLightMult, clamp(noonFactor, 0.0, 1.0));
    vec3 dayNightMult = mix(nightLightMult, clearMult, clamp(sunVisibility2, 0.0, 1.0));
    return mix(dayNightMult, rainLightMult, clamp(rainFactor, 0.0, 1.0));
}

vec3 plagueAtmColorMult(float noonFactor, float sunVisibility2, float rainFactor,
                         vec3 morningAtmMult, vec3 noonAtmMult,
                         vec3 nightAtmMult, vec3 rainAtmMult) {
    vec3 clearMult = mix(morningAtmMult, noonAtmMult, clamp(noonFactor, 0.0, 1.0));
    vec3 dayNightMult = mix(nightAtmMult, clearMult, clamp(sunVisibility2, 0.0, 1.0));
    return mix(dayNightMult, rainAtmMult, clamp(rainFactor, 0.0, 1.0));
}

#endif // PLAGUE_LIGHT_AND_AMBIENT_COLORS_INCLUDE
