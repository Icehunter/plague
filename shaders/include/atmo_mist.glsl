#ifndef PLAGUE_ATMO_MIST
#define PLAGUE_ATMO_MIST

// Compute only: geometry passes do not carry this runtime option in u_PackOptions.
// The mist stays fixed in world space until wind and climate data exist.
#define u_FogLocalMist 1.0 //[0.00..2.00 step 0.05] runtime "Local Mist Amount"

// Bank size: two chunks wide, one chunk tall. The eight-block march cells split each bank
// into four steps across and two steps up. One flat bank still holds the 0.15 top
// optical-depth value, over 32 blocks instead of 128, so mist shows up over shorter paths.
// These sizes come from tools/verify_mist_banks.py and the native render check.
const vec3 PLAGUE_ATMO_MIST_CELL_BLOCKS = vec3(32.0, 16.0, 32.0);
const float PLAGUE_ATMO_LOCAL_MIST_CELL_TAU = 0.15;

// Independent integer mix: the odd numbers are the largest primes below 2^16, 2^15, and
// 2^14. The third value adds height shape within the Fog Height range.
uint plagueAtmoMistHash(ivec3 cell) {
    uint value = uint(cell.x) * 65521u ^ uint(cell.y) * 32749u ^ uint(cell.z) * 16381u;
    value ^= value >> 16;
    value *= 65521u;
    value ^= value >> 15;
    value *= 32749u;
    value ^= value >> 16;
    return value;
}

float plagueAtmoMistLattice(ivec3 cell) {
    // All 24-bit integers, including both endpoints, are exactly representable as floats.
    return float(plagueAtmoMistHash(cell) >> 8) / 16777215.0;
}

float plagueAtmoLocalMistSigma(vec3 cameraRelativeBlocks, out float weatherMistScale) {
    weatherMistScale = 1.0;
    if (u_FogLocalMist <= 0.0 || u_FogDensity <= 0.0 || u_WorldBounds.w > 1.5) return 0.0;

    // Split the camera's whole-cell origin before adding relative position. A fixed world
    // sample stays in the same cell as the camera moves, without adding two large floats.
    vec3 cameraCell = floor(u_CameraAbs / PLAGUE_ATMO_MIST_CELL_BLOCKS);
    vec3 local = (u_CameraAbs - cameraCell * PLAGUE_ATMO_MIST_CELL_BLOCKS
                  + cameraRelativeBlocks) / PLAGUE_ATMO_MIST_CELL_BLOCKS;
    ivec3 cell = ivec3(cameraCell) + ivec3(floor(local));
    vec3 f = fract(local);
    // Smooth blend: value, slope, and curve all match at each cell edge (quintic curve).
    vec3 blend = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float z0 = mix(
        mix(plagueAtmoMistLattice(cell), plagueAtmoMistLattice(cell + ivec3(1, 0, 0)), blend.x),
        mix(plagueAtmoMistLattice(cell + ivec3(0, 1, 0)),
            plagueAtmoMistLattice(cell + ivec3(1, 1, 0)), blend.x), blend.y);
    float z1 = mix(
        mix(plagueAtmoMistLattice(cell + ivec3(0, 0, 1)),
            plagueAtmoMistLattice(cell + ivec3(1, 0, 1)), blend.x),
        mix(plagueAtmoMistLattice(cell + ivec3(0, 1, 1)),
            plagueAtmoMistLattice(cell + ivec3(1, 1, 1)), blend.x), blend.y);
    // Keep the same middle-half smooth curve. Plain [0,1] noise has an average value of
    // 1/2, so multiplying by two spreads weather mist between gaps and banks with an
    // average of one.
    float bank = smoothstep(0.25, 0.75, mix(z0, z1, blend.z));
    weatherMistScale = mix(1.0, 2.0 * bank, min(u_FogLocalMist, 1.0));

    float altitudeBlocks = max((u_CameraAbs.y - plagueAtmoSeaLevel()) + cameraRelativeBlocks.y, 0.0);
    float vertical = exp(-altitudeBlocks / max(u_FogHeight, 1.0));
    float peakSigma = PLAGUE_ATMO_LOCAL_MIST_CELL_TAU
                    / (PLAGUE_ATMO_MIST_CELL_BLOCKS.x * PLAGUE_ATMO_METRES_PER_BLOCK);
    return max(u_FogLocalMist, 0.0) * max(u_FogDensity, 0.0) * peakSigma * bank * vertical;
}

#endif
