#ifndef PLAGUE_VOXEL_ATLAS_PAGES
#define PLAGUE_VOXEL_ATLAS_PAGES

// VoxelFaceTexture header bits 27..28 name static overflow pages 1..3; zero retains base UVs.
// Fornax's BlockAtlasGhostLayout maps page k to a quarter-scale ghost at ((k-1)/4, 3/4).
bool plagueSourceAtlasPage(uint flags, bool missingMap,
        inout vec2 uv0, inout vec2 ds, inout vec2 dt, out int page) {
    page = int((flags >> 3) & 3u) - 1;
    if (page < 0) return true;
    ivec3 blockSize = textureSize(u_BlockAtlasPages, 0);
    // The engine's absent-generation array is 1x1x1. It supplies a valid descriptor, not a source.
    if (any(lessThanEqual(blockSize.xy, ivec2(1))) || page >= blockSize.z) return false;
    if (!missingMap) {
        ivec3 materialSize = textureSize(u_MaterialAtlasPages, 0);
        if (any(lessThanEqual(materialSize.xy, ivec2(1))) || page >= materialSize.z) return false;
    }
    uv0 = (uv0 - vec2(float(page) * 0.25, 0.75)) * 4.0;
    ds *= 4.0;
    dt *= 4.0;
    return true;
}

ivec2 plagueSourceBlockSize(int page) {
    return page < 0 ? textureSize(u_BlockAtlas, 0) : textureSize(u_BlockAtlasPages, 0).xy;
}
ivec2 plagueSourceMaterialSize(int page) {
    return page < 0 ? textureSize(u_MaterialAtlas, 0) : textureSize(u_MaterialAtlasPages, 0).xy;
}
vec4 plagueSourceBlockTexel(int page, ivec2 texel) {
    return page < 0 ? texelFetch(u_BlockAtlas, texel, 0)
                    : texelFetch(u_BlockAtlasPages, ivec3(texel, page), 0);
}
vec4 plagueSourceMaterialTexel(int page, ivec2 texel) {
    return page < 0 ? texelFetch(u_MaterialAtlas, texel, 0)
                    : texelFetch(u_MaterialAtlasPages, ivec3(texel, page), 0);
}
#endif
