#ifndef PLAGUE_REFLECTION_CLIP
#define PLAGUE_REFLECTION_CLIP

// Cut the ray range down to the part where f(t) >= 0 for one clip plane.
// Nothing is divided by w until every clip plane has been applied.
bool plagueClipReflectionPlane(float origin, float direction, inout vec2 interval) {
    if (direction == 0.0) return origin >= 0.0;
    float crossing = -origin / direction;
    if (direction > 0.0) interval.x = max(interval.x, crossing);
    else interval.y = min(interval.y, crossing);
    return interval.y > interval.x;
}

bool plagueClipReflectionRay(vec4 origin, vec4 direction, inout vec2 interval) {
    // 2^-20 is eight float steps at clip scale 1, a small guard right at the eye.
    return plagueClipReflectionPlane(origin.w - 0.00000095367431640625, direction.w, interval)
        && plagueClipReflectionPlane(origin.w + origin.x, direction.w + direction.x, interval)
        && plagueClipReflectionPlane(origin.w - origin.x, direction.w - direction.x, interval)
        && plagueClipReflectionPlane(origin.w + origin.y, direction.w + direction.y, interval)
        && plagueClipReflectionPlane(origin.w - origin.y, direction.w - direction.y, interval)
        && plagueClipReflectionPlane(origin.z, direction.z, interval)
        && plagueClipReflectionPlane(origin.w - origin.z, direction.w - direction.z, interval);
}
#endif
