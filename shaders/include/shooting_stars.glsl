#ifndef PLAGUE_SHOOTING_STARS_INC
#define PLAGUE_SHOOTING_STARS_INC

#moj_import <fornax_runtime:sky_hash.glsl>

// Meteors: a hashed cell grid on the star plane, translated by time. A cell that clears a rare
// threshold draws one streak (a capsule around a line segment, trail behind, bright head at the
// tip).
//
// No position/direction tables: a meteor's direction is `normalize(position - radiant)`, one
// hashed point per night, so streaks diverge from a shared radiant the way a real shower does
// (perspective on parallel bodies) rather than reading as unrelated scratches.
//
// Start positions come from a golden-angle spiral: successive angles differing by the golden angle
// is the standard way to place points with no clumping and no radial spokes (why sunflower seeds
// pack that way).
//
// Time is in SECONDS at the call site; a Minecraft day is 24000 ticks == 1200 seconds, which is
// where the night index below comes from.

#define PLAGUE_SHOOTING_STARS //[] compile "Shooting Stars"
#define PLAGUE_SS_COUNT 4 //[1 2 3 4 5 6 7 8 9 10] compile "Shooting Star Count"
#define u_ShootingStarSpeed 8.0 //[4.00..15.00 step 0.25] runtime "Shooting Star Speed"
#define u_ShootingStarChance 0.5 //[0.10..1.00 step 0.05] runtime "Shooting Star Frequency"
#define u_ShootingStarSize 0.50 //[0.20..0.85 step 0.01] runtime "Shooting Star Size"
#define u_ShootingStarThickness 0.60 //[0.20..2.00 step 0.05] runtime "Shooting Star Thickness"
#define u_ShootingStarTrail 0.60 //[0.20..1.50 step 0.05] runtime "Shooting Star Trail Length"
#define u_ShootingStarBrightness 1.0 //[0.00..3.00 step 0.05] runtime "Shooting Star Brightness"


// The golden angle, 2*pi*(1 - 1/phi), in radians. Placing successive points this far apart is what
// keeps them from clumping or forming spokes.
const float PLAGUE_SS_GOLDEN_ANGLE = 2.39996323;

// How far out the spiral reaches, in cell units. Below the cell's own half-width so a streak starts
// inside its own cell rather than on the boundary.
const float PLAGUE_SS_SPIRAL_RADIUS = 0.62;

// A meteor is brighter than the stars it crosses; that is the entire reason it reads as one.
const float PLAGUE_SS_GAIN = 26.0;

// Derived from a rate, not picked: naked-eye sporadic rate is ~6/hour, a shower peak an order of
// magnitude above; the per-cell probability lands near the upper end of that range across the
// patch the loop covers. The gamma shapes the user's control so the slider is perceptually even
// rather than linear in a very small number.
const float PLAGUE_SS_BASE_RATE = 0.00042;
const float PLAGUE_SS_CHANCE_GAMMA = 1.7;

// Moon washout. A full moon is roughly a magnitude and a half of sky brightness over a new moon,
// which removes most of the faint end of any shower, so the span is wide.
const float PLAGUE_SS_MOON_MIN = 0.55;
const float PLAGUE_SS_MOON_MAX = 1.9;

// The head. A meteor's light curve peaks sharply at the leading point and decays behind it; these
// set how tight that peak is and how far above the trail it rises.
const float PLAGUE_SS_HEAD_TIGHTNESS = 11.0;
const float PLAGUE_SS_HEAD_RISE = 4.5;

/** Distance from p to the segment a..b. The streak is a capsule around this. */
float plagueDistLine(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * t);
}

// The length term fades a streak as it grows past unit length, so a meteor brightens partway
// through its travel and then goes out rather than sliding across at constant brightness.
float plagueDrawLine(vec2 p, vec2 a, vec2 b) {
    float d = plagueDistLine(p, a, b);
    float m = smoothstep(u_ShootingStarThickness * 0.01, 0.00001, d);
    float span = length(a - b);
    m *= smoothstep(1.0, 0.45, span);
    return m;
}

/** The i'th start position on the golden-angle spiral. */
vec2 plagueShootingStarOrigin(int i, float nightIndex) {
    float fi = float(i);
    // sqrt of the index keeps the points area-uniform rather than crowding the centre.
    float radius = PLAGUE_SS_SPIRAL_RADIUS * sqrt((fi + 0.5) / 10.0);
    // The night rotates the whole spiral, so consecutive nights do not repeat the same layout.
    float angle = fi * PLAGUE_SS_GOLDEN_ANGLE + nightIndex * 1.1;
    return radius * vec2(cos(angle), sin(angle));
}

/**
 * One candidate meteor in one cell.
 *
 * The hash threshold is what makes them rare, so almost every cell returns immediately. Moon phase
 * modulates it: a new moon is a darker sky and lets more through.
 */
float plagueShootingStar(vec2 uv, vec2 startPos, vec2 direction, float moonPhase) {
    vec2 id = floor(uv * 0.5);
    float h = plagueHash12(id);

    float newMoonVisibility = 1.0 - abs(moonPhase - 4.0) / 4.0;
    float moonPhaseFactor = mix(PLAGUE_SS_MOON_MIN, PLAGUE_SS_MOON_MAX, newMoonVisibility);

    float threshold = PLAGUE_SS_BASE_RATE * pow(u_ShootingStarChance, PLAGUE_SS_CHANCE_GAMMA);
    if (h >= threshold * moonPhaseFactor) {
        return 0.0;
    }

    vec2 gv = fract(uv * 0.5) * 2.0 - 1.0;
    float line = plagueDrawLine(gv, startPos, startPos + direction * 0.9);

    float alongTrail = dot(gv - startPos, direction);
    float trail = smoothstep(u_ShootingStarTrail, -0.1, alongTrail);

    // A sharp reciprocal spike at the leading end: the head, several times the trail's brightness
    // at the tip and falling off fast behind it.
    float headOffset = (alongTrail - 1.0) * PLAGUE_SS_HEAD_TIGHTNESS;
    float headBrightness = 1.0 + PLAGUE_SS_HEAD_RISE / (1.0 + headOffset * headOffset);

    return line * trail * headBrightness;
}

/**
 * The whole field.
 *
 * @param starCoord the STAR FIELD's own coordinate, reused directly
 * @param VdotS     view dotted with the TRUE sun
 */
vec3 plagueGetShootingStars(vec2 starCoord, float VdotU, float VdotS, float syncedTime,
                            float invNoonFactor2, float sunVisibility, float invRainFactor,
                            float starBrightness, float moonPhase) {
#ifndef PLAGUE_SHOOTING_STARS
    return vec3(0.0);
#else
    if (VdotU < 0.0) {
        return vec3(0.0);
    }
    float horizonFade = min(VdotU * 3.0, 1.0);

    float visibility = max(1.0 - 1.0 / (1.0 + abs(VdotS) * 1000.0), 0.0) * horizonFade;

    // The same day/night curve the star field uses, so meteors and stars appear and vanish together.
    float invNoon4 = invNoonFactor2 * invNoonFactor2;
    visibility *= invNoon4 * invNoon4 * (1.0 - 0.5 * sunVisibility);
    visibility *= invRainFactor;

    if (visibility <= 0.01) {
        return vec3(0.0);
    }

    vec2 uv = starCoord * 6.0 * (1.0 - u_ShootingStarSize);
    float speed = syncedTime * u_ShootingStarSpeed;
    float nightIndex = floor(syncedTime / 1200.0);

    // Tonight's radiant, somewhere off the patch so the trails diverge across it rather than
    // fanning out from a point in the middle of view.
    vec2 radiantHash = plagueHash22(vec2(nightIndex, 7.0));
    vec2 radiant = (radiantHash * 2.0 - 1.0) * 2.2;

    float stars = 0.0;
    for (int i = 0; i < PLAGUE_SS_COUNT; i++) {
        vec2 origin = plagueShootingStarOrigin(i, nightIndex);
        // Direction is geometry, not a stored value: away from the radiant, from where this one is.
        vec2 direction = normalize(origin - radiant);

        // Slightly different speed per streak, so they do not travel as a rigid formation.
        vec2 offsetUV = uv + direction * speed * (0.8 + 0.04 * float(i));
        stars += plagueShootingStar(offsetUV, origin, direction, moonPhase);
    }

    // Meteors are hotter than the ambient star field: ablating rock runs yellow-white rather than
    // blue-white, so they take the star chromaticity warmed toward neutral.
    vec3 meteorColour = mix(PLAGUE_STAR_COLOR, vec3(1.0, 0.97, 0.88), 0.55);
    float intensity = min(stars * visibility, 1.0);
    return meteorColour * intensity * PLAGUE_SS_GAIN * u_ShootingStarBrightness * starBrightness;
#endif
}

#endif // PLAGUE_SHOOTING_STARS_INC
