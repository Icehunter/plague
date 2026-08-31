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
const float PLAGUE_MOON_DISC_RADIUS = 0.1974;

// The sun's angular radius, radians. 0.00465 is the real sun, eight pixels across at 1080p and a
// 70-degree vertical FOV; 0.2915 is vanilla's quad. Above about 0.12 the disc is wider than its own
// aureole (u_SunGlowStrength's falloff) and covers it.
#define u_SunDiscSize 0.090 //[0.010..0.300 step 0.005] runtime "Sun Size"

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
// Atlas coordinate for a sprite, held half a texel inside its own rect. uv spans [0,1] inclusive,
// so an un-inset sample at 0 or 1 sits exactly on the rect boundary and linear filtering pulls in
// whatever the atlas packs next to it. The celestials atlas carries the sun and all eight moon
// phases side by side, so that neighbour draws as a bright frame around the disc, brightest where
// the sprite itself is dark and hides nothing.
vec2 plagueCelestialAtlasUv(sampler2D celestials, vec4 rect, vec2 uv) {
    vec2 halfTexel = 0.5 / vec2(textureSize(celestials, 0));
    return clamp(mix(rect.xy, rect.zw, uv), rect.xy + halfTexel, rect.zw - halfTexel);
}

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

float plagueDiscCoverage(vec3 texel, float rainFactor) {
    float brightness = dot(texel, vec3(0.2126, 0.7152, 0.0722));
    float feather = PLAGUE_DISC_FEATHER * (1.0 + 2.0 * rainFactor);
    // Clamped at 0: past rainFactor ~0.32 the unclamped edge goes negative, so background
    // brightness (0) stops mapping to exactly zero coverage, tinting the disc's whole quad.
    return smoothstep(max(PLAGUE_DISC_EDGE - feather, 0.0), PLAGUE_DISC_EDGE + feather, brightness);
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

vec3 plagueShadeMoonDisc(vec3 texel, vec3 moonRadiance, float rainFactor) {
    return moonRadiance * plagueDiscCoverage(texel, rainFactor);
}

/**
 * @param sunDirTrue the TRUE sun direction; the moon is its negation, vanilla's own convention
 * @param moonRect   the same for THIS frame's moon phase; the engine has already selected it
 * @param moonGlow   night ramp for the moon, so it is not painted onto a bright afternoon sky
 */
vec3 plagueCelestialDiscs(vec3 viewRay, vec3 sunDirTrue, sampler2D celestials,
                          vec4 moonRect,
                          float invRainFactor, float moonGlow,
                          vec3 sunRadiance, vec3 moonRadiance) {
    // Zero-rect means the atlas wasn't captured this session (headless frame, or reload in flight);
    // sampling it would fetch texel 0 and paint a stray square on the sky. Only the moon reads the
    // atlas, so only the moon is gated on it.
    bool moonRectValid = moonRect.z > moonRect.x && moonRect.w > moonRect.y;

    vec3 result = vec3(0.0);

    // The sun needs no sprite: its disc is a shape, and the shape is analytic. It therefore draws
    // whether or not the atlas was captured, which the moon below cannot.
    if (plagueFacingCelestial(viewRay, sunDirTrue)) {
        vec2 uv = plagueCelestialUv(viewRay, sunDirTrue, max(u_SunDiscSize, 0.001));
        result += plagueShadeSunDisc(uv, sunRadiance, 1.0 - invRainFactor)
                * (u_SunDiscBrightness * invRainFactor);
    }

    vec3 moonDir = -sunDirTrue;
    if (moonRectValid && plagueFacingCelestial(viewRay, moonDir)) {
        vec2 uv = plagueCelestialUv(viewRay, moonDir, PLAGUE_MOON_DISC_RADIUS);
        if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
            vec4 texel = texture(celestials, plagueCelestialAtlasUv(celestials, moonRect, uv));
            // Same rule. The phase lives in the sprite, as black rgb or as zero alpha; the
            // multiply honours either.
            result += plagueShadeMoonDisc(texel.rgb * texel.a, moonRadiance, 1.0 - invRainFactor)
                    * (u_MoonDiscBrightness * moonGlow * invRainFactor);
        }
    }

    return result;
}

#endif // PLAGUE_CELESTIALS
