#ifndef PLAGUE_CELESTIALS
#define PLAGUE_CELESTIALS

// Sun and moon discs, from vanilla's celestials atlas (builtin.celestials + this frame's sprite
// rects). Placed here rather than through vanilla's sky-textured geometry stage because
// SKY_PROCEDURAL cancels vanilla's sky pass outright, so its quads are never submitted; drawing
// from the real atlas (not a procedural blob) keeps resource-pack sun/moon art and moon phases
// working, since 26.2 stores each phase as its own sprite.
//
// Both discs are found by ANGLE: the rejection of viewRay onto the celestial direction gives a
// local disc-space UV with no matrix or screen position, so it stays correct at any FOV.

// Angular radius, DERIVED from vanilla's SkyRenderer geometry: sun quad half-width 30, moon 20,
// both at distance 100, giving atan(30/100)=0.2915 rad and atan(20/100)=0.1974 rad. ~60x the real
// sun/moon's ~0.5-degree size (0.00465 rad, the figure brdf.glsl uses for solar solid angle) —
// deliberate, matching vanilla, since a physically-sized sun is a handful of pixels.
const float PLAGUE_SUN_DISC_RADIUS  = 0.2915;
const float PLAGUE_MOON_DISC_RADIUS = 0.1974;

// Multiples of each body's OWN radiance (not an absolute), so brightness stays meaningful as the
// atmosphere's colour changes. The sun's default is >1 to survive the aureole drawn around it.
#define u_SunDiscBrightness 9.0 //[0.00..30.00 step 0.50] runtime "Sun Disc Brightness"
#define u_MoonDiscBrightness 3.0 //[0.00..12.00 step 0.25] runtime "Moon Disc Brightness"

// Disc-local UV for a view ray against a celestial direction, or outside 0..1 when the ray misses.
vec2 plagueCelestialUv(vec3 viewRay, vec3 dir, float radius) {
    // Any vector not parallel to dir works as a basis seed; world up fails only when looking exactly
    // at the zenith celestial, so swap seeds near the pole rather than producing a degenerate basis.
    vec3 seed = abs(dir.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 tangentX = normalize(cross(seed, dir));
    vec3 tangentY = cross(dir, tangentX);

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
float plagueDiscCoverage(vec3 texel, float rainFactor) {
    float brightness = dot(texel, vec3(0.2126, 0.7152, 0.0722));
    float feather = PLAGUE_DISC_FEATHER * (1.0 + 2.0 * rainFactor);
    // Clamped at 0: past rainFactor ~0.32 the unclamped edge goes negative, so background
    // brightness (0) stops mapping to exactly zero coverage, tinting the disc's whole quad.
    return smoothstep(max(PLAGUE_DISC_EDGE - feather, 0.0), PLAGUE_DISC_EDGE + feather, brightness);
}

vec3 plagueShadeSunDisc(vec3 texel, vec2 discUv, vec3 sunRadiance, float rainFactor) {
    // mu = cosine of the angle between the sightline and the disc's surface normal there, which
    // the limb-darkening law is a function of.
    vec2 fromCentre = discUv * 2.0 - 1.0;
    float radius = min(length(fromCentre), 1.0);
    float mu = sqrt(max(1.0 - radius * radius, 0.0));
    float limb = 1.0 - PLAGUE_SUN_LIMB_DARKENING * (1.0 - mu);

    return sunRadiance * plagueDiscCoverage(texel, rainFactor) * limb;
}

vec3 plagueShadeMoonDisc(vec3 texel, vec3 moonRadiance, float rainFactor) {
    return moonRadiance * plagueDiscCoverage(texel, rainFactor);
}

/**
 * @param sunDirTrue the TRUE sun direction; the moon is its negation, vanilla's own convention
 * @param sunRect    {u0, v0, u1, v1} of the sun sprite in the atlas
 * @param moonRect   the same for THIS frame's moon phase; the engine has already selected it
 * @param moonGlow   night ramp for the moon, so it is not painted onto a bright afternoon sky
 */
vec3 plagueCelestialDiscs(vec3 viewRay, vec3 sunDirTrue, sampler2D celestials,
                          vec4 sunRect, vec4 moonRect,
                          float invRainFactor, float moonGlow,
                          vec3 sunRadiance, vec3 moonRadiance) {
    // Zero-rect means the atlas wasn't captured this session (headless frame, or reload in flight);
    // sampling it would fetch texel 0 and paint a stray square on the sky.
    bool sunRectValid  = sunRect.z  > sunRect.x  && sunRect.w  > sunRect.y;
    bool moonRectValid = moonRect.z > moonRect.x && moonRect.w > moonRect.y;
    if (!sunRectValid && !moonRectValid) {
        return vec3(0.0);
    }

    vec3 result = vec3(0.0);

    if (sunRectValid && plagueFacingCelestial(viewRay, sunDirTrue)) {
        vec2 uv = plagueCelestialUv(viewRay, sunDirTrue, PLAGUE_SUN_DISC_RADIUS);
        if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
            vec4 texel = texture(celestials, mix(sunRect.xy, sunRect.zw, uv));
            // Additive, premultiplied by the sprite's alpha. Additive blending hides the corners
            // only where the art is opaque on black; a disc on transparent carries white rgb in its
            // transparent pixels, and adding rgb alone paints the whole sprite square. Opaque art
            // has alpha 1 throughout, so the multiply is a no-op there.
            result += plagueShadeSunDisc(texel.rgb * texel.a, uv, sunRadiance, 1.0 - invRainFactor)
                    * (u_SunDiscBrightness * invRainFactor);
        }
    }

    vec3 moonDir = -sunDirTrue;
    if (moonRectValid && plagueFacingCelestial(viewRay, moonDir)) {
        vec2 uv = plagueCelestialUv(viewRay, moonDir, PLAGUE_MOON_DISC_RADIUS);
        if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
            vec4 texel = texture(celestials, mix(moonRect.xy, moonRect.zw, uv));
            // Same rule. The phase lives in the sprite, as black rgb or as zero alpha; the
            // multiply honours either.
            result += plagueShadeMoonDisc(texel.rgb * texel.a, moonRadiance, 1.0 - invRainFactor)
                    * (u_MoonDiscBrightness * moonGlow * invRainFactor);
        }
    }

    return result;
}

#endif // PLAGUE_CELESTIALS
