#ifndef PLAGUE_GI_SURFACE_CACHE
#define PLAGUE_GI_SURFACE_CACHE

// Four recurring raster surfaces fit the owner's four-phase TAA coverage cycle. More distinct
// surfaces (including longer AA cycles) evict the least recently observed entry; this is bounded.
const int PLAGUE_GI_CACHE_ENTRIES = 4;
// Reuse the bounce's existing 24-frame confidence window as the maximum unobserved lifetime.
const float PLAGUE_GI_CACHE_MAX_GAP = 24.0;

bool plagueGiLightingHistoryValid() {
    return plagueLightingHistoryValid(imageLoad(u_CacheTransform, ivec2(4, 0)));
}

// Older screen coordinates are valid only with the exact same unjittered camera. Translation is
// tested separately because the inverse matrix is camera-relative; motion keeps ordinary history.
bool plagueGiCacheTransformMatches() {
    if (!plagueGiLightingHistoryValid()) return false;
    if (any(notEqual(u_CameraDelta.xyz, vec3(0.0)))) return false;
    for (int column = 0; column < 4; ++column) {
        if (any(notEqual(imageLoad(u_CacheTransform, ivec2(column, 0)),
                         u_InvProjModelViewNoJitter[column]))) return false;
    }
    return true;
}

ivec2 plagueGiCacheTexel(ivec2 cell, ivec2 gridSize, int entry) {
    return cell + ivec2(0, entry * gridSize.y);
}

// The tuple's moment alpha is elapsed frames without a ray observation, not sample age. The
// caller supplies the existing surface matcher; cached geometry never becomes current geometry.
bool plagueGiCacheFind(ivec2 cell, ivec2 gridSize, vec3 normal, vec3 position, out ivec2 cacheTap) {
    cacheTap = ivec2(0);
    if (!plagueGiCacheTransformMatches()) return false;
    float tolerance = max(PLAGUE_GI_HISTORY_PLANE * length(position), PLAGUE_GI_HISTORY_PLANE_FLOOR);
    for (int entry = 0; entry < PLAGUE_GI_CACHE_ENTRIES; ++entry) {
        ivec2 tap = plagueGiCacheTexel(cell, gridSize, entry);
        vec4 moments = imageLoad(u_CacheMoments, tap);
        if (moments.b <= 0.0 || moments.a >= PLAGUE_GI_CACHE_MAX_GAP) continue;
        if (!plagueGiHistorySurfaceMatches(imageLoad(u_CacheSurface, tap), normal, position, tolerance)) continue;
        cacheTap = tap;
        return true;
    }
    return false;
}

// Applying the existing EMA once for each elapsed frame yields this compounded weight. Missing
// observations do not increase sample count, or stretch the 24-frame lighting response.
float plagueGiCacheBlend(float gathered, float storedGap) {
    return max(1.0 / gathered,
               1.0 - pow(1.0 - 1.0 / PLAGUE_GI_CACHE_MAX_GAP, storedGap + 1.0));
}

#endif
