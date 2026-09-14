#ifndef PLAGUE_CLOUD_CANDIDATE_CACHE
#define PLAGUE_CLOUD_CANDIDATE_CACHE
// Measured 2026-09-13 at owner options: 512 tiles per axis and eight tiles per candidate cell
// reduce total clear/storm dispatch cost ~15/20%, including generation, with identical colour/front.
// These cache dimensions affect hit rate only. Misses evaluate the original procedural field.
const int PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE = 512;
const int PLAGUE_CLOUD_CANDIDATE_CACHE_TILES_PER_CELL = 8;

// Minimum quadratic lobe metric over an axis-aligned enclosure of the transformed tile.
float plagueCloudTileLobeMetricLower(vec2 centre, vec2 halfExtent, vec2 lobeCentre, float radius) {
    vec2 delta = max(abs(centre - lobeCentre) - halfExtent, vec2(0.0));
    vec2 normalizedDelta = delta / max(radius, 1e-3);
    return dot(normalizedDelta, normalizedDelta);
}

// Nine bits in x-major/z-minor order, one per original candidate; 511 retains all nine.
// Absolute integer tile coordinates in allocationP * 8. This bounds candidates only:
// the original query still evaluates its sheet and patch fields before consulting the atlas.
float plagueCloudCandidateTileMask(ivec2 tile, PlagueCloudDeck deck) {
    // No candidates exist at zero population; the sheet remains evaluated by the reader.
    if (deck.population <= 0.0) return 0.0;
    float radius = PLAGUE_CLOUD_MORPHOLOGY_RADIUS * deck.footprint;
    float sizeBias = PLAGUE_CLOUD_SIZE_DENSITY_GAIN * log2(max(deck.sizeRatio, 1e-3));
    // Candidate patch and vertical penalties are nonnegative, so omitting them raises the bound.
    float boundPeak = sizeBias + deck.convectiveLift;
    float boundPotentialError = PLAGUE_CLOUD_CANDIDATE_BOUND_ERROR
            * max(1.0, abs(sizeBias) + abs(deck.convectiveLift)
                    + abs(deck.cut) + abs(PLAGUE_CLOUD_FIELD_TOP)
                    + PLAGUE_CLOUD_MORPHOLOGY_VERTICAL_PENALTY);
    float fallbackUpper = boundPeak + boundPotentialError;
    if (isnan(radius) || isinf(radius)) return -1.0;

    vec2 tileLow = vec2(tile) / float(PLAGUE_CLOUD_CANDIDATE_CACHE_TILES_PER_CELL);
    // A tile is one eighth of a candidate cell; its half extent is one sixteenth.
    vec2 halfExtent = vec2(0.5 / float(PLAGUE_CLOUD_CANDIDATE_CACHE_TILES_PER_CELL));
    vec2 centre = tileLow + halfExtent;
    ivec2 baseCell = ivec2(floor(tileLow));
    uint mask = 0u;
    for (int x = -1; x <= 1; x++) {
        for (int z = -1; z <= 1; z++) {
            ivec2 cellId = baseCell + ivec2(x, z);
            float rank = plagueCloudCandidateHash(cellId + PLAGUE_CLOUD_RANK_SALT, 2u);
            if (rank >= deck.population) continue;
            vec2 jitter = plagueCloudCandidateJitter(cellId);
            vec2 site = vec2(cellId) + 0.5
                      + (jitter - 0.5) * PLAGUE_CLOUD_SITE_JITTER;
            vec2 axisSeed = jitter * 2.0 - 1.0;
            // Use the actual normalization floor. This transform remains valid for short axes.
            vec2 axis = axisSeed * inversesqrt(max(dot(axisSeed, axisSeed), 1e-6));
            vec2 perpendicular = vec2(-axis.y, axis.x);
            float aspect = mix(PLAGUE_CLOUD_MORPHOLOGY_ASPECT_MIN,
                               PLAGUE_CLOUD_MORPHOLOGY_ASPECT_MAX, jitter.x);
            vec2 delta = centre - site;
            vec2 localCentre = vec2(dot(delta, axis) / aspect,
                                    dot(delta, perpendicular) * aspect);
            vec2 localHalf = vec2(dot(halfExtent, abs(axis)) / aspect,
                                  dot(halfExtent, abs(perpendicular)) * aspect);
            vec2 lobeOffset = radius * PLAGUE_CLOUD_MORPHOLOGY_LOBE_OFFSET
                            * vec2(jitter.x < 0.5 ? -1.0 : 1.0,
                                   jitter.y < 0.5 ? -1.0 : 1.0);
            vec2 crownOffset = vec2(-lobeOffset.y, lobeOffset.x);

            // Propagate the existing 64-epsilon budget through world-coordinate subtraction and
            // the ellipse's absolute row sum. Enlarging the enclosure can only reduce the metric.
            float coordinateMagnitude = max(1.0, max(max(abs(centre.x), abs(centre.y)),
                    max(max(abs(site.x), abs(site.y)), max(abs(radius), length(lobeOffset)))));
            float ellipseScale = max(1.0, (abs(axis.x) + abs(axis.y)) * max(aspect, 1.0 / aspect));
            localHalf += vec2(PLAGUE_CLOUD_CANDIDATE_BOUND_ERROR * coordinateMagnitude * ellipseScale);
            if (any(isnan(localCentre)) || any(isinf(localCentre))
                    || any(isnan(localHalf)) || any(isinf(localHalf))) return -1.0;

            float metric = plagueCloudTileLobeMetricLower(localCentre, localHalf, vec2(0.0),
                                                          radius * PLAGUE_CLOUD_MORPHOLOGY_CORE_RADIUS);
            metric = min(metric, plagueCloudTileLobeMetricLower(localCentre, localHalf, lobeOffset,
                                                                radius * PLAGUE_CLOUD_MORPHOLOGY_SIDE_RADIUS));
            metric = min(metric, plagueCloudTileLobeMetricLower(localCentre, localHalf, crownOffset,
                                                                radius * PLAGUE_CLOUD_MORPHOLOGY_CROWN_RADIUS));
            float horizontalPenalty = PLAGUE_CLOUD_MORPHOLOGY_PENALTY * metric;
            // Cover the remaining radius divide, squaring, penalty multiply and final subtraction.
            // The coordinate enclosure handles absolute error; this term covers relative error.
            float potentialError = boundPotentialError + PLAGUE_CLOUD_CANDIDATE_BOUND_ERROR
                                                       * max(1.0, abs(horizontalPenalty));
            float candidateUpper = boundPeak - horizontalPenalty + potentialError;
            if (isnan(candidateUpper) || isinf(candidateUpper)) return -1.0;
            if (candidateUpper > deck.cut - PLAGUE_CLOUD_FIELD_TOP)
                mask |= 1u << uint((x + 1) * 3 + z + 1);
        }
    }
    return float(mask);
}

shared ivec2 plagueCloudCandidateOrigins[PLAGUE_CLOUD_LAYERS];

ivec2 plagueCloudCandidateOrigin(PlagueCloudDeck deck) {
    vec2 drift = plagueCloudDrift(deck, u_SkyState.w * 0.05);
    vec2 allocationQ = plagueCloudAllocationCoord(u_CameraAbs.xz, deck.cell, deck.shear,
                                                 deck.axisSwing, deck.veer, drift);
    vec2 allocationP = allocationQ / PLAGUE_CLOUD_ALLOCATION_PERIOD;
    return ivec2(floor(allocationP * float(PLAGUE_CLOUD_CANDIDATE_CACHE_TILES_PER_CELL)))
            - ivec2(PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE / 2);
}

#ifdef PLAGUE_CLOUD_CANDIDATE_CACHE_READ
int plagueCloudCandidateDeckIndex;

bool plagueCloudCandidateCachedMask(vec2 allocationQ, out float upper) {
    vec2 allocationP = allocationQ / PLAGUE_CLOUD_ALLOCATION_PERIOD;
    vec2 tileP = allocationP * float(PLAGUE_CLOUD_CANDIDATE_CACHE_TILES_PER_CELL);
    if (any(isnan(tileP)) || any(isinf(tileP))) return false;
    // 2^30 leaves room for atlas-origin arithmetic within signed 32-bit indices.
    if (any(greaterThanEqual(abs(tileP), vec2(1073741824.0)))) return false;
    ivec2 local = ivec2(floor(tileP)) - plagueCloudCandidateOrigins[plagueCloudCandidateDeckIndex];
    if (any(lessThan(local, ivec2(0)))
            || any(greaterThanEqual(local, ivec2(PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE)))) return false;
    ivec2 expectedSize = ivec2(PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE,
                                  PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE * PLAGUE_CLOUD_LAYERS + 1);
    if (any(notEqual(imageSize(u_CloudCandidateMask), expectedSize))) return false;
    // Zero is cleared/unavailable. The final atlas row certifies same-frame generation;
    // old contents cannot be accepted after a skipped dispatch, resize, or world reload.
    if (imageLoad(u_CloudCandidateMask, ivec2(plagueCloudCandidateDeckIndex,
            PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE * PLAGUE_CLOUD_LAYERS)).r != u_FrameState.x + 1.0) return false;
    float encoded = imageLoad(u_CloudCandidateMask,
            ivec2(local.x, plagueCloudCandidateDeckIndex * PLAGUE_CLOUD_CANDIDATE_CACHE_SIDE + local.y)).r;
    if (isnan(encoded) || isinf(encoded) || encoded < 1.0 || encoded > 512.0
            || encoded != floor(encoded)) return false;
    upper = encoded - 1.0;
    return true;
}
#endif

#endif
