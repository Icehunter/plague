#ifndef PLAGUE_HEAT_OPTIONS
#define PLAGUE_HEAT_OPTIONS

// Every heat-shimmer option, declared once: heat_shimmer.fsh, heat_blur_h.fsh, heat_blur_v.fsh and
// tonemap.fsh import this rather than each carrying its own copy, since the option scanner
// requires every declaration of a name to be byte-identical across files.

#define u_HeatShimmer 1.0 //[0.00..2.00 step 0.05] runtime "Heat Shimmer Strength"

// Per-drive toggles. Biome (deserts, other hot-and-dry biomes) joins this list once the aerial
// pass carries per-column heat; nothing to toggle for it yet.
#define u_HeatShimmerEmissive 1.0 //[0.0..1.0 step 1.0] runtime "Lava & Fire Heat"
#define u_HeatShimmerNether 1.0 //[0.0..1.0 step 1.0] runtime "Nether Heat"

// Independent of Heat Shimmer Strength above, which scales the wave/emissive drive only. First
// guess, tune once seen live.
#define u_NetherHeatAmbient 0.45 //[0.00..2.00 step 0.05] runtime "Nether Heat Ambient"

// Chunks. Ramps in over the 8 blocks past this point.
#define u_NetherHeatDistance 1.0 //[0.10..4.00 step 0.10] runtime "Nether Heat Start"

#define u_NetherHeatBlurStrength 1.0 //[0.00..2.00 step 0.05] runtime "Nether Heat Blur Strength"

// Chunks. Only air past this distance softens into haze.
#define u_NetherHeatBlurStart 3.0 //[0.10..8.00 step 0.10] runtime "Nether Heat Blur Start"

#endif // PLAGUE_HEAT_OPTIONS
