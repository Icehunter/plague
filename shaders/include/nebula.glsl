#ifndef PLAGUE_NEBULA
#define PLAGUE_NEBULA

#moj_import <fornax_runtime:sky_hash.glsl>

// The night nebula. Shares the star field's projection (requires stars.glsl for plagueStarCoord) so
// the two sit in one sky rather than sliding against each other as separate layers.
//
// Palette is emission spectroscopy, not authored tint: real emission nebulae glow at discrete lines
// (H-alpha 656nm red, O-III 501nm teal, H-beta 486nm blue), so colour here is a function of DENSITY
// (thin gas reads red H-alpha, dense hot cores swing teal with O-III) rather than a set of tints.
//
// Structure is layered fractal noise at different drift rates for parallax depth, with faint stars
// embedded so it doesn't read as flat fog. Time is in SECONDS at the call site.

#define PLAGUE_NEBULA_ENABLED //[] compile "Night Nebula"

#define u_NebulaIntensity 1.0 //[0.00..2.00 step 0.05] runtime "Nebula Intensity"
#define u_NebulaZoom 3.5 //[1.00..5.00 step 0.05] runtime "Nebula Zoom"
#define u_NebulaAmount 0.5 //[0.15..0.70 step 0.01] runtime "Nebula Amount"
// Where the hydrogen envelope gives way to the ionised (teal) core, and over how much density.
#define u_NebulaIonisedOnset 0.06 //[0.00..0.60 step 0.01] runtime "Nebula Core Onset"
#define u_NebulaIonisedWidth 0.34 //[0.05..0.90 step 0.01] runtime "Nebula Core Blend"
#define u_NebulaDrift 1.0 //[0.00..4.00 step 0.05] runtime "Nebula Drift Speed"
#define u_NebulaStarGlow 7.0 //[0.00..20.00 step 0.5] runtime "Nebula Star Glow"

// Bent further toward the sphere than the star field: a gnomonic-stretched cloud smears at the
// horizon, where individual stars still read as points.
const float PLAGUE_NEBULA_SPHERENESS = 0.75;

const int PLAGUE_NEBULA_OCTAVES = 5;

// Emission line chromaticities, approximate sRGB for each wavelength above.
const vec3 PLAGUE_NEBULA_H_ALPHA = vec3(0.90, 0.38, 0.46);
const vec3 PLAGUE_NEBULA_O_III   = vec3(0.44, 0.86, 0.76);
const vec3 PLAGUE_NEBULA_H_BETA  = vec3(0.44, 0.52, 0.94);

// The End's core line, standing where O-III stands in an Overworld nebula. There is no oxygen in a
// dead cloud, so the green goes and what is left of hydrogen past H-beta is the violet pair:
// H-gamma 434.0 nm and H-delta 410.2 nm, mixed at the Case B recombination ratios 0.468 and 0.259
// (Osterbrock & Ferland, Astrophysics of Gaseous Nebulae and Active Galactic Nuclei, 2nd ed. 2006,
// table 4.4, T = 10^4 K, n_e = 10^2 per cm^3). Red and violet with no green between them is why
// the End reads purple, and it is a property of the gas rather than a colour anyone picked.
//
// Wavelengths to sRGB by the same analytic CIE fit the other three use (Wyman, Sloan & Shirley,
// JCGT 2(2), 2013), then pulled toward white by the same amount, since one pure colour on its
// own falls outside what a screen can show and comes out harsh.
const vec3 PLAGUE_NEBULA_H_GAMMA = vec3(0.49, 0.38, 1.00);

// Slow: a nebula that visibly churns reads as smoke.
const float PLAGUE_NEBULA_TIMESCALE = 0.012;

// Density at which O-III starts to take over from H-alpha (below red, above teal).
const float PLAGUE_NEBULA_IONISED_ONSET = 0.42;
const float PLAGUE_NEBULA_IONISED_WIDTH = 0.30;

// Sparser/dimmer than the main star field, at a coarser lattice, so they read as embedded rather
// than as the field showing through.
const float PLAGUE_NEBULA_STAR_LATTICE = 150.0;
const float PLAGUE_NEBULA_STAR_DENSITY = 0.030;


/**
 * The cloud, its stars, and its fade.
 *
 * @param VdotU  view dotted with up; nebula visibility grows with elevation, same as the star field
 * @param VdotS  view dotted with the TRUE sun; clears the same region the star field clears
 * @param nightFactor  gates visibility so the nebula fades in only after true night
 */
struct PlagueNebulaTuning {
    float intensity;   // overall strength
    float zoom;        // feature size
    float amount;      // how much of the sky the cloud covers
    float coreOnset;   // density at which the core line takes over
    float coreWidth;   // how gradually it does
    float drift;       // how fast it moves
    float starGlow;    // how much the stars behind it glow through
};

PlagueNebulaTuning plagueNebulaTuningSky() {
    return PlagueNebulaTuning(u_NebulaIntensity, u_NebulaZoom, u_NebulaAmount,
                              u_NebulaIonisedOnset, u_NebulaIonisedWidth, u_NebulaDrift,
                              u_NebulaStarGlow);
}

vec3 plagueGetNebulaField(vec3 viewRay, float visibility, float VdotS, float syncedTime,
                          vec3 coreColour, float starBrightness, PlagueNebulaTuning tune);

vec3 plagueGetNightNebula(vec3 viewRay, float VdotU, float VdotS, float syncedTime,
                          float nightFactor, float invRainFactor, float starBrightness) {
#ifndef PLAGUE_NEBULA_ENABLED
    return vec3(0.0);
#else
    float elevation = max(VdotU, 0.0);

    // Concentrated overhead and gone at the horizon; gated on night twice (ramp, then squared).
    float visibility = elevation * min(nightFactor * 2.0, 1.0);
    visibility *= visibility;
    visibility *= invRainFactor;
    return plagueGetNebulaField(viewRay, visibility, VdotS, syncedTime,
                                PLAGUE_NEBULA_O_III, starBrightness, plagueNebulaTuningSky());
#endif
}

/**
 * The cloud itself, with the caller supplying how visible it is and which line its dense cores
 * burn. Split out so the End can hand it a sky with no night in it and a core with no oxygen.
 */
vec3 plagueGetNebulaField(vec3 viewRay, float visibility, float VdotS, float syncedTime,
                          vec3 coreColour, float starBrightness, PlagueNebulaTuning tune) {
#ifndef PLAGUE_NEBULA_ENABLED
    return vec3(0.0);
#else

    // Skips the octaves below for every daytime and near-horizon pixel, which is most of them.
    if (visibility < 0.001) {
        return vec3(0.0);
    }

    vec2 uv = plagueStarCoord(viewRay, PLAGUE_NEBULA_SPHERENESS, syncedTime);
    float t = syncedTime * PLAGUE_NEBULA_TIMESCALE * tune.drift;
    vec2 scaled = uv * tune.zoom;

    // Three layers drifting at different rates/directions; only that they disagree matters.
    float layerFar = plagueSkyFbm(scaled + vec2(t * 0.31, t * 0.17), PLAGUE_NEBULA_OCTAVES);
    float layerMid = plagueSkyFbm(scaled * 1.7 + vec2(-t * 0.44, t * 0.26), PLAGUE_NEBULA_OCTAVES);
    float layerNear = plagueSkyFbm(scaled * 2.9 + vec2(t * 0.21, -t * 0.38), PLAGUE_NEBULA_OCTAVES - 1);

    // Weighted so the broad layer sets the shape and the finer ones only texture it.
    float density = layerFar * 0.55 + layerMid * 0.30 + layerNear * 0.15;

    // The field measures mean 0.50, stddev 0.127, so the cutoff has to sit inside that range or it
    // passes the whole sky or none of it. At the default amount this covers ~11% of the sky, ~2.5%
    // dense enough for a core; raising the amount grows clouds outward from their cores.
    float cut = mix(0.74, 0.54, clamp(tune.amount, 0.0, 1.0));
    density = smoothstep(cut, cut + 0.30, density);
    if (density <= 0.0) {
        return vec3(0.0);
    }

    // H-beta rides with H-alpha (both hydrogen) at roughly a third the strength.
    float ionised = smoothstep(tune.coreOnset, tune.coreOnset + tune.coreWidth, density);
    vec3 hydrogen = mix(PLAGUE_NEBULA_H_ALPHA, PLAGUE_NEBULA_H_BETA, 0.30);
    vec3 colour = mix(hydrogen, coreColour, ionised);

    // Wider clearance than the star field: a diffuse cloud must be gone well before the disc.
    float sunClear = abs(VdotS);
    sunClear *= sunClear;
    sunClear *= sunClear;
    sunClear *= sunClear;
    visibility *= 1.0 - sunClear;

    vec2 starScaled = uv * (PLAGUE_NEBULA_STAR_LATTICE / max(u_StarSize, 1e-3));
    vec2 starCell = floor(starScaled);
    // Same analytic coverage stars.glsl uses; without it these dim while turning, brighten at rest.
    vec2 starFw = fwidth(starScaled);
    float starFootprint = clamp(max(starFw.x, starFw.y), 0.0, 0.5);
    float h = plagueHash12(starCell + 4.31);
    float starCut = 1.0 - PLAGUE_NEBULA_STAR_DENSITY;
    float starGlow = 0.0;
    if (h >= starCut) {
        float mag = (h - starCut) / PLAGUE_NEBULA_STAR_DENSITY;
        mag *= mag;
        float starEdge = plagueStarEdgeWidth(u_StarSoftness, starFootprint);
        float sdw = max(starEdge - PLAGUE_STAR_EDGE_SOFTNESS, 0.0);
        starGlow = mag * plagueStarEdgeFactor(fract(starScaled), u_StarRoundness, starEdge)
                 * (1.0 + 2.03 * sdw + 5.88 * sdw * sdw) * starBrightness;
    }

    // Multiplies rather than adds, so stars read as embedded in the gas rather than painted over it.
    colour *= 1.0 + tune.starGlow * starGlow;

    // Squared so emission falls off faster than linearly, keeping the cloud's boundary soft.
    float alpha = density * density * visibility * tune.intensity;

    return max(colour * alpha, vec3(0.0));
#endif
}

#endif // PLAGUE_NEBULA
