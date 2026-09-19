#ifndef PLAGUE_VOXEL_LOCAL_LAYOUT
#define PLAGUE_VOXEL_LOCAL_LAYOUT
// VoxelSourceWindow ABI2: sparse committed cells grouped by toroidal section slot. These are
// engine capacity/stride contracts, not a camera-relative illumination volume.
const int PLAGUE_LOCAL_CAPACITY = 4096;
const int PLAGUE_LOCAL_MAX_SLOTS = 33 * 33 * 33;
const int PLAGUE_LOCAL_RECORDS = 16 + PLAGUE_LOCAL_MAX_SLOTS * 2;
const int PLAGUE_LOCAL_RAW_WORDS = PLAGUE_LOCAL_RECORDS + PLAGUE_LOCAL_CAPACITY * 8;
// A record is one RUN: a flat rectangle of touching faces of one block kind, all facing the same
// way. A lone lamp face is a run of one cell by one, so nothing needs a small case. A run holds
// one face, which is what keeps the record small.
const int PLAGUE_LOCAL_RECORD_WORDS = 25;
// Words 8 to 23 hold four quarters of the one face, four words each. Three of every four carry
// that quarter's colour. The fourth word of the first three quarters carries the whole face's
// colour, the four quarters averaged, at offsets 3, 7 and 11.
const int PLAGUE_LOCAL_RECORD_FACE_COLOUR = 3;
// Word 24: the box the emitting block fills inside ONE of its cells, in the same five-bits-per-axis
// packing the brick grid uses. A full block is the whole cell; a torch is a small box inside it.
// How far the run reaches past that one cell is the span, in the run word.
const int PLAGUE_LOCAL_RECORD_BOX = 24;
// Word 7: which way the face points in bits 0 to 2, then each span one less than the number of
// cells it covers, four bits each. The two spans run along the face in the order a face reads its
// own axes: a Y face spans x then z, a Z face spans x then y, an X face spans y then z.
const int PLAGUE_LOCAL_RECORD_RUN = 7;
int plagueLocalRunFace(uint run) { return int(run & 7u); }
vec2 plagueLocalRunSpan(uint run) {
    return vec2(float((run >> 3) & 15u) + 1.0, float((run >> 7) & 15u) + 1.0);
}

/** The unit cell, which is what a full-shaped block fills. */
uint plagueLocalPackBox(vec3 lo, vec3 hi) {
    uvec3 l = uvec3(clamp(round(lo * 16.0), 0.0, 31.0));
    uvec3 h = uvec3(clamp(round(hi * 16.0), 0.0, 31.0));
    return l.x | (l.y << 5) | (l.z << 10) | (h.x << 15) | (h.y << 20) | (h.z << 25);
}
void plagueLocalUnpackBox(uint packed, out vec3 lo, out vec3 hi) {
    // Zero is what an unwritten record reads as, and a box of no size emits nothing at all. A
    // record from an older frame would otherwise switch every light in the world off for a frame.
    if (packed == 0u) { lo = vec3(0.0); hi = vec3(1.0); return; }
    lo = vec3(packed & 31u, (packed >> 5) & 31u, (packed >> 10) & 31u) / 16.0;
    hi = vec3((packed >> 15) & 31u, (packed >> 20) & 31u, (packed >> 25) & 31u) / 16.0;
}
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
