#version 330 core
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>

uniform sampler2D u_Input0; // builtin.depth
uniform sampler2D u_Input1; // builtin.gNormal
// The complete raster map remains the fallback for every receiving point.
uniform sampler2DShadow u_Input2; // complete sunShadowMap
#define SUN_SHADOW_MAP u_Input2
uniform sampler2D u_Input5; // sunShadowMapRaw (existing reserved binding)
uniform sampler2D u_Input8; // rtTerrainShadowDepth
uniform sampler2D u_Input9; // sunEntityShadowMapRaw
#define SHADOW_COMPARISON_MAP u_Input2
#define SHADOW_RAW_MAP u_Input5
#define RT_TERRAIN_SHADOW_DEPTH u_Input8
#define ENTITY_SHADOW_RAW_MAP u_Input9
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
    float depth = texture(u_Input0, texCoord).r;
    vec4 worldH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec3 worldPos = worldH.xyz / (abs(worldH.w) > 1e-6 ? worldH.w : 1.0);
    vec3 shadingNormal = texture(u_Input1, texCoord).rgb;
    // Match the lighting pass's surface plane and offset, including the entity fallback normal.
    // The plane is worked out before any early return, so a sky pixel at the edge can't break it
    // for its neighbors.
    vec3 planeNormal = cross(dFdx(worldPos), dFdy(worldPos));
    float planeLength = length(planeNormal);
    planeNormal = planeLength > 1e-6 ? planeNormal / planeLength : shadingNormal;
    if (dot(planeNormal, shadingNormal) < 0.0) planeNormal = -planeNormal;
    if (depth <= 0.0) return;
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
