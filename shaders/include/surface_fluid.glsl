#ifndef PLAGUE_SURFACE_FLUID_GLSL
#define PLAGUE_SURFACE_FLUID_GLSL

const int SURFACE_FLUID_GRID = 64;
const int SURFACE_FLUID_DRY = 0;
const int SURFACE_FLUID_WATER = 1;
const int SURFACE_FLUID_LAVA = 2;
const uint SURFACE_FLUID_VALID = 0x80000000u;
const float SURFACE_FLUID_HEIGHT_TOLERANCE = 0.75;
// solidTopY where the column's topmost motion-blocking block is the fluid itself, i.e. open water.
// Far below any buildable Y, so a plain comparison against a water line rejects it.
const float SURFACE_FLUID_NO_SOLID_TOP = -30000.0;

// Status-word field positions, matching Fornax SurfaceFluidClipmapBuffer. Flow is vanilla's own
// fluid flow vector, quantized to a signed byte per axis; the flag is set only where it quantized
// to something non-zero, so a still source reads as not flowing.
const int SURFACE_FLUID_FLOW_X_SHIFT = 8;
const int SURFACE_FLUID_FLOW_Z_SHIFT = 16;
const int SURFACE_FLUID_FLOW_BITS = 8;
const int SURFACE_FLUID_FLOW_FLAG = 1 << 24;
const float SURFACE_FLUID_FLOW_SCALE = 127.0;

// Two ivec4s per column: (worldX, worldZ, floatBits(surfaceY), status) then
// (floatBits(solidTopY), reserved x3). Matching Fornax SurfaceFluidClipmapBuffer.
const int SURFACE_FLUID_VECS_PER_COLUMN = 2;

layout(std430, set = 0, binding = 2) readonly buffer SurfaceFluidClipmap {
    ivec4 columns[];
} surfaceFluidClipmap;

vec2 surfaceFluidWorldPosition(ivec2 simulationCoord, ivec2 simulationSize) {
    float cellsPerBlock = float(simulationSize.x) / 64.0;
    return u_LocalActorPosition.xz
            + (vec2(simulationCoord) + vec2(0.5) - 0.5 * vec2(simulationSize)) / cellsPerBlock;
}

ivec2 surfaceFluidWorldColumn(ivec2 simulationCoord, ivec2 simulationSize) {
    return ivec2(floor(surfaceFluidWorldPosition(simulationCoord, simulationSize)));
}

bool surfaceFluidDescribes(ivec4 record, ivec2 worldColumn) {
    return (uint(record.w) & SURFACE_FLUID_VALID) != 0u
            && all(equal(record.xy, worldColumn));
}

int surfaceFluidColumnBase(ivec2 worldColumn) {
    int slot = (worldColumn.y & (SURFACE_FLUID_GRID - 1)) * SURFACE_FLUID_GRID
            + (worldColumn.x & (SURFACE_FLUID_GRID - 1));
    return slot * SURFACE_FLUID_VECS_PER_COLUMN;
}

ivec4 surfaceFluidColumnRecord(ivec2 worldColumn) {
    return surfaceFluidClipmap.columns[surfaceFluidColumnBase(worldColumn)];
}

/** Top plane of the column's highest motion-blocking block, fluid there or not. */
float surfaceFluidColumnSolidTop(ivec2 worldColumn) {
    return intBitsToFloat(surfaceFluidClipmap.columns[surfaceFluidColumnBase(worldColumn) + 1].x);
}

bool surfaceFluidCellValid(ivec2 simulationCoord, ivec2 simulationSize, out float surfaceY) {
#if SURFACE_FLUID_DETAIL == 0
    surfaceY = 0.0;
    return true;
#else
    if (any(lessThan(simulationCoord, ivec2(0)))
            || any(greaterThanEqual(simulationCoord, simulationSize))) {
        surfaceY = 0.0;
        return false;
    }
    ivec2 worldColumn = surfaceFluidWorldColumn(simulationCoord, simulationSize);
    ivec4 record = surfaceFluidColumnRecord(worldColumn);
    surfaceY = intBitsToFloat(record.z);
    int kind = record.w & 0xff;
    return surfaceFluidDescribes(record, worldColumn) && kind == SURFACE_FLUID_WATER;
#endif
}

/**
 * The whole record, rather than the water-only view above. `surfaceY` is the exposed surface and
 * `solidTopY` the highest non-fluid top, which differ wherever something is built over water.
 * False for an unpublished column, and for every column with boundaries off.
 */
bool surfaceFluidColumnState(ivec2 worldColumn, out int kind, out float surfaceY,
                            out float solidTopY, out vec2 flow) {
    kind = SURFACE_FLUID_DRY;
    surfaceY = 0.0;
    solidTopY = 0.0;
    flow = vec2(0.0);
#if SURFACE_FLUID_DETAIL == 0
    return false;
#else
    ivec4 record = surfaceFluidColumnRecord(worldColumn);
    if (!surfaceFluidDescribes(record, worldColumn)) {
        return false;
    }
    kind = record.w & 0xff;
    surfaceY = intBitsToFloat(record.z);
    solidTopY = surfaceFluidColumnSolidTop(worldColumn);
    // bitfieldExtract on a signed int sign-extends, which is what the signed-byte packing needs.
    flow = vec2(bitfieldExtract(record.w, SURFACE_FLUID_FLOW_X_SHIFT, SURFACE_FLUID_FLOW_BITS),
                bitfieldExtract(record.w, SURFACE_FLUID_FLOW_Z_SHIFT, SURFACE_FLUID_FLOW_BITS))
            / SURFACE_FLUID_FLOW_SCALE;
    return true;
#endif
}

/** The same record, addressed by simulation cell. Out of the field, nothing is published. */
bool surfaceFluidCellRecord(ivec2 simulationCoord, ivec2 simulationSize,
                            out int kind, out float surfaceY, out float solidTopY, out vec2 flow) {
    if (any(lessThan(simulationCoord, ivec2(0)))
            || any(greaterThanEqual(simulationCoord, simulationSize))) {
        kind = SURFACE_FLUID_DRY;
        surfaceY = 0.0;
        solidTopY = 0.0;
        flow = vec2(0.0);
        return false;
    }
    return surfaceFluidColumnState(surfaceFluidWorldColumn(simulationCoord, simulationSize),
            kind, surfaceY, solidTopY, flow);
}

#endif
