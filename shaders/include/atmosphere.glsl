#ifndef PLAGUE_ATMOSPHERE
#define PLAGUE_ATMOSPHERE

// The air itself: how much of it a ray of light passes through, and what survives the trip.
//
// Nothing here chooses a colour: sunset is orange because a low sun crosses more air and blue
// scatters out first; twilight's blue band is ozone absorbing hardest at the Chappuis peak
// (~600nm); moonlight reads cool from the Purkinje shift (rod vision peaks 48nm shorter than
// cone), not because the Moon is blue (it is faintly red).
//
// EVERY CONSTANT BELOW IS AN OUTPUT OF tools/derive_atmosphere.py. Change the physics there and
// paste its block back; tools/verify_atmosphere.py re-checks the derivation against five published
// anchors (Rayleigh optical depth at 550nm, ozone optical depth at the Chappuis peak, refractive
// index of air, Planckian locus at CIE Illuminant A and D65) on every run.
//
// Sources: Peck & Reeder 1972 (dispersion), Bodhaine et al. 1999 (Rayleigh coefficient), Serdyuchenko
// et al. 2014 (ozone cross-sections), US Standard Atmosphere 1976 (density and scale height),
// Bruneton & Neyret 2008 (aerosol layer), Kim et al. 2002 (Planckian locus), CIE photopic/scotopic
// luminosity functions.
//
// No multiplier sits on top of a measured coefficient: that would be an authored colour wearing a
// physicist's coat, uncheckable against any anchor. Free parameters (how much air, haze, ozone) are
// sliders with a physical meaning and neutral default, never folded into a coefficient.

// --- Tuning ---------------------------------------------------------------------------------------
//
// Six live sliders; each moves a quantity that genuinely varies in the real atmosphere, so none can
// push the model somewhere unphysical, only somewhere with different weather.
//
// IMPORT ONLY FROM A FULLSCREEN PASS: these reach the shader via u_PackOptions, which deferred
// geometry shaders don't receive, so from a geometry shader every slider below silently falls back
// to its compile-time default. tools/verify_atmosphere.py keeps it that way.

// Multiplies the whole molecular column (surface pressure). Up = longer Rayleigh path = deeper blue
// overhead, warmer low sun — the lever for sunset warmth; there's no separate orange constant.
#define u_AirDensity 1.0 //[0.25..4.00 step 0.05] runtime "Air Density"

// Aerosol load (dust/salt/smoke/humidity), grey/non-spectral so it hazes without tinting. 1.0 is a
// clear continental day.
#define u_AirTurbidity 1.0 //[0.00..8.00 step 0.10] runtime "Haze"

// Ozone column, multiples of the 300 Dobson global mean. The twilight control: the only term that
// absorbs mid-visible-band, keeping the post-sunset sky blue instead of grey.
#define u_AirOzone 1.0 //[0.00..3.00 step 0.05] runtime "Ozone"

// Overall gain on sunlight and moonlight. Not physics, see the calibration note below.
#define u_SunIntensity 1.0 //[0.00..3.00 step 0.05] runtime "Sun Intensity"
#define u_MoonIntensity 1.0 //[0.00..3.00 step 0.05] runtime "Moon Intensity"

// How far the eye has shifted to rod vision at night. 1.0 is the full Purkinje shift (cool
// moonlight); 0.0 shows moonlight as a camera would record it (slightly warm).
#define u_NightScotopic 1.0 //[0.00..1.00 step 0.05] runtime "Night Color Shift"

// --- Derived constants (tools/derive_atmosphere.py) -----------------------------------------------

// Per-metre coefficients at sea level, integrated across each sRGB primary's band rather than
// point-sampled (lambda^-4 varies 2.4x across the blue band alone).
const vec3  PLAGUE_RAYLEIGH_SCATTER   = vec3(8.433571e-06, 1.310345e-05, 2.786892e-05);
const vec3  PLAGUE_OZONE_ABSORB       = vec3(2.156649e-06, 1.543816e-06, 2.924076e-07);
// Aerosols scatter near wavelength-independently (why haze is grey); extinction exceeds scattering
// since they also absorb, the ratio being the single-scattering albedo. Only EXTINCT is read today
// (transmittance only) — SCATTER awaits the in-scattering integration but is kept here so the pair
// stays derived together.
const float PLAGUE_AEROSOL_SCATTER    = 2.100000e-05;
const float PLAGUE_AEROSOL_EXTINCT    = 2.333333e-05;

const float PLAGUE_SCALE_HEIGHT_AIR   = 8500.0;
const float PLAGUE_SCALE_HEIGHT_HAZE  = 1200.0;
const float PLAGUE_OZONE_PEAK_ALT     = 25000.0;
const float PLAGUE_OZONE_HALF_WIDTH   = 15000.0;

const float PLAGUE_PLANET_RADIUS      = 6371000.0;
const float PLAGUE_ATMOSPHERE_DEPTH   = 100000.0;
const float PLAGUE_ATMOSPHERE_TOP     = PLAGUE_PLANET_RADIUS + PLAGUE_ATMOSPHERE_DEPTH;

// Sun's nominal effective temperature; its colour comes out of plagueBlackbody at this value, the
// same function torchlight uses.
const float PLAGUE_SUN_TEMPERATURE    = 5772.0;

// Per-channel gain from the eye's peak shifting 555nm->507nm, and the Moon's own reflectance; both
// luminance-normalised (hue only). Signs oppose: the Moon is warm, the dark-adapted eye cool, and
// the eye wins.
const vec3  PLAGUE_SCOTOPIC_SHIFT     = vec3(0.5660, 0.9868, 2.4085);
const vec3  PLAGUE_LUNAR_ALBEDO_TINT  = vec3(1.0984, 0.9885, 0.8238);

/*
 * The two numbers here that are NOT physics. Real sky luminance spans ~9 orders of magnitude
 * between noon and moonless night, but the pack has one fixed exposure; until metering lands, these
 * place the model's output into the range that exposure was tuned against, each being the scale that
 * reproduces the zenith brightness the pack already had. Deliberate: the batch that changes how
 * light COLOUR is derived shouldn't also change how bright the world is. Retires the same way
 * u_Exposure does, once real metering lands.
 */
const float PLAGUE_SUN_LUMINANCE      = 1.3453;
const float PLAGUE_MOON_LUMINANCE     = 0.0889;

// --- Density and transmittance --------------------------------------------------------------------

/*
 * The density profile this model assumes no longer appears as code here — it's baked into the
 * fitted curve below and lives as executable code in tools/derive_atmosphere.py. Air and aerosol
 * fall off exponentially from the ground (aerosol ~7x faster, why haze hugs the surface); ozone is a
 * tent layer peaking in the stratosphere, and its half-width sets the peak density that reproduces a
 * published 300 DU column — change the width without re-running the script and the column silently
 * stops being 300 DU.
 */

/*
 * Column-along-a-ray integral, no longer marched: sky.glsl needs several directions per fragment on
 * heavily overdrawn translucent geometry, unaffordable there or here. Replaced by a fitted AIRMASS
 * curve, Kasten & Young's (1989) functional form with coefficients refit to this model's own
 * clean-exponential integral (their published ones are ~10% off at the horizon here, fitted to the
 * real atmosphere's temperature structure instead). One coefficient set per component, since air,
 * haze and ozone have very different vertical extents and horizon behaviour.
 *
 * tools/derive_atmosphere.py still integrates directly and verify_atmosphere.py re-checks these
 * against it on every run; worst error zenith-to-horizon is 0.15%/0.16%/0.42% (air/haze/ozone).
 */
const vec3  PLAGUE_AIRMASS_A          = vec3(1.229951, 0.058707, 7.371668);
const vec3  PLAGUE_AIRMASS_B          = vec3(98.0000, 92.7500, 99.2500);
const vec3  PLAGUE_AIRMASS_C          = vec3(1.80000, 1.66000, 2.00000);

/**
 * Column density of each component along a ray leaving `eyeHeight` at `cosZenith`.
 *
 * @param cosZenith   the ray's elevation as a cosine from the zenith: 1 up, 0 level
 * @param eyeHeight metres above sea level, which is y=0 in this model and y=64 in Minecraft's
 * @param amounts     per-component column multipliers. Passed rather than read from the sliders so
 *                    a caller can ask about air that is not the air outside: overcast, which is
 *                    the same atmosphere with far more water in it, is exactly that call.
 *
 * Clamped at the horizon (not extrapolated): below it the ray hits the planet, which is the
 * caller's problem, not the air's.
 */
vec3 plagueAirColumn(float cosZenith, float eyeHeight, vec3 amounts) {
    float zenithDeg = min(degrees(acos(clamp(cosZenith, -1.0, 1.0))), 90.0);
    vec3 airmass = 1.0 / (vec3(cos(radians(zenithDeg)))
            + PLAGUE_AIRMASS_A * pow(PLAGUE_AIRMASS_B - vec3(zenithDeg), -PLAGUE_AIRMASS_C));

    // Vertical column each airmass multiplies. Air/haze thin as the camera climbs (a fifth of the
    // haze sits below you at the build limit), why a mountain top is clearer than a valley floor.
    vec3 vertical = vec3(PLAGUE_SCALE_HEIGHT_AIR * exp(-eyeHeight / PLAGUE_SCALE_HEIGHT_AIR),
                         PLAGUE_SCALE_HEIGHT_HAZE * exp(-eyeHeight / PLAGUE_SCALE_HEIGHT_HAZE),
                         PLAGUE_OZONE_HALF_WIDTH);

    return vertical * airmass * amounts;
}

/** The same, with the air that is actually outside. */
vec3 plagueAirColumn(float cosZenith, float eyeHeight) {
    return plagueAirColumn(cosZenith, eyeHeight, vec3(u_AirDensity, u_AirTurbidity, u_AirOzone));
}

/** Optical depth of a column: what each component takes out of a ray passing through it. */
vec3 plagueAirExtinction(vec3 column) {
    return PLAGUE_RAYLEIGH_SCATTER * column.x
         + PLAGUE_AEROSOL_EXTINCT * column.y
         + PLAGUE_OZONE_ABSORB * column.z;
}

/**
 * Beer-Lambert transmittance on the column. High sun = short path = near-white; low sun's path is
 * an order of magnitude longer and blue goes first (3.3x red's coefficient), leaving orange — no
 * table or time-of-day curve involved.
 */
vec3 plagueAirTransmittance(float cosZenith, float eyeHeight) {
    return exp(-plagueAirExtinction(plagueAirColumn(cosZenith, eyeHeight)));
}

/**
 * Eye position in planet-centred coordinates. Minecraft sea level (y=64) maps directly onto this
 * model's altitude 0. Floored at 1m so a camera in a ravine can't end up inside the planet, which
 * would invert the whole integration.
 */
vec3 plagueAirEyePos(float cameraY) {
    return vec3(0.0, PLAGUE_PLANET_RADIUS + max(cameraY, 1.0), 0.0);
}

// --- Emitter colour -------------------------------------------------------------------------------

/**
 * Blackbody colour at a temperature: Planckian locus in CIE xy (published piecewise cubic fit),
 * through to sRGB. Unit luminance, so callers scale brightness without moving hue.
 *
 * PIECEWISE IN BOTH COORDINATES: a widely-copied single-branch version costs ~0.018 in y by 6500K,
 * visibly off-locus, and this pack's block-light slider reaches 8000K. Anchored against CIE
 * Illuminant A and D65 (tools/derive_atmosphere.py), which catches that.
 *
 * One function serves every emitter: candle at 1900K, torch at 4000K, the Sun at 5772K. Block light
 * isn't an authored orange — it's what a warm incandescent actually is.
 */
vec3 plagueBlackbody(float temperature) {
    float kelvin = max(temperature, 1000.0);
    float inv = 1.0 / kelvin;
    float inv2 = inv * inv;
    float inv3 = inv2 * inv;

    float chromaX = kelvin < 4000.0
            ? dot(vec4(-0.2661239e9, -0.2343589e6, 0.8776956e3, 0.179910),
                  vec4(inv3, inv2, inv, 1.0))
            : dot(vec4(-3.0258469e9, 2.1070379e6, 0.2226347e3, 0.240390),
                  vec4(inv3, inv2, inv, 1.0));

    vec4 chromaYFit;
    if (kelvin < 2222.0) {
        chromaYFit = vec4(-1.1063814, -1.34811020, 2.18555832, -0.20219683);
    } else if (kelvin < 4000.0) {
        chromaYFit = vec4(-0.9549476, -1.37418593, 2.09137015, -0.16748867);
    } else {
        chromaYFit = vec4(3.0817580, -5.87338670, 3.75112997, -0.37001483);
    }

    float x2 = chromaX * chromaX;
    float chromaY = dot(chromaYFit, vec4(x2 * chromaX, x2, chromaX, 1.0));

    // xyY at Y = 1 into XYZ, then into the pack's working space.
    float safeY = max(chromaY, 1e-4);
    vec3 xyz = vec3(chromaX / safeY, 1.0, (1.0 - chromaX - chromaY) / safeY);

    const mat3 XYZ_TO_LINEAR_SRGB = mat3(
         3.2404542, -0.9692660,  0.0556434,
        -1.5371385,  1.8760108, -0.2040259,
        -0.4985314,  0.0415560,  1.0572252);

    vec3 linear = max(XYZ_TO_LINEAR_SRGB * xyz, vec3(0.0));
    return linear / max(dot(linear, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
}

/**
 * Sunlight reaching the eye: the Sun's own spectrum, minus whatever the air took out of it.
 *
 * @param sunDir unit vector toward the Sun
 */
vec3 plagueSunColor(vec3 airEyePos, vec3 sunDir) {
    return plagueAirTransmittance(sunDir.y, length(airEyePos) - PLAGUE_PLANET_RADIUS)
            * plagueBlackbody(PLAGUE_SUN_TEMPERATURE)
            * (PLAGUE_SUN_LUMINANCE * u_SunIntensity);
}

/**
 * Moonlight reaching the eye, same path and air as sunlight. Three factors past the transmittance:
 * sunlight (what the Moon has to work with), the regolith's mild red reflectance (moonlight leaves
 * the Moon slightly WARM, opposite the usual depiction), then the eye's rod vision taking over as
 * cones drop out (peaking 48nm shorter) — that last step is what makes night blue, and
 * u_NightScotopic is how far it's allowed to go.
 */
vec3 plagueMoonColor(vec3 airEyePos, vec3 moonDir) {
    vec3 reflected = plagueAirTransmittance(moonDir.y, length(airEyePos) - PLAGUE_PLANET_RADIUS)
            * plagueBlackbody(PLAGUE_SUN_TEMPERATURE)
            * PLAGUE_LUNAR_ALBEDO_TINT;
    vec3 adapted = reflected * mix(vec3(1.0), PLAGUE_SCOTOPIC_SHIFT, u_NightScotopic);
    return adapted * (PLAGUE_MOON_LUMINANCE * u_MoonIntensity);
}

#endif // PLAGUE_ATMOSPHERE
