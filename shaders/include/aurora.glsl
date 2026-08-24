#ifndef PLAGUE_AURORA
#define PLAGUE_AURORA

// Aurora march: flattened onto the horizontal plane and stepped with SQUARED sample spacing,
// which produces the vertical streaking with no vertical geometry. See the palette block below
// for why the colour isn't authored.

#define PLAGUE_AURORA_ENABLED //[] compile "Aurora Borealis"
#define PLAGUE_AURORA_CONDITION 0 //[0 1] compile "Aurora Condition" {0="Every clear night" 1="Full moon only"}
#define PLAGUE_AURORA_STYLE 0 //[0 1] compile "Aurora Style" {0="Smooth" 1="Blocky"}
// u_AuroraDetail is a frequency multiplier on the derived UV scale below.
#define u_AuroraDetail 1.0 //[0.50..5.00 step 0.05] runtime "Aurora Detail"
// 0.000175 = a ~tenth-noise-texel filament width at the march's 11x plane scale, against
// builtin.noise's 512x512 resolution (1 texel = 1/512 UV). Must move with that resolution.
#define PLAGUE_AURORA_NOISE_UV (0.000175 * u_AuroraDetail)
#define PLAGUE_AURORA_SAMPLES 25 //[10 15 20 25 30 40] compile "Aurora Quality" {10="Fastest" 15="Fast" 20="Balanced" 25="High" 30="Very High" 40="Ultra"}
#define u_AuroraSize 1.0 //[0.50..2.00 step 0.05] runtime "Aurora Size"
#define u_AuroraIntensity 1.0 //[0.00..2.00 step 0.05] runtime "Aurora Intensity"
// Where along the curtain each emission line takes over. See the palette block for the physics.
#define u_AuroraRedOnset 0.62 //[0.20..1.00 step 0.01] runtime "Aurora High-Altitude Red"
#define u_AuroraRedWidth 0.30 //[0.05..0.80 step 0.01] runtime "Aurora Red Blend"
#define u_AuroraVioletExtent 0.18 //[0.00..0.60 step 0.01] runtime "Aurora Low-Altitude Violet"

// Isolates the aurora from every other sky element so "the aurora is blocky" can be told apart
// from "something later in the frame is blocky" (vanilla's cloud silhouettes measure 58.7%
// axis-aligned vs a 22% baseline and sit on top of it). Turn Bloom to 0 too, to rule out the post chain.
//#define PLAGUE_DEBUG_AURORA_ONLY //[] compile "Show Only the Aurora"
#define u_AuroraDebugGain 20.0 //[1.0..100.0 step 1.0] runtime "Aurora View Brightness"

const float PLAGUE_AURORA_DRAW_DISTANCE = 0.65;

// Emission spectroscopy, stratified by altitude: 557.7nm green (atomic O, ~100-150km, dominant
// line), 630.0nm red (atomic O, >200km, forbidden transition, survives only where collisions are
// rare), 427.8nm violet (ionised N2, <100km, sharp lower fringe). The march's distance parameter
// stands in for altitude, so the colour gradient falls out of sample position, not authorship.
const vec3 PLAGUE_AURORA_N2_VIOLET = vec3(0.42, 0.32, 1.00);   // 427.8 nm, bottom
const vec3 PLAGUE_AURORA_O_GREEN   = vec3(0.25, 1.00, 0.52);   // 557.7 nm, body
const vec3 PLAGUE_AURORA_O_RED     = vec3(1.00, 0.28, 0.34);   // 630.0 nm, top

// builtin.noise's per-texel white noise (A channel). No fract() wrap needed: FullscreenPassRunner
// binds this texture REPEAT + LINEAR, so the hardware already wraps coordinates that leave 0..1
// near the horizon.
float plagueNoise(sampler2D noiseTex, vec2 uv) {
    return texture(noiseTex, uv).a;
}

// Returns <= 0 for "none" so the caller can skip the march. The sun term is a hard subtraction,
// not a fade: an aurora is invisible in daylight, not merely dimmer.
float plagueAuroraVisibility(float VdotU, float sunVisibility, float rainFactor, float moonPhase) {
    float visibility = sqrt(clamp(VdotU * (PLAGUE_AURORA_DRAW_DISTANCE * 1.125 + 0.75) - 0.225,
                                  0.0, 1.0))
                     - sunVisibility - rainFactor;

    // Fades out toward the zenith: an aurora is a curtain seen edge-on, brightest partway up the
    // sky, not a dome overhead.
    visibility *= 1.0 - VdotU * 0.9;

#if PLAGUE_AURORA_CONDITION == 1
    // Phase 0 is FULL, so subtracting the index means only a full moon escapes a penalty and
    // anything past a sliver kills it outright.
    visibility -= moonPhase;
#endif

    return visibility;
}

/** @param dither breaks the banding 25 quadratically-spaced samples would otherwise show as rings */
vec3 plagueGetAurora(vec3 viewRay, float VdotU, float dither, vec2 cameraXZ, float syncedTime,
                     float sunVisibility, float rainFactor, float moonPhase, sampler2D noiseTex) {
#ifndef PLAGUE_AURORA_ENABLED
    return vec3(0.0);
#else
    float visibility = plagueAuroraVisibility(VdotU, sunVisibility, rainFactor, moonPhase);
    if (visibility <= 0.0) {
        return vec3(0.0);
    }

    // Flatten onto the horizontal plane. Below the horizon this diverges, but visibility has already
    // returned <= 0 there, so the march never runs with a negative y.
    vec3 wpos = viewRay;
    wpos.xz /= wpos.y;

    // Slow world-anchored drift. MEASURED: an earlier 8x rate compensated for the wrong cause (a
    // coarse 16-cell lattice, not this rate) and just made it glimmer at 12%/frame instead of the
    // intended 0.44%.
    vec2 cameraPositionM = cameraXZ * 0.0075;
    // mod(...,1024.0) keeps syncedTime's term small: unwrapped it reaches tens of thousands of
    // seconds, loses low bits in float32 against the small per-pixel offset, and floor() below
    // collapses the whole sky into one cell (aurora vanishes). 1024 is a power of two, so the wrap
    // costs no precision and lands on a cell boundary.
    cameraPositionM.x += mod(syncedTime * 0.04, 1024.0);

    const int sampleCount = PLAGUE_AURORA_SAMPLES;
    const int sampleCountP = sampleCount + 5;
    float ditherM = dither + 5.0;
    // Shimmer rate (distinct from the drift above). MEASURED: 0.001/sec is plenty on per-texel
    // noise; an earlier 30x crossed several texels per frame, which reads as glimmer, not shimmer.
    float auroraAnimate = syncedTime * 0.001;

    vec3 aurora = vec3(0.0);
    for (int i = 0; i < sampleCount; i++) {
        float t = (float(i) + ditherM) / float(sampleCountP);
        float current = t * t;

        vec2 planePos = wpos.xz * (u_AuroraSize * 0.8 + current) * 11.0 + cameraPositionM;

#if PLAGUE_AURORA_STYLE == 1
        // Blocky arm: floor() before the UV scale snaps the plane into hard cells (offered for
        // pixel-art skies, not more correct). Cell size depends only on wpos.xz*11.0, so it's
        // independent of the noise resolution and hasn't been eye-matched to the smooth arm.
        planePos = floor(planePos) * PLAGUE_AURORA_NOISE_UV;

        float ridge = 1.0 - 2.0 * abs(plagueNoise(noiseTex, planePos) - 0.5);
        ridge *= ridge;  // ^2
        ridge *= ridge;  // ^4
        ridge *= ridge;  // ^8
        ridge *= ridge;  // ^16

        float detail = plagueNoise(noiseTex, planePos * 100.0 + auroraAnimate);
        ridge *= pow(detail, 1.5);
#else
        planePos *= PLAGUE_AURORA_NOISE_UV;

        float ridge = 1.0 - 2.0 * abs(plagueNoise(noiseTex, planePos) - 0.5);
        ridge *= ridge;
        ridge *= ridge;
        ridge *= ridge;
        ridge *= ridge;

        // Opposite-drifting layers, which is what makes the curtain shimmer rather than slide.
        ridge *= plagueNoise(noiseTex, planePos * 3.0 + auroraAnimate);
        ridge *= plagueNoise(noiseTex, planePos * 5.0 - auroraAnimate);
#endif

        // `current` stands in for altitude; see the palette block above for the emission physics.
        float fringe = 1.0 - smoothstep(0.0, max(u_AuroraVioletExtent, 1e-3), current);
        float high = smoothstep(u_AuroraRedOnset, u_AuroraRedOnset + u_AuroraRedWidth, current);
        vec3 emission = mix(PLAGUE_AURORA_O_GREEN, PLAGUE_AURORA_O_RED, high);
        emission = mix(emission, PLAGUE_AURORA_N2_VIOLET, fringe * 0.75);

        float currentM = 1.0 - current;
        aurora += ridge * currentM * emission;
    }

#if PLAGUE_AURORA_STYLE == 1
    aurora *= 1.3;
#else
    aurora *= 1.8;
#endif
    return max(aurora * visibility / float(sampleCount) * u_AuroraIntensity, vec3(0.0));
#endif
}

#endif // PLAGUE_AURORA
