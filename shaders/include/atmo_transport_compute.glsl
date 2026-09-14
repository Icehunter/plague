#ifndef PLAGUE_ATMO_TRANSPORT_COMPUTE
#define PLAGUE_ATMO_TRANSPORT_COMPUTE

// Compute binding ABI for the aerial writer; transport math is stage-neutral.
#define FORNAX_COMPUTE_GLOBALS
#define FORNAX_GLOBALS_BINDING 0
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:atmo_transport.glsl>

// Bindings: 0 globals, 1 packOptions (engine-injected), 2 atmoTransmittance, 3 atmoMultiScatter,
// 4 atmoSkyView, 5 sunShadowMap, 6 raw raster, 7 RT terrain, 8 raw entities.
// The aerial writer appends its output after these shared bindings.
// Inputs are appended; storage targets are storage images, never samplers.
// The shadow map is a sampler because a depth format cannot be a storage image.
layout(rgba16f, set = 0, binding = 2) uniform readonly image2D u_Transmittance;
layout(rgba16f, set = 0, binding = 3) uniform readonly image2D u_MultiScatter;
layout(rgba16f, set = 0, binding = 4) uniform readonly image2D u_SkyView;
layout(set = 0, binding = 5) uniform sampler2DShadow u_SunShadow;
layout(set = 0, binding = 6) uniform sampler2D u_ShadowRaw;
layout(set = 0, binding = 7) uniform sampler2D u_RtTerrainShadow;
layout(set = 0, binding = 8) uniform sampler2D u_EntityShadowRaw;
#define SHADOW_COMPARISON_MAP u_SunShadow
#define SHADOW_RAW_MAP u_ShadowRaw
#define RT_TERRAIN_SHADOW_DEPTH u_RtTerrainShadow
#define ENTITY_SHADOW_RAW_MAP u_EntityShadowRaw
#moj_import <fornax_runtime:shadow_handoff.glsl>

#ifdef SHADOWS
#moj_import <fornax_runtime:atmo_shadow.glsl>
float plagueAtmoSunShadow(vec3 posBlocks, vec3 sunDir) {
    return plagueAtmoShadowAt(posBlocks, sunDir).x;
}
#endif

vec4 plagueAtmoFetchTransmittance(vec2 uv) {
    ivec2 i0;
    ivec2 i1;
    vec2 f;
    plagueAtmoBilinearSetup(uv, imageSize(u_Transmittance), i0, i1, f);
    return plagueAtmoBilinearMix(imageLoad(u_Transmittance, i0), imageLoad(u_Transmittance, ivec2(i1.x, i0.y)),
                                 imageLoad(u_Transmittance, ivec2(i0.x, i1.y)), imageLoad(u_Transmittance, i1), f);
}

vec4 plagueAtmoFetchMultiScatter(vec2 uv) {
    ivec2 i0;
    ivec2 i1;
    vec2 f;
    plagueAtmoBilinearSetup(uv, imageSize(u_MultiScatter), i0, i1, f);
    return plagueAtmoBilinearMix(imageLoad(u_MultiScatter, i0), imageLoad(u_MultiScatter, ivec2(i1.x, i0.y)),
                                 imageLoad(u_MultiScatter, ivec2(i0.x, i1.y)), imageLoad(u_MultiScatter, i1), f);
}

vec4 plagueAtmoFetchSkyView(vec2 uv) {
    ivec2 i0;
    ivec2 i1;
    vec2 f;
    plagueAtmoBilinearSetup(uv, imageSize(u_SkyView), i0, i1, f);
    return plagueAtmoBilinearMix(imageLoad(u_SkyView, i0), imageLoad(u_SkyView, ivec2(i1.x, i0.y)),
                                 imageLoad(u_SkyView, ivec2(i0.x, i1.y)), imageLoad(u_SkyView, i1), f);
}

#endif
