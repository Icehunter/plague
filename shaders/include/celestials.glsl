#ifndef PLAGUE_CELESTIALS
#define PLAGUE_CELESTIALS

// Sun and moon discs, drawn as shapes rather than sprites. Placed here rather than in vanilla's
// sky-textured geometry stage because SKY_PROCEDURAL cancels vanilla's sky pass outright, so its
// quads are never submitted. Nothing here reads the celestials atlas: the sun is a disc, the moon a
// lit sphere. Resource-pack sun and moon art therefore has no effect, only size, brightness and
// phase.
//
// Both discs are found by ANGLE: the rejection of viewRay onto the celestial direction gives a
// local disc-space UV with no matrix or screen position, so it stays correct at any FOV.

// Angular radius, DERIVED from vanilla's SkyRenderer geometry: sun quad half-width 30, moon 20,
// both at distance 100, giving atan(30/100)=0.2915 rad and atan(20/100)=0.1974 rad. ~60x the real
// sun/moon's ~0.5-degree size (0.00465 rad, the figure brdf.glsl uses for solar solid angle) —
// deliberate, matching vanilla, since a physically-sized sun is a handful of pixels.
const float PLAGUE_MOON_DISC_RADIUS = 0.1974;

// The sun's angular radius, radians. 0.00465 is the real sun, eight pixels across at 1080p and a
// 70-degree vertical FOV; 0.2915 is vanilla's quad. Above about 0.12 the disc is wider than its own
// aureole (u_SunGlowStrength's falloff) and covers it.
#define u_SunDiscSize 0.090 //[0.010..0.300 step 0.005] runtime "Sun Size"

// Multiples of each body's OWN radiance (not an absolute), so brightness stays meaningful as the
// atmosphere's colour changes. The sun's default is >1 to survive the aureole drawn around it.
#define u_SunDiscBrightness 9.0 //[0.00..30.00 step 0.50] runtime "Sun Disc Brightness"
#define u_MoonDiscBrightness 3.0 //[0.00..12.00 step 0.25] runtime "Moon Disc Brightness"

// The moon's angular radius, radians. 0.1974 is vanilla's quad; the real moon is 0.00452, within a
// few percent of the sun's, which is why eclipses work.
#define u_MoonDiscSize 0.070 //[0.010..0.250 step 0.005] runtime "Moon Size"

// Disc-local frame for a celestial direction. Any vector not parallel to dir works as a seed; world
// up fails only when looking exactly at the zenith celestial, so the seed swaps near the pole
// rather than producing a degenerate basis.
void plagueCelestialBasis(vec3 dir, out vec3 tangentX, out vec3 tangentY) {
    vec3 seed = abs(dir.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    tangentX = normalize(cross(seed, dir));
    tangentY = cross(dir, tangentX);
}

// Disc-local UV for a view ray against a celestial direction, or outside 0..1 when the ray misses.
vec2 plagueCelestialUv(vec3 viewRay, vec3 dir, float radius) {
    vec3 tangentX, tangentY;
    plagueCelestialBasis(dir, tangentX, tangentY);

    float offsetX = dot(viewRay, tangentX);
    float offsetY = dot(viewRay, tangentY);

    return vec2(offsetX, offsetY) / radius * 0.5 + 0.5;
}

// Guards the antipodal ghost: whether the ray is on the disc's own hemisphere at all.
bool plagueFacingCelestial(vec3 viewRay, vec3 dir) {
    return dot(viewRay, dir) > 0.0;
}


// --- Shading the two discs ------------------------------------------------------------------------
//
// The atlas texture is a MASK, not the output colour: the art (near-white on black) decides only
// WHERE the disc is. Both take the radiance the atmosphere already computed for that body
// (plagueSunColor/plagueMoonColor), so a disc can never disagree with the light it casts.
//
// Shaded differently on purpose: the Sun is limb-darkened (grazing sightlines see a higher, cooler
// photosphere layer), the Moon is not (regolith backscatters toward the light, so a full moon reads
// as a flat disc, not a lit sphere).

// Linear limb-darkening coefficient for the Sun; leaves ~40% of central intensity at the limb,
// matching the Sun's real appearance around 550nm.
const float PLAGUE_SUN_LIMB_DARKENING = 0.6;

// Smoothstep, not a power curve: a power curve is violently sensitive to input (measured 7x
// overreaction to a 15% input change at ^6), which broke the underwater caller's prefiltered taps.
const float PLAGUE_DISC_EDGE = 0.28;
const float PLAGUE_DISC_FEATHER = 0.17;

/** @param rainFactor widens the edge, because a disc seen through weather has a soft one */
// Edge feather, in disc radii, so it tracks the disc rather than a fixed angle. At the default
// 0.090 rad the disc is about 80 pixels of radius on a 1080-line display at a 70-degree vertical
// FOV, making this a two-pixel edge: enough to anti-alias, short of a visible blur.
const float PLAGUE_DISC_RADIAL_FEATHER = 0.02;

// Local copy: this file is imported before light_and_ambient_colors in some passes.
const float PLAGUE_CELESTIAL_TAU = 6.283185307179586;

/**
 * Disc coverage from the disc-local radius: 1 inside the disc, 0 past the rim.
 *
 * The shape is analytic, not the sprite's alpha or brightness. Rain widens the edge, as it does for
 * the sampled path.
 */
float plagueDiscCoverageRadial(float radius, float rainFactor) {
    float feather = PLAGUE_DISC_RADIAL_FEATHER * (1.0 + 2.0 * rainFactor);
    return 1.0 - smoothstep(1.0 - feather, 1.0, radius);
}

vec3 plagueShadeSunDisc(vec2 discUv, vec3 sunRadiance, float rainFactor) {
    // mu = cosine of the angle between the sightline and the disc's surface normal there, which
    // the limb-darkening law is a function of.
    vec2 fromCentre = discUv * 2.0 - 1.0;
    float radius = length(fromCentre);
    float mu = sqrt(max(1.0 - min(radius, 1.0) * min(radius, 1.0), 0.0));
    float limb = 1.0 - PLAGUE_SUN_LIMB_DARKENING * (1.0 - mu);

    return sunRadiance * plagueDiscCoverageRadial(radius, rainFactor) * limb;
}

/**
 * Surface normal of the moon's near hemisphere under a view ray, or false where the ray misses.
 *
 * The disc coordinate is the sphere's tangent-plane position, so the remaining component follows
 * from the unit constraint. It is negated because the visible hemisphere faces the viewer, against
 * moonDir.
 */
bool plagueMoonSurface(vec3 viewRay, vec3 moonDir, float radius, out vec3 normal, out float rim) {
    vec3 tangentX, tangentY;
    plagueCelestialBasis(moonDir, tangentX, tangentY);
    vec2 offset = vec2(dot(viewRay, tangentX), dot(viewRay, tangentY)) / max(radius, 1e-4);
    rim = length(offset);
    if (rim > 1.0) {
        normal = -moonDir;
        return false;
    }
    normal = normalize(tangentX * offset.x + tangentY * offset.y
                     - moonDir * sqrt(max(1.0 - rim * rim, 0.0)));
    return true;
}

/**
 * Illumination direction for the moon, from the phase index.
 *
 * The moon sits exactly opposite the sun in this sky, so the real sun direction lights the whole
 * near hemisphere and every night is full. The index becomes an angle instead: 0 puts the light
 * behind the viewer (full), 4 behind the moon (new), and values between place the terminator as a
 * curve across the sphere.
 */
vec3 plagueMoonLightDir(vec3 moonDir, float phaseIndex) {
    float phase = PLAGUE_CELESTIAL_TAU * clamp(phaseIndex, 0.0, 7.0) / 8.0;
    vec3 tangentX, tangentY;
    plagueCelestialBasis(moonDir, tangentX, tangentY);
    return normalize(-moonDir * cos(phase) + tangentX * sin(phase));
}

/**
 * Lommel-Seeliger reflectance, the standard photometric law for a lunar regolith: I = mu0/(mu0+mu).
 *
 * Not Lambert. Regolith backscatters, so the disc reads nearly flat in brightness out to the rim
 * rather than falling off toward it, and the terminator stays sharp. mu is the cosine to the
 * viewer, which for this orthographic disc is exactly the normal's component along the view.
 */
vec3 plagueShadeMoonSphere(vec3 normal, float rim, vec3 lightDir, vec3 moonRadiance,
                           float rainFactor) {
    float mu0 = max(dot(normal, lightDir), 0.0);
    float mu = sqrt(max(1.0 - rim * rim, 0.0));
    float reflectance = mu0 / max(mu0 + mu, 1e-4);
    // Flat albedo: an albedo map multiplies in here, and the maria are what it adds.
    return moonRadiance * reflectance * plagueDiscCoverageRadial(rim, rainFactor);
}

/**
 * @param sunDirTrue the TRUE sun direction; the moon is its negation, vanilla's own convention
 * @param moonPhaseIndex u_SkyCelestial.w, 0 full through 4 new; sets where the terminator sits
 * @param moonGlow   night ramp for the moon, so it is not painted onto a bright afternoon sky
 */
vec3 plagueCelestialDiscs(vec3 viewRay, vec3 sunDirTrue, float moonPhaseIndex,
                          float invRainFactor, float moonGlow,
                          vec3 sunRadiance, vec3 moonRadiance) {
    vec3 result = vec3(0.0);

    // The sun needs no sprite: its disc is a shape, and the shape is analytic. It therefore draws
    // whether or not the atlas was captured, which the moon below cannot.
    if (plagueFacingCelestial(viewRay, sunDirTrue)) {
        vec2 uv = plagueCelestialUv(viewRay, sunDirTrue, max(u_SunDiscSize, 0.001));
        result += plagueShadeSunDisc(uv, sunRadiance, 1.0 - invRainFactor)
                * (u_SunDiscBrightness * invRainFactor);
    }

    vec3 moonDir = -sunDirTrue;
    if (plagueFacingCelestial(viewRay, moonDir)) {
        vec3 normal;
        float rim;
        if (plagueMoonSurface(viewRay, moonDir, max(u_MoonDiscSize, 0.001), normal, rim)) {
            vec3 lightDir = plagueMoonLightDir(moonDir, moonPhaseIndex);
            result += plagueShadeMoonSphere(normal, rim, lightDir, moonRadiance,
                                            1.0 - invRainFactor)
                    * (u_MoonDiscBrightness * moonGlow * invRainFactor);
        }
    }

    return result;
}

#endif // PLAGUE_CELESTIALS
