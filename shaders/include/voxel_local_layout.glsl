#ifndef PLAGUE_VOXEL_LOCAL_LAYOUT
#define PLAGUE_VOXEL_LOCAL_LAYOUT
// VoxelSourceWindow ABI2: sparse committed cells grouped by toroidal section slot. These are
// engine capacity/stride contracts, not a camera-relative illumination volume.
const int PLAGUE_LOCAL_CAPACITY = 4096;
const int PLAGUE_LOCAL_MAX_SLOTS = 33 * 33 * 33;
const int PLAGUE_LOCAL_RECORDS = 16 + PLAGUE_LOCAL_MAX_SLOTS * 2;
const int PLAGUE_LOCAL_RAW_WORDS = PLAGUE_LOCAL_RECORDS + PLAGUE_LOCAL_CAPACITY * 8;
const int PLAGUE_LOCAL_RECORD_WORDS = 104;
const int PLAGUE_LOCAL_SOURCE_WORDS = PLAGUE_LOCAL_RECORDS + PLAGUE_LOCAL_CAPACITY * PLAGUE_LOCAL_RECORD_WORDS;
// Authored work domain: three quarters of one 16-block section. Only source distance tapers;
// the adjacent 27 sections contain every candidate, independently of eye distance/height.
const float PLAGUE_LOCAL_REACH = 12.0;
const float PLAGUE_LOCAL_NUDGE = 1.0 / 4096.0; // Matches voxel traversal's geometric tolerance.
const float PLAGUE_LOCAL_PLANE_TOLERANCE = PLAGUE_LOCAL_NUDGE * 4.0;
vec3 plagueLocalNormal(int face) {
    vec3 n = vec3(0.0);
    n[face < 2 ? 1 : face < 4 ? 2 : 0] = (face & 1) == 0 ? -1.0 : 1.0;
    return n;
}
vec3 plagueLocalFacePoint(ivec3 cell, int face, int quadrant) {
    vec2 st = (vec2(quadrant & 1, quadrant >> 1) + 0.5) * 0.5;
    float plane = float(face & 1);
    return vec3(cell) + (face < 2 ? vec3(st.x, plane, st.y)
                      : face < 4 ? vec3(st, plane) : vec3(plane, st));
}
float plagueLocalFalloff(float distance) {
    // Last quarter closes the finite source integration domain continuously. Inverse-square
    // transport determines the interior; there is no receiver/camera coverage multiplier.
    return 1.0 - smoothstep(PLAGUE_LOCAL_REACH * 0.75, PLAGUE_LOCAL_REACH, distance);
}
#endif
