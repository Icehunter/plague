#ifndef PLAGUE_GLASS_PHOTON_CACHE
#define PLAGUE_GLASS_PHOTON_CACHE
#moj_import <fornax_runtime:glass_options.glsl>
#moj_import <fornax_runtime:voxel_local_layout.glsl>
// Persistent transport ABI: header, compact source indices, exact section tokens, source rows.
// ASCII GLP2 identifies opaque-receiver point records with last-segment visibility.
// Include the path budget: changing source quotas must rebuild retained positions and flux weights.
const uint PLAGUE_GLASS_CACHE_TAG=0x474c5032u^uint(PLAGUE_GLASS_SAMPLES);
const int PLAGUE_GLASS_CACHE_SOURCES=16;
const int PLAGUE_GLASS_CACHE_SECTIONS=PLAGUE_GLASS_CACHE_SOURCES+PLAGUE_LOCAL_CAPACITY;
const int PLAGUE_GLASS_CACHE_ROWS=PLAGUE_GLASS_CACHE_SECTIONS+PLAGUE_LOCAL_MAX_SLOTS*8;
const int PLAGUE_GLASS_CACHE_WORDS=PLAGUE_GLASS_CACHE_ROWS+PLAGUE_LOCAL_CAPACITY*PLAGUE_LOCAL_RECORD_WORDS;
// Source identity is ordered absolute geometry, independent of admission order and camera position.
uint plagueGlassSourceKey(ivec3 cell,uint run,uint box) {
    uint key=plagueGlassHash(uint(cell.x));
    key=plagueGlassHash(key^uint(cell.y));
    key=plagueGlassHash(key^uint(cell.z));
    return plagueGlassHash(plagueGlassHash(key^run)^box);
}
#endif
