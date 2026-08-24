#ifndef PLAGUE_SURFACE_FLUID_GLSL
#define PLAGUE_SURFACE_FLUID_GLSL

const int SURFACE_FLUID_GRID = 64;
const int SURFACE_FLUID_DRY = 0;
const int SURFACE_FLUID_WATER = 1;
const int SURFACE_FLUID_LAVA = 2;
const uint SURFACE_FLUID_VALID = 0x80000000u;
const float SURFACE_FLUID_HEIGHT_TOLERANCE = 0.75;

layout(std430, set = 0, binding = 2) readonly buffer SurfaceFluidClipmap {
    ivec4 columns[];
} surfaceFluidClipmap;

ivec2 surfaceFluidWorldColumn(ivec2 simulationCoord, ivec2 simulationSize) {
    float cellsPerBlock = float(simulationSize.x) / 64.0;
    vec2 worldXZ = u_LocalActorPosition.xz
            + (vec2(simulationCoord) + vec2(0.5) - 0.5 * vec2(simulationSize)) / cellsPerBlock;
    return ivec2(floor(worldXZ));
}

bool surfaceFluidDescribes(ivec4 record, ivec2 worldColumn) {
    return (uint(record.w) & SURFACE_FLUID_VALID) != 0u
            && all(equal(record.xy, worldColumn));
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
    int slot = (worldColumn.y & (SURFACE_FLUID_GRID - 1)) * SURFACE_FLUID_GRID
            + (worldColumn.x & (SURFACE_FLUID_GRID - 1));
    ivec4 record = surfaceFluidClipmap.columns[slot];
    surfaceY = intBitsToFloat(record.z);
    int kind = record.w & 0xff;
    return surfaceFluidDescribes(record, worldColumn) && kind == SURFACE_FLUID_WATER;
#endif
}

#endif
