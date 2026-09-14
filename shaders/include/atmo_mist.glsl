#ifndef PLAGUE_ATMO_MIST
#define PLAGUE_ATMO_MIST

// Compute transport only. Keeping this runtime option out of geometry's imports preserves its
// pack-options ABI. The field is static until world-local climate and wind are validated.
#define u_FogLocalMist 1.0 //[0.00..2.00 step 0.05] runtime "Local Mist Amount"

// First-milestone constraints, checked and rendered by tools/verify_atmo_mist_gpu.py:
// an eight-chunk lattice forms broad banks; peak optical depth across one cell is 0.15 at amount
// one and sea level. These define an optically thin starting medium, not a fitted look.
const float PLAGUE_ATMO_MIST_CELL_BLOCKS = 128.0;
const float PLAGUE_ATMO_LOCAL_MIST_CELL_TAU = 0.15;

// An independently authored integer permutation. The odd multipliers are the largest primes
// below 2^16 and 2^15, respectively; shifts split the 32-bit word around those widths. Multiplying
// by an odd number and xor-shifting both preserve a permutation modulo 2^32. Coordinate mixing
// selects a lattice value; no floating-point sine hash or sampled noise asset is involved.
uint plagueAtmoMistHash(ivec2 cell) {
    uint value = uint(cell.x) * 65521u ^ uint(cell.y) * 32749u;
    value ^= value >> 16;
    value *= 65521u;
    value ^= value >> 15;
    value *= 32749u;
    value ^= value >> 16;
    return value;
}

float plagueAtmoMistLattice(ivec2 cell) {
    // A float exactly represents all 24-bit integers. Both endpoints of [0,1] are reachable.
    return float(plagueAtmoMistHash(cell) >> 8) / 16777215.0;
}

float plagueAtmoLocalMistSigma(vec3 cameraRelativeBlocks) {
    if (u_FogLocalMist <= 0.0 || u_FogDensity <= 0.0 || u_WorldBounds.w > 1.5) return 0.0;

    // Separate the camera's integral lattice origin before adding the short relative offset.
    // Adding small offsets to a large absolute world coordinate first would discard detail.
    // This needs the render camera u_CameraAbs: depth reconstruction includes the same camera
    // motion, including bob, and their sum identifies the fixed world point.
    vec2 cameraCell = floor(u_CameraAbs.xz / PLAGUE_ATMO_MIST_CELL_BLOCKS);
    vec2 local = (u_CameraAbs.xz - cameraCell * PLAGUE_ATMO_MIST_CELL_BLOCKS
                  + cameraRelativeBlocks.xz) / PLAGUE_ATMO_MIST_CELL_BLOCKS;
    ivec2 cell = ivec2(cameraCell) + ivec2(floor(local));
    vec2 f = fract(local);
    // The quintic satisfying value 0/1 and first/second derivative zero at either cell face.
    // It has maximum slope 15/8, so lattice boundaries cannot produce a density step.
    vec2 blend = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float low = mix(plagueAtmoMistLattice(cell), plagueAtmoMistLattice(cell + ivec2(1, 0)), blend.x);
    float high = mix(plagueAtmoMistLattice(cell + ivec2(0, 1)),
                     plagueAtmoMistLattice(cell + ivec2(1, 1)), blend.x);
    // Remap the middle half of the value range: the lower quarter is clear and the upper quarter
    // reaches peak mist. Cubic smoothstep adds no slope at either threshold; combined with the
    // quintic above, per-axis slope is bounded by (15/8)*3/128 per block.
    float bank = smoothstep(0.25, 0.75, mix(low, high, blend.y));
    float altitudeBlocks = max((u_CameraAbs.y - plagueAtmoSeaLevel()) + cameraRelativeBlocks.y, 0.0);
    // The existing Fog Height option is an e-folding height in blocks, including its saved18.
    float vertical = exp(-altitudeBlocks / max(u_FogHeight, 1.0));
    float peakSigma = PLAGUE_ATMO_LOCAL_MIST_CELL_TAU
                    / (PLAGUE_ATMO_MIST_CELL_BLOCKS * PLAGUE_ATMO_METRES_PER_BLOCK);
    return max(u_FogLocalMist, 0.0) * max(u_FogDensity, 0.0) * peakSigma * bank * vertical;
}

#endif
