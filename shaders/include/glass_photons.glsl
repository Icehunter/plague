#ifndef PLAGUE_GLASS_PHOTON_LAYOUT
#define PLAGUE_GLASS_PHOTON_LAYOUT
#moj_import <fornax_runtime:glass_options.glsl>
#moj_import <fornax_runtime:glass_optics.glsl>
// Active prefix of the fixed graph allocation; source faces and sky each receive half the paths.
const uint PLAGUE_GLASS_PHOTONS = uint(PLAGUE_GLASS_SAMPLES);
const uint PLAGUE_GLASS_HASH_SIZE = 65536u; // One bucket per maximum-budget path bounds mean collisions.
// Reconstruction radius is one quarter block: neighbouring block centres never share a kernel.
// Jensen (1996), surface photon density estimation. Kernel footprint is a quality limit, not glass roughness.
const float PLAGUE_GLASS_GATHER_RADIUS = 0.25;
const float PLAGUE_GLASS_HASH_CELL = 0.5; // Diameter of the gather disk.
const float PLAGUE_GLASS_SUN_RADIUS = 16.0; // One section either side of the camera; a finite sampling domain.
// Four vec4s: cache-origin-relative position/valid, flux/source kind, incoming direction, geometric normal.
const uint PLAGUE_GLASS_PHOTON_WORDS = 4u;
uint plagueGlassBucket(ivec3 cell) {
    uvec3 p=uvec3(cell);
    // Ordered mixing avoids forcing every axis permutation into one linked list in cubic rooms.
    uint key=plagueGlassHash(p.x);
    key=plagueGlassHash(key^p.y);
    return plagueGlassHash(key^p.z) & (PLAGUE_GLASS_HASH_SIZE-1u);
}
float plagueGlassKernel(float squaredDistance) {
    float r=PLAGUE_GLASS_GATHER_RADIUS;
    // The cone integrates to pi*r^2/3 over a disk, so this density preserves total photon flux.
    return max(0.0,1.0-sqrt(max(squaredDistance,0.0))/r)*3.0/(3.141592653589793*r*r);
}
#endif
