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
 * World XZ to a coverage sample coordinate: cell-normalised, sheared along the wind, drifted, then
 * domain-warped to break the coverage/detail volumes' own exact periodicity.
 *
 * The shear divides the along-wind axis (dividing a sampling coordinate by s makes the sampled
 * feature s times longer, which is what shear physically does downwind). Drift is added AFTER the
 * shear, in the sheared frame, so a genus with shear s advects s times faster in world blocks than
 * the nominal wind speed: ten percent at the cumulus row's 1.10.
 *
 * Takes `cell`/`shear` explicitly so callers state the fixed coordinate frame they use. The active
 * density paths pass the calm reference cell for every weather state: blending normalized
 * coordinates would continuously rescale an absolute-world transform around world origin.
 *
 * Without the warp, `q` repeats the coverage/detail volumes' 48-texel tile exactly every one cell,
 * since GL_REPEAT wraps a plain `worldXZ / cell` in lockstep and a grazing-angle view ray crosses
 * dozens of repeats (PLAGUE_CLOUD_DISTANCE / cell is ~69 at the shipped Cloud Size): a perfectly
 * periodic field viewed obliquely from one point is a textbook Moire generator. `plagueSkyFbm`
 * (already used by the erosion curl, no new noise source) evaluated at PLAGUE_CLOUD_WEATHER_CLOUDS
 * cells per cycle decorrelates repeats far enough apart to break the Moire pattern while barely
 * moving within any one cell, leaving a single cloud's own silhouette untouched.
 */
vec2 plagueCloudAllocationCoord(vec2 worldXZ, float cell, float shear, vec2 drift) {
    vec2 q = worldXZ / max(cell, 1e-3);
    float along = dot(q, PLAGUE_CLOUD_WIND_UNIT);
    q += PLAGUE_CLOUD_WIND_UNIT * (along / max(shear, 1e-3) - along);
    q += drift;
    return q;
}

vec2 plagueCloudSampleCoord(vec2 worldXZ, float cell, float shear, vec2 drift) {
    vec2 q = plagueCloudAllocationCoord(worldXZ, cell, shear, drift);

    vec2 warpCoord = q / PLAGUE_CLOUD_WEATHER_CLOUDS;
    vec2 warp = vec2(plagueSkyFbm(warpCoord, 2),
                      plagueSkyFbm(warpCoord + vec2(31.7, 57.3), 2)) - 0.5;
    return q + warp * PLAGUE_CLOUD_WARP_STRENGTH;
}

// One candidate cell per four fixed lobe cells gives stable 230.4-block world-space addresses.
// The 0.90 span was authored against the six 2026-08-28 high-altitude owner captures: +/-0.45
// cells keeps each site inside its home cell while breaking the visible rows left by +/-0.18.
const float PLAGUE_CLOUD_ALLOCATION_PERIOD = 4.0;
const float PLAGUE_CLOUD_SITE_JITTER = 0.90;

// Stable owner-local density potential authored against the owner's 2026-08-28 ring/base/storm
// captures. It is deliberately NOT a support mask: the fixed world-space 3-D volume is sampled
// after this potential and owns the visible isosurface. The three fixed lobes only organise that
// density into a non-radial cloud identity. Weather may widen the morphology through
// deck.footprint; Cloud Size may not scale any radius, offset, or sample coordinate.
const float PLAGUE_CLOUD_MORPHOLOGY_RADIUS = 0.42;
const float PLAGUE_CLOUD_MORPHOLOGY_ASPECT_MIN = 0.86;
const float PLAGUE_CLOUD_MORPHOLOGY_ASPECT_MAX = 1.18;
const vec2 PLAGUE_CLOUD_MORPHOLOGY_LOBE_OFFSET = vec2(0.42, 0.24);
const float PLAGUE_CLOUD_MORPHOLOGY_CORE_RADIUS = 0.74;
const float PLAGUE_CLOUD_MORPHOLOGY_SIDE_RADIUS = 0.64;
const float PLAGUE_CLOUD_MORPHOLOGY_CROWN_RADIUS = 0.56;

// A quadratic penalty of 0.36 raises the fixed 0.450656 cutoff beyond the measured 0.78005 field
// ceiling at one nominal lobe radius. The sampled field therefore closes the edge before any
// analytic boundary exists. The 0.24 Size gain was selected from the same capture sequence: over
// the accepted 0.922..1.461 physical response it moves the nested isosurface by -0.028..+0.131,
// enough to reveal new irregular density without moving the cloud's address.
const float PLAGUE_CLOUD_MORPHOLOGY_PENALTY = 0.36;
// 0.52 exceeds FIELD_TOP - CANDIDATE_CUTOFF plus maximum Size's +0.131 bias, so profile zero is
// guaranteed empty before h reaches either hard endpoint. That keeps cloud tops irregular while
// the per-owner h=0 plane remains the locally-flat condensation base.
const float PLAGUE_CLOUD_MORPHOLOGY_VERTICAL_PENALTY = 0.52;
const float PLAGUE_CLOUD_SIZE_DENSITY_GAIN = 0.24;

// A stratiform layer's own feature size. deck.cell is 57.6 blocks, sized for cumulus, and cannot
// change per form: a moving world-coordinate divisor rephases the field around world origin. The
// sheet's large structure rides on top of it at 32 cells (~1840 blocks), the scale real stratus
// varies thickness over. Without it a closed sheet is a flat lid over the volume's fine stipple.
const float PLAGUE_CLOUD_SHEET_SCALE = 32.0;

// Scale of the field that decides WHERE a genus is at all, in WORLD BLOCKS. The candidate lattice is
// uniform, so without this every genus fills the whole sky at whatever density its population sets:
// cirrocumulus puts 901 cells in a 512-block patch and a fifth of them active covers everything.
//
// One distance for every genus: patchiness belongs to the air mass. In blocks rather than deck
// cells, or the patch shrinks with the genus and the finest-celled decks get the smallest patches.
//
// Sized against a deck's VISIBLE extent, not the cloud draw distance. Altocumulus sits 768 blocks
// up, so by 15 degrees elevation it is 2866 blocks away and nearly all of it is nearer; a period
// near the 4000-block draw distance exceeds the whole visible deck and reads as no patchiness at
// all. 1200 puts two to three banks and their gaps across the sky. Picked off plan views of the
// live candidate field over that visible extent: 600 breaks into clumps too small to be masses,
// 1000-1500 reads as banks.
const float PLAGUE_CLOUD_PATCH_BLOCKS = 1200.0;
// Amplitude, against a floor whose whole range is 0.479 (early-out to SHEET_FLOOR). At 0.20 a
// mid-strength sheet opens real holes while a full one only thins: breaking up versus overcast.
const float PLAGUE_CLOUD_SHEET_VARIATION = 0.20;

// +/-6.144 blocks (eight percent of the reference cumulus depth), keyed by the existing owner
// jitter hash. Each individual base is still a plane, while neighbouring clouds no longer share
// the one global deck-base line visible in the owner's low-angle capture.
const float PLAGUE_CLOUD_BASE_VARIATION = 0.08 * PLAGUE_CLOUD_CUMULUS_DEPTH;

// These odd uints are the first little-endian 32-bit SHA-256 word of the stated project-domain
// labels, with bit zero set: plague.cloud.candidate.{x,z,lane,seed,avalanche.0,avalanche.1}.
// That is a reproducible in-repo derivation, not a borrowed hash. The authored 16/15/16 shifts
// and two avalanche multiplies are pinned by the 3x3/5x5 and exact population verifier checks.
const uint PLAGUE_CLOUD_HASH_X = 3145090451u;
const uint PLAGUE_CLOUD_HASH_Z = 749339837u;
const uint PLAGUE_CLOUD_HASH_LANE = 1193920015u;
const uint PLAGUE_CLOUD_HASH_SEED = 2452362395u;
const uint PLAGUE_CLOUD_HASH_MIX_0 = 1534486637u;
const uint PLAGUE_CLOUD_HASH_MIX_1 = 2579079u;

// First salt in the deterministic 0..2047 lexicographic integer-hash search whose fixed 24x24
// probe gave the accepted uniform rank distribution. Keeping lane 2 separate from jitter lanes 0/1
// prevents a site's position and ellipse from correlating with when Amount activates it.
const ivec2 PLAGUE_CLOUD_RANK_SALT = ivec2(219, 718);

uint plagueCloudCandidateHashBits(ivec2 cellId, uint lane) {
    uint h = uint(cellId.x) * PLAGUE_CLOUD_HASH_X
           + uint(cellId.y) * PLAGUE_CLOUD_HASH_Z
           + lane * PLAGUE_CLOUD_HASH_LANE
           + PLAGUE_CLOUD_HASH_SEED;
    h ^= h >> 16u;
    h *= PLAGUE_CLOUD_HASH_MIX_0;
    h ^= h >> 15u;
    h *= PLAGUE_CLOUD_HASH_MIX_1;
    h ^= h >> 16u;
    return h;
}

float plagueCloudCandidateHash(ivec2 cellId, uint lane) {
    // float exactly represents every 24-bit integer; 2^-24 therefore avoids backend-dependent
    // integer-to-float rounding while returning the same [0,1) value on every conforming GPU.
    return float(plagueCloudCandidateHashBits(cellId, lane) >> 8u) * (1.0 / 16777216.0);
}

vec2 plagueCloudCandidateJitter(ivec2 cellId) {
    return vec2(plagueCloudCandidateHash(cellId, 0u),
                plagueCloudCandidateHash(cellId, 1u));
}

float plagueCloudPotentialLobe(vec2 local, vec2 centre, float radius) {
    vec2 horizontal = (local - centre) / max(radius, 1e-3);
    return dot(horizontal, horizontal);
}

float plagueCloudHeightProfile(float h, float family);

/** Stable max-union of active owner density potentials. Each candidate's rank, site, base offset,
 * lobe frame, and texture coordinates are fixed data. Increasing Amount can only raise the max;
 * increasing Size raises the density potential but never dilates this analytic organisation.
 * `ownerH` belongs to the winning potential and is used only for height-modulated erosion. */
float plagueCloudCandidatePotential(vec2 allocationQ, float worldY, PlagueCloudDeck deck,
                                    out float ownerH) {
    ownerH = -1.0;
    if (deck.population <= 0.0) {
        return -1e6;
    }

    vec2 allocationP = allocationQ / PLAGUE_CLOUD_ALLOCATION_PERIOD;
    ivec2 baseCell = ivec2(floor(allocationP));
    float radius = PLAGUE_CLOUD_MORPHOLOGY_RADIUS * deck.footprint;
    float sizeBias = PLAGUE_CLOUD_SIZE_DENSITY_GAIN * log2(max(deck.sizeRatio, 1e-3));

    // A stratiform deck is a layer, not a scatter of candidates. Seeding the union with the deck's
    // own floor keeps every position eligible so the base volume alone decides where the sheet is
    // thick; candidates then ride on top of it as ragged base variation. The floor carries the same
    // vertical penalty the candidates do, so the sheet closes at its own top and base instead of
    // ending on a flat lid. A convective deck's floor is far below the early-out, which reproduces
    // the candidate-only field exactly.
    // Where this genus exists at all. Subtracted from every candidate's potential, so a low patch
    // pushes the whole neighbourhood under the cutoff and leaves open sky rather than thinning the
    // cells evenly. Costs one fbm on decks that ask for it and nothing on decks that do not.
    float patchGate = 0.0;
    if (deck.patchiness > 0.0) {
        // deck.cell takes cell-normalised allocationQ back to world blocks. Shear and drift ride
        // along, elongating a patch downwind and advecting it.
        patchGate = deck.patchiness
                  * (1.0 - plagueSkyFbm(allocationQ * deck.cell / PLAGUE_CLOUD_PATCH_BLOCKS, 2));
    }

    float bestPotential = -1e6;
    float sheetH = (worldY - deck.base) / max(deck.depth, 1e-3);
    if (deck.sheetFloor > -1.0 && sheetH > 0.0 && sheetH < 1.0) {
        // Per position, not a constant: a uniform floor is a flat lid. Drift rides in through
        // allocationQ, so thick and thin regions advect with the deck.
        float sheetVary = plagueSkyFbm(allocationQ / PLAGUE_CLOUD_SHEET_SCALE, 2);
        bestPotential = deck.sheetFloor
                      - PLAGUE_CLOUD_SHEET_VARIATION * (1.0 - sheetVary)
                      - PLAGUE_CLOUD_MORPHOLOGY_VERTICAL_PENALTY
                      * (1.0 - plagueCloudHeightProfile(sheetH, deck.family));
        ownerH = sheetH;
    }

    for (int x = -1; x <= 1; x++) {
        for (int z = -1; z <= 1; z++) {
            ivec2 cellId = baseCell + ivec2(x, z);
            float rank = plagueCloudCandidateHash(cellId + PLAGUE_CLOUD_RANK_SALT, 2u);
            if (rank >= deck.population) {
                continue;
            }

            vec2 jitter = plagueCloudCandidateJitter(cellId);
            float candidateBase = deck.base
                                + (jitter.y * 2.0 - 1.0) * PLAGUE_CLOUD_BASE_VARIATION;
            float h = (worldY - candidateBase) / max(deck.depth, 1e-3);
            if (h <= 0.0 || h >= 1.0) {
                continue;
            }

            vec2 site = vec2(cellId) + 0.5
                      + (jitter - 0.5) * PLAGUE_CLOUD_SITE_JITTER;
            vec2 delta = allocationP - site;

            // Reuse the position hashes as a stable ellipse orientation/aspect seed. Reciprocal
            // axis scaling preserves support area while varying the silhouette.
            vec2 axisSeed = jitter * 2.0 - 1.0;
            vec2 axis = axisSeed * inversesqrt(max(dot(axisSeed, axisSeed), 1e-6));
            vec2 perpendicular = vec2(-axis.y, axis.x);
            float aspect = mix(PLAGUE_CLOUD_MORPHOLOGY_ASPECT_MIN,
                               PLAGUE_CLOUD_MORPHOLOGY_ASPECT_MAX, jitter.x);
            vec2 local = vec2(dot(delta, axis) / aspect,
                              dot(delta, perpendicular) * aspect);

            // Hash-derived signs mirror the same three-lobe potential per owner. Weather footprint
            // scales this frame; Size is intentionally absent and reaches only sizeBias above.
            vec2 lobeOffset = radius * PLAGUE_CLOUD_MORPHOLOGY_LOBE_OFFSET
                            * vec2(jitter.x < 0.5 ? -1.0 : 1.0,
                                   jitter.y < 0.5 ? -1.0 : 1.0);
            vec2 crownOffset = vec2(-lobeOffset.y, lobeOffset.x);

            float horizontalMetric = plagueCloudPotentialLobe(
                    local, vec2(0.0), radius * PLAGUE_CLOUD_MORPHOLOGY_CORE_RADIUS);
            horizontalMetric = min(horizontalMetric, plagueCloudPotentialLobe(
                    local, lobeOffset, radius * PLAGUE_CLOUD_MORPHOLOGY_SIDE_RADIUS));
            horizontalMetric = min(horizontalMetric, plagueCloudPotentialLobe(
                    local, crownOffset, radius * PLAGUE_CLOUD_MORPHOLOGY_CROWN_RADIUS));

            float profile = plagueCloudHeightProfile(h, deck.family);
            float candidatePotential = sizeBias + deck.convectiveLift - patchGate
                                      - PLAGUE_CLOUD_MORPHOLOGY_PENALTY * horizontalMetric
                                      - PLAGUE_CLOUD_MORPHOLOGY_VERTICAL_PENALTY
                                      * (1.0 - profile);
            if (candidatePotential > bestPotential) {
                bestPotential = candidatePotential;
                ownerH = h;
            }
        }
    }
    return bestPotential;
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
// The condensation curve alone saturates every cloud to solid: the missing quantity is the cloud's
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

// Third profile anchor: a deep tower whose top SPREADS before it cuts off, rather than tapering
// uniformly, giving the anvil-adjacent shape a cumulonimbus needs. Authored the same way SHEET/TOWER
// were: solved against the drawn silhouette. Wider base span than TOWER's own (a storm's updraught
// core is broader relative to its own height than a fair-weather cumulus's) and a top onset well
// below 1.0, leaving real room for the spreading band above it.
const float PLAGUE_CLOUD_STORMTOP_BASE = 0.08;
const float PLAGUE_CLOUD_STORMTOP_TOP  = 0.30;

/**
 * The vertical shape, from a flat sheet at family 0 through a deep tower at family 1 to a
 * spreading-top storm tower at family 2.
 *
 * @param h      fractional height through the column's own envelope, 0 at base, 1 at top
 * @param family the genus's own selector, see cloud_types.glsl for how each row got its value
 *
 * Two smoothsteps and two mixes: cheap because this runs once per marched sample and once per sun
 * tap. Shape lives entirely in where the two smoothstep edges sit.
 */
float plagueCloudHeightProfile(float h, float family) {
    float f = clamp(family, 0.0, 2.0);
    float t = f < 1.0 ? f : f - 1.0;
    float baseSpan = f < 1.0
            ? mix(PLAGUE_CLOUD_SHEET_BASE, PLAGUE_CLOUD_TOWER_BASE, t)
            : mix(PLAGUE_CLOUD_TOWER_BASE, PLAGUE_CLOUD_STORMTOP_BASE, t);
    float topOnset = f < 1.0
            ? mix(PLAGUE_CLOUD_SHEET_TOP, PLAGUE_CLOUD_TOWER_TOP, t)
            : mix(PLAGUE_CLOUD_TOWER_TOP, PLAGUE_CLOUD_STORMTOP_TOP, t);
    return smoothstep(0.0, baseSpan, h) * (1.0 - smoothstep(topOnset, 1.0, h));
}

/**
 * World blocks one full cycle of the coverage/detail volumes' Y axis should span, independent of
 * how tall weather has grown the deck. `h` (fractional slab height, 0..1) always spans exactly one
 * noise cycle when used AS a texture coordinate directly: fine at the calm depth this is tuned
 * against, but deck.depth grows up to 25x at full thunder (cloud_types.glsl) while the fixed XZ
 * frame preserves the calm reference scale, and sampling the same one Y cycle across 25x the world
 * depth would stretch every Worley cell into a near-continuous vertical column, reading as a
 * radiating fan of light/dark rays at grazing angles.
 *
 * Candidate Size changes slab depth and the selected density isosurface only. Keeping this world
 * period fixed means larger whole clouds reveal more unchanged 3D density rather than stretching
 * one texture lobe or rephasing the field around world origin.
 */
float plagueCloudHeightRef(PlagueCloudDeck deck) {
    return PLAGUE_CLOUD_CUMULUS_DEPTH;
}

// Four retains several generated volume cells through the cumulus depth. The horizontal scale is
// derived, not independently authored: 4 * 76.8 / 57.6 = 5.3333 makes one organization texture
// unit span the same 307.2 world blocks on X/Z and Y at the accepted reference. This removes the
// 0.148 vertical:horizontal broad-field bias measured in the six 2026-08-28 owner captures.
const float PLAGUE_CLOUD_ORGANIZATION_VERTICAL_SCALE = 4.0;
const float PLAGUE_CLOUD_ORGANIZATION_SCALE =
        PLAGUE_CLOUD_ORGANIZATION_VERTICAL_SCALE * PLAGUE_CLOUD_CUMULUS_DEPTH
        / (PLAGUE_CLOUD_CUMULUS_CELL * PLAGUE_CLOUD_REFERENCE_SCALE);

// At every Size, 0.20 leaves the local sample as edge/lobe breakup while the near-isotropic broad
// sample owns the density masses inside the owner-local dome; selected from the same captures.
const float PLAGUE_CLOUD_PRIMARY_WEIGHT = 0.20;

/** Coarse-volume density at fixed local plus broad/medium true-3D scales. */
float plagueCloudBaseShape(vec3 p, PlagueCloudDeck deck) {
    float primary = PLAGUE_CLOUD_NOISE_3D(p).r;
    vec3 organizationP = vec3(p.x / PLAGUE_CLOUD_ORGANIZATION_SCALE,
                              0.5 + (p.y - 0.5) / PLAGUE_CLOUD_ORGANIZATION_VERTICAL_SCALE,
                              p.z / PLAGUE_CLOUD_ORGANIZATION_SCALE);
    float organization = PLAGUE_CLOUD_NOISE_3D(organizationP).r;
    return mix(organization, primary, PLAGUE_CLOUD_PRIMARY_WEIGHT);
}

/**
 * Condense one already-sampled world-space base value through the winning candidate's density
 * potential. Candidate organisation moves the cutoff, not the coordinate and not final alpha, so
 * the sampled irregular 3-D isosurface always owns the visible silhouette.
 *
 * @param n         the two-volume base field at a fixed world-space coordinate
 * @param potential stable max candidate potential; Size raises it monotonically
 */
float plagueCloudCoverage(float n, PlagueCloudDeck deck, float potential) {
    if (deck.population <= 0.0) {
        return 0.0;
    }
    float cut = deck.cut - potential;
    float span = max(PLAGUE_CLOUD_FIELD_TOP - cut, PLAGUE_CLOUD_MIN_SPAN);
    // Linear position across the surviving range, then the condensation curve (PLAGUE_CLOUD_CONDENSE).
    float raw = clamp((n - cut) / span, 0.0, 1.0);
    float edge = smoothstep(0.0, PLAGUE_CLOUD_CONDENSE, raw);
    // edge is boundary SHARPNESS (a phase change, same for every cloud); vigour is DENSITY (varies
    // per cloud). Multiplying keeps crisp edges on a wispy cloud instead of fading both ends.
    float vigour = mix(PLAGUE_CLOUD_VIGOUR_FLOOR, 1.0, raw);
    return edge * vigour;
}

/** One tap of the 3D erosion/detail volume (tools/generate_cloud_noise.py). */
float plagueCloudDetail(vec3 p) {
    return PLAGUE_CLOUD_DETAIL_3D(p).r;
}

/**
 * 2D curl noise (a divergence-free vector field) derived from plagueSkyFbm's own gradient via
 * finite differences, offset 90 degrees between the two components: the standard construction,
 * since curl of a scalar potential in 2D is just the perpendicular gradient. Bends the erosion
 * sample position so eroded edges wander rather than following the noise lattice's own straight
 * isolines, with no new texture: it reuses the ALU field the coordinate warp already samples.
 */
vec2 plagueCloudCurl(vec2 p, float epsilon) {
    float n1 = plagueSkyFbm(p + vec2(0.0, epsilon), 2);
    float n2 = plagueSkyFbm(p - vec2(0.0, epsilon), 2);
    float n3 = plagueSkyFbm(p + vec2(epsilon, 0.0), 2);
    float n4 = plagueSkyFbm(p - vec2(epsilon, 0.0), 2);
    float dx = (n1 - n2) / (2.0 * epsilon);
    float dy = (n3 - n4) / (2.0 * epsilon);
    return vec2(dy, -dx);
}

// Curl warp scale: small relative to one erosion cell, enough to visibly bend an eroded edge
// without displacing it into a neighbouring cell's own detail. Authored, retune against a render.
const float PLAGUE_CLOUD_CURL_STRENGTH = 0.35;
const float PLAGUE_CLOUD_CURL_EPSILON  = 0.1;

// How much erosion survives at the very base of a column, as a fraction of full strength.
// Authored: a real cumulus base is sharp almost to the ground, so this stays low.
const float PLAGUE_CLOUD_EROSION_BASE_FLOOR = 0.25;

/**
 * How many erosion cells the fixed-frequency field carries. The design value is unconditional and
 * not clamped against the march step; Cloud Size changes morphology and physical depth without
 * changing the XZ erosion coordinate.
 *
 * Kept as a function rather than folded into its callers so a genus wanting different roughness has
 * one place to say so when 7b lands.
 */
float plagueCloudErosionCells(PlagueCloudDeck deck) {
    return PLAGUE_CLOUD_EROSION_CELLS;
}

/**
 * Two octaves, weighted so the coarse one sets the lobes and the fine one only roughens them,
 * curl-warped so the eroded edge wanders rather than following the noise lattice's own straight
 * lines, and height-modulated: softened near the base (a real cumulus base stays sharp almost to
 * the ground), applied more directly near the top (the wispy, broken upper surface).
 *
 * @param h fractional height through the column's own envelope (0 at base, 1 at that column's own
 *          top): the same normalised height plagueCloudCoverage already computes, passed through
 *          rather than recomputed
 */
float plagueCloudErosion(vec3 p, float h) {
    vec2 warp = plagueCloudCurl(p.xz, PLAGUE_CLOUD_CURL_EPSILON) * PLAGUE_CLOUD_CURL_STRENGTH;
    vec3 warped = vec3(p.x + warp.x, p.y, p.z + warp.y);
    float detail = plagueCloudDetail(warped) * 0.66667
                 + plagueCloudDetail(warped * PLAGUE_CLOUD_EROSION_LACUNARITY + PLAGUE_CLOUD_EROSION_OFFSET)
                   * 0.33333;
    // Base floor stays flat: erosion softened toward h=0. Top stays wispy: erosion at full strength
    // toward h=1. Authored curve shape (not linear) so the transition sits mostly in the upper half
    // of the column, matching how a real cumulus base stays sharp much closer to its own ceiling
    // than a naive linear fade would give.
    float heightMod = mix(PLAGUE_CLOUD_EROSION_BASE_FLOOR, 1.0, smoothstep(0.0, 0.6, h));
    return detail * heightMod;
}

/**
 * World XZ displaced downwind in proportion to height inside the deck: the base trails the top by
 * `deck.fallShear` cells across the full depth, centred so mid-height keeps its place and the layer
 * leans rather than sliding.
 *
 * Applied before BOTH the allocation and sample coordinates, never just the sample one. The
 * allocation coordinate is what decides where a candidate sits at all, so shearing only the sample
 * coordinate perturbs the noise inside a blob and leaves the blob itself upright.
 */
vec2 plagueCloudFallShearXZ(vec3 worldPos, PlagueCloudDeck deck) {
    if (deck.fallShear <= 0.0) {
        return worldPos.xz;
    }
    float h = clamp((worldPos.y - deck.base) / max(deck.depth, 1e-3), 0.0, 1.0);
    return worldPos.xz + PLAGUE_CLOUD_WIND_UNIT * (deck.fallShear * deck.cell * (h - 0.5));
}

/**
 * NORMALISED density at a world position, 0..1. The whole three-factor field. The march turns this
 * into an extinction coefficient by multiplying by `tau / depth` (the genus's vertical optical depth
 * over its own thickness), which is why nothing in this file needs an extinction constant of its own.
 *
 * @param worldPos absolute world position, not camera-relative (the field is anchored to the world)
 * @param drift    from plagueCloudDrift, hoisted by the caller: it is constant along a ray
 *
 * One fixed calm/reference XZ coordinate frame serves every weather state. Rain and thunder change
 * depth, family, optical depth, coverage and the top profile, while the broad organization lookup
 * supplies the large-scale masses. This keeps the field phase anchored in world space throughout a
 * weather transition and the density path at the two base-volume samples owned by
 * plagueCloudBaseShape.
 */
float plagueCloudDensityAt(vec3 worldPos, PlagueCloudDeck deck, vec2 drift) {
    vec2 shearedXZ = plagueCloudFallShearXZ(worldPos, deck);
    vec2 allocationQ = plagueCloudAllocationCoord(shearedXZ, deck.cell, deck.shear, drift);
    float ownerH;
    float potential = plagueCloudCandidatePotential(allocationQ, worldPos.y, deck, ownerH);
    if (potential <= deck.cut - PLAGUE_CLOUD_FIELD_TOP) {
        return 0.0;
    }

    vec2 q = plagueCloudSampleCoord(shearedXZ, deck.cell, deck.shear, drift);
    // Absolute height above the shared reference base keeps the volume phase fixed while ownerH
    // supplies each candidate's independent locally-flat base and vertical morphology.
    float noiseY = (worldPos.y - deck.base) / plagueCloudHeightRef(deck);
    float baseShape = plagueCloudBaseShape(vec3(q.x, noiseY, q.y), deck);
    float shaped = plagueCloudCoverage(baseShape, deck, potential);
    if (shaped <= 0.0) {
        return 0.0;
    }

    // The erosion coordinate rides the same fixed reference coordinate as coverage, so the fray
    // stays phase-locked to the cloud through the weather transition. Vertically it reuses
    // plagueCloudCoverage's own rescaled coordinate (see plagueCloudHeightRef) rather than the raw
    // fractional height, which would stretch into vertical columns the same way the coverage sample
    // would. Cell count is the resolvable one rather than the nominal eight; see
    // plagueCloudErosionCells.
    float erosionY = (worldPos.y - deck.base) / plagueCloudHeightRef(deck);
    vec3 e = vec3(q.x, erosionY, q.y) * plagueCloudErosionCells(deck);

    float rest = 1.0 - shaped;
    float weight = PLAGUE_CLOUD_EROSION_PEAK * shaped * rest * rest;
    float eaten = plagueCloudErosion(e, ownerH) * PLAGUE_CLOUD_EROSION_STRENGTH * weight;
    return clamp(shaped - eaten, 0.0, 1.0);
}

/**
 * The same field with its most expensive term dropped: no erosion. For the sun march only, since it
 * produces an optical depth (an integral), the one quantity that genuinely does not care about
 * high-frequency detail. Do not use where density itself is drawn: it is a different, visibly
 * smoother field.
 */
float plagueCloudDensityCoarseIn(vec3 worldPos, PlagueCloudDeck deck, vec2 drift) {
    vec2 shearedXZ = plagueCloudFallShearXZ(worldPos, deck);
    vec2 allocationQ = plagueCloudAllocationCoord(shearedXZ, deck.cell, deck.shear, drift);
    float ownerH;
    float potential = plagueCloudCandidatePotential(allocationQ, worldPos.y, deck, ownerH);
    if (potential <= deck.cut - PLAGUE_CLOUD_FIELD_TOP) {
        return 0.0;
    }
    vec2 q = plagueCloudSampleCoord(shearedXZ, deck.cell, deck.shear, drift);
    float noiseY = (worldPos.y - deck.base) / plagueCloudHeightRef(deck);
    float baseShape = plagueCloudBaseShape(vec3(q.x, noiseY, q.y), deck);
    return plagueCloudCoverage(baseShape, deck, potential);
}

/**
 * Coarse entry point for secondary cloud-shadow and reflection consumers.
 */
float plagueCloudDensityCoarse(vec3 worldPos, PlagueCloudDeck deck, vec2 drift) {
    return plagueCloudDensityCoarseIn(worldPos, deck, drift);
}

/**
 * Normalised density at a world position, computing its own drift. Self-contained for a
 * cloud-shadow consumer with no ray to hoist a drift out of; the march uses the hoisted pair above
 * instead since recomputing drift per sample would be wasted work.
 */
float plagueCloudDensity(vec3 worldPos, PlagueCloudDeck deck, float syncedTime) {
    return plagueCloudDensityAt(worldPos, deck, plagueCloudDrift(deck, syncedTime));
}

#endif // PLAGUE_CLOUD_DENSITY
