#ifndef PLAGUE_CLOUD_DENSITY
#define PLAGUE_CLOUD_DENSITY

// ------------------------------------------------------------------------------------------------
// The density field
// ------------------------------------------------------------------------------------------------

/**
 * How far the deck has drifted, in coverage-cell units, ready to be added to a sample coordinate.
 *
 * @param syncedTime seconds since world start; see PLAGUE_CLOUD_DRIFT_WRAP for precision handling
 *
 * The rate is formed before the multiply by time so the division by cell size and wind length keeps
 * the step count small, rather than being applied to an already-large product.
 */
vec2 plagueCloudDrift(PlagueCloudDeck deck, float syncedTime) {
    float rate = PLAGUE_CLOUD_WIND_SPEED * max(u_CloudSpeed, 0.0)
               / (max(deck.cell, 1e-3) * PLAGUE_CLOUD_WIND_LENGTH);
    return mod(syncedTime * rate, PLAGUE_CLOUD_DRIFT_WRAP) * PLAGUE_CLOUD_WIND;
}

/**
 * World XZ to a coverage sample coordinate: cell-normalised, sheared along the wind, drifted.
 *
 * The shear divides the along-wind axis (dividing a sampling coordinate by s makes the sampled
 * feature s times longer, which is what shear physically does downwind). Drift is added AFTER the
 * shear, in the sheared frame, so a genus with shear s advects s times faster in world blocks than
 * the nominal wind speed — ten percent at the cumulus row's 1.10.
 */
vec2 plagueCloudSampleCoord(vec2 worldXZ, PlagueCloudDeck deck, vec2 drift) {
    vec2 q = worldXZ / max(deck.cell, 1e-3);
    float along = dot(q, PLAGUE_CLOUD_WIND_UNIT);
    q += PLAGUE_CLOUD_WIND_UNIT * (along / max(deck.shear, 1e-3) - along);
    return q + drift;
}

// ------------------------------------------------------------------------------------------------
// The field's noise primitive
// ------------------------------------------------------------------------------------------------
//
// The coverage and region fields run on sky_hash.glsl's ALU lattice, not a noise texture: measured
// in game, swapping to texture fetches cost 12 fps rather than saving any, since an FBM's octave
// coordinates are dependent and randomly addressed, so nothing prefetches. Texture noise still wins
// for ONE tap at a coherent coordinate, which is why the erosion field below samples the texture.
/**
 * The coverage/region field's FBM: gain 0.5, normalised by summed amplitude, rotated between
 * octaves, same shape as the hash version it replaces so the solved cutoffs still mean what they
 * say. Statistics measured in cloud_types.glsl.
 *
 * @param p       position in cell units: one unit is one lattice cell of the base octave
 * @param octaves the caller's choice: the full field for the marched density, a cheap two for the
 *                sun march
 */
float plagueCloudFieldFbm(vec2 p, int octaves) {
    return plagueSkyFbm(p, octaves);
}

/**
 * Is this part of the world under a weather system at all: 0 clear, 1 cloudy, soft between. The
 * low-frequency half of the two-scale construction (cloud_types.glsl's PLAGUE_CLOUD_REGION_DENSITY
 * carries the coverage-split argument).
 *
 * Sampled in the same advected, sheared frame as the clouds, at a coarser zoom: `q` is
 * cell-normalised, so multiplying by `deck.cell` cancels the cell out of every term except shear and
 * drift, which are already cell-independent in world blocks — this coordinate is a pure function of
 * world position, time, wind and shear, so Cloud Size cannot reach it. Sampling in a static or
 * unsheared frame would let clouds die at an invisible line or slip apart from their weather system
 * over time (0.19 blocks/s at default speed).
 *
 * PLAGUE_CLOUD_DRIFT_WRAP keeps the drift jump on the noise lattice only at the default Cloud Size;
 * off it, the field becomes a different field once per 325 hours of continuous world time.
 */
float plagueCloudRegion(vec2 q, PlagueCloudDeck deck) {
    vec2 wq = q / PLAGUE_CLOUD_WEATHER_CLOUDS;
    float w = plagueCloudFieldFbm(wq, PLAGUE_CLOUD_WEATHER_OCTAVES);
    float band = PLAGUE_CLOUD_WEATHER_BAND * PLAGUE_CLOUD_WEATHER_SIGMA;
    return smoothstep(deck.regionCut - band, deck.regionCut + band, w);
}

// HOW FAST AIR CONDENSES ONCE IT IS INSIDE A CLOUD, as a fraction of the field's surviving range.
// A cloud boundary is a phase change, not a gradient: liquid water content jumps at the boundary
// then varies slowly through the interior, so a real cumulus is opaque through its core and thin
// only at the fringe. A linear remap instead spreads most columns just above threshold, so nothing
// reaches an opaque core and the sky reads as one connected translucent mass.
//
// Measured on the shipped field, over columns with any cloud:
//
//     curve         opaque core (alpha > 0.9)    translucent fringe (0.2 to 0.8)
//     linear                  30%                            44%
//     0.60                    52%                            26%
//     0.45                    63%                            20%     <- shipped
//     0.25                    79%                            11%
//
// 0.45 is where cores become solid while a real fringe survives; 0.25 crushes the thin edges that
// make a wispy cloud wispy. Covered fraction (0.367) does not move across these values.
const float PLAGUE_CLOUD_CONDENSE = 0.45;

// HOW WEAK THE WEAKEST CLOUD IS, as a fraction of a fully developed one's density.
// The condensation curve alone saturates every cloud to solid — the missing quantity is the cloud's
// own VIGOUR (how deep the convection that made it went), a property separate from boundary
// sharpness. How far a column sits above the coverage threshold measures it, scaling the plateau
// while the edge keeps its own fast rise.
//
// Measured over columns with cloud in them:
//
//     curve                 solid (>0.9)   mid    wispy (<0.35)
//     linear                     30%       44%         14%
//     condensation only          63%       20%         14%
//     both, floor 0.30           45%       28%         23%     <- shipped
//
// 0.30 is where the wispy share peaks without the solid share falling below the mid one.
//
// Both tables are relative-height measurements, sampled at a fixed fraction of a column's own
// plateau. PLAGUE_CLOUD_PARCEL_MIN_TOP below does not change them.
const float PLAGUE_CLOUD_VIGOUR_FLOOR = 0.30;

// Fraction of the slab a marginal column reaches. A strong column reaches 1.0. A column's own
// field strength stands in for how deep its updraught went, the quantity PLAGUE_CLOUD_VIGOUR_FLOOR
// already reads for density.
//
// 900x900 sample, shipped cumulus row: 0.35 gives median cloud-top height 0.45 of slab depth,
// coefficient of variation 0.30.
const float PLAGUE_CLOUD_PARCEL_MIN_TOP = 0.35;

/**
 * The vertical shape, from a flat sheet at convective 0 to a deep tower at convective 1.
 *
 * @param h          fractional height through the column's own envelope, 0 at base, 1 at top
 * @param convective the genus's own selector, see cloud_types.glsl for how each row got its value
 *
 * Two smoothsteps and two mixes: cheap because this runs once per marched sample and once per sun
 * tap. Shape lives entirely in where the two smoothstep edges sit.
 */
float plagueCloudHeightProfile(float h, float convective) {
    float c = clamp(convective, 0.0, 1.0);
    float baseSpan = mix(PLAGUE_CLOUD_SHEET_BASE, PLAGUE_CLOUD_TOWER_BASE, c);
    float topOnset = mix(PLAGUE_CLOUD_SHEET_TOP, PLAGUE_CLOUD_TOWER_TOP, c);
    return smoothstep(0.0, baseSpan, h) * (1.0 - smoothstep(topOnset, 1.0, h));
}

/**
 * The coverage field, thresholded at the deck's solved cutoff and remapped back to 0..1, then
 * shaped vertically. Without the remap, density steps from nothing to `1 - cut` the instant the
 * field crosses threshold, drawing a hard edge exactly where the silhouette should be softest.
 *
 * The region enters as the threshold, not a multiplier: multiplying would thin a cloud toward
 * transparency at a system's edge while leaving its footprint the same, breaking the coverage figure
 * the genus row states. Mixing the cutoff toward PLAGUE_CLOUD_FIELD_CLOSED instead makes an
 * out-of-region column exactly empty and expresses the crossing through the cell field's own lumps,
 * so a weather system's edge always thins out rather than drawing a line.
 *
 * Measured end to end (20,000 world positions, Balanced tier, cumulus at 0.375 coverage): the
 * one-field and two-field constructions agree to within 0.011 on every alpha threshold, confirming
 * the second scale changes how the sky is organised and not how much of it is covered.
 *
 * @param octaves    the caller's choice: the full field for the marched density, a cheap two for
 *                   the sun march. See PLAGUE_CLOUD_COVERAGE_OCTAVES_COARSE.
 * @param region     from plagueCloudRegion, hoisted by the caller because the sun march reuses one
 *                   value across all five of its taps
 * @param h          fractional height through the slab, 0 at the base, 1 at the ceiling
 * @param convective the genus's own height-profile selector, see cloud_types.glsl
 */
float plagueCloudCoverage(vec2 q, PlagueCloudDeck deck, int octaves, float region,
                          float h, float convective) {
    float cut = mix(PLAGUE_CLOUD_FIELD_CLOSED, deck.cut, region);
    float n = plagueCloudFieldFbm(q, octaves);
    float span = max(PLAGUE_CLOUD_FIELD_TOP - cut, PLAGUE_CLOUD_MIN_SPAN);
    // Linear position across the surviving range, then the condensation curve (PLAGUE_CLOUD_CONDENSE).
    float raw = clamp((n - cut) / span, 0.0, 1.0);

    // Column's own ceiling: PLAGUE_CLOUD_PARCEL_MIN_TOP for a marginal column, 1.0 for a strong core.
    float top = mix(PLAGUE_CLOUD_PARCEL_MIN_TOP, 1.0, raw);
    float profile = plagueCloudHeightProfile(min(h / max(top, 1e-3), 1.0), convective);

    // Profile applies before the condensation edge. A marginal column's value drops under
    // threshold as h nears its own top, closing the footprint to zero with no shared ceiling.
    raw *= profile;
    float edge = smoothstep(0.0, PLAGUE_CLOUD_CONDENSE, raw);
    // edge is boundary SHARPNESS (a phase change, same for every cloud); vigour is DENSITY (varies
    // per cloud). Multiplying keeps crisp edges on a wispy cloud instead of fading both ends.
    float vigour = mix(PLAGUE_CLOUD_VIGOUR_FLOOR, 1.0, raw);
    return edge * vigour;
}

/**
 * One tap of the three-dimensional erosion field, built from the two-dimensional noise texture.
 * Two horizontal slices, each offset into a different part of the tile by the R2 sequence and
 * smoothstep-interpolated between, avoid the vertical streaks a 2D pattern extruded upward gives.
 * No fract() wrap on the UV: the sampler repeats and the texture is tileable, so the hardware wrap
 * is exact.
 */
float plagueCloudDetail(vec3 p) {
    float slice = floor(p.y);
    float f = p.y - slice;
    f = f * f * (3.0 - 2.0 * f);

    vec2 offLo = fract(slice * PLAGUE_CLOUD_SLICE_R2) * PLAGUE_CLOUD_NOISE_TEXELS;
    vec2 offHi = fract((slice + 1.0) * PLAGUE_CLOUD_SLICE_R2) * PLAGUE_CLOUD_NOISE_TEXELS;

    float lo = PLAGUE_CLOUD_NOISE((p.xz + offLo) / PLAGUE_CLOUD_NOISE_TEXELS).a;
    float hi = PLAGUE_CLOUD_NOISE((p.xz + offHi) / PLAGUE_CLOUD_NOISE_TEXELS).a;
    return mix(lo, hi, f);
}

/**
 * How many erosion cells the field carries. The design value, unconditionally — not clamped against
 * the march step. Cloud Size scales the slab's DEPTH along with its width, so the field stays
 * self-similar under the slider without needing a resolution-driven clamp; the tiers' own per-pixel
 * dither and temporal resolve already converge detail finer than one march step.
 *
 * Kept as a function rather than folded into its callers so a genus wanting different roughness has
 * one place to say so when 7b lands.
 */
float plagueCloudErosionCells(PlagueCloudDeck deck) {
    return PLAGUE_CLOUD_EROSION_CELLS;
}

/** Two octaves of it, weighted so the coarse one sets the lobes and the fine one only roughens them. */
float plagueCloudErosion(vec3 p) {
    return plagueCloudDetail(p) * 0.66667
         + plagueCloudDetail(p * PLAGUE_CLOUD_EROSION_LACUNARITY + PLAGUE_CLOUD_EROSION_OFFSET)
           * 0.33333;
}

/**
 * NORMALISED density at a world position, 0..1. The whole three-factor field. The march turns this
 * into an extinction coefficient by multiplying by `tau / depth` (the genus's vertical optical depth
 * over its own thickness), which is why nothing in this file needs an extinction constant of its own.
 *
 * @param worldPos absolute world position, not camera-relative (the field is anchored to the world)
 * @param drift    from plagueCloudDrift, hoisted by the caller: it is constant along a ray
 *
 * Four early-outs in increasing cost order: outside the slab, outside every weather system, below
 * the coverage cutoff, zero after the height profile. The region is tested before the cell field so
 * the cheap 3-octave region check can reject the expensive 4-octave field and erosion fetches
 * entirely — rejecting 12-56% of samples depending on Cloud Amount, worth more the fuller the sky.
 */
float plagueCloudDensityAt(vec3 worldPos, PlagueCloudDeck deck, vec2 drift, out float regionOut) {
    regionOut = 0.0;
    float h = (worldPos.y - deck.base) / max(deck.depth, 1e-3);
    if (h <= 0.0 || h >= 1.0) {
        return 0.0;
    }

    vec2 q = plagueCloudSampleCoord(worldPos.xz, deck, drift);

    float region = plagueCloudRegion(q, deck);
    regionOut = region;
    if (region <= 0.0) {
        return 0.0;
    }

    float shaped = plagueCloudCoverage(q, deck, PLAGUE_CLOUD_COVERAGE_OCTAVES, region,
                                       h, deck.convective);
    if (shaped <= 0.0) {
        return 0.0;
    }

    // The erosion coordinate rides the same sheared, drifted sample coordinate the coverage does, so
    // the fray travels with the cloud it belongs to instead of sliding through it. Vertically it uses
    // the fractional height, which is what gives the field the slab's aspect ratio. The cell count is
    // the resolvable one rather than the nominal eight, see plagueCloudErosionCells.
    vec3 e = vec3(q.x, h, q.y) * plagueCloudErosionCells(deck);

    float rest = 1.0 - shaped;
    float weight = PLAGUE_CLOUD_EROSION_PEAK * shaped * rest * rest;
    float eaten = plagueCloudErosion(e) * PLAGUE_CLOUD_EROSION_STRENGTH * weight;
    return clamp(shaped - eaten, 0.0, 1.0);
}

/**
 * The same field with its two most expensive terms dropped: two coverage octaves, no erosion. For
 * the sun march only — it produces an optical depth (an integral), the one quantity that genuinely
 * does not care about high-frequency detail. Do not use where density itself is drawn: it is a
 * different, visibly smoother field.
 *
 * @param region taken as given rather than sampled, so a caller walking a short fan pays for the
 *               region field once. See plagueCloudLightTransmittance for the approximation's range.
 */
float plagueCloudDensityCoarseIn(vec3 worldPos, PlagueCloudDeck deck, vec2 drift, float region) {
    float h = (worldPos.y - deck.base) / max(deck.depth, 1e-3);
    if (h <= 0.0 || h >= 1.0) {
        return 0.0;
    }
    vec2 q = plagueCloudSampleCoord(worldPos.xz, deck, drift);
    return plagueCloudCoverage(q, deck, PLAGUE_CLOUD_COVERAGE_OCTAVES_COARSE, region,
                               h, deck.convective);
}

/**
 * The same, sampling the region at this position rather than being handed one. The entry point for
 * a caller with no fan to hoist out of: the resolve's cloud-shadow query, three isolated heights
 * above one fragment with no neighbouring taps to share a region with.
 */
float plagueCloudDensityCoarse(vec3 worldPos, PlagueCloudDeck deck, vec2 drift) {
    float region = plagueCloudRegion(plagueCloudSampleCoord(worldPos.xz, deck, drift), deck);
    return plagueCloudDensityCoarseIn(worldPos, deck, drift, region);
}

/**
 * Normalised density at a world position, computing its own drift. Self-contained for a
 * cloud-shadow consumer with no ray to hoist a drift out of; the march uses the hoisted pair above
 * instead since recomputing drift per sample would be wasted work.
 */
float plagueCloudDensity(vec3 worldPos, PlagueCloudDeck deck, float syncedTime) {
    // Region is an output of the density evaluation, discarded here rather than via a second entry
    // point, which would be two versions of the same field free to drift apart.
    float unusedRegion;
    return plagueCloudDensityAt(worldPos, deck, plagueCloudDrift(deck, syncedTime), unusedRegion);
}

#endif // PLAGUE_CLOUD_DENSITY
