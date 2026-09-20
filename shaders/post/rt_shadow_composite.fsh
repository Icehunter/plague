#version 330 core
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:shadow_debug.glsl>

uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GNormal; // builtin.gNormal
// The complete raster map remains the fallback for every receiving point.
uniform sampler2DShadow u_SunShadowMap; // complete sunShadowMap
#define SUN_SHADOW_MAP u_SunShadowMap
uniform sampler2D u_SunShadowMapRaw; // sunShadowMapRaw (existing reserved binding)
uniform sampler2D u_RtTerrainShadowDepth; // rtTerrainShadowDepth
uniform sampler2D u_SunEntityShadowMapRaw; // sunEntityShadowMapRaw
uniform sampler2D u_GMotion; // builtin.gMotion, debug views only
#define SHADOW_COMPARISON_MAP u_SunShadowMap
#define SHADOW_RAW_MAP u_SunShadowMapRaw
#define RT_TERRAIN_SHADOW_DEPTH u_RtTerrainShadowDepth
#define ENTITY_SHADOW_RAW_MAP u_SunEntityShadowMapRaw
float plagueRtSelectedSum = 0.0;
#define PLAGUE_SHADOW_RECORD_COVERAGE(coverage) plagueRtSelectedSum += (coverage)
#moj_import <fornax_runtime:shadow_handoff.glsl>
#define SUN_SHADOW_LOOKUP(receiver, uv, reference) plagueShadowLookup(receiver, uv, reference)

// The resolve_hdr name supplies the same active sun/moon direction as the lighting resolve.
layout(std140) uniform u_PassParams {
    vec2 u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4 u_SunDirection;
};
in vec2 texCoord;
out vec4 fragColor;
#ifdef SHADOWS
#moj_import <fornax_runtime:shadow_filter.glsl>
#endif

// Preserve the seabed caustic query's own light-direction bias and out-of-map dark fallback.
float plagueCausticSunVisibility(vec3 receiver, vec3 sunDir) {
    vec4 clip = u_SunViewProj * vec4(receiver + sunDir * 0.08, 1.0);
    vec3 ndc = clip.xyz / max(clip.w, 1e-6);
    float distortion = length(ndc.xy) * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    vec2 uv = ndc.xy / distortion * 0.5 + 0.5;
    if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0
            || ndc.z <= 0.0 || ndc.z >= 1.0) return 0.0;
    return plagueShadowLookup(receiver, uv, ndc.z);
}

void main() {
    fragColor = vec4(1.0, 1.0, 1.0, 0.0);
#ifdef SHADOWS
#ifdef PLAGUE_DEBUG_VIEWS
    int debugView = int(u_Param3 + 0.5);
    if (debugView == DBG_MOTION) {
        // Keep the same brightness boost this debug view already used, before handing off as
        // RGBA16F. Returning early, before the depth check, also keeps motion visible on sky
        // pixels and frees up resolve's motion input.
        fragColor = vec4(abs(texture(u_GMotion, texCoord).rg) * 40.0, 0.0, 1.0);
        return;
    }
    if (debugView == DBG_SHADOW_MAP_VIEW) {
        // This view reads the shadow map directly, including pixels where the camera sees sky.
        ivec2 mapTexel = ivec2(texCoord * vec2(textureSize(SHADOW_RAW_MAP, 0)));
        fragColor = plagueShadowDebugMapColor(texelFetch(SHADOW_RAW_MAP, mapTexel, 0).r);
        return;
    }
#endif
    float depth = texture(u_Depth, texCoord).r;
    vec4 worldH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec3 worldPos = worldH.xyz / (abs(worldH.w) > 1e-6 ? worldH.w : 1.0);
    vec3 shadingNormal = texture(u_GNormal, texCoord).rgb;
    // Match the lighting pass's surface plane and offset, including the entity fallback normal.
    // The plane is worked out before any early return, so a sky pixel at the edge can't break it
    // for its neighbors.
    vec3 planeNormal = cross(dFdx(worldPos), dFdy(worldPos));
    float planeLength = length(planeNormal);
    planeNormal = planeLength > 1e-6 ? planeNormal / planeLength : shadingNormal;
    if (dot(planeNormal, shadingNormal) < 0.0) planeNormal = -planeNormal;
    if (depth <= 0.0) return;
#ifdef PLAGUE_DEBUG_VIEWS
    if (debugView == DBG_SHADOW_DEPTH_COMPARE) {
        // Match resolve's fallback for the shading normal and for a missing light direction,
        // but not its geometric bias.
        vec3 normal = dot(shadingNormal, shadingNormal) > 1e-6
                ? normalize(shadingNormal) : vec3(0.0, 1.0, 0.0);
        vec3 light = u_SunDirection.xyz;
        vec3 debugSunDir = dot(light, light) > 1e-6
                ? normalize(light) : normalize(vec3(0.3, 0.9, 0.2));
        vec3 coordinates = plagueShadowDebugCoordinates(worldH.xyz / worldH.w, normal, debugSunDir);
        ivec2 mapTexel = ivec2(clamp(coordinates.xy, 0.0, 1.0)
                              * vec2(textureSize(SHADOW_RAW_MAP, 0)));
        float storedDepth = texelFetch(SHADOW_RAW_MAP, mapTexel, 0).r;
        fragColor = vec4(coordinates.z, 0.0, storedDepth, 0.0);
        return;
    }
#endif
    vec3 sunDir = normalize(u_SunDirection.xyz);
    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);
    float direct = sunVisibility(worldPos, planeNormal, sunDir, rainFactor);
    float rtSelected = plagueRtSelectedSum / float(2 * SHADOW_SAMPLES);
    float ambient = sunVisibilityAt(worldPos, planeNormal, sunDir, rainFactor,
                                    PLAGUE_SHADOW_AMBIENT_BROADEN);
    fragColor = vec4(direct, ambient, plagueCausticSunVisibility(worldPos, sunDir),
                     rtSelected);
#endif
}
