// Puddles: where rainwater POOLS, as patches (two noise octaves, placement refined by resource-pack
// height where available), not a uniform wet coating. Normal is flattened to the face normal inside
// a puddle — without it, reflections scatter off the brick's own bumpy normals instead of mirroring.
//
// Runs in the geometry stage, not the resolve: the height map only exists here, and the normal must
// change BEFORE it's written to the G-buffer.
//
// Rain animation below is driven by v_WaveClock (terrain.vsh forwards u_SkyState.w/20.0, the same
// clock water waves use). Exposed as "Puddle Ripples" (PLAGUE_PUDDLE_RIPPLE_PCT) on Materials.

/**
 * How much water this fragment has standing on it, 0..1. `engineWetness` is the engine's
 * accumulated soak (u_FrameState.w), never the instantaneous rain level. `worldXZ` must be
 * ABSOLUTE world coordinates — camera-relative would slide every puddle as the player walked.
 * `height` is raw labPBR height (0 deepest, 1 surface); callers with no height sidecar pass 0.5.
 */
float plaguePuddleAmount(sampler2D noiseTex, vec2 worldXZ, float height, float faceNormalY,
                         float skyLight, float engineWetness) {
    // cos(20deg)=0.94 to cos(45deg)=0.71: a face steeper than ~20 degrees sheds faster than rain
    // lands, past 45 holds nothing — the ramp bounds, not a tuned window.
    float openness = smoothstep(0.71, 0.94, faceNormalY) * smoothstep(0.75, 0.95, skyLight);
    if (min(engineWetness, openness) <= 1e-2) {
        return 0.0;
    }

    // Single octave, not 4-octave FBM: a sum of octaves concentrates around its mean (CLT), giving
    // a faint sheen everywhere instead of distinct pools. R = ~3-block fine feature, G = 5x
    // broader and halved (clusters WHERE pools group, doesn't decide if a given texel is one).
    vec2 pos = worldXZ * 0.02;
    float basin = texture(noiseTex, pos).r + texture(noiseTex, pos * 0.2).g * 0.5;
    basin /= 1.5;

    // Relief refines placement (water runs into low parts); a surface with no height sidecar
    // passes neutral 0.5 and is placed by the world field alone.
    basin += (1.0 - height) * 0.15;

    // A FILL LEVEL, NOT A THRESHOLD: `basin` is depth, `engineWetness` is how full the ground is,
    // so puddles grow/evaporate from the RIM inward rather than jumping at a coverage cutoff.
    float level = clamp(engineWetness, 0.0, 1.0);
    float standing = basin - (1.0 - level) * 0.62;

    return standing * openness;
}

/**
 * World-XZ height GRADIENT (not brightness) of discrete rain impacts, so it changes the actual
 * reflected-light normal rather than painting a ring onto albedo. Each stable world-space cell gets
 * one randomized impact travelling outward with a positive crest and negative trough (signed, since
 * a drop both raises water and leaves the depression it came from). Evaluated analytically — one
 * noise lookup — rather than through a pressure texture, which would join unrelated puddles across
 * dry blocks until Plague has water-aware boundaries.
 */
vec2 plaguePuddleImpactGradient(sampler2D noiseTex, vec2 worldXZ, float time, float rainLevel,
                                float density) {
    float rain = clamp(rainLevel, 0.0, 1.0);
    if (rain <= 0.01) {
        return vec2(0.0);
    }

    float cellSize = mix(1.6, 0.55, clamp(density, 0.0, 1.0));
    vec2 cell = floor(worldXZ / cellSize);
    vec2 rnd = texture(noiseTex, (cell + 0.5) * 0.037).rg;

    // Light rain activates fewer cells rather than dimming a synchronized ripple everywhere.
    if (rnd.y > rain) {
        return vec2(0.0);
    }

    vec2 cellCentre = (cell + 0.5) * cellSize;
    vec2 impactCentre = cellCentre + (rnd - 0.5) * cellSize * 0.6;
    vec2 fromImpact = worldXZ - impactCentre;
    float distanceToImpact = length(fromImpact);
    vec2 radial = distanceToImpact > 1e-5 ? fromImpact / distanceToImpact : vec2(0.0);

    // One drop per cell PER PERIOD, its own period and only the first ~third of it alive at once —
    // a shared clock rate previously synced every cell into a visible checkerboard grid at full rain.
    float period = mix(1.05, 2.10, rnd.x);
    float cycle = fract(time / period + rnd.x * 7.31 + rnd.y * 3.77);
    const float RIPPLE_DUTY = 0.38;
    if (cycle > RIPPLE_DUTY) {
        return vec2(0.0);
    }
    float age = cycle / RIPPLE_DUTY;
    float radius = age * 0.46;
    // 4cm birth width (not 2.6): a narrower ring reads as a white flash near the eye, since the
    // gradient peak scales as 1/width.
    float width = 0.04 + age * 0.038;

    float ringDelta = (distanceToImpact - radius) / width;
    float troughWidth = width * 1.30;
    float troughRadius = radius - width * 1.75;
    float hollowDelta = (distanceToImpact - troughRadius) / troughWidth;
    float ring = exp(-ringDelta * ringDelta);
    float hollow = exp(-hollowDelta * hollowDelta);

    // d/ddistance exp(-x^2); the minus between the two terms is the signed impulse: displaced
    // water ahead, the depression it came from behind.
    float ringDerivative = ring * (-2.0 * ringDelta / width);
    float hollowDerivative = hollow * (-2.0 * hollowDelta / troughWidth);
    float envelope = (1.0 - age) * (1.0 - age);
    const float IMPACT_HEIGHT = 0.012;
    // VOLUME-NEUTRAL: solving w_hollow = (width*radius)/(troughWidth*troughRadius) at the mid-life
    // radius so the ring and trough integrate to zero net water; wrong and every drop is a
    // permanent bump or dent.
    const float HOLLOW_WEIGHT = 0.71;
    float radialDerivative = (ringDerivative - hollowDerivative * HOLLOW_WEIGHT)
            * envelope * IMPACT_HEIGHT * rain;
    return radial * radialDerivative;
}

/**
 * Applies a puddle: flattens the normal, smooths the material, floors F0. Three offset windows on
 * the same field — normal [0.5,0.57], material wetting [0.35,0.57], albedo darkening [0.3,0.565] —
 * so soaking reaches furthest and the mirror least far, giving a damp fringe around a reflective
 * centre. `f0` is left alone for conductors: flooring it toward water's 0.04 would turn iron into
 * plastic.
 */
float plagueApplyPuddle(float puddleNoise, inout vec3 normal, vec3 faceNormal,
                        inout float smoothness, inout float f0, bool conductor) {
    if (puddleNoise <= 0.0) {
        return 0.0;
    }

    // Geometry eases in (smoothstep) while material terms below ramp linearly-squared: an eased
    // material ramp would reach full gloss too early and lose the damp fringe. Stopping film
    // coverage short of 100% preserves substrate relief instead of an opaque flat mirror.
    const float PUDDLE_MAX_FILM_COVERAGE = 0.88;
    normal = normalize(mix(normal, faceNormal,
            smoothstep(0.5, 0.57, puddleNoise) * PUDDLE_MAX_FILM_COVERAGE));

    // Squared, not linear: keeps the fringe merely damp instead of the whole puddle reading as one
    // flat reflective disc.
    float materialWet = clamp((puddleNoise - 0.35) / (0.57 - 0.35), 0.0, 1.0);
    materialWet *= materialWet;
    smoothness = mix(smoothness, 1.0, materialWet * PUDDLE_MAX_FILM_COVERAGE);
    if (!conductor) {
        f0 = max(f0, 0.04 * materialWet);
    }

    // Wider, earlier window than the material terms above, so the soaked patch downstream reads
    // visibly larger than the reflective one.
    float albedoWet = clamp((puddleNoise - 0.3) / (0.565 - 0.3), 0.0, 1.0);
    return albedoWet * albedoWet;
}
