#ifndef PLAGUE_ATMO_DEBUG_OPTIONS
#define PLAGUE_ATMO_DEBUG_OPTIONS

// Post/compute only: geometry has no runtime options block. Off removes the extra probe queries.
#define PLAGUE_AIR_SHADOW_DEBUG 0 //[0 1] compile "Test: Air Shadow Coverage" {0="Off" 1="On"}
// Probe domain matches the shadow-distance control, one chunk per step; the initial
// 96-block plane is the owner's saved shadow boundary used by verify_atmo_shadow_gpu.py.
#define u_AirShadowProbeDistance 96.0 //[16.0..512.0 step 16.0] runtime "Air Shadow Distance (Blocks)"

#endif
