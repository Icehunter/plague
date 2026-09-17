#ifndef PLAGUE_CLOUD_HISTORY
#define PLAGUE_CLOUD_HISTORY

// Every mode refreshes every pixel; Fast reduces march samples before the existing blend.
#define PLAGUE_CLOUD_HISTORY_DEBUG 0 //[0 1 2] compile "Test View: Cloud History" {0="Off" 1="Candidates" 2="Error"}
// Not an option. The cloud's own history blend follows the engine's temporal consumer: on whenever
// TAA, TAAU, or MetalFX upscaling runs (FX_TAA covers all three), off otherwise. A frame-rotating
// dither with no consumer flashes, and a consumer with no rotating dither has nothing to average,
// so tying the two together leaves no way to set it wrong. Guarded so an offline harness can still
// pin a value by define.
#ifndef PLAGUE_CLOUD_TEMPORAL
#if defined(FX_TAA) && FX_TAA != 0
#define PLAGUE_CLOUD_TEMPORAL 1
#else
#define PLAGUE_CLOUD_TEMPORAL 0
#endif
#endif

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

// Slack on the depth containment test, as a fraction of the neighbourhood's own far distance.
//
// First-hit distance is rounded off by the march's step length, and that length is not fixed: a
// long ray spends its whole budget at the step cap, which floors at
// int(PLAGUE_CLOUD_MIN_SLAB_STEPS) * 2 = 8 segments (clouds.glsl), and the arithmetic growth across
// the span puts the last segment at about twice the mean. One step is then about 2/8 of the ray,
// which is where 0.25 comes from: the cap floor, not a tuned number, and it moves if that floor
// does.
//
// An exact test rejects on this rounding rather than on any real mismatch, hardest on grazing rays,
// which carry the fewest samples and need the accumulation most. The failure is silent: noise that
// never settles.
//
// This is the second gate, not the only one: the colour clamp below keeps the blended result
// inside the current frame's own 3x3 range no matter what this test allows, so loosening it cannot
// let history drift past what this frame rendered.
const float PLAGUE_CLOUD_HISTORY_DEPTH_SLACK = 0.25;

float plagueCloudHistoryBlendWeight(vec4 fresh, vec4 previous, vec4 lower, vec4 upper,
                                    vec2 previousDepthRange, vec2 currentDepthRange) {
    float slack = PLAGUE_CLOUD_HISTORY_DEPTH_SLACK * max(currentDepthRange.y, 0.0);
    if (!plagueCloudHistoryPremultiplied(fresh) || !plagueCloudHistoryPremultiplied(previous)
        || !plagueCloudHistoryFinite(lower) || !plagueCloudHistoryFinite(upper)
        || any(lessThan(lower, vec4(0.0))) || lower.a > 1.0 || upper.a > 1.0
        || any(greaterThan(lower, upper)) || any(lessThan(fresh, lower))
        || any(greaterThan(fresh, upper))
        || !plagueCloudHistoryFinite(vec4(previousDepthRange, currentDepthRange))
        || previousDepthRange.x <= 0.0 || currentDepthRange.x <= 0.0
        || previousDepthRange.x > previousDepthRange.y || currentDepthRange.x > currentDepthRange.y
        || previousDepthRange.x < currentDepthRange.x - slack
        || previousDepthRange.y > currentDepthRange.y + slack) {
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
