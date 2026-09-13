#ifndef PLAGUE_SHADOW_HANDOFF
#define PLAGUE_SHADOW_HANDOFF
// Callers bind the full raster depth, independent entity depth and RT depth/validity as raw maps.
// Selection follows the receiving world point; a blocker may lie anywhere along its light ray.
float plagueShadowReceiverWeight(vec3 receiver) {
#if RT_SHADOWS
    float radiusSquared = u_ShadowMapParams.y;
    if (!(radiusSquared > 0.0)) return 0.0;
    float radius = sqrt(radiusSquared);
    // Two blocks are one eighth of the minimum one-chunk distance. Keeping this band fixed
    // leaves already-covered receivers unchanged when the owner raises the distance.
    float transitionWidth = min(2.0, radius);
    return 1.0 - smoothstep(radius - transitionWidth, radius, length(receiver.xz));
#else
    return 0.0;
#endif
}

#ifndef PLAGUE_SHADOW_RECORD_COVERAGE
#define PLAGUE_SHADOW_RECORD_COVERAGE(coverage)
#endif

float plagueShadowTexel(ivec2 texel, float reference, float rtWeight, out float rtSelected) {
    rtSelected = 0.0;
#if RT_SHADOWS
    if (rtWeight > 0.0) {
        vec4 traced = texelFetch(RT_TERRAIN_SHADOW_DEPTH, texel, 0);
        // Alpha is current-frame coverage: zero is unknown, even when red holds a lit miss.
        // Fall back before interpolation so one untraced texel cannot erase a valid neighbor.
        if (traced.a > 0.5) {
            float entityDepth = texelFetch(ENTITY_SHADOW_RAW_MAP, texel, 0).r;
            float completeDepth = min(traced.r, entityDepth);
            float rtVisibility = step(reference, completeDepth);
            rtSelected = rtWeight;
            // Covered taps need no terrain-raster read. Only the transition needs both backends.
            if (rtWeight >= 1.0) return rtVisibility;
            float rasterVisibility = step(reference, texelFetch(SHADOW_RAW_MAP, texel, 0).r);
            return mix(rasterVisibility, rtVisibility, rtWeight);
        }
    }
#endif
    return step(reference, texelFetch(SHADOW_RAW_MAP, texel, 0).r);
}

float plagueShadowLookup(vec3 receiver, vec2 uv, float reference) {
    float weight = plagueShadowReceiverWeight(receiver);
#ifdef SHADOW_COMPARISON_MAP
    // Outside RT coverage, preserve the existing hardware comparison path and its lookup cost.
    if (weight <= 0.0) {
        PLAGUE_SHADOW_RECORD_COVERAGE(0.0);
        return textureLod(SHADOW_COMPARISON_MAP, vec3(uv, reference), 0.0);
    }
#endif
    // Reproduce the comparison sampler's bilinear PCF with depth union BEFORE comparison.
    // Interpolating depths, or multiplying independently filtered visibility, changes occlusion.
    ivec2 size = textureSize(SHADOW_RAW_MAP, 0);
    vec2 position = uv * vec2(size) - 0.5;
    ivec2 lower = ivec2(floor(position));
    vec2 fraction = fract(position);
    ivec2 maximum = size - 1;
    float c00, c10, c01, c11;
    float v00 = plagueShadowTexel(clamp(lower, ivec2(0), maximum), reference, weight, c00);
    float v10 = plagueShadowTexel(clamp(lower + ivec2(1, 0), ivec2(0), maximum), reference, weight, c10);
    float v01 = plagueShadowTexel(clamp(lower + ivec2(0, 1), ivec2(0), maximum), reference, weight, c01);
    float v11 = plagueShadowTexel(clamp(lower + ivec2(1, 1), ivec2(0), maximum), reference, weight, c11);
    // Optional diagnostic consumes the same weighted tap choices, without another depth fetch.
    PLAGUE_SHADOW_RECORD_COVERAGE(mix(mix(c00, c10, fraction.x), mix(c01, c11, fraction.x), fraction.y));
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}
#endif
