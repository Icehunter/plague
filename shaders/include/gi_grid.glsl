#ifndef PLAGUE_GI_GRID
#define PLAGUE_GI_GRID

// The grid is laid over the unjittered image. TAA jitter shifts the rendered picture by
// u_JitterOffset every frame, so a cell that reads at its fixed place plus that shift sees the
// same world point every frame. Reading at the fixed place alone sees a different point each
// frame, which on foliage alternates between a leaf and the gap beside it, breaks history
// reprojection, and sparkles.
// Nearest raster sampling can still change cutout coverage across jitter phases; a fixed grid
// addresses the same location, but does not guarantee that its history contains a surface.

vec2 plagueGiCellUv(vec2 cell, vec2 size) {
    return (cell + 0.5) / size + u_JitterOffset * 0.5;
}

vec2 plagueGiGridPlace(vec2 screenUv, vec2 size) {
    return (screenUv - u_JitterOffset * 0.5) * size - 0.5;
}

#endif
