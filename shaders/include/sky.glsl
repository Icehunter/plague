#ifndef PLAGUE_SKY
#define PLAGUE_SKY

// The dome: an authored palette, keyed on the sun's elevation, not computed live from scattering.
// A pure single-scattering dome measured wrong at the terminator (sunset horizon red-to-blue ratio
// 1.34, not orange) and switched which body lit the sky on a threshold that fired exactly when the
// sunset should be strongest. Day and night keys are still SAMPLED from the scattering model below;
// only the twilight keys (where the model was wrong) are authored by eye — see the palette section.
// No threshold anywhere in the blend: the palette is a continuous function of sun elevation, and
// sunrise/sunset are their own keys with their own span (u_TwilightSpan) so they can't be skipped.

#moj_import <fornax_runtime:atmosphere.glsl>

// --- Tuning ---------------------------------------------------------------------------------------
//
// IMPORT THIS FILE ONLY FROM A FULLSCREEN PASS, or bridge these options into the program's own
// settings block: they arrive through u_PackOptions, which deferred geometry does not receive.
// terrain.fsh does import this file and does bridge them; Fornax's own build check fails if a new
// option here is added without a matching bridge there.

// How long sunrise and sunset last: stretches the palette's fixed-elevation keys around the
// horizon. Matters more here than elsewhere because a Minecraft day is twenty minutes, so the sun
// crosses the horizon in seconds; at 1.0 the arc runs about 16 degrees below the horizon to 25
// above.
#define u_TwilightSpan 1.0 //[0.25..3.00 step 0.05] runtime "Sunset Length"

// How fast the sky falls from its zenith colour to its horizon colour. Low is a flat wash; high
// keeps the zenith colour most of the way down and then turns quickly near the horizon.
#define u_SkyGradient 3.6 //[0.50..8.00 step 0.10] runtime "Sky Gradient"

// How far around the sun the warm horizon band reaches. Low wraps the warmth most of the way around
// the sky; high confines it to a narrow wedge on the sun's own side.
#define u_SunsetBandWidth 1.3 //[0.30..8.00 step 0.10] runtime "Sunset Band Width"

// How tightly the warm band hugs the horizon; low lets the colour climb toward the zenith, which
// is deliberately the default — warmth reaching well up the sky is most of what reads as a sunset
// rather than a bright stripe under a blue dome. Range floor moved to 0.2 after the chosen value
// sat pinned on the old 0.5 floor.
#define u_SunsetBandHeight 0.5 //[0.20..10.00 step 0.10] runtime "Sunset Band Height"

// The halo around each body, in the sky rather than in the bloom pass, so it reads as air rather
// than as a lens. Strength is how bright, tightness is how far it spreads.
#define u_SunGlowStrength 1.20 //[0.00..3.00 step 0.05] runtime "Sun Glow"
#define u_SunGlowTightness 90.0 //[4.00..400.00 step 2.00] runtime "Sun Glow Tightness"
#define u_MoonGlowStrength 0.80 //[0.00..3.00 step 0.05] runtime "Moon Glow"
#define u_MoonGlowTightness 240.0 //[4.00..400.00 step 2.00] runtime "Moon Glow Tightness"

// Overall dome brightness. Not a look value in the way the palette is: it is the same exposure
// stand-in the sun and moon gains are, and it retires with them when metering lands.
#define u_SkyBrightness 1.0 //[0.00..3.00 step 0.05] runtime "Sky Brightness"

// Warmth toward a blackbody at the temperature below, so a scalar slider names an actual colour
// rather than a taste. Applied only to the sunward band near the horizon, weighted by closeness to
// the sunset key — inert at noon and midnight. Temperature's range floor moved to 1000 K after the
// default sat pinned on the old 1500 K floor.
#define u_SunsetSkyWarmth 0.85 //[0.00..1.00 step 0.05] runtime "Sunset Sky Warmth"
#define u_SunsetTemp 1500.0 //[1000.0..4500.0 step 50.0] runtime "Sunset Colour Temperature"

// The same warmth applied to the LIGHT (sunlight and bounced ambient) instead of the sky —
// separate slider because a sky can be as orange as you like while lighting the ground neutrally.
#define u_SunsetLightWarmth 0.45 //[0.00..1.00 step 0.05] runtime "Sunset Light Warmth"

// How much of the WHOLE DOME the ambient is taken from, vs. the zenith alone. 1 is physically
// honest (a surface is lit by the entire hemisphere); matters most at sunset, when the dome's
// brightest region and its bluest are as far apart as they get.
#define u_AmbientSkyBleed 1.0 //[0.00..1.00 step 0.05] runtime "Sky Ambient Spread"

// How much vanilla's biome sky colour nudges the dome's hue. Brightness is divided out first so it
// can only move hue, which is also what lets it survive a thunderstorm (vanilla's value falls to
// zero there; a plain multiply would follow it to black).
#define u_SkyBiomeTint 0.25 //[0.00..1.00 step 0.05] runtime "Biome Sky Tint"

// --- The palette ------------------------------------------------------------------------------------
//
// Five keys, each a zenith / horizon / sunward triple, at the sun elevations below.
//
// DAY and NIGHT are SAMPLED from this pack's own scattering model (atmosphere.glsl plus the
// single-scatter integral in tools/derive_sky.py) — the keys the physics got right.
// GOLDEN, SUNSET and DUSK are AUTHORED by eye: the model's answers there were wrong (sunset
// red-to-blue ratio 1.34; a uniformly grey-green dusk dome). These are this pack's own colours.
//
// Ordered night to day; the phase coordinate below indexes them in that order.
const float PLAGUE_SKY_KEY_NIGHT  = -0.28;   // sine of the sun's elevation, about -16 degrees
const float PLAGUE_SKY_KEY_DUSK   = -0.10;   // about -6 degrees
const float PLAGUE_SKY_KEY_SUNSET =  0.00;   // on the horizon
const float PLAGUE_SKY_KEY_GOLDEN =  0.14;   // about +8 degrees
const float PLAGUE_SKY_KEY_DAY    =  0.42;   // about +25 degrees

// SAMPLED: what the scattering model gives with the moon overhead.
const vec3 PLAGUE_SKY_NIGHT_ZENITH = vec3(0.0026, 0.0057, 0.0268);
const vec3 PLAGUE_SKY_NIGHT_HORIZON = vec3(0.0133, 0.0216, 0.0531);
const vec3 PLAGUE_SKY_NIGHT_SUNWARD = vec3(0.0140, 0.0229, 0.0555);

// THE HORIZON KEYS STAY COOL. HORIZON is omnidirectional (the whole ring around you); putting
// warmth there paints a pink haze in every direction and leaves nothing cool for the sunset to
// stand against. All the warmth lives in SUNWARD instead, which applies only on the sun's side.

// AUTHORED. The last of the light: cool almost everywhere, one ember where the sun went down.
const vec3 PLAGUE_SKY_DUSK_ZENITH   = vec3(0.0420, 0.0560, 0.1200);
const vec3 PLAGUE_SKY_DUSK_HORIZON  = vec3(0.0950, 0.1080, 0.1900);
const vec3 PLAGUE_SKY_DUSK_SUNWARD  = vec3(0.7000, 0.2100, 0.1200);

// AUTHORED: the sun on the horizon. The sunward value is what this whole file exists to deliver,
// and it is deliberately over 1 so it carries into the bloom the way a real low sun does.
const vec3 PLAGUE_SKY_SUNSET_ZENITH  = vec3(0.1450, 0.2050, 0.4400);
const vec3 PLAGUE_SKY_SUNSET_HORIZON = vec3(0.3200, 0.3450, 0.5200);
const vec3 PLAGUE_SKY_SUNSET_SUNWARD = vec3(2.6000, 0.7000, 0.1500);

// AUTHORED: the low sun before it touches. This is the golden hour, and it is the key that was
// missing entirely: gold on the sun's side, a pale warm-white horizon elsewhere, blue still overhead.
const vec3 PLAGUE_SKY_GOLDEN_ZENITH  = vec3(0.2150, 0.3050, 0.6600);
const vec3 PLAGUE_SKY_GOLDEN_HORIZON = vec3(0.7400, 0.7600, 0.8600);
const vec3 PLAGUE_SKY_GOLDEN_SUNWARD = vec3(2.9000, 1.5000, 0.4200);

// SAMPLED: what the scattering model gives with the sun at sixty degrees.
const vec3 PLAGUE_SKY_DAY_ZENITH = vec3(0.2731, 0.3865, 0.8815);
const vec3 PLAGUE_SKY_DAY_HORIZON = vec3(1.3994, 1.4541, 1.7448);
const vec3 PLAGUE_SKY_DAY_SUNWARD = vec3(1.5034, 1.5689, 1.8802);

// Overcast: what the dome is dragged toward, and how far. Grey and flat, because a cloud deck is
// what you are actually looking at and it has no gradient of its own worth speaking of.
const vec3 PLAGUE_SKY_OVERCAST = vec3(0.30, 0.32, 0.35);
const float PLAGUE_SKY_RAIN_FLATTEN = 0.80;

// The one number here that is not a look value: solved so the dome's cosine-weighted average at
// noon matches the pack's fixed exposure (the average, not any single direction, since a palette
// and a gradient differ most in distribution). Re-solves with the palette via tools/derive_sky.py.
// Retires with u_Exposure when metering lands.
const float PLAGUE_SKY_LUMINANCE = 1.1253;

/** Everything about the sky that does not depend on which way you are looking. */
struct PlagueSkyColors {
    vec3 zenith;      // the palette resolved for this instant
    vec3 horizon;
    vec3 sunward;
    vec3 glow;        // halo colour, warm by day and cool at night
    float lightUp;    // the TRUE sun's elevation, as a cosine from the zenith
    float dayWeight;  // 1 once the sun is up, 0 deep in the night, continuous between
    float rainFactor;
};

// Where in the palette this instant sits, 0 (full night) to 4 (full day). Sum of smoothsteps, one
// per adjacent key pair, each flat below its own range and flat above — monotone, exact at every
// key, no corner anywhere: no single frame where the sky jumps, unlike a threshold pick between
// two bodies.
float plagueSkyPhase(float sunUp) {
    float span = max(u_TwilightSpan, 0.05);
    float night = PLAGUE_SKY_KEY_NIGHT * span;
    float dusk = PLAGUE_SKY_KEY_DUSK * span;
    float sunset = PLAGUE_SKY_KEY_SUNSET * span;
    float golden = PLAGUE_SKY_KEY_GOLDEN * span;
    float day = PLAGUE_SKY_KEY_DAY * span;

    return smoothstep(night, dusk, sunUp)
         + smoothstep(dusk, sunset, sunUp)
         + smoothstep(sunset, golden, sunUp)
         + smoothstep(golden, day, sunUp);
}

// Triangle centred on the sunset key, deliberately wider than one key so the golden and dusk keys
// still get 0.4 of it rather than zero. Shared by the sky's warmth and the light's, so the two
// cannot disagree about when a sunset is.
float plagueSunsetWeight(float phase) {
    return max(1.0 - abs(phase - 2.0) * 0.6, 0.0);
}

/** The palette entry at a phase coordinate, by successive mixes: exact at every key. */
vec3 plagueSkyKey(float phase, vec3 night, vec3 dusk, vec3 sunset, vec3 golden, vec3 day) {
    vec3 c = mix(night, dusk, clamp(phase, 0.0, 1.0));
    c = mix(c, sunset, clamp(phase - 1.0, 0.0, 1.0));
    c = mix(c, golden, clamp(phase - 2.0, 0.0, 1.0));
    c = mix(c, day, clamp(phase - 3.0, 0.0, 1.0));
    return c;
}

/**
 * Radiance from one direction, before the glow and the dither.
 *
 * @param VdotU view dotted with world up: +1 zenith, 0 level, -1 straight down
 * @param VdotS view dotted with the TRUE sun; positive on the sun's side at any hour
 */
vec3 plagueSkyRadiance(PlagueSkyColors c, float VdotU, float VdotS) {
    float up = clamp(VdotU, -1.0, 1.0);

    // Raised to a power rather than mixed linearly, so the horizon colour stays a band at the
    // bottom of the sky instead of washing halfway up it.
    float toHorizon = pow(1.0 - max(up, 0.0), max(u_SkyGradient, 0.05));
    vec3 sky = mix(c.zenith, c.horizon, toHorizon);

    // Two separate falloffs (how far around, how high) so a sunset reads as a band, not a smear.
    float band = pow(max(1.0 - abs(up), 0.0), max(u_SunsetBandHeight, 0.05))
               * pow(max(VdotS, 0.0), max(u_SunsetBandWidth, 0.05));
    sky = mix(sky, c.sunward, clamp(band, 0.0, 1.0));

    return sky;
}

/**
 * The dome as a fragment sees it.
 *
 * @param dither   per-pixel 0..1. A dome is a smooth gradient across thousands of pixels, which is
 *                 where 8-bit banding shows first and worst.
 * @param doGlow   the halo around whichever body is up. Off for AMBIENT samples: ambient asks what
 *                 the sky is worth on average, and a sample that landed near the sun would answer
 *                 with the halo and light the whole world from it.
 * @param doGround fade below the horizon toward what the ground bounces back, for sites that see
 *                 under it. Off leaves the sky's own value there, which reflections want.
 */
vec3 plagueGetSky(PlagueSkyColors c, float VdotU, float VdotS, float dither,
                  bool doGlow, bool doGround) {
    vec3 sky = plagueSkyRadiance(c, VdotU, VdotS);

    if (doGlow) {
        // Sun at +VdotS, moon at -VdotS (vanilla's convention), each weighted by how far into its
        // own half of the day we are so neither appears or vanishes at a threshold.
        float sun = pow(max(VdotS, 0.0), max(u_SunGlowTightness, 1.0))
                  * u_SunGlowStrength * c.dayWeight;
        float moon = pow(max(-VdotS, 0.0), max(u_MoonGlowTightness, 1.0))
                   * u_MoonGlowStrength * (1.0 - c.dayWeight);
        sky += c.glow * ((sun + moon) * (1.0 - c.rainFactor * 0.8));
    }

    if (doGround) {
        float below = clamp(-VdotU / 0.25, 0.0, 1.0);
        below = below * below * (3.0 - 2.0 * below);
        sky = mix(sky, plagueSkyRadiance(c, 0.0, VdotS) * 0.28, below);
    }

    sky += (dither - 0.5) / 128.0;
    return max(sky, vec3(0.0));
}

/**
 * The view-independent half, shared by every direction a fragment asks about (dome, fog, missed
 * reflection, zenith ambient), so they cannot disagree — hence a struct, not four separate calls.
 *
 * @param skyColor      vanilla's biome sky attribute, used only as a hue nudge
 * @param lightDirTrue  the TRUE sun direction, NEVER the active light — the moon at midnight sits
 *                      where the sun sits at noon, and keying off the active light has shipped that
 *                      exact bug before (sky built as noon at midnight)
 * @param sunVisibility accepted and deliberately not branched on; see below
 * @param cameraY       accepted and unused — the palette does not thin with altitude; kept so call
 *                      sites need not change if that becomes worth modelling
 */
PlagueSkyColors plagueSkyColors(vec3 skyColor, vec3 lightDirTrue, float sunVisibility,
                                float rainFactor, float cameraY) {
    PlagueSkyColors c;

    float rain = clamp(rainFactor, 0.0, 1.0);
    c.rainFactor = rain;
    c.lightUp = clamp(lightDirTrue.y, -1.0, 1.0);

    // Elevation, not sunVisibility: elevation is continuous, while a threshold on sunVisibility
    // fires exactly as the sun crosses the horizon — the moment a sunset needs to be smoothest.
    // sunVisibility stays in the signature for callers that already compute it, but nothing here
    // branches on it.
    float phase = plagueSkyPhase(c.lightUp);

    c.zenith = plagueSkyKey(phase, PLAGUE_SKY_NIGHT_ZENITH, PLAGUE_SKY_DUSK_ZENITH,
                            PLAGUE_SKY_SUNSET_ZENITH, PLAGUE_SKY_GOLDEN_ZENITH,
                            PLAGUE_SKY_DAY_ZENITH);
    c.horizon = plagueSkyKey(phase, PLAGUE_SKY_NIGHT_HORIZON, PLAGUE_SKY_DUSK_HORIZON,
                             PLAGUE_SKY_SUNSET_HORIZON, PLAGUE_SKY_GOLDEN_HORIZON,
                             PLAGUE_SKY_DAY_HORIZON);
    c.sunward = plagueSkyKey(phase, PLAGUE_SKY_NIGHT_SUNWARD, PLAGUE_SKY_DUSK_SUNWARD,
                             PLAGUE_SKY_SUNSET_SUNWARD, PLAGUE_SKY_GOLDEN_SUNWARD,
                             PLAGUE_SKY_DAY_SUNWARD);

    // Toward a blackbody at the chosen temperature, normalised so it moves hue and leaves
    // brightness to the key.
    float warmWeight = plagueSunsetWeight(phase) * u_SunsetSkyWarmth;
    if (warmWeight > 0.0) {
        vec3 warmRef = plagueBlackbody(u_SunsetTemp);
        float sunwardLuma = max(dot(c.sunward, vec3(0.2126, 0.7152, 0.0722)), 1e-4);
        c.sunward = mix(c.sunward, warmRef * sunwardLuma, warmWeight);
    }

    // Reaches 1 AT the sunset key, not halfway past it: the sun's halo is largest and most useful
    // right on the horizon.
    c.dayWeight = clamp(phase - 1.0, 0.0, 1.0);

    // Halo takes the sunward HUE, normalised then scaled by the horizon key's own luminance —
    // not to unit luminance, which made the moon's halo ~40x brighter than the sky around it (night
    // sky ~0.007, day sky ~1.5). Scaling by horizon luminance makes both sliders mean the same
    // thing at any hour: what fraction of the sky's own brightness the halo peaks at.
    float skyLevel = max(dot(c.horizon, vec3(0.2126, 0.7152, 0.0722)), 1e-4);
    c.glow = c.sunward / max(dot(c.sunward, vec3(0.2126, 0.7152, 0.0722)), 1e-4) * skyLevel;

    // Drags the palette's keys themselves toward flat grey rather than laying a sheet over the
    // top, so a rainy sunset is a dull orange rather than an orange behind grey.
    float flatten = rain * PLAGUE_SKY_RAIN_FLATTEN;
    vec3 overcast = PLAGUE_SKY_OVERCAST * max(c.dayWeight, 0.04);
    c.zenith = mix(c.zenith, overcast, flatten);
    c.horizon = mix(c.horizon, overcast, flatten);
    c.sunward = mix(c.sunward, overcast, flatten);

    // Faded out by the colour's own MAGNITUDE, not clamped per channel — per-channel clamping hits
    // the floor at different moments for each channel (blue above it, red already pinned) and the
    // normalised hue visibly lurches before snapping to neutral at dusk.
    float biomeLevel = dot(max(skyColor, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
    vec3 biome = biomeLevel > 1e-3 ? skyColor / biomeLevel : vec3(1.0);
    float biomeFade = smoothstep(0.0, 0.02, biomeLevel);
    vec3 tint = mix(vec3(1.0), biome, u_SkyBiomeTint * (1.0 - rain) * biomeFade);

    float gain = PLAGUE_SKY_LUMINANCE * u_SkyBrightness;
    c.zenith *= tint * gain;
    c.horizon *= tint * gain;
    c.sunward *= tint * gain;
    c.glow *= tint * gain;

    return c;
}

// Representative radiances at fixed directions, for consumers that want "the colour of the sky"
// without a direction to ask about: haze lit by the whole dome, cloud bases lit from below. No
// glow on any of them — a halo is the least average part of a sky. They take VdotS because
// distance haze IS the sky and must warm on the sun's side too; sampling straight ahead makes a
// correctly-rendered sunset invisible behind a wall of haze that doesn't know where the sun is.

// Warms a light colour toward the same reference the sky uses. Luminance-preserving, so turning it
// up moves hue without quietly changing exposure. Keyed on the sky's own phase, so light and sky
// can't disagree about the time of day.
vec3 plagueWarmLowSun(vec3 light, float sunUp) {
    float weight = plagueSunsetWeight(plagueSkyPhase(sunUp)) * u_SunsetLightWarmth;
    if (weight <= 0.0) {
        return light;
    }
    float luma = max(dot(light, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
    return mix(light, plagueBlackbody(u_SunsetTemp) * luma, weight);
}

/**
 * The whole visible dome, cosine-weighted: what a flat upward-facing surface is actually lit by.
 * This is what ambient wants — sampling the zenith alone lit a sunset with its bluest, least
 * representative direction and lost the warm bounce off water and open ground.
 *
 * Five samples: the zenith plus two elevations on each side of the sun, enough to carry the
 * sun-side asymmetry; more samples move the answer by less than the dither does.
 *
 * @param sunUp the TRUE sun's elevation cosine, needed to turn each sample's azimuth into a VdotS
 */
vec3 plagueSkyHemisphere(PlagueSkyColors c, float sunUp) {
    float horizontalSun = sqrt(max(1.0 - sunUp * sunUp, 0.0));

    // (elevation sine, cosine, azimuth sign toward the sun, cosine weight)
    const vec4 SAMPLES[5] = vec4[](
        vec4(1.000, 0.000,  0.0, 0.30),   // zenith
        vec4(0.819, 0.574,  1.0, 0.22),   // 55 degrees, sunward
        vec4(0.819, 0.574, -1.0, 0.22),   // 55 degrees, away
        vec4(0.423, 0.906,  1.0, 0.16),   // 25 degrees, sunward
        vec4(0.423, 0.906, -1.0, 0.10)    // 25 degrees, away
    );

    vec3 total = vec3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 5; i++) {
        float VdotU = SAMPLES[i].x;
        float VdotS = SAMPLES[i].y * SAMPLES[i].z * horizontalSun + VdotU * sunUp;
        total += plagueSkyRadiance(c, VdotU, VdotS) * SAMPLES[i].w;
        weight += SAMPLES[i].w;
    }
    return total / weight;
}

vec3 plagueSkyAnchorUp(PlagueSkyColors c, float VdotS) {
    return plagueSkyRadiance(c, 1.0, VdotS);
}
vec3 plagueSkyAnchorMiddle(PlagueSkyColors c, float VdotS) {
    return plagueSkyRadiance(c, 0.7071, VdotS);
}
vec3 plagueSkyAnchorDown(PlagueSkyColors c, float VdotS) {
    return plagueSkyRadiance(c, 0.05, VdotS);
}

#endif // PLAGUE_SKY
