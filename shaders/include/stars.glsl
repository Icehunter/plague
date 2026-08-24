#ifndef PLAGUE_STARS
#define PLAGUE_STARS

#moj_import <fornax_runtime:sky_hash.glsl>

// Stars are a hashed lattice, not a texture or point list: the view direction projects onto a
// plane cut into cells, and a cell holds a star when its hash clears a cutoff — so star COUNT is a
// probability (density * lattice^2), and the amount setting moves the cutoff, not a scale.
//
// The lattice resolution (PLAGUE_STAR_LATTICE) is set by TEMPORAL STABILITY, not visual size: the
// engine's temporal pass rejects history on every camera-rotation frame (reprojection lands on a
// star-less pixel), so a star must read correctly in one frame — it cannot borrow accumulated
// brightness. Enlarging cell size to fix single-frame flicker was tried and FALSIFIED (the fade
// survived unaltered); that symptom lives in the engine's temporal pass, not here — see
// tools/verify_star_trails.py.
//
// Brightness distribution follows real starlight: raising a uniform hash to a power
// (PLAGUE_STAR_MAGNITUDE_FALLOFF) reproduces the roughly-3x-per-magnitude population curve with no
// hand-picked threshold table.
//
// Time is in SECONDS at the call site; u_SkyState.w is ticks, converted (*0.05) where read.

#define PLAGUE_STAR_AMOUNT 2 //[0 1 2 3 4] compile "Star Amount" {0="None" 1="Sparse" 2="Default" 3="Rich" 4="Dense"}
#define u_StarSize 1.0 //[0.50..2.00 step 0.05] runtime "Star Size"
#define u_StarRoundness 1.0 //[-1.00..1.00 step 0.05] runtime "Star Roundness"
#define u_StarSoftness 0.0 //[0.00..1.00 step 0.05] runtime "Star Softness"
// Multiplier on the derived population below, so the derivation stays the anchor and this is a
// deliberate departure from it rather than a free-floating number.
#define u_StarDensity 1.0 //[0.25..3.00 step 0.05] runtime "Star Density"
#define u_StarMagnitudeFalloff 3.0 //[1.00..6.00 step 0.10] runtime "Star Magnitude Falloff"
#define u_StarBrightness 1.0 //[0.00..3.00 step 0.05] runtime "Star Brightness"
#define u_StarColorSpread 0.22 //[0.00..1.00 step 0.02] runtime "Star Colour Spread"

// Bends the gnomonic projection back toward the sphere so cells stay finite near the horizon
// (a pure gnomonic plane stretches without limit there).
const float PLAGUE_STAR_SPHERENESS = 0.5;

// 380: 2*tan(35 deg) screen span over a 2000px-wide present, ~0.0007 UV/pixel, landing on a 3.7px star.
const float PLAGUE_STAR_LATTICE = 380.0;

// Fraction of cells holding a star, DERIVED from a target count (density * lattice^2): a few
// hundred stars in a 70-degree view, matching what the naked eye sees of ~2500 over a whole sky.
const float PLAGUE_STAR_DENSITY = 0.00171;

// Chromaticity only; brightness is PLAGUE_STAR_GAIN, kept separate so the two tune independently.
// Integrated starlight is slightly blue of white, so green and blue lead.
const vec3 PLAGUE_STAR_COLOR = vec3(0.84, 0.90, 1.00);
const float PLAGUE_STAR_GAIN = 13.0;

// Angular radius (dot-product units) of the hole kept clear around the sun and moon.
const float PLAGUE_STAR_SUN_CLEARANCE = 0.035;

// Radians/second about the celestial axis: a Minecraft day is 1200 seconds, so 2*pi/1200.
const float PLAGUE_STAR_ROTATION_RATE = 0.005236;

const float PLAGUE_STAR_EDGE_SOFTNESS = 0.16;

// Elevation over which the field fades in above the horizon, hiding the gnomonic projection's
// smear in the last few degrees rather than tuning appearance.
const float PLAGUE_STAR_HORIZON_FADE = 2.6;

// Chebyshev distance draws a square, Euclidean a circle; `roundness` mixes between them. Round is
// default: at one to three pixels across, a square star reads as a rendering artifact.
float plagueStarEdgeWidth(float softness, float footprint) {
    return max(PLAGUE_STAR_EDGE_SOFTNESS + softness * 0.4, footprint);
}

float plagueStarEdgeFactor(vec2 fractPart, float roundness, float edgeWidth) {
    vec2 fromCentre = fractPart - 0.5;
    float euclidean = length(fromCentre);
    float chebyshev = max(abs(fromCentre.x), abs(fromCentre.y));
    float shape = mix(chebyshev, euclidean, clamp(roundness * 0.5 + 0.5, 0.0, 1.0));
    // The feather resolves coverage ANALYTICALLY rather than relying on temporal accumulation:
    // widened to at least the screen footprint (`footprint`, from the caller's fwidth) so one
    // frame already carries the average a jittered point sample would otherwise lose on turning.
    // Fragment stage only, for that reason.
    return smoothstep(0.5, 0.5 - edgeWidth, shape);
}

// Dividing by y is a gnomonic projection: the hemisphere maps onto a plane, so the lattice is
// uniform in the plane rather than on the sphere.
vec2 plagueStarCoord(vec3 viewRay, float sphereness, float syncedTime) {
    vec3 wpos = normalize(viewRay);

    // Rotates the unit DIRECTION, not the projected plane coordinate: the gnomonic projection is
    // nonlinear in angle, so translating the plane coordinate would drift stars at different rates
    // by position and pull the constellations apart instead of turning them rigidly.
    float angle = PLAGUE_STAR_ROTATION_RATE * syncedTime;
    float s = sin(angle);
    float c = cos(angle);
    wpos.xz = mat2(c, -s, s, c) * wpos.xz;

    vec3 starCoord = wpos / (wpos.y + length(wpos.xz) * sphereness);
    return starCoord.xz;
}

/**
 * @param VdotU          view dotted with world up; below the horizon there is no plane to project
 * @param VdotS          view dotted with the TRUE sun, for the clearance hole
 * @param invNoonFactor2 (1 - noonFactor)^2, the day/night crossfade the pack is keyed on
 * @param starBrightness vanilla's own dusk/dawn star ramp
 */
vec3 plagueGetStars(vec2 starCoord, float VdotU, float VdotS, float sizeMult, float starAmount,
                    float invNoonFactor2, float sunVisibility, float invRainFactor,
                    float starBrightness) {
#if PLAGUE_STAR_AMOUNT == 0
    return vec3(0.0);
#else
    if (VdotU < 0.0) {
        return vec3(0.0);
    }
    float horizonFade = min(VdotU * PLAGUE_STAR_HORIZON_FADE, 1.0);

#if PLAGUE_STAR_AMOUNT == 1
    float density = PLAGUE_STAR_DENSITY * 0.4 * u_StarDensity;
#elif PLAGUE_STAR_AMOUNT == 2
    float density = PLAGUE_STAR_DENSITY * u_StarDensity;
#elif PLAGUE_STAR_AMOUNT == 3
    float density = PLAGUE_STAR_DENSITY * 2.0 * u_StarDensity;
#else
    float density = PLAGUE_STAR_DENSITY * 3.5 * u_StarDensity;
#endif
    density = max(density - starAmount * 0.01, 0.0);
    if (density <= 0.0) {
        return vec3(0.0);
    }

    float lattice = PLAGUE_STAR_LATTICE / max(u_StarSize * sizeMult, 1e-3);
    vec2 scaled = starCoord * lattice;
    vec2 cell = floor(scaled);
    vec2 fractPart = fract(scaled);

    // Lattice cells per pixel; grows near the horizon where the projection stretches, widening the
    // feather to match and keeping the field from aliasing into sparkle there.
    vec2 fw = fwidth(scaled);
    float footprint = clamp(max(fw.x, fw.y), 0.0, 0.5);

    float h = plagueHash12(cell);
    float cutoff = 1.0 - density;
    if (h < cutoff) {
        return vec3(0.0);
    }
    float magnitude = pow((h - cutoff) / density, u_StarMagnitudeFalloff);

    float edgeWidthUsed = plagueStarEdgeWidth(u_StarSoftness, footprint);
    magnitude *= plagueStarEdgeFactor(fractPart, u_StarRoundness, edgeWidthUsed);

    // Energy correction: widening the feather spreads the star over more of its cell, so
    // cell-integrated brightness falls nonlinearly. MEASURED fit of that loss's inverse: 1.00 at
    // base width, 1.24 at a quarter-cell, 2.37 at the half-cell clamp.
    float dw = max(edgeWidthUsed - PLAGUE_STAR_EDGE_SOFTNESS, 0.0);
    magnitude *= 1.0 + 2.03 * dw + 5.88 * dw * dw;

    // Decorrelated hash tints the star warm/cool around the field's own chromaticity.
    float tint = plagueHash12(cell + 19.7) * 2.0 - 1.0;
    vec3 colour = PLAGUE_STAR_COLOR * (1.0 + u_StarColorSpread * vec3(tint, 0.0, -tint));

    float clearance = smoothstep(1.0 - PLAGUE_STAR_SUN_CLEARANCE, 1.0, abs(VdotS));
    magnitude *= (1.0 - clearance) * horizonFade;

    // Fourth power makes the daylight crossfade decisive rather than gradual.
    float invNoon4 = invNoonFactor2 * invNoonFactor2;
    magnitude *= invNoon4 * invNoon4 * (1.0 - 0.5 * sunVisibility);
    magnitude *= invRainFactor;

    return PLAGUE_STAR_GAIN * u_StarBrightness * max(magnitude, 0.0) * colour * starBrightness;
#endif
}

#endif // PLAGUE_STARS
