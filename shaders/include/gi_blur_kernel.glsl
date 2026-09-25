#ifndef PLAGUE_GI_BLUR_KERNEL
#define PLAGUE_GI_BLUR_KERNEL

#moj_import <fornax_runtime:gi_grid.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>

// One step of a variance-guided, edge-aware spreading filter over the bounce grid.
//
// One ray per cell is a very noisy estimate of a very smooth thing: light arriving from the whole
// hemisphere changes slowly across a flat surface. Averaging neighbours trades resolution the
// signal does not have for noise it does.
//
// Run several times with the step doubled each time, which is the à-trous arrangement: the same
// small tap count covers a far wider area than one pass could, because each pass averages cells
// that are themselves already averages. The caller names its step in cells. The first pass must
// stay at one cell: a filter whose smallest gap is two only ever lands on even neighbours, and
// the odd and even cells become two sets that never mix, a checkerboard two cells across.
// Dammertz, Sewtz, Hanika and Lensch, "Edge-Avoiding À-Trous Wavelet Transform for Fast Global
// Illumination Filtering", HPG 2009.
//
// Three things stop the filter at an edge: facing, so a wall does not lend its light to the
// floor it meets; distance from the cell's own plane, so a block face standing in front of a
// wall stays apart from it; and the gap in brightness measured against the cell's own standard
// deviation, so a noisy cell mixes freely with its neighbours while a converged edge between lit
// and shaded stays. The variance travels with the light in its alpha, so the next pass knows how
// sure each cell is, and a young cell takes its variance from its neighbours because a few frames
// cannot estimate it. Schied, Kaplanyan, Wyman, Patney, Chaitanya, Benthin, Salvi, Lefohn and
// Nowrouzezahrai, "Spatiotemporal Variance-Guided Filtering", HPG 2017.
//
// The caller declares u_Bounce (rgb light, a variance on every pass after the first), u_Dir (the
// bearing, averaged by the same weights), u_Depth, u_GNormal, u_OutBlurred (rgb light, a
// variance) and u_OutDir, imports globals and gi_history_test.glsl, and on the first pass only
// defines PLAGUE_GI_BLUR_FIRST and declares u_Moments (r mean luminance, g mean luminance
// squared, b frames gathered) from the resolve.

// Two cells either side of the middle. Wider than this in one pass reaches across a whole small
// room before the next pass has widened anything.
const int PLAGUE_GI_BLUR_RADIUS = 2;
// Binomial row of five, the discrete Gaussian at this width. Nearer cells count for more, which is
// what stops the passes together reading as a flat box.
const float PLAGUE_GI_BLUR_TAP[5] = float[5](0.0625, 0.25, 0.375, 0.25, 0.0625);
// Power on the cosine between two normals. Schied et al. 2017 use 128: a tilt of ten degrees
// counts a neighbour at a tenth, and a wall meeting a floor at nothing.
const float PLAGUE_GI_BLUR_SIGMA_NORMAL = 128.0;
// How many of the cell's own standard deviations a brightness gap may span before the neighbour
// stops counting. Schied et al. 2017 use 4.
const float PLAGUE_GI_BLUR_SIGMA_LUMA = 4.0;
// Keeps the luminance stop finite where the variance is zero: a converged cell then mixes only
// with neighbours of the same brightness.
const float PLAGUE_GI_BLUR_LUMA_EPSILON = 1e-4;
// Frames below which the running moments cannot say how noisy a cell is, so its neighbours say
// instead. Schied et al. 2017 use 4.
const float PLAGUE_GI_BLUR_YOUNG = 4.0;

float plagueGiBlurLuma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// The flat face a texel sits on, decoded from gNormal's alpha, not the bumped normal in its
// rgb: leaves change their bumped normal texel to texel, which fails every facing test below,
// and the flat face stays the same across a whole leaf block.
vec3 plagueGiBlurFaceNormal(vec4 packed) {
    return dot(packed.xyz, packed.xyz) > 1e-6
            ? plagueDecodeGeometricNormal(packed.a, normalize(packed.xyz)) : vec3(0.0);
}

// Falls off with the neighbour's distance from this cell's plane, in the same tolerance the
// history test uses, so a neighbour the history would reject barely counts here either.
float plagueGiBlurPlaneWeight(vec3 here, vec3 normalHere, vec3 there) {
    float tolerance = max(PLAGUE_GI_HISTORY_PLANE * length(here), PLAGUE_GI_HISTORY_PLANE_FLOOR);
    return exp(-abs(dot(there - here, normalHere)) / tolerance);
}

float plagueGiBlurNormalWeight(vec3 a, vec3 b) {
    return pow(max(dot(a, b), 0.0), PLAGUE_GI_BLUR_SIGMA_NORMAL);
}

// The variance of one cell as the previous stage left it. On the first pass that is the spread
// of the running moments; on later passes it rides in the light's alpha.
float plagueGiBlurInputVariance(ivec2 cell, float spatialVariance) {
#ifdef PLAGUE_GI_BLUR_FIRST
    vec3 m = imageLoad(u_Moments, cell).rgb;
    float temporal = max(m.g - m.r * m.r, 0.0);
    // Reuse the receiver's same-surface estimate for young taps: one sample's zero temporal
    // variance must not tell the wider passes that freshly exposed scenery has converged.
    return m.b < PLAGUE_GI_BLUR_YOUNG ? max(temporal, spatialVariance) : temporal;
#else
    return imageLoad(u_Bounce, cell).a;
#endif
}

float plagueGiBlurStoredVariance(ivec2 cell) {
    return plagueGiBlurInputVariance(cell, 0.0);
}

#ifdef PLAGUE_GI_BLUR_FIRST
// A young cell has too few frames for its moments to mean anything, so its variance is taken from
// the spread of brightness across its neighbours on the same surface instead, and the larger of
// the two is kept. Computed once, for the cell being filtered.
float plagueGiBlurCellVariance(ivec2 cell, ivec2 size, vec3 here, vec3 normalHere) {
    float temporal = plagueGiBlurStoredVariance(cell);
    if (imageLoad(u_Moments, cell).b >= PLAGUE_GI_BLUR_YOUNG) {
        return temporal;
    }
    float sumLuma = 0.0;
    float sumSquare = 0.0;
    float sumWeight = 0.0;
    for (int y = -PLAGUE_GI_BLUR_RADIUS; y <= PLAGUE_GI_BLUR_RADIUS; ++y) {
        for (int x = -PLAGUE_GI_BLUR_RADIUS; x <= PLAGUE_GI_BLUR_RADIUS; ++x) {
            ivec2 tap = clamp(cell + ivec2(x, y), ivec2(0), size - 1);
            vec2 tapUv = plagueGiCellUv(vec2(tap), vec2(size));
            float tapDepth = texture(u_Depth, tapUv).r;
            if (tapDepth <= 0.0) continue;
            vec3 tapNormal = plagueGiBlurFaceNormal(texture(u_GNormal, tapUv));
            if (dot(tapNormal, tapNormal) <= 1e-6) continue;
            float w = PLAGUE_GI_BLUR_TAP[x + PLAGUE_GI_BLUR_RADIUS]
                    * PLAGUE_GI_BLUR_TAP[y + PLAGUE_GI_BLUR_RADIUS]
                    * plagueGiBlurNormalWeight(normalHere, tapNormal)
                    * plagueGiBlurPlaneWeight(here, normalHere, plagueGiHistoryPosition(tapUv, tapDepth));
            float luma = plagueGiBlurLuma(imageLoad(u_Bounce, tap).rgb);
            sumLuma += luma * w;
            sumSquare += luma * luma * w;
            sumWeight += w;
        }
    }
    if (sumWeight <= 0.0) {
        return temporal;
    }
    float mean = sumLuma / sumWeight;
    return max(temporal, max(sumSquare / sumWeight - mean * mean, 0.0));
}
#else
float plagueGiBlurCellVariance(ivec2 cell, ivec2 size, vec3 here, vec3 normalHere) {
    return plagueGiBlurStoredVariance(cell);
}
#endif

void plagueGiBlurCell(ivec2 cell, int step, ivec2 size) {
    vec2 uv = plagueGiCellUv(vec2(cell), vec2(size));
    float depth = texture(u_Depth, uv).r;

    // Sky, which no surface receives. Passed through rather than filtered so the edge of the world
    // does not pull the horizon's light inward.
    if (depth <= 0.0) {
        imageStore(u_OutBlurred, cell, imageLoad(u_Bounce, cell));
        imageStore(u_OutDir, cell, imageLoad(u_Dir, cell));
        return;
    }
    vec3 normalHere = plagueGiBlurFaceNormal(texture(u_GNormal, uv));
    if (dot(normalHere, normalHere) <= 1e-6) normalHere = vec3(0.0, 1.0, 0.0);
    vec3 here = plagueGiHistoryPosition(uv, depth);

    // The cell's own variance, smoothed over its immediate neighbours before it sets the
    // brightness stop: one cell's estimate is itself noisy, and a stop that jumps from cell to
    // cell leaves a pattern of its own. Three by three at one cell whatever this pass's step.
    float variance = plagueGiBlurCellVariance(cell, size, here, normalHere);
#ifdef PLAGUE_GI_BLUR_FIRST
    // A young cell already has a spatial 5x5 estimate. Mixing it with its neighbours' empty
    // temporal moments would dilute that estimate precisely where history has just been lost.
    if (imageLoad(u_Moments, cell).b >= PLAGUE_GI_BLUR_YOUNG) {
#endif
    float smoothedVariance = 0.0;
    float smoothedWeight = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            ivec2 tap = clamp(cell + ivec2(x, y), ivec2(0), size - 1);
            if (texture(u_Depth, plagueGiCellUv(vec2(tap), vec2(size))).r <= 0.0) continue;
            float w = (x == 0 ? 0.5 : 0.25) * (y == 0 ? 0.5 : 0.25);
            smoothedVariance += (x == 0 && y == 0 ? variance : plagueGiBlurStoredVariance(tap)) * w;
            smoothedWeight += w;
        }
    }
    if (smoothedWeight > 0.0) {
        variance = smoothedVariance / smoothedWeight;
    }
#ifdef PLAGUE_GI_BLUR_FIRST
    }
#endif
    float sigmaLuma = PLAGUE_GI_BLUR_SIGMA_LUMA * sqrt(max(variance, 0.0)) + PLAGUE_GI_BLUR_LUMA_EPSILON;
    float lumaHere = plagueGiBlurLuma(imageLoad(u_Bounce, cell).rgb);

    vec3 total = vec3(0.0);
    // The bearing is averaged the same way and by the same taps. Averaging vectors is what keeps
    // its meaning: neighbours that agree about where the light is keep the length that says so,
    // and neighbours that disagree shorten it, which is the honest answer for that spot.
    vec3 bearing = vec3(0.0);
    float weight = 0.0;
    float varianceSum = 0.0;
    for (int y = -PLAGUE_GI_BLUR_RADIUS; y <= PLAGUE_GI_BLUR_RADIUS; ++y) {
        for (int x = -PLAGUE_GI_BLUR_RADIUS; x <= PLAGUE_GI_BLUR_RADIUS; ++x) {
            ivec2 tap = clamp(cell + ivec2(x, y) * step, ivec2(0), size - 1);
            vec2 tapUv = plagueGiCellUv(vec2(tap), vec2(size));
            float tapDepth = texture(u_Depth, tapUv).r;
            if (tapDepth <= 0.0) continue;
            vec3 tapNormal = plagueGiBlurFaceNormal(texture(u_GNormal, tapUv));
            if (dot(tapNormal, tapNormal) <= 1e-6) continue;
            vec3 tapColour = imageLoad(u_Bounce, tap).rgb;
            float w = PLAGUE_GI_BLUR_TAP[x + PLAGUE_GI_BLUR_RADIUS]
                    * PLAGUE_GI_BLUR_TAP[y + PLAGUE_GI_BLUR_RADIUS]
                    * plagueGiBlurNormalWeight(normalHere, tapNormal)
                    * plagueGiBlurPlaneWeight(here, normalHere, plagueGiHistoryPosition(tapUv, tapDepth))
                    * exp(-abs(lumaHere - plagueGiBlurLuma(tapColour)) / sigmaLuma);
            total += tapColour * w;
            bearing += imageLoad(u_Dir, tap).rgb * w;
            weight += w;
            // The variance of a weighted mean is the weights squared times each part's own.
            varianceSum += plagueGiBlurInputVariance(tap, variance) * w * w;
        }
    }

    // A cell whose every neighbour was rejected keeps its own sample rather than going black.
    if (weight > 0.0) {
        imageStore(u_OutBlurred, cell, vec4(total / weight, varianceSum / (weight * weight)));
        imageStore(u_OutDir, cell, vec4(bearing / weight, 1.0));
    } else {
        imageStore(u_OutBlurred, cell, vec4(imageLoad(u_Bounce, cell).rgb, variance));
        imageStore(u_OutDir, cell, imageLoad(u_Dir, cell));
    }
}

#endif
