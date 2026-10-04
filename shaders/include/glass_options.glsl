#ifndef PLAGUE_GLASS_OPTIONS
#define PLAGUE_GLASS_OPTIONS
#define PLAGUE_GLASS_TRANSPORT 1 //[0 1] compile "Glass Light Transport" {0="Off" 1="On"}
// Quarter, half and full of the existing 65536-path budget; each tier splits equally by source kind.
#define PLAGUE_GLASS_SAMPLES 65536 //[16384 32768 65536] compile "Glass Photons"
// Two rays per update balance measured per-frame traversal work with stationary convergence.
#define PLAGUE_GLASS_GLOSSY_SAMPLES 2 //[1 2 4 8] compile "Glass Glossy Rays"
// Captured cave replay: four weighted visibility draws cost 153 ms versus exact 333 ms;
// empirical equal-time camera variance was 0.46 of exact. Zero keeps exhaustive visibility.
#define PLAGUE_GLASS_VISIBILITY_SAMPLES 4 //[0 1 4 8] compile "Glass Endpoint Visibility" {0="Exact" 1="1 Sample" 4="4 Samples" 8="8 Samples"}
// 2026-10-01 captured cave end-wall replay: 24-block optical work reach recovered
// 22.8x indirect radiance over 12. Source integration retains its separate 12-block domain.
// Tiers: existing 12, measured 24, doubled 48, capped by the existing 64-block view domain.
#define PLAGUE_GLASS_PATH_REACH 24 //[12 24 48 64] compile "Glass Bounce Reach"
#endif
