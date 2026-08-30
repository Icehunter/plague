#ifndef PLAGUE_PRECIP_FIELD
#define PLAGUE_PRECIP_FIELD

// The engine's coarse nearby-precipitation field, decoded. u_CameraSkyLight.y classifies the
// camera's own column only, so it steps at a biome border; this reads the surrounding columns and
// returns a fraction instead.
//
// A pass opts in by declaring the buffer and the accessor before the import:
//
//     layout(std430, set = 0, binding = N) readonly buffer PrecipCoarseClipmap { int words[]; } ...;
//     #define PLAGUE_PRECIP_CLIPMAP(slot) precipCoarseClipmap.words[slot]
//
// Without it every query reports not covered and callers keep their camera-local value, which is
// what the fullscreen passes reaching this file through clouds.glsl do.

// PrecipCoarseClipmapBuffer's ABI: 4-block cells, 128 per axis, one word each. Low byte is the
// value, bit 8 marks a sampled word, upper 16 bits are 8 tile-index bits per axis. The tag makes a
// read self-validating, so no window anchor has to reach the shader: a cell outside the uploaded
// window fails it and reads as not covered.
const int PLAGUE_PRECIP_CELL_STRIDE_LOG2 = 2;
const int PLAGUE_PRECIP_GRID = 128;
const int PLAGUE_PRECIP_GRID_SHIFT = 7;
const int PLAGUE_PRECIP_VALUE_MASK = 0xFF;
const int PLAGUE_PRECIP_VALID_MASK = 0x100;

const int PLAGUE_PRECIP_NONE = 0;
const int PLAGUE_PRECIP_RAIN = 1;
const int PLAGUE_PRECIP_SNOW = 2;

// Radius the neighbourhood spans, blocks. The observed weather boundary is about 100 blocks across:
// narrower ramps too fast to remove the step, wider averages the boundary away.
const float PLAGUE_PRECIP_NEIGHBOURHOOD = 48.0;

// Vogel disc: golden angle, sqrt-spaced radii (Vogel 1979), even at any orientation without a
// ring's axis alignment.
//
// Layout alone cannot smooth the ramp. The field is constant over a whole biome, so a point sample
// flips in one block and N taps give N jumps; placement only moves them, and at some orientation
// two land together. Each tap is interpolated over the four cells around it instead, which makes
// the tap continuous, and a sum of continuous taps has no jump at any orientation.
//
// 16 off a measured sweep: ramp width plateaus near 78 blocks from 9 taps up, so the count only
// buys slope, 0.150 aridity per block at 5 taps, 0.083 at 9, 0.063 at 16, 0.039 at 32. Every lane
// reads the same addresses, this depending only on the camera column, so the taps broadcast.
const int PLAGUE_PRECIP_TAPS = 16;
const float PLAGUE_PRECIP_GOLDEN_ANGLE = 2.39996322972865332;

/** Storage slot for a world cell. Toroidal, so it needs no anchor. */
int plaguePrecipSlot(ivec2 cell) {
    return (cell.y & (PLAGUE_PRECIP_GRID - 1)) * PLAGUE_PRECIP_GRID
         + (cell.x & (PLAGUE_PRECIP_GRID - 1));
}

/** The bounded tag a word must carry to describe this cell. */
int plaguePrecipTag(ivec2 cell) {
    return (((cell.x >> PLAGUE_PRECIP_GRID_SHIFT) & 0xFF) << 16)
         | (((cell.y >> PLAGUE_PRECIP_GRID_SHIFT) & 0xFF) << 24);
}

/**
 * One column's precipitation class, or false if the cell is outside the uploaded window.
 *
 * Arithmetic shift is floor division for a power-of-two stride; an integer divide gets the negative
 * half of the world wrong.
 */
bool plaguePrecipColumn(vec2 worldXZ, out int precipType) {
    precipType = PLAGUE_PRECIP_NONE;
#ifdef PLAGUE_PRECIP_CLIPMAP
    ivec2 block = ivec2(floor(worldXZ));
    ivec2 cell = block >> PLAGUE_PRECIP_CELL_STRIDE_LOG2;
    int word = PLAGUE_PRECIP_CLIPMAP(plaguePrecipSlot(cell));
    if ((word & PLAGUE_PRECIP_VALID_MASK) == 0
            || (word & 0xFFFF0000) != plaguePrecipTag(cell)) {
        return false;
    }
    precipType = word & PLAGUE_PRECIP_VALUE_MASK;
    return true;
#else
    return false;
#endif
}

/**
 * Fraction of the neighbourhood in each class, ramped across biome borders.
 *
 * An uncovered column is left out of the average rather than counted as none, or a player beyond
 * the window would read as desert. With nothing covered this returns false and the caller keeps
 * whatever the camera reported.
 */
bool plaguePrecipNeighbourhood(vec2 worldXZ, out float aridFraction, out float coldFraction) {
    aridFraction = 0.0;
    coldFraction = 0.0;
#ifdef PLAGUE_PRECIP_CLIPMAP
    float covered = 0.0;
    float arid = 0.0;
    float cold = 0.0;
    int precipType;

    // Cell centres sit half a cell in from the cell origin, so the half-cell shift puts the
    // interpolation lattice on them rather than on the corners.
    float cellSize = float(1 << PLAGUE_PRECIP_CELL_STRIDE_LOG2);

    for (int i = 0; i < PLAGUE_PRECIP_TAPS; i++) {
        float radius = PLAGUE_PRECIP_NEIGHBOURHOOD
                     * sqrt((float(i) + 0.5) / float(PLAGUE_PRECIP_TAPS));
        float theta = float(i) * PLAGUE_PRECIP_GOLDEN_ANGLE;
        vec2 tap = worldXZ + radius * vec2(cos(theta), sin(theta));

        vec2 lattice = tap / cellSize - 0.5;
        vec2 baseCell = floor(lattice);
        vec2 f = lattice - baseCell;

        // An uncovered corner contributes no weight rather than a zero value; the total is
        // renormalised by the weight actually gathered.
        for (int c = 0; c < 4; c++) {
            vec2 corner = baseCell + vec2(float(c & 1), float((c >> 1) & 1));
            float w = (c == 0 ? (1.0 - f.x) * (1.0 - f.y)
                    : c == 1 ? f.x * (1.0 - f.y)
                    : c == 2 ? (1.0 - f.x) * f.y
                             : f.x * f.y);
            if (w <= 0.0) {
                continue;
            }
            if (plaguePrecipColumn(corner * cellSize + 0.5 * cellSize, precipType)) {
                covered += w;
                arid += w * (precipType == PLAGUE_PRECIP_NONE ? 1.0 : 0.0);
                cold += w * (precipType == PLAGUE_PRECIP_SNOW ? 1.0 : 0.0);
            }
        }
    }
    if (covered <= 0.0) {
        return false;
    }
    aridFraction = arid / covered;
    coldFraction = cold / covered;
    return true;
#else
    return false;
#endif
}

#endif // PLAGUE_PRECIP_FIELD
