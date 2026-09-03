#ifndef PLAGUE_ATMO_LUT
#define PLAGUE_ATMO_LUT

// The scattering tables: what the air between the eye and the sky does to light, integrated
// rather than fitted. Three small textures, rewritten every frame by the atmo_* compute
// passes and sampled by whoever needs the sky in a direction.
//
//   atmoTransmittance  what survives from a point in the air to the top of the atmosphere
//   atmoMultiScatter   light that has bounced more than once before reaching a point, per unit sun
//   atmoSkyView        the dome as the camera sees it this frame: in-scatter along every ray
//   atmoAerial         the same march bounded at each screen froxel's depth: aerial perspective
//
// Method: Hillaire 2020, "A Scalable and Production Ready Sky and Atmosphere Rendering Technique"
// (EGSR). Transmittance table parameterisation: Bruneton & Neyret 2008 §4 (unit-range altitude and
// distance to the top, exact at the horizon). Media coefficients and profiles: atmosphere.glsl.
// Every writer/reader pair below shares one mapping function so a compute pass and a fullscreen
// pass cannot disagree about which texel means which direction.
//
// This include tests no compile option and must not: an import is spliced before the program's own
// defines, so a #if here would silently read 0. The program decides whether to sample.
//
// How a table is read is the program's. The engine binds a storage target to a compute pass as a
// storage image (imageLoad, no filtering) and to a fullscreen pass as a sampler (texture()), so the
// same read cannot be written here once. A reader declares, before the import, which tables it
// reads (PLAGUE_ATMO_READS_TRANSMITTANCE / _MULTISCATTER / _SKYVIEW) and then defines the matching
// plagueAtmoFetch*(vec2 uv) after it, returning the texel at texture()'s own footprint; a compute
// reader builds that from imageLoad with plagueAtmoBilinearSetup and plagueAtmoBilinearMix below.
//
// Twin: tools/plague_atmo_lut.py, function for function; tools/verify_atmo_lut.py checks it.

#moj_import <fornax_runtime:atmosphere.glsl>

const float PLAGUE_ATMO_PI = 3.14159265358979;

// 192 blocks is the 1 km cumulus base in cloud_types.glsl; the same metre serves the air, so a
// cloud and the haze under it agree about how high the camera is.
const float PLAGUE_ATMO_METRES_PER_BLOCK = 1000.0 / 192.0;

// Used when the engine reports no dimension (u_WorldBounds.w == 0): vanilla overworld sea level.
const float PLAGUE_ATMO_SEA_LEVEL_FALLBACK = 63.0;

// Aerosol asymmetry, Bruneton & Neyret 2008 (their default g for the Cornette-Shanks lobe).
const float PLAGUE_ATMO_MIE_G = 0.76;

// The pack's existing ground bounce (the same 0.15 the palette's ambient uses).
const float PLAGUE_ATMO_GROUND_ALBEDO = 0.15;

// How far below the horizon plagueAtmoMarch eases from the sky branch's own value into the ground
// term, so the two agree exactly at the boundary instead of stepping between "full sky" and
// "0.15 times sky" in one texel. Matches the depth sky.glsl's own doGround arm uses (-VdotU / 0.25,
// about 14 degrees), since it is the same kind of fade for the same reason.
const float PLAGUE_ATMO_GROUND_BAND_DEG = 14.0;

// Not physics. One gain on both lights, solved by tools/derive_atmo_lut.py so the noon dome's
// cosine-weighted average matches TARGET_NOON_DOME in derive_sky.py, the brightness the pack's fixed
// exposure was approved against. A stand-in for exposure metering.
const float PLAGUE_ATMO_SKY_GAIN = 20.3773;

// Also not physics: the hold-down derive_sky.py applies to its night keys, so the moonlit dome
// lands where the palette's does and the additive star and nebula layers stay readable.
const float PLAGUE_ATMO_MOON_HOLD = 0.2289;

// The third stand-in: adaptation. Across sunset the real dome falls thirty-fold while a fixed
// exposure holds still, so a twenty-minute day shows the evening as one minute of orange band and
// then night. An eye or a camera opens up instead. This gain rides the sun's term alone (the moon
// keeps its own hold), rising as the sun sets and fading once the sky is the moon's. Fitted by
// tools/derive_atmo_lut.py --twilight against the palette's sun-side horizon from -2 to -12
// degrees, with the sun's share of the zenith never brightening by more than a quarter over a
// step as the sun sets: 1.0 above +1 degree, 6.9 at -2, 16 from -6 to -8, 10.7 at -12, 1.0 again
// below -18. Retires with metering.
const float PLAGUE_ATMO_TWILIGHT_GAIN = 16.0;
const vec2 PLAGUE_ATMO_TWILIGHT_RISE = vec2(-6.0, 1.0);    // degrees: full gain at .x, none at .y
const vec2 PLAGUE_ATMO_TWILIGHT_FALL = vec2(-18.0, -8.0);  // degrees: none at .x, full at .y

// Ground mist, the fog drive's time-and-weather signal as a shallow aerosol layer (albedo 1, the
// aerosol phase). Fitted by tools/derive_atmo_lut.py --mist so the mist's share of the prior fog
// model's opacity at 100 blocks is reproduced for that model's own dawn (0.40 at drive amount
// 0.72) and after-rain (0.48 at 0.96) states, the prior model's clear-air baseline removed first
// since the marched air carries that. A value 2.9x this put an 85% veil at 100 blocks after rain
// and read as a wall.
const float PLAGUE_ATMO_MIST_SIGMA = 0.00133;

// Aerial table: 32 x 32 screen froxels per slice, 32 depth slices, then one slice holding the sky
// along each froxel's ray and one holding the per-channel transmittance exponent (see
// plagueAtmoTransmittanceChroma), side by side in one texture.
const int PLAGUE_ATMO_AERIAL_GRID = 32;
const int PLAGUE_ATMO_AERIAL_SLICES = 32;
const int PLAGUE_ATMO_AERIAL_SKY_SLICE = 32;
const int PLAGUE_ATMO_AERIAL_CHROMA_SLICE = 33;
const ivec2 PLAGUE_ATMO_AERIAL_SIZE = ivec2(1088, 32);  // 34 slices of 32
const int PLAGUE_ATMO_AERIAL_STEPS = 24;

// The night-sky gate: stars, nebula, meteors and the aurora come in between the end of civil
// twilight and the end of nautical twilight, the sun 6 and 12 degrees under the horizon (the
// published definitions). Keyed on the sun, not the dome's luminance: with the pack's moon held
// far above a real moon, a moonlit zenith and a civil-twilight zenith read the same.
const float PLAGUE_ATMO_NIGHT_BEGIN_DEG = -6.0;
const float PLAGUE_ATMO_NIGHT_FULL_DEG = -12.0;

const ivec2 PLAGUE_ATMO_TRANSMITTANCE_SIZE = ivec2(256, 64);
const ivec2 PLAGUE_ATMO_MULTISCATTER_SIZE = ivec2(32, 32);
const ivec2 PLAGUE_ATMO_SKYVIEW_SIZE = ivec2(192, 108);
const int PLAGUE_ATMO_TRANSMITTANCE_STEPS = 40;
const int PLAGUE_ATMO_MULTISCATTER_DIRECTIONS = 64;
const int PLAGUE_ATMO_MULTISCATTER_STEPS = 20;
const int PLAGUE_ATMO_SKYVIEW_STEPS = 32;

// --- The air this frame ---------------------------------------------------------------------------

struct PlagueAtmoAir {
    vec3 amounts;       // per-component column multipliers: air, haze, ozone
    float hazeScale;    // multiplier on the aerosol scale height
    float mistDensity;  // ground-mist scattering per metre at sea level; 0 for the sky tables
    float mistHeight;   // its e-folding height in metres
};

/**
 * The sliders, with the weather folded into the aerosol. Rain and thunder load the air with water
 * and lower the haze layer. The multipliers are tuning targets, not yet set against renders.
 */
PlagueAtmoAir plagueAtmoAir(float rain, float thunder) {
    PlagueAtmoAir air;
    air.amounts = vec3(u_AirDensity,
                       u_AirTurbidity * (1.0 + 2.0 * rain + 2.0 * thunder),
                       u_AirOzone);
    air.hazeScale = 1.0 - 0.2 * rain;
    air.mistDensity = 0.0;
    air.mistHeight = 1.0;
    return air;
}

/**
 * The same air with the fog drive's mist folded in, for the aerial table only: the sky tables see
 * the mist neither in transmittance nor in scatter, which undercounts a dawn's dimming of the sun
 * by a few percent and is left for the climate phase.
 *
 * @param mistAmount  the drive's optical-depth multiplier less one, floored at zero
 * @param fogAmount   the Fog Amount slider
 * @param mistHeightBlocks the drive's moist-layer height, rain-stretched, in blocks
 */
PlagueAtmoAir plagueAtmoAirWithMist(PlagueAtmoAir air, float mistAmount, float fogAmount,
                                    float mistHeightBlocks) {
    air.mistDensity = PLAGUE_ATMO_MIST_SIGMA * max(mistAmount, 0.0) * max(fogAmount, 0.0);
    air.mistHeight = max(mistHeightBlocks, 1.0) * PLAGUE_ATMO_METRES_PER_BLOCK;
    return air;
}

/** Mist scattering per metre at an altitude: full below sea level, e-folding above it. */
float plagueAtmoMist(float altitude, PlagueAtmoAir air) {
    return air.mistDensity * exp(-max(altitude, 0.0) / air.mistHeight);
}

/** Metres above the model's sea level for a world Y. Floored at 1 m, as plagueAirEyePos does. */
float plagueAtmoAltitude(float worldY, float seaLevel) {
    return max((worldY - seaLevel) * PLAGUE_ATMO_METRES_PER_BLOCK, 1.0);
}

/** Sea level from the engine, or the overworld's when the engine reports no dimension. */
float plagueAtmoSeaLevel() {
    return u_WorldBounds.w > 0.5 ? u_WorldBounds.x : PLAGUE_ATMO_SEA_LEVEL_FALLBACK;
}

/** The camera's distance from the planet centre this frame, from u_Globals alone. */
float plagueAtmoCameraRadius() {
    return PLAGUE_PLANET_RADIUS + plagueAtmoAltitude(u_CameraAbs.y, plagueAtmoSeaLevel());
}

/** Per-component density at an altitude: the profiles atmosphere.glsl's fit encodes. */
vec3 plagueAtmoDensity(float altitude, PlagueAtmoAir air) {
    float h = max(altitude, 0.0);
    return vec3(exp(-h / PLAGUE_SCALE_HEIGHT_AIR),
                exp(-h / (PLAGUE_SCALE_HEIGHT_HAZE * air.hazeScale)),
                max(1.0 - abs(h - PLAGUE_OZONE_PEAK_ALT) / PLAGUE_OZONE_HALF_WIDTH, 0.0))
            * air.amounts;
}

/** Scattering coefficient per metre at a density (air and haze; ozone only absorbs). */
vec3 plagueAtmoScattering(vec3 density) {
    return PLAGUE_RAYLEIGH_SCATTER * density.x + vec3(PLAGUE_AEROSOL_SCATTER * density.y);
}

/** Extinction per metre at a density: the same coefficients plagueAirExtinction applies. */
vec3 plagueAtmoExtinction(vec3 density) {
    return plagueAirExtinction(density);
}

/**
 * Per-channel transmittance from a luminance one: T_c = T_lum ^ (sigma_c / sigma_lum), exact for
 * one homogeneous medium and taken at the given altitude for the mixed air. The aerial table
 * stores one transmittance channel because the resolve cannot afford a second texture.
 */
vec3 plagueAtmoTransmittanceChroma(float altitude, PlagueAtmoAir air) {
    vec3 extinction = plagueAtmoExtinction(plagueAtmoDensity(altitude, air))
            + vec3(plagueAtmoMist(altitude, air));
    float luminance = dot(extinction, vec3(0.2126, 0.7152, 0.0722));
    return extinction / max(luminance, 1e-12);
}

// --- Phase functions, each integrating to 1 over the sphere ---------------------------------------

float plagueAtmoPhaseRayleigh(float cosTheta) {
    return 3.0 / (16.0 * PLAGUE_ATMO_PI) * (1.0 + cosTheta * cosTheta);
}

/** Cornette & Shanks 1992. */
float plagueAtmoPhaseMie(float cosTheta) {
    float g = PLAGUE_ATMO_MIE_G;
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return 3.0 / (8.0 * PLAGUE_ATMO_PI) * (1.0 - g2) * (1.0 + cosTheta * cosTheta)
            / ((2.0 + g2) * denom * sqrt(max(denom, 1e-6)));
}

// --- Geometry: planet-centred, r is distance from the centre, mu is cos(zenith) of a direction ----

float plagueAtmoDistanceToTop(float r, float mu) {
    float b = r * mu;
    float disc = b * b - r * r + PLAGUE_ATMOSPHERE_TOP * PLAGUE_ATMOSPHERE_TOP;
    return -b + sqrt(max(disc, 0.0));
}

/** Distance to the ground along the direction, or -1 when the ray never reaches it. */
float plagueAtmoDistanceToGround(float r, float mu) {
    float disc = r * r * (mu * mu - 1.0) + PLAGUE_PLANET_RADIUS * PLAGUE_PLANET_RADIUS;
    if (mu < 0.0 && disc >= 0.0) {
        return -r * mu - sqrt(disc);
    }
    return -1.0;
}

/** cos(zenith) of the horizon seen from r: every direction below it ends on the ground. */
float plagueAtmoHorizonMu(float r) {
    float ratio = PLAGUE_PLANET_RADIUS / max(r, PLAGUE_PLANET_RADIUS);
    return -sqrt(max(1.0 - ratio * ratio, 0.0));
}

/** How far below level the horizon sits from r, in radians. */
float plagueAtmoHorizonDip(float r) {
    return acos(clamp(PLAGUE_PLANET_RADIUS / max(r, PLAGUE_PLANET_RADIUS), 0.0, 1.0));
}

// --- Texel conventions ----------------------------------------------------------------------------
//
// A writer at texel t stores the value for unit coordinate t / (size - 1); a reader with unit
// coordinate x samples at 0.5 / size + x * (1 - 1 / size), the centre of that same texel. Bilinear
// interpolation then runs between stored values and never past the edge.

vec2 plagueAtmoTexelUnit(ivec2 texel, ivec2 size) {
    return vec2(texel) / vec2(size - 1);
}

vec2 plagueAtmoTexelUv(vec2 unit, ivec2 size) {
    vec2 s = vec2(size);
    return 0.5 / s + clamp(unit, 0.0, 1.0) * (1.0 - 1.0 / s);
}

/** The two texels and the weights a linear sampler would use at uv, for an image read. */
void plagueAtmoBilinearSetup(vec2 uv, ivec2 size, out ivec2 i0, out ivec2 i1, out vec2 f) {
    vec2 p = uv * vec2(size) - 0.5;
    i0 = clamp(ivec2(floor(p)), ivec2(0), size - 1);
    i1 = min(i0 + 1, size - 1);
    f = clamp(p - vec2(i0), 0.0, 1.0);
}

vec4 plagueAtmoBilinearMix(vec4 c00, vec4 c10, vec4 c01, vec4 c11, vec2 f) {
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// --- Transmittance table --------------------------------------------------------------------------

vec2 plagueAtmoTransmittanceUnit(float r, float mu) {
    float H = sqrt(PLAGUE_ATMOSPHERE_TOP * PLAGUE_ATMOSPHERE_TOP
                   - PLAGUE_PLANET_RADIUS * PLAGUE_PLANET_RADIUS);
    float rho = sqrt(max(r * r - PLAGUE_PLANET_RADIUS * PLAGUE_PLANET_RADIUS, 0.0));
    float d = plagueAtmoDistanceToTop(r, mu);
    float dMin = PLAGUE_ATMOSPHERE_TOP - r;
    float dMax = rho + H;
    return vec2((d - dMin) / max(dMax - dMin, 1e-3), rho / H);
}

void plagueAtmoTransmittanceParams(vec2 unit, out float r, out float mu) {
    float H = sqrt(PLAGUE_ATMOSPHERE_TOP * PLAGUE_ATMOSPHERE_TOP
                   - PLAGUE_PLANET_RADIUS * PLAGUE_PLANET_RADIUS);
    float rho = H * unit.y;
    r = sqrt(rho * rho + PLAGUE_PLANET_RADIUS * PLAGUE_PLANET_RADIUS);
    float dMin = PLAGUE_ATMOSPHERE_TOP - r;
    float dMax = rho + H;
    float d = dMin + unit.x * (dMax - dMin);
    mu = d < 1e-3 ? 1.0 : clamp((H * H - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0);
}

#ifdef PLAGUE_ATMO_READS_TRANSMITTANCE
vec4 plagueAtmoFetchTransmittance(vec2 uv);

/** Transmittance from (r, mu) to the top of the atmosphere. Below the horizon it is meaningless. */
vec3 plagueAtmoTransmittance(float r, float mu) {
    return plagueAtmoFetchTransmittance(plagueAtmoTexelUv(plagueAtmoTransmittanceUnit(r, mu),
                                                          PLAGUE_ATMO_TRANSMITTANCE_SIZE)).rgb;
}

/**
 * Transmittance toward a light from a point in the air: zero once the light is below that point's
 * horizon, faded in over 0.005 of cosine so a sample crossing the terminator does not step.
 */
vec3 plagueAtmoTransmittanceToLight(float r, float muLight) {
    float horizon = plagueAtmoHorizonMu(r);
    float lit = smoothstep(horizon, horizon + 0.005, muLight);
    if (lit <= 0.0) {
        return vec3(0.0);
    }
    return plagueAtmoTransmittance(r, max(muLight, horizon)) * lit;
}
#endif

// --- Multiple-scattering table --------------------------------------------------------------------

vec2 plagueAtmoMultiScatterUnit(float r, float muLight) {
    return vec2(muLight * 0.5 + 0.5,
                (r - PLAGUE_PLANET_RADIUS) / PLAGUE_ATMOSPHERE_DEPTH);
}

void plagueAtmoMultiScatterParams(vec2 unit, out float r, out float muLight) {
    muLight = unit.x * 2.0 - 1.0;
    r = PLAGUE_PLANET_RADIUS + unit.y * PLAGUE_ATMOSPHERE_DEPTH;
}

#ifdef PLAGUE_ATMO_READS_MULTISCATTER
vec4 plagueAtmoFetchMultiScatter(vec2 uv);

/** Multiply-scattered radiance per unit light radiance, isotropic, at (r, muLight). */
vec3 plagueAtmoMultiScatter(float r, float muLight) {
    return plagueAtmoFetchMultiScatter(plagueAtmoTexelUv(plagueAtmoMultiScatterUnit(r, muLight),
                                                         PLAGUE_ATMO_MULTISCATTER_SIZE)).rgb;
}
#endif

// --- Sky-view table -------------------------------------------------------------------------------
//
// x: azimuth from the sun's vertical plane, 0..pi. The dome is mirror-symmetric about that plane,
//    and the moon at -sunDir lies in it too, so one half is the whole sky.
// y: elevation, with a square-root warp either side of the camera's own horizon so the band where
//    the sky changes fastest gets the texels.

vec2 plagueAtmoLightAzimuth(vec3 lightDir) {
    vec2 h = lightDir.xz;
    float len = length(h);
    return len > 1e-4 ? h / len : vec2(1.0, 0.0);
}

vec2 plagueAtmoSkyViewUnit(vec3 viewDir, vec3 sunDir, float r) {
    float dip = plagueAtmoHorizonDip(r);
    float e = asin(clamp(viewDir.y, -1.0, 1.0));
    float v;
    if (e >= -dip) {
        float t = (e + dip) / (0.5 * PLAGUE_ATMO_PI + dip);
        v = 0.5 + 0.5 * sqrt(clamp(t, 0.0, 1.0));
    } else {
        float t = (-dip - e) / max(0.5 * PLAGUE_ATMO_PI - dip, 1e-4);
        v = 0.5 - 0.5 * sqrt(clamp(t, 0.0, 1.0));
    }
    vec2 azimuth = plagueAtmoLightAzimuth(sunDir);
    vec2 h = viewDir.xz;
    float len = length(h);
    float phi = len > 1e-4 ? acos(clamp(dot(h / len, azimuth), -1.0, 1.0)) : 0.0;
    return vec2(phi / PLAGUE_ATMO_PI, v);
}

vec3 plagueAtmoSkyViewDir(vec2 unit, vec3 sunDir, float r) {
    float dip = plagueAtmoHorizonDip(r);
    float e;
    if (unit.y >= 0.5) {
        float t = (unit.y - 0.5) * 2.0;
        e = -dip + t * t * (0.5 * PLAGUE_ATMO_PI + dip);
    } else {
        float t = (0.5 - unit.y) * 2.0;
        e = -dip - t * t * (0.5 * PLAGUE_ATMO_PI - dip);
    }
    float phi = unit.x * PLAGUE_ATMO_PI;
    vec2 azimuth = plagueAtmoLightAzimuth(sunDir);
    vec2 side = vec2(-azimuth.y, azimuth.x);
    vec2 h = cos(phi) * azimuth + sin(phi) * side;
    return vec3(h.x * cos(e), sin(e), h.y * cos(e));
}

#ifdef PLAGUE_ATMO_READS_SKYVIEW
vec4 plagueAtmoFetchSkyView(vec2 uv);

/**
 * The dome in a direction: rgb in-scattered radiance, a the luminance transmittance to where the
 * ray ended (the top of the atmosphere, or the ground for directions below the horizon).
 */
vec4 plagueAtmoSkyView(vec3 viewDir, vec3 sunDir, float r) {
    return plagueAtmoFetchSkyView(plagueAtmoTexelUv(plagueAtmoSkyViewUnit(viewDir, sunDir, r),
                                                    PLAGUE_ATMO_SKYVIEW_SIZE));
}

/**
 * The visible dome, cosine-weighted: the five reads plagueSkyHemisphere takes (the zenith, then
 * 55 and 25 degrees up on the sun's side and away), so a cloud lit by this dome is lit the way it
 * was by the palette's.
 */
vec3 plagueAtmoSkyHemisphere(vec3 sunDir, float r) {
    vec2 azimuth = plagueAtmoLightAzimuth(sunDir);
    // (elevation sine, cosine, azimuth sign toward the sun, cosine weight)
    const vec4 SAMPLES[5] = vec4[](
        vec4(1.000, 0.000,  0.0, 0.30),
        vec4(0.819, 0.574,  1.0, 0.22),
        vec4(0.819, 0.574, -1.0, 0.22),
        vec4(0.423, 0.906,  1.0, 0.16),
        vec4(0.423, 0.906, -1.0, 0.10));
    vec3 total = vec3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 5; i++) {
        vec2 horizontal = azimuth * (SAMPLES[i].y * SAMPLES[i].z);
        vec3 dir = vec3(horizontal.x, SAMPLES[i].x, horizontal.y);
        total += plagueAtmoSkyView(dir, sunDir, r).rgb * SAMPLES[i].w;
        weight += SAMPLES[i].w;
    }
    return total / weight;
}

/**
 * What a cloud is lit by from the sky: the five reads above, plus the horizon band five degrees
 * up on the sun's side and away. A cosine-weighted dome is what a flat upward surface receives;
 * a cloud is a volume lit from the side too, and at twilight the sun-side horizon is the brightest
 * thing in the sky by far (0.8 against a zenith of 0.09 at -2 degrees). Weights authored: the
 * horizon pair carries a fifth of the total, the share of a hemisphere within ten degrees of level.
 */
vec3 plagueAtmoCloudAmbient(vec3 sunDir, float r) {
    vec2 azimuth = plagueAtmoLightAzimuth(sunDir);
    const vec4 SAMPLES[7] = vec4[](
        vec4(1.000, 0.000,  0.0, 0.30),
        vec4(0.819, 0.574,  1.0, 0.22),
        vec4(0.819, 0.574, -1.0, 0.22),
        vec4(0.423, 0.906,  1.0, 0.16),
        vec4(0.423, 0.906, -1.0, 0.10),
        vec4(0.087, 0.996,  1.0, 0.17),
        vec4(0.087, 0.996, -1.0, 0.08));
    vec3 total = vec3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 7; i++) {
        vec2 horizontal = azimuth * (SAMPLES[i].y * SAMPLES[i].z);
        vec3 dir = vec3(horizontal.x, SAMPLES[i].x, horizontal.y);
        total += plagueAtmoSkyView(dir, sunDir, r).rgb * SAMPLES[i].w;
        weight += SAMPLES[i].w;
    }
    return total / weight;
}
#endif

// --- Lights ---------------------------------------------------------------------------------------

/** The adaptation gain on the sun's term for a sun elevation (sine), see PLAGUE_ATMO_TWILIGHT_GAIN. */
float plagueAtmoTwilightGain(float sunElevationSine) {
    float e = degrees(asin(clamp(sunElevationSine, -1.0, 1.0)));
    float bump = (1.0 - smoothstep(PLAGUE_ATMO_TWILIGHT_RISE.x, PLAGUE_ATMO_TWILIGHT_RISE.y, e))
               * smoothstep(PLAGUE_ATMO_TWILIGHT_FALL.x, PLAGUE_ATMO_TWILIGHT_FALL.y, e);
    return 1.0 + (PLAGUE_ATMO_TWILIGHT_GAIN - 1.0) * bump;
}

/**
 * Sunlight above the atmosphere: the blackbody the discs use, at the pack's calibration, with the
 * twilight adaptation for this sun.
 */
vec3 plagueAtmoSunRadiance(vec3 sunDir) {
    return plagueBlackbody(PLAGUE_SUN_TEMPERATURE)
            * (PLAGUE_SUN_LUMINANCE * u_SunIntensity * PLAGUE_ATMO_SKY_GAIN
               * plagueAtmoTwilightGain(sunDir.y));
}

/** Moonlight above the atmosphere: plagueMoonColor's chain without the air, held down for stars. */
vec3 plagueAtmoMoonRadiance() {
    vec3 adapted = plagueBlackbody(PLAGUE_SUN_TEMPERATURE) * PLAGUE_LUNAR_ALBEDO_TINT
            * mix(vec3(1.0), PLAGUE_SCOTOPIC_SHIFT, u_NightScotopic);
    return adapted * (PLAGUE_MOON_LUMINANCE * u_MoonIntensity
                      * PLAGUE_ATMO_SKY_GAIN * PLAGUE_ATMO_MOON_HOLD);
}

// --- Aerial table ---------------------------------------------------------------------------------
//
// Screen froxels: x, y from the projection's own NDC (uv * 2 - 1 is the resolve's ray-reconstruction
// input and a geometry pass's gl_Position.xy / w alike), depth quadratic to twice the render
// distance so the near field, where the eye can tell, gets the slices.

/** Twice the terrain render distance, in blocks: the same anchor the fog sites use. */
float plagueAtmoAerialFar() {
    float renderDistance = u_CameraSkyLight.z > 1.0 ? u_CameraSkyLight.z : max(u_RenderFog.y, 32.0);
    return 2.0 * renderDistance;
}

/** Depth in blocks of slice i's far edge. */
float plagueAtmoAerialSliceDepth(int slice, float far) {
    float s = float(slice + 1) / float(PLAGUE_ATMO_AERIAL_SLICES);
    return far * s * s;
}

/** Texture uv of a froxel inside a slice, clamped half a texel inside it so slices never bleed. */
vec2 plagueAtmoAerialUv(vec2 ndcUv, int slice) {
    float inset = 0.5 / float(PLAGUE_ATMO_AERIAL_GRID);
    vec2 s = clamp(ndcUv, vec2(inset), vec2(1.0 - inset));
    return vec2((float(slice) + s.x) / float(PLAGUE_ATMO_AERIAL_SIZE.x / PLAGUE_ATMO_AERIAL_GRID), s.y);
}

#ifdef PLAGUE_ATMO_READS_AERIAL
vec4 plagueAtmoFetchAerial(vec2 uv);

/**
 * In-scatter rgb and luminance transmittance from the camera to a point dist blocks along the
 * froxel at ndcUv: a lerp between the two enclosing slices, and between the camera (nothing
 * scattered, everything transmitted) and the first.
 */
vec4 plagueAtmoAerial(vec2 ndcUv, float dist, float far) {
    float s = sqrt(clamp(dist / max(far, 1.0), 0.0, 1.0)) * float(PLAGUE_ATMO_AERIAL_SLICES) - 1.0;
    if (s <= 0.0) {
        return mix(vec4(0.0, 0.0, 0.0, 1.0), plagueAtmoFetchAerial(plagueAtmoAerialUv(ndcUv, 0)), s + 1.0);
    }
    int i0 = min(int(floor(s)), PLAGUE_ATMO_AERIAL_SLICES - 1);
    int i1 = min(i0 + 1, PLAGUE_ATMO_AERIAL_SLICES - 1);
    return mix(plagueAtmoFetchAerial(plagueAtmoAerialUv(ndcUv, i0)),
               plagueAtmoFetchAerial(plagueAtmoAerialUv(ndcUv, i1)), clamp(s - float(i0), 0.0, 1.0));
}

/**
 * The aerial pair past the table's far edge, for a cloud beyond it. The extra path is CLEAR air
 * at the cloud's own altitude (the caller supplies its extinction per metre): the table's own
 * transmittance carries the ground mist of the first few hundred blocks, and continuing it as if
 * that mist went on would fog every distant cloud flat. The extra in-scatter tends to the sky
 * along the ray, seen through what the table already let through. Exact at the edge.
 */
vec4 plagueAtmoAerialBeyond(vec4 aerialFar, vec3 skyAlong, float extraMetres, float extinctionPerMetre) {
    float t = exp(-max(extinctionPerMetre, 0.0) * max(extraMetres, 0.0));
    return vec4(aerialFar.rgb + aerialFar.a * skyAlong * (1.0 - t), aerialFar.a * t);
}

/** How much of the additive night sky shows for a sun elevation (sine). */
float plagueAtmoNightGate(float sunElevationSine) {
    float e = degrees(asin(clamp(sunElevationSine, -1.0, 1.0)));
    return 1.0 - smoothstep(PLAGUE_ATMO_NIGHT_FULL_DEG, PLAGUE_ATMO_NIGHT_BEGIN_DEG, e);
}

/** The sky along the froxel's ray: what a surface dissolves into at the render cutoff. */
vec3 plagueAtmoAerialSky(vec2 ndcUv) {
    return plagueAtmoFetchAerial(plagueAtmoAerialUv(ndcUv, PLAGUE_ATMO_AERIAL_SKY_SLICE)).rgb;
}

/** The per-channel transmittance exponent this frame (plagueAtmoTransmittanceChroma). */
vec3 plagueAtmoAerialChroma(vec2 ndcUv) {
    return plagueAtmoFetchAerial(plagueAtmoAerialUv(ndcUv, PLAGUE_ATMO_AERIAL_CHROMA_SLICE)).rgb;
}
#endif

// --- The march ------------------------------------------------------------------------------------

struct PlagueAtmoPhases {
    float rayleighSun;
    float mieSun;
    float rayleighMoon;
    float mieMoon;
};

/** The four phase values a ray needs, for the sun and the moon opposite it. */
PlagueAtmoPhases plagueAtmoPhases(vec3 dir, vec3 sunDir) {
    float cosSun = dot(dir, sunDir);
    PlagueAtmoPhases p;
    p.rayleighSun = plagueAtmoPhaseRayleigh(cosSun);
    p.mieSun = plagueAtmoPhaseMie(cosSun);
    p.rayleighMoon = plagueAtmoPhaseRayleigh(-cosSun);
    p.mieMoon = plagueAtmoPhaseMie(-cosSun);
    return p;
}

#if defined(PLAGUE_ATMO_READS_TRANSMITTANCE) && defined(PLAGUE_ATMO_READS_MULTISCATTER)
/**
 * Radiance scattered toward the eye per metre at a point, and the extinction there. Below the
 * model's ground (a camera in a valley looking down) the density is sea level's and the tables are
 * read at sea level; the world keeps going where the model's planet stops.
 */
void plagueAtmoScatterAt(vec3 pos, vec3 sunDir, PlagueAtmoPhases phases, vec3 sunRadiance,
                         vec3 moonRadiance, PlagueAtmoAir air,
                         out vec3 scattered, out vec3 extinction) {
    float r = length(pos);
    float rTable = max(r, PLAGUE_PLANET_RADIUS + 1.0);
    vec3 up = pos / r;
    float altitude = r - PLAGUE_PLANET_RADIUS;
    vec3 density = plagueAtmoDensity(altitude, air);
    float mist = plagueAtmoMist(altitude, air);
    vec3 scatterAir = PLAGUE_RAYLEIGH_SCATTER * density.x;
    vec3 scatterHaze = vec3(PLAGUE_AEROSOL_SCATTER * density.y + mist);
    extinction = plagueAtmoExtinction(density) + vec3(mist);

    float muSun = dot(up, sunDir);
    vec3 sun = plagueAtmoTransmittanceToLight(rTable, muSun)
            * (scatterAir * phases.rayleighSun + scatterHaze * phases.mieSun)
            + plagueAtmoMultiScatter(rTable, muSun) * (scatterAir + scatterHaze);
    vec3 moon = plagueAtmoTransmittanceToLight(rTable, -muSun)
            * (scatterAir * phases.rayleighMoon + scatterHaze * phases.mieMoon)
            + plagueAtmoMultiScatter(rTable, -muSun) * (scatterAir + scatterHaze);
    scattered = sun * sunRadiance + moon * moonRadiance;
}

/**
 * In-scatter along one ray from its origin to a distance, lit by the sun and the moon. Steps are
 * spaced quadratically: on a grazing ray the aerosol layer is gone within the first few kilometres
 * of a path a thousand long, and uniform steps would put one sample in it.
 *
 * @return rgb radiance, a the luminance transmittance to the end
 */
vec4 plagueAtmoMarchTo(vec3 origin, vec3 dir, vec3 sunDir, vec3 sunRadiance, vec3 moonRadiance,
                       PlagueAtmoAir air, float end, int steps, out vec3 transmittance) {
    PlagueAtmoPhases phases = plagueAtmoPhases(dir, sunDir);
    vec3 radiance = vec3(0.0);
    transmittance = vec3(1.0);
    float tPrev = 0.0;
    for (int i = 0; i < steps; i++) {
        float s = float(i + 1) / float(steps);
        float tNext = end * s * s;
        float dt = tNext - tPrev;
        float t = 0.5 * (tPrev + tNext);
        tPrev = tNext;

        vec3 scattered;
        vec3 extinction;
        plagueAtmoScatterAt(origin + dir * t, sunDir, phases, sunRadiance, moonRadiance, air,
                            scattered, extinction);
        vec3 stepTransmittance = exp(-extinction * dt);
        vec3 integrated = (scattered - scattered * stepTransmittance) / max(extinction, vec3(1e-12));
        radiance += transmittance * integrated;
        transmittance *= stepTransmittance;
    }
    return vec4(radiance, dot(transmittance, vec3(0.2126, 0.7152, 0.0722)));
}

vec4 plagueAtmoMarchTo(vec3 origin, vec3 dir, vec3 sunDir, vec3 sunRadiance, vec3 moonRadiance,
                       PlagueAtmoAir air, float end, int steps) {
    vec3 transmittance;
    return plagueAtmoMarchTo(origin, dir, sunDir, sunRadiance, moonRadiance, air, end, steps,
                             transmittance);
}

/**
 * The whole ray. Above the horizon it runs to the top of the atmosphere. Below it, it runs to the
 * model's ground and shows that ground through the remaining air: a Lambertian surface at the
 * pack's albedo lit by the sun and moon through the air at ground level, with the horizon sky in
 * the same azimuth as its ambient. That is what the undrawn world past the render distance reads
 * as from altitude: grazing rays haze into the horizon, steep ones see dim ground under haze.
 *
 * The two branches are blended across PLAGUE_ATMO_GROUND_BAND_DEG rather than switched at the
 * horizon: right at the boundary a grazing ray's ground intercept is metres away and contributes
 * almost nothing of its own, so the ground formula alone was close to PLAGUE_ATMO_GROUND_ALBEDO
 * (0.15) times the sky branch's own value in the same texel that value stepped down from full
 * brightness: a five- to sevenfold cliff, worst exactly where the sky-view table's warp
 * concentrates its texels. Blending toward the "ray kept going" sky value at the boundary makes
 * the two sides equal there by construction, and the sqrt warp still gives that boundary the most
 * texels, so the transition itself gets sampled rather than jumped over.
 */
vec4 plagueAtmoMarch(vec3 origin, vec3 dir, vec3 sunDir, vec3 sunRadiance, vec3 moonRadiance,
                     PlagueAtmoAir air, int steps) {
    float r0 = length(origin);
    float mu0 = dot(origin, dir) / r0;
    float muHorizon = plagueAtmoHorizonMu(r0);
    if (mu0 > muHorizon) {
        return plagueAtmoMarchTo(origin, dir, sunDir, sunRadiance, moonRadiance, air,
                                 plagueAtmoDistanceToTop(r0, mu0), steps);
    }

    // What this same ray would be if the ground were not there: continuous with the branch above
    // by construction, since it is the identical expression at the identical mu0.
    vec4 asIfSky = plagueAtmoMarchTo(origin, dir, sunDir, sunRadiance, moonRadiance, air,
                                     plagueAtmoDistanceToTop(r0, mu0), steps);

    float toGround = plagueAtmoDistanceToGround(r0, mu0);
    vec3 transmittance;
    vec4 toGroundRadiance = plagueAtmoMarchTo(origin, dir, sunDir, sunRadiance, moonRadiance, air,
                                              toGround, steps, transmittance);
    // The same azimuth, tilted up to graze the horizon: the direction the ground is standing in
    // for.
    vec3 up = origin / r0;
    vec3 level = dir - up * mu0;
    float levelLength = length(level);
    level = levelLength > 1e-5 ? level / levelLength : vec3(1.0, 0.0, 0.0);
    vec3 horizonDir = normalize(level * sqrt(max(1.0 - muHorizon * muHorizon, 0.0)) + up * muHorizon);
    vec4 horizonSky = plagueAtmoMarchTo(origin, horizonDir, sunDir, sunRadiance, moonRadiance, air,
                                        plagueAtmoDistanceToTop(r0, muHorizon), steps);
    vec3 groundPoint = origin + dir * toGround;
    vec3 groundUp = groundPoint / length(groundPoint);
    float cosSun = dot(groundUp, sunDir);
    float groundR = PLAGUE_PLANET_RADIUS + 1.0;
    vec3 directOnGround = plagueAtmoTransmittanceToLight(groundR, cosSun) * sunRadiance * max(cosSun, 0.0)
                        + plagueAtmoTransmittanceToLight(groundR, -cosSun) * moonRadiance * max(-cosSun, 0.0);
    vec3 ground = PLAGUE_ATMO_GROUND_ALBEDO * (directOnGround / PLAGUE_ATMO_PI + horizonSky.rgb);
    vec4 groundFormula = vec4(toGroundRadiance.rgb + transmittance * ground, toGroundRadiance.a);

    float belowDeg = degrees(asin(clamp(muHorizon, -1.0, 1.0)) - asin(clamp(mu0, -1.0, 1.0)));
    float band = smoothstep(0.0, PLAGUE_ATMO_GROUND_BAND_DEG, belowDeg);
    return mix(asIfSky, groundFormula, band);
}
#endif

#endif // PLAGUE_ATMO_LUT
