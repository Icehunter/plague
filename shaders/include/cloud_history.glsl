#ifndef PLAGUE_CLOUD_HISTORY
#define PLAGUE_CLOUD_HISTORY

// Both paths keep the complete fresh march; the diagnostic measures raw correspondence.
#define PLAGUE_CLOUD_HISTORY_DEBUG 0 //[0 1 2] compile "Cloud History" {0="Off" 1="Candidates" 2="Error"}
#define PLAGUE_CLOUD_TEMPORAL 0 //[0 1] compile "Cloud Temporal Blend" {0="Off" 1="On"}

#if PLAGUE_CLOUD_HISTORY_DEBUG != 0 || PLAGUE_CLOUD_TEMPORAL != 0
// R32F carries 7 contributor bits and a 20-bit source stamp. The fixed exponent tag
// keeps every payload finite and normalized; only imageLoad, never filtering, may decode it.
float plagueCloudHistoryPack(uint mask, float stamp) {
    return uintBitsToFloat(0x40000000u | (uint(stamp) << 7u) | mask);
}

bool plagueCloudHistoryUnpack(float value, out uint mask, out float stamp) {
    uint bits = floatBitsToUint(value);
    mask = bits & 127u;
    stamp = float((bits >> 7u) & 0xfffffu);
    return (bits & 0xf8000000u) == 0x40000000u && stamp > 0.0 && stamp <= 720720.0;
}

bool plagueCloudHistoryFinite(vec4 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueCloudHistoryPremultiplied(vec4 colour) {
    // Radiance is HDR, so RGB can exceed alpha; zero opacity must still carry zero radiance.
    return plagueCloudHistoryFinite(colour) && all(greaterThanEqual(colour, vec4(0.0)))
        && colour.a <= 1.0 && (colour.a > 0.0 || all(equal(colour.rgb, vec3(0.0))));
}

float plagueCloudHistoryBlendWeight(vec4 fresh, vec4 previous, vec4 lower, vec4 upper,
                                    vec2 previousDepthRange, vec2 currentDepthRange) {
    if (!plagueCloudHistoryPremultiplied(fresh) || !plagueCloudHistoryPremultiplied(previous)
        || !plagueCloudHistoryFinite(lower) || !plagueCloudHistoryFinite(upper)
        || any(lessThan(lower, vec4(0.0))) || lower.a > 1.0 || upper.a > 1.0
        || any(greaterThan(lower, upper)) || any(lessThan(fresh, lower))
        || any(greaterThan(fresh, upper))
        || !plagueCloudHistoryFinite(vec4(previousDepthRange, currentDepthRange))
        || previousDepthRange.x <= 0.0 || currentDepthRange.x <= 0.0
        || previousDepthRange.x > previousDepthRange.y || currentDepthRange.x > currentDepthRange.y
        || previousDepthRange.x < currentDepthRange.x || previousDepthRange.y > currentDepthRange.y) {
        return 0.0;
    }
    // Equal weighting of two fresh frames caps history at one half. A single scalar keeps
    // the premultiplied colour convex while intersecting the current RGBA support bounds.
    float weight = 0.5;
    vec4 delta = previous - fresh;
    if (!plagueCloudHistoryFinite(delta)) return 0.0;
    for (int lane = 0; lane < 4; lane++) {
        if (delta[lane] > 0.0) weight = min(weight, (upper[lane] - fresh[lane]) / delta[lane]);
        if (delta[lane] < 0.0) weight = min(weight, (lower[lane] - fresh[lane]) / delta[lane]);
    }
    return weight;
}

bool plagueCloudHistoryConsecutive(vec4 current, vec4 previous, float reset) {
    // CameraJitter wraps at 720720. Stored stamps add one so cleared images are invalid.
    return plagueCloudHistoryFinite(current) && plagueCloudHistoryFinite(previous)
        && reset == 0.0 && previous.x > 0.0
        && current.x == mod(previous.x, 720720.0) + 1.0
        && all(equal(current.zw, previous.zw)) && current.y >= previous.y;
}

bool plagueCloudHistoryCalendar(vec4 current, vec4 previous, float tickDelta) {
    // Day fractions are quantized separately from game ticks. One tick bounds that quantization;
    // faster/backward calendar changes are rejected until a fresh frame establishes the new state.
    float dayDelta = current.x - previous.x;
    float ticks = dayDelta * 24000.0 + (current.y - previous.y) * 24000.0;
    return plagueCloudHistoryFinite(current) && plagueCloudHistoryFinite(previous)
        && abs(dayDelta) <= 1.0 && ticks >= -1.0 && ticks <= ceil(tickDelta) + 1.0;
}

bool plagueCloudHistorySingle(uint mask) {
    return mask != 0u && mask < 128u && (mask & (mask - 1u)) == 0u;
}

bool plagueCloudHistoryWind(float now, float previous, float rate, float wrap,
                            float cell, float shear, vec2 wind, out vec2 backward) {
    // Inverse of cloud_density's ADDITIVE, sheared allocation drift. Use its actual phase
    // arithmetic; a dt*speed shortcut misses quantization at large game ages.
    float a = now * rate;
    float b = previous * rate;
    backward = (mod(a, wrap) - mod(b, wrap)) * cell * shear * wind;
    return now >= previous && floor(a / wrap) == floor(b / wrap)
        && plagueCloudHistoryFinite(vec4(backward, a, b));
}

bool plagueCloudHistoryProject(vec3 ray, float distance, vec3 cameraDelta,
                               vec2 backward, mat4 previousVP, out vec2 uv,
                               out float previousDistance) {
    vec3 point = ray * distance + cameraDelta + vec3(backward.x, 0.0, backward.y);
    previousDistance = length(point);
    vec4 clip = previousVP * vec4(point, 1.0);
    uv = vec2(0.0);
    if (!plagueCloudHistoryFinite(clip) || !(clip.w > 0.0) || !(distance > 0.0)) {
        return false;
    }
    uv = clip.xy / clip.w * 0.5 + 0.5;
    return plagueCloudHistoryFinite(vec4(uv, previousDistance, 0.0));
}

vec3 plagueCloudHistoryError(vec4 fresh, vec4 previous, float distance, float prediction) {
    // Unitless symmetric RGB error, absolute opacity error, symmetric proxy-depth error.
    // The display clamps to [0,1]; these are measurements, not acceptance thresholds.
    vec3 sum = abs(fresh.rgb) + abs(previous.rgb);
    vec3 delta = abs(fresh.rgb - previous.rgb);
    float total = sum.r + sum.g + sum.b;
    float colour = total > 0.0 ? (delta.r + delta.g + delta.b) / total : 0.0;
    float depth = distance + prediction;
    return vec3(colour, abs(fresh.a - previous.a),
                depth > 0.0 ? abs(distance - prediction) / depth : 0.0);
}
#endif
#endif
