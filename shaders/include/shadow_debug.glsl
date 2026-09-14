#ifndef PLAGUE_SHADOW_DEBUG
#define PLAGUE_SHADOW_DEBUG

//#define PLAGUE_DEBUG_VIEWS //[] compile "Motion and Shadow-Map Debug Views"
// Engine GBufferDebugView shaderId ABI. Both passes receive the same live u_Param3.
#define DBG_MOTION 4
#define DBG_SHADOW_QUERY_3 33
#define DBG_SHADOW_MAP_VIEW 40

// Keep the projection query's diagnostic bias in one place. Both QUERY_2's
// coordinates and QUERY_3's stored-depth lookup must inspect the identical receiving point.
vec3 plagueShadowDebugCoordinates(vec3 worldPos, vec3 normal, vec3 sunDir) {
    float slope = 1.0 - abs(dot(normal, sunDir));
    vec3 biased = worldPos + normal * (0.05 + 0.35 * slope) + sunDir * 0.05;
    vec4 clip = u_SunViewProj * vec4(biased, 1.0);
    vec3 ndc = clip.xyz / clip.w;
    float distortion = length(ndc.xy) * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    return vec3(ndc.xy / distortion * 0.5 + 0.5, ndc.z);
}

vec4 plagueShadowDebugMapColor(float depth) {
    // Diagnostic calibration: occupied raster depths measured in the bottom fifth;
    // magenta marks the clear sentinel. Decode before the RGBA16F handoff to retain its precision.
    if (depth >= 0.999) return vec4(1.0, 0.0, 0.7, 1.0);
    return vec4(vec3(clamp(depth / 0.2, 0.0, 1.0)), 1.0);
}

#endif
