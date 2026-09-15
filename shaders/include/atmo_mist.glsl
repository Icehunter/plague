#ifndef PLAGUE_ATMO_MIST
#define PLAGUE_ATMO_MIST

// Compute only: geometry passes do not carry this runtime option in u_PackOptions.
#define u_FogLocalMist 1.0 //[0.00..2.00 step 0.05] runtime "Local Mist Amount"

// Bank size. Each number has to be a power of two: the camera split below needs
// floor(x / C) * C to come out exact, and no other divisor does, so far from spawn the whole grid
// would step. Twice as wide as deep draws banks as streaks along the wind instead of round blobs;
// the wind below runs 20 degrees off X, so a streak lies within 10 degrees of the way it moves.
// The eight-block march steps across this eight times, four deep and twice up, so nothing here is
// too small for the march that reads it.
const vec3 PLAGUE_ATMO_MIST_CELL_BLOCKS = vec3(64.0, 16.0, 32.0);

// How thick the mist reads, kept apart from the cell shape: one flat bank blocks this much light
// over this many blocks, whatever shape the grid is stretched to. Keeping the two apart lets the
// shape change without changing how thick the mist looks. Both from tools/verify_mist_banks.py.
const float PLAGUE_ATMO_LOCAL_MIST_CELL_TAU = 0.15;
const float PLAGUE_ATMO_MIST_TAU_BLOCKS = 32.0;

// The way the cloud decks drift, written out again rather than imported: clouds.glsl needs its
// noise macros set before it is included and fails to build without them. The mist and the sky
// over it must agree on which way the wind blows. See PLAGUE_CLOUD_WIND.
const vec2 PLAGUE_ATMO_MIST_WIND_UNIT = vec2(11.0, -4.0) / 11.7046999107;

// The cloud wind (PLAGUE_CLOUD_WIND_SPEED, 1.92 blocks/s) brought down to the ground. Wind slows
// near the ground as ln(z / z0); at 10 blocks up against the 192-block cloud deck, with ground
// roughness z0 = 0.5 m (open country, a few things in the way), that comes to 0.61 of the cloud
// speed. The clouds and the mist under them then move with the same air.
//
// Not the 1.5 m/s of real ground fog, which works out at 0.29 blocks/s. Banks here are 64 blocks
// wide, not a few metres, so at that speed one takes 222 seconds to pass and
// tools/out/mist-speed-0.288 looks frozen over a ten-second watch. At this size, real speed is the
// wrong thing to match; the air the clouds move in holds up.
const float PLAGUE_ATMO_MIST_SPEED_BLOCKS = 1.17;

// How far one layer moves before a new one takes over, in blocks: one cell across the wind, so a
// bank lasts about as long as it takes to cross its own width. At the speed above, 27 seconds.
const float PLAGUE_ATMO_MIST_SLICE_TRAVEL = 32.0;

// How far to shift the grid from one layer to the next. The hash mixes whole numbers, so a shift
// by whole cells gives a field with no likeness to the one before. The three share no factor, so
// back-to-back layers never share a row or column.
const ivec3 PLAGUE_ATMO_MIST_SLICE_SEED = ivec3(17, 11, 23);

// How much of the banks is left when the weather asks for no mist at all. The banks are mist, so
// they have to follow the same weather the layer above them does. Without this a clear evening
// still carries the morning's banks in full, you can never see past 8.7 km, and that greys out the
// sky line and everything that mirrors it.
//
// Worked out, not picked by eye. Air alone blocks 4.0e-5 per metre at sea level, which lets you
// see 98 km, cleaner than any real clear day. The WMO calls 40 km "very clear", which needs
// 9.8e-5, so the banks owe the 5.8e-5 gap against their own 4.5e-4 at mean cover: 0.13.
// tools/verify_mist_banks.py prints both ends.
const float PLAGUE_ATMO_MIST_CLEAR_FLOOR = 0.13;

// Independent integer mix: the odd numbers are the largest primes below 2^16, 2^15, and
// 2^14. The third value adds height shape within the Fog Height range.
//
// The last mix is fmix32 from MurmurHash3 (Austin Appleby, 2011, public domain), as published.
// Its two full-width multipliers are what this needs: the shorter primes above cannot spread bits
// across the whole number, and leave next-door cells alike by as much as -0.51. The blend then
// draws that as rows of blobs lined up with the axes, which is the grid itself showing through.
// Worst match between next-door cells over twelve seeds: 0.506 with the short numbers, 0.035 with
// these. Silent failure: a weak mix never errors, it just draws the grid.
uint plagueAtmoMistHash(ivec3 cell) {
    uint value = uint(cell.x) * 65521u ^ uint(cell.y) * 32749u ^ uint(cell.z) * 16381u;
    value ^= value >> 16;
    value *= 0x85ebca6bu;
    value ^= value >> 13;
    value *= 0xc2b2ae35u;
    value ^= value >> 16;
    return value;
}

float plagueAtmoMistLattice(ivec3 cell) {
    // All 24-bit integers, including both endpoints, are exactly representable as floats.
    return float(plagueAtmoMistHash(cell) >> 8) / 16777215.0;
}

/**
 * One smooth read of the grid, at an offset in blocks from the camera.
 *
 * Splits off the camera's whole-cell part before adding the offset. A fixed world point stays in
 * the same cell as the camera moves, without adding two big numbers together.
 *
 * @param seed  whole-cell shift picking which layer of the field this is
 */
float plagueAtmoMistField(vec3 offsetBlocks, ivec3 seed) {
    vec3 cameraCell = floor(u_CameraAbs / PLAGUE_ATMO_MIST_CELL_BLOCKS);
    vec3 local = (u_CameraAbs - cameraCell * PLAGUE_ATMO_MIST_CELL_BLOCKS
                  + offsetBlocks) / PLAGUE_ATMO_MIST_CELL_BLOCKS;
    ivec3 cell = ivec3(cameraCell) + ivec3(floor(local)) + seed;
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
    return mix(z0, z1, blend.z);
}

/**
 * @param mistDrive  how much mist the weather asks for, 0..PLAGUE_ATMO_MIST_MAX_DRIVE
 *                   (atmo_lut.glsl)
 */
float plagueAtmoLocalMistSigma(vec3 cameraRelativeBlocks, float mistDrive,
                               out float weatherMistScale) {
    weatherMistScale = 1.0;
    if (u_FogLocalMist <= 0.0 || u_FogDensity <= 0.0 || u_WorldBounds.w > 1.5) return 0.0;

    // Two layers of the grid, each drifting with the wind for one travel and then handed over to
    // a new one. At the hand-over the old layer sits right where the new one starts, so the fade
    // is clean and the mist melts and forms again as it moves. One layer sliding on forever would
    // be a belt of shapes that move but never change, and its offset would grow until the maths
    // ran out of digits. Nothing here goes past one travel, so no wrap is needed.
    //
    // u_SkyState.w is getGameTime(), which /time set and the day length cannot touch, so it is the
    // right clock for wind. It counts ticks and never resets, so on a world past about 325 hours
    // `phase` steps every 0.01s instead of every frame. That makes the drift a little chunky; it
    // does not tear it.
    float cycles = u_SkyState.w * (PLAGUE_ATMO_MIST_SPEED_BLOCKS * 0.05
                                   / PLAGUE_ATMO_MIST_SLICE_TRAVEL);
    float phase = fract(cycles);
    ivec3 seed = PLAGUE_ATMO_MIST_SLICE_SEED * int(floor(cycles));
    vec2 stride = PLAGUE_ATMO_MIST_WIND_UNIT * PLAGUE_ATMO_MIST_SLICE_TRAVEL;
    vec3 drift = vec3(stride.x, 0.0, stride.y);
    float noise = mix(
        plagueAtmoMistField(cameraRelativeBlocks - drift * phase, seed),
        plagueAtmoMistField(cameraRelativeBlocks - drift * (phase - 1.0),
                            seed + PLAGUE_ATMO_MIST_SLICE_SEED),
        phase);
    // Mixing two unrelated fields at w flattens them, worst by half at the halfway point. Pushing
    // the result back out from the middle keeps the banks as strong through the hand-over. Without
    // it they wash out and sharpen once a cycle, which looks like the mist breathing.
    noise = 0.5 + (noise - 0.5) * inversesqrt(phase * phase + (1.0 - phase) * (1.0 - phase));

    // Keep the same middle-half smooth curve. Plain [0,1] noise has an average value of
    // 1/2, so multiplying by two spreads weather mist between gaps and banks with an
    // average of one.
    float bank = smoothstep(0.25, 0.75, noise);
    weatherMistScale = mix(1.0, 2.0 * bank, min(u_FogLocalMist, 1.0));

    float altitudeBlocks = max((u_CameraAbs.y - plagueAtmoSeaLevel()) + cameraRelativeBlocks.y, 0.0);
    float vertical = exp(-altitudeBlocks / max(u_FogHeight, 1.0));
    float peakSigma = PLAGUE_ATMO_LOCAL_MIST_CELL_TAU
                    / (PLAGUE_ATMO_MIST_TAU_BLOCKS * PLAGUE_ATMO_METRES_PER_BLOCK);
    // Measured against the most the weather can ask for, so full mist gives full banks. The
    // slider still sets the amount; this only says whether the weather has any to give.
    float weather = mix(PLAGUE_ATMO_MIST_CLEAR_FLOOR, 1.0,
                        clamp(mistDrive / PLAGUE_ATMO_MIST_MAX_DRIVE, 0.0, 1.0));
    return max(u_FogLocalMist, 0.0) * max(u_FogDensity, 0.0) * peakSigma * bank * vertical * weather;
}

#endif
