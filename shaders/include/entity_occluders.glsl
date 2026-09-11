#ifndef PLAGUE_ENTITY_OCCLUDERS
#define PLAGUE_ENTITY_OCCLUDERS
// Caller supplies plagueEntityOccluderWord(int) and plagueEntityOccluderSize(), reading the
// engine's entityOccluders buffer at whichever u_InputN slot the pass bound it to. Header word 0
// is the live record count; each record is a camera-relative axis-aligned box, the same origin as
// the local-light segment it is tested against.

// Mirrors EntityOccluderBuffer.HEADER_FLOATS/MAX_OCCLUDERS/FLOATS_PER_OCCLUDER in the engine.
const int ENTITY_OCCLUDER_HEADER_WORDS = 4;
const int ENTITY_OCCLUDER_MAX = 64;
const int ENTITY_OCCLUDER_RECORD_WORDS = 12;

bool plagueEntityOccluderHitsBox(vec3 origin, vec3 dir, vec3 boundsMin, vec3 boundsMax, float maxT) {
    vec3 inv = 1.0 / dir;
    vec3 t0 = (boundsMin - origin) * inv, t1 = (boundsMax - origin) * inv;
    vec3 tNear = min(t0, t1), tFar = max(t0, t1);
    float tEnter = max(max(tNear.x, tNear.y), tNear.z), tExit = min(min(tFar.x, tFar.y), tFar.z);
    // An origin already inside a box gives tEnter < 0; clamping to 0 still reports a hit, so a
    // light held inside a body's own box is shadowed the same as by any other body.
    return tExit >= max(tEnter, 0.0) && tEnter <= maxT;
}
bool plagueEntityOccluded(vec3 origin, vec3 dir, float maxT) {
    // A missing or wrong-sized buffer must read as no bodies at all, not as whatever count
    // word 0 happens to hold.
    if (plagueEntityOccluderSize() != ENTITY_OCCLUDER_HEADER_WORDS
            + ENTITY_OCCLUDER_MAX * ENTITY_OCCLUDER_RECORD_WORDS) return false;
    int count = min(int(plagueEntityOccluderWord(0)), ENTITY_OCCLUDER_MAX);
    for (int i = 0; i < count; i++) {
        int base = ENTITY_OCCLUDER_HEADER_WORDS + i * ENTITY_OCCLUDER_RECORD_WORDS;
        vec3 boundsMin = vec3(plagueEntityOccluderWord(base), plagueEntityOccluderWord(base + 1),
                plagueEntityOccluderWord(base + 2));
        vec3 boundsMax = vec3(plagueEntityOccluderWord(base + 4), plagueEntityOccluderWord(base + 5),
                plagueEntityOccluderWord(base + 6));
        // A dropped item's drawn sprite is about half the width and depth of its published
        // collision box; the raw box would cast a too-wide dark tile under it. Shrink toward the
        // box's centre on the flat axes only; height stays as given.
        float kind = plagueEntityOccluderWord(base + 3); // 4 = item, per the engine's published kinds
        if (kind == 4.0) {
            vec3 centre = 0.5 * (boundsMin + boundsMax);
            boundsMin.xz = mix(centre.xz, boundsMin.xz, 0.5);
            boundsMax.xz = mix(centre.xz, boundsMax.xz, 0.5);
        }
        if (plagueEntityOccluderHitsBox(origin, dir, boundsMin, boundsMax, maxT)) return true;
    }
    return false;
}
#endif
