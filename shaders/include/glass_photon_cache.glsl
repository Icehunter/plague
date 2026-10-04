#ifndef PLAGUE_GLASS_PHOTON_CACHE
#define PLAGUE_GLASS_PHOTON_CACHE
#moj_import <fornax_runtime:glass_options.glsl>
#moj_import <fornax_runtime:voxel_local_layout.glsl>
// Persistent transport ABI: header, compact source indices, exact section tokens, source rows.
// ASCII GLP7 invalidates the old glass-only GI family; clear-air higher opaque bounces
// share the same incident-irradiance map. Direct source-to-receiver paths remain excluded.
const uint PLAGUE_GLASS_CACHE_TAG=0x474c5037u^uint(PLAGUE_GLASS_SAMPLES);
// Independent GI sample progression is not scene identity: changing it must not reset
// direct retained photons or the camera-glossy history (which reads header word 1).
const int PLAGUE_GLASS_CACHE_GI_PHASE=11;
const int PLAGUE_GLASS_CACHE_GI_SWEEP=12;
// One eighth of the GI-only map bounds steady trace work to 8192 paths at the maximum budget;
// eight frames replace every slot. Scheduling/flux invariants: verify_gi_photon_refresh.py.
const uint PLAGUE_GLASS_GI_REFRESH_PHASES=8u;
// Spare header words retain the last reset even after stable frames overwrite changed.
// Reason bits:1 invalid inventory,2 layout,4 origin,8 source header,16 section,32 source row;
// 64 marks changed/missing ownership whose influence cannot be scoped to one receiver.
const int PLAGUE_GLASS_CACHE_RESET_REASON=13;
const int PLAGUE_GLASS_CACHE_RESET_FRAME=14;
// Lowest changed word: section words first, then source-row words; UINT_MAX means neither.
const int PLAGUE_GLASS_CACHE_RESET_WORD=15;
const int PLAGUE_GLASS_CACHE_SOURCES=16;
// One exclusive direct-path prefix per admitted source; the last prefix is half the path budget.
// GI retains its independent equal per-source quotas and never reads these prefixes.
const int PLAGUE_GLASS_CACHE_DIRECT_PREFIX=PLAGUE_GLASS_CACHE_SOURCES+PLAGUE_LOCAL_CAPACITY;
const int PLAGUE_GLASS_CACHE_SECTIONS=PLAGUE_GLASS_CACHE_DIRECT_PREFIX+PLAGUE_LOCAL_CAPACITY;
const int PLAGUE_GLASS_CACHE_ROWS=PLAGUE_GLASS_CACHE_SECTIONS+PLAGUE_LOCAL_MAX_SLOTS*8;
// Append current-frame receiver-history metadata; every existing photon/source offset stays fixed.
// Reason16-only geometry changes may be disjoint from an individual receiver's finite transport.
const int PLAGUE_GLASS_CACHE_HISTORY_REASON=PLAGUE_GLASS_CACHE_ROWS+PLAGUE_LOCAL_CAPACITY*PLAGUE_LOCAL_RECORD_WORDS;
const int PLAGUE_GLASS_CACHE_HISTORY_LO=PLAGUE_GLASS_CACHE_HISTORY_REASON+1;
const int PLAGUE_GLASS_CACHE_HISTORY_HI=PLAGUE_GLASS_CACHE_HISTORY_REASON+4;
const int PLAGUE_GLASS_CACHE_WORDS=PLAGUE_GLASS_CACHE_HISTORY_REASON+7;
// Source identity is ordered absolute geometry, independent of admission order and camera position.
uint plagueGlassSourceKey(ivec3 cell,uint run,uint box) {
    uint key=plagueGlassHash(uint(cell.x));
    key=plagueGlassHash(key^uint(cell.y));
    key=plagueGlassHash(key^uint(cell.z));
    return plagueGlassHash(plagueGlassHash(key^run)^box);
}
#endif
