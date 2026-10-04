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
// The 2026-09-29 frame-158 cave capture places only 42.1% of opaque GI hits within the
// quarter-block caustic footprint. A half-block GI footprint reaches 71.1% while keeping
// the estimator normalized; direct caustics retain their sharper quarter-block kernel.
const float PLAGUE_GI_PHOTON_RADIUS=0.5;
// Oct 1 frame136: half-block bins with support rejection reduced mean linked-record reads
// from867 to449 over2048 captured receiver points. Radius and flux normalization stay unchanged.
const float PLAGUE_GI_PHOTON_HASH_CELL=0.5;
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
// Producers and consumers must reload together: a flat hash reader silently misses banked heads.
// Seven exact receiver classes (generic plus the six cube axes) fit eight power-of-two
// banks in the existing head allocation. Oct 1 frame59: this removes84% of primary
// candidate reads (396288928 ->63248844), without changing the normal predicate or flux.
const uint PLAGUE_GLASS_NORMAL_BANKS=8u;
uint plagueGlassNormalBank(vec3 normal) {
    for(int axis=0;axis<3;++axis) {
        vec3 direction=vec3(0.0); direction[axis]=1.0;
        if(all(equal(normal,-direction))) return uint(axis*2+1);
        if(all(equal(normal,direction))) return uint(axis*2+2);
    }
    return 0u; // All non-axis normals stay reachable, including boundary/invalid records.
}
bool plagueGlassNormalBankSupported(uint bank,vec3 normal) {
    if(bank==0u) return true;
    uint axis=(bank-1u)/2u;
    float sign=(bank&1u)==0u?1.0:-1.0;
    // Exactly the existing photon receiver test, including near-axis generic queries.
    return sign*normal[axis]>=0.99;
}
uint plagueGlassNormalBucket(ivec3 cell,uint bank) {
    uint side=PLAGUE_GLASS_HASH_SIZE/PLAGUE_GLASS_NORMAL_BANKS;
    return bank*side+(plagueGlassBucket(cell)&(side-1u));
}
float plagueGlassKernel(float squaredDistance) {
    float r=PLAGUE_GLASS_GATHER_RADIUS;
    // The cone integrates to pi*r^2/3 over a disk, so this density preserves total photon flux.
    return max(0.0,1.0-sqrt(max(squaredDistance,0.0))/r)*3.0/(3.141592653589793*r*r);
}
float plagueGiPhotonKernel(float squaredDistance) {
    return max(0.0,1.0-sqrt(max(squaredDistance,0.0))/PLAGUE_GI_PHOTON_RADIUS)
            *3.0/(3.141592653589793*PLAGUE_GI_PHOTON_RADIUS*PLAGUE_GI_PHOTON_RADIUS);
}
#endif
