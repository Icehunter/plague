#ifndef PLAGUE_ATMO_LUT
#define PLAGUE_ATMO_LUT

// The scattering tables: what the air between the eye and the sky does to light, integrated
// rather than fitted. Three small textures, rewritten every frame by the atmo_* compute
// passes and sampled by whoever needs the sky in a direction.
//
//   atmoTransmittance  what survives from a point in the air to the top of the atmosphere
//   atmoMultiScatter   light that has bounced more than once before reaching a point, per unit sun
//   atmoSkyView        the dome as the camera sees it this frame: in-scatter along every ray
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

// Not physics. One gain on both lights, solved by tools/derive_atmo_lut.py so the noon dome's
// cosine-weighted average matches TARGET_NOON_DOME in derive_sky.py, the brightness the pack's fixed
// exposure was approved against. A stand-in for exposure metering.
const float PLAGUE_ATMO_SKY_GAIN = 20.3773;

// Also not physics: the hold-down derive_sky.py applies to its night keys, so the moonlit dome
// lands where the palette's does and the additive star and nebula layers stay readable.
const float PLAGUE_ATMO_MOON_HOLD = 0.2289;

const ivec2 PLAGUE_ATMO_TRANSMITTANCE_SIZE = ivec2(256, 64);
const ivec2 PLAGUE_ATMO_MULTISCATTER_SIZE = ivec2(32, 32);
const ivec2 PLAGUE_ATMO_SKYVIEW_SIZE = ivec2(192, 108);
const int PLAGUE_ATMO_TRANSMITTANCE_STEPS = 40;
const int PLAGUE_ATMO_MULTISCATTER_DIRECTIONS = 64;
const int PLAGUE_ATMO_MULTISCATTER_STEPS = 20;
const int PLAGUE_ATMO_SKYVIEW_STEPS = 32;

// --- The air this frame ---------------------------------------------------------------------------

struct PlagueAtmoAir {
    vec3 amounts;     // per-component column multipliers: air, haze, ozone
    float hazeScale;  // multiplier on the aerosol scale height
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
    return air;
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
#endif

// --- Lights ---------------------------------------------------------------------------------------

/** Sunlight above the atmosphere: the blackbody the discs use, at the pack's calibration. */
vec3 plagueAtmoSunRadiance() {
    return plagueBlackbody(PLAGUE_SUN_TEMPERATURE)
            * (PLAGUE_SUN_LUMINANCE * u_SunIntensity * PLAGUE_ATMO_SKY_GAIN);
}

/** Moonlight above the atmosphere: plagueMoonColor's chain without the air, held down for stars. */
vec3 plagueAtmoMoonRadiance() {
    vec3 adapted = plagueBlackbody(PLAGUE_SUN_TEMPERATURE) * PLAGUE_LUNAR_ALBEDO_TINT
            * mix(vec3(1.0), PLAGUE_SCOTOPIC_SHIFT, u_NightScotopic);
    return adapted * (PLAGUE_MOON_LUMINANCE * u_MoonIntensity
                      * PLAGUE_ATMO_SKY_GAIN * PLAGUE_ATMO_MOON_HOLD);
}

// --- The march ------------------------------------------------------------------------------------

/**
 * In-scatter along one ray through the air, lit by the sun and the moon, both scattering tables in
 * hand. Steps are spaced quadratically in distance: on a grazing ray the aerosol layer is gone
 * within the first few kilometres of a path a thousand long, and uniform steps would put one sample
 * in it.
 *
 * @return rgb radiance, a the luminance transmittance to the end of the ray
 */
#if defined(PLAGUE_ATMO_READS_TRANSMITTANCE) && defined(PLAGUE_ATMO_READS_MULTISCATTER)
vec4 plagueAtmoMarch(vec3 origin, vec3 dir, vec3 sunDir, vec3 sunRadiance, vec3 moonRadiance,
                     PlagueAtmoAir air, int steps) {
    float r0 = length(origin);
    float mu0 = dot(origin, dir) / r0;
    float toGround = plagueAtmoDistanceToGround(r0, mu0);
    float end = toGround > 0.0 ? toGround : plagueAtmoDistanceToTop(r0, mu0);

    float cosSun = dot(dir, sunDir);
    float phaseRayleighSun = plagueAtmoPhaseRayleigh(cosSun);
    float phaseMieSun = plagueAtmoPhaseMie(cosSun);
    float phaseRayleighMoon = plagueAtmoPhaseRayleigh(-cosSun);
    float phaseMieMoon = plagueAtmoPhaseMie(-cosSun);

    vec3 radiance = vec3(0.0);
    vec3 transmittance = vec3(1.0);
    float tPrev = 0.0;
    for (int i = 0; i < steps; i++) {
        float s = float(i + 1) / float(steps);
        float tNext = end * s * s;
        float dt = tNext - tPrev;
        float t = 0.5 * (tPrev + tNext);
        tPrev = tNext;

        vec3 pos = origin + dir * t;
        float r = length(pos);
        vec3 up = pos / r;
        vec3 density = plagueAtmoDensity(r - PLAGUE_PLANET_RADIUS, air);
        vec3 scatterAir = PLAGUE_RAYLEIGH_SCATTER * density.x;
        vec3 scatterHaze = vec3(PLAGUE_AEROSOL_SCATTER * density.y);
        vec3 extinction = plagueAtmoExtinction(density);

        float muSun = dot(up, sunDir);
        vec3 sun = plagueAtmoTransmittanceToLight(r, muSun)
                * (scatterAir * phaseRayleighSun + scatterHaze * phaseMieSun)
                + plagueAtmoMultiScatter(r, muSun) * (scatterAir + scatterHaze);
        vec3 moon = plagueAtmoTransmittanceToLight(r, -muSun)
                * (scatterAir * phaseRayleighMoon + scatterHaze * phaseMieMoon)
                + plagueAtmoMultiScatter(r, -muSun) * (scatterAir + scatterHaze);
        vec3 scattered = sun * sunRadiance + moon * moonRadiance;

        vec3 stepTransmittance = exp(-extinction * dt);
        vec3 integrated = (scattered - scattered * stepTransmittance) / max(extinction, vec3(1e-12));
        radiance += transmittance * integrated;
        transmittance *= stepTransmittance;
    }
    return vec4(radiance, dot(transmittance, vec3(0.2126, 0.7152, 0.0722)));
}
#endif

#endif // PLAGUE_ATMO_LUT
