#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "World Reflections" {0="Off" 1="On"}
// The stand-in sprite's alpha keeps leaves; see-through texels fall through to the background.
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
#ifdef PLAGUE_OPAQUE_REFLECTION
uniform sampler2D u_GNormal; // opaque normal, with geometric normal packed in alpha
uniform sampler2D u_Input1; // opaque receiver depth
uniform sampler2D u_GMaterial; // appended input: same smoothness cutoff as opaque SSR
#moj_import <fornax_runtime:geometric_normal.glsl>
#moj_import <fornax_runtime:opaque_reflection_grid.glsl>
#else
uniform sampler2D u_WaterNormal; // water normal
uniform sampler2D u_WaterDepth; // water depth
// Opaque binds depth twice for the shared input layout; the engine aliases u_Depth to its
// first slot (u_Input1), so declaring both names there would redeclare the same sampler.
uniform sampler2D u_Depth; // opaque depth
#endif
#moj_import <fornax_runtime:voxel_coverage.glsl>
#ifdef PLAGUE_OPAQUE_REFLECTION
uniform sampler2D u_Input7; // current opaque SSR, at the selected reflection tier's resolution
#else
uniform sampler2D u_SsrWaterRaw; // current SSR
#endif
uniform sampler2DShadow u_SunShadowMap; // sun shadow map
uniform sampler2D u_NormalAtlas; // normal atlas
uniform sampler2D u_MaterialAtlas; // material atlas
uniform sampler2D u_AtmoTransmittance; // atmospheric transmittance
uniform sampler2D u_AtmoMultiScatter; // atmospheric multiscatter
uniform sampler2D u_AtmoSkyView; // atmospheric sky view
uniform sampler2D u_SunShadowMapRaw; // sunShadowMapRaw
uniform sampler2D u_RtTerrainShadowDepth; // rtTerrainShadowDepth
uniform sampler2D u_SunEntityShadowMapRaw; // sunEntityShadowMapRaw
#define SHADOW_COMPARISON_MAP u_SunShadowMap
#define SHADOW_RAW_MAP u_SunShadowMapRaw
#define RT_TERRAIN_SHADOW_DEPTH u_RtTerrainShadowDepth
#define ENTITY_SHADOW_RAW_MAP u_SunEntityShadowMapRaw
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:shadow_handoff.glsl>
#moj_import <fornax_runtime:voxel_reflection_fog.glsl>
#moj_import <fornax_runtime:surface_lighting.glsl>
#moj_import <fornax_runtime:voxel_surface.glsl>
// The usual Fornax PassParams layout. The engine sends the same light and bounds as resolve.
layout(std140) uniform u_PassParams {
    vec2 u_PassTexelSize; float u_Param2; float u_Param3;
    vec4 u_SunDirection; vec4 u_SunSprite; vec4 u_MoonSprite;
};
in vec2 texCoord;
out vec4 fragColor;

#ifndef PLAGUE_OPAQUE_REFLECTION
bool plagueVoxelFallbackNeeded(vec2 uv) {
    ivec2 size = textureSize(u_SsrWaterRaw, 0);
    vec2 center = uv * vec2(size);
    // A half-size texel covers 4x4 full-size pixels. Testing its centre alone would drop the
    // fallback for the other weak rays in that block.
    vec2 support = u_PassTexelSize * vec2(size);
    // The blur asks for in-between UVs, so cover every overlapping SSR texel, not pixel centres.
    ivec2 first = max(ivec2(floor(center - support)), ivec2(0));
    ivec2 last = min(ivec2(ceil(center + support)) - 1, size - 1);
    for (int y = first.y; y <= last.y; ++y) {
        for (int x = first.x; x <= last.x; ++x) {
            ivec2 pixel = ivec2(x, y);
            if (texelFetch(u_SsrWaterRaw, pixel, 0).a > 0.5) continue;
            float depth = texelFetch(u_WaterDepth, pixel, 0).r;
            if (depth > 0.0 && texelFetch(u_Depth, pixel, 0).r < depth
                    && abs(texelFetch(u_WaterNormal, pixel, 0).a) >= 0.5) return true;
        }
    }
    return false;
}
#endif

void main() {
    fragColor = vec4(0.0);
#if PLAGUE_VOXEL_REFLECTIONS != 0
    if (u_WaterState.x > 0.5) return;
#ifdef PLAGUE_OPAQUE_REFLECTION
    ivec2 screenSize = textureSize(u_Input7, 0);
    // Traced at full resolution on both tiers, so each pixel is its own receiver. The screen
    // trace (u_Input7) may be half resolution; it is only looked up at this pixel's UV.
    vec2 receiverUv = texCoord;
    float depth = texture(u_Input1,receiverUv).r;
    vec4 packedNormal = texture(u_GNormal,receiverUv);
    // The cutoff is shared with ssr_trace/ssr_blur; below it the receiver never consumes a ray.
    if (depth<=0.0 || texture(u_GMaterial,receiverUv).r<0.1
            || dot(packedNormal.xyz,packedNormal.xyz)<1e-6) return;
    // Every receiver is traced, so this target holds the world answer alone. A screen hit is
    // not copied in: it flips between hit and miss across jitter steps, and the merge downstream
    // would then flip between two answers. The merge picks by screen confidence.
    vec3 normal = normalize(packedNormal.xyz);
    vec3 receiverNormal = plagueDecodeGeometricNormal(packedNormal.a,normal);
#else
    vec2 receiverUv = texCoord;
    vec3 normal; float roughness,flags;
    plagueDecodeWaterReflectionSurface(texture(u_WaterNormal,texCoord),normal,roughness,flags);
    float depth = texture(u_WaterDepth,texCoord).r;
    if (abs(flags)<0.5 || depth<=0.0 || texture(u_Depth,texCoord).r>=depth) return;
    vec3 receiverNormal = normal;
    if (!plagueVoxelFallbackNeeded(texCoord)) return;
#endif
    vec4 h = u_InvProjModelView*vec4(receiverUv*2.0-1.0,depth,1.0);
    vec3 origin = h.xyz/h.w;
#ifdef PLAGUE_OPAQUE_REFLECTION
    // Schuessler et al., Microfacet-based Normal Mapping for Robust Monte Carlo Path Tracing (2017)
    vec3 wo = -normalize(origin);
    vec3 wp = normal;
    vec3 wg = receiverNormal;
    vec3 r;
    if (dot(wp,wg) < 0.9999) {
        vec3 wt = -normalize(wp - dot(wp,wg)*wg);
        if (dot(wo,wp) > 1e-4) {
            r = reflect(normalize(origin), wp);
            if (dot(r,wg) <= 0.0) r = reflect(r, wt);
            if (dot(r,wg) <= 0.0) r = reflect(r, wp);
        } else {
            r = reflect(normalize(origin), wt);
            if (dot(r,wg) <= 0.0) r = reflect(r, wp);
        }
    } else {
        r = reflect(normalize(origin), wp);
    }
    if (dot(r,wg) < 1e-3) r = normalize(r + wg*(1e-3 - dot(r,wg)));
    vec3 rayDirection = r;
#else
    vec3 rayDirection = reflect(normalize(origin),normal);
#endif
    float rain = clamp(u_SkyState.x,0.0,1.0);
    PlagueCustomPalette palette = PlagueCustomPalette(
            u_AtmPaletteNoonExponent, u_AtmPaletteNoonBrightness,
            vec3(u_AtmPaletteSunsetTintR, u_AtmPaletteSunsetTintG, u_AtmPaletteSunsetTintB),
            vec3(u_AtmPaletteNightR, u_AtmPaletteNightG, u_AtmPaletteNightB),
            vec3(u_AtmPaletteRainDayR, u_AtmPaletteRainDayG, u_AtmPaletteRainDayB),
            vec3(u_AtmPaletteRainNightR, u_AtmPaletteRainNightG, u_AtmPaletteRainNightB),
            vec3(u_LightPaletteNoonR, u_LightPaletteNoonG, u_LightPaletteNoonB),
            vec3(u_LightPaletteSunsetR, u_LightPaletteSunsetG, u_LightPaletteSunsetB),
            u_LightPaletteSunsetWarmth,
            vec3(u_LightPaletteNightR, u_LightPaletteNightG, u_LightPaletteNightB),
            vec3(u_LightPaletteRainDayR, u_LightPaletteRainDayG, u_LightPaletteRainDayB),
            vec3(u_LightPaletteRainNightR, u_LightPaletteRainNightG, u_LightPaletteRainNightB),
            u_LightPaletteRainMagnitude);

    PlagueLighting lighting = plagueOverworldLighting(max(u_SkyColor.rgb,vec3(0)),
            u_SunDirection.w,u_SkyState.y,rain,u_ScreenBrightness,palette);
    vec3 sunDirTrue = dot(u_SkyCelestial.xyz,u_SkyCelestial.xyz)>1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0,1,0);
    vec3 sunDir = dot(u_SunDirection.xyz,u_SunDirection.xyz)>1e-6
            ? normalize(u_SunDirection.xyz) : vec3(0,1,0);
    PlagueSkyColors skyColours = plagueSkyColors(max(u_SkyColor.rgb,vec3(0)),sunDirTrue,
            lighting.sunVisibility,rain,u_CameraAbs.y);
    vec3 atmColorMult = vec3(1);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor,lighting.sunVisibility2,lighting.rainFactor,
            vec3(u_AtmMorningR,u_AtmMorningG,u_AtmMorningB)*u_AtmMorningI,
            vec3(u_AtmNoonR,u_AtmNoonG,u_AtmNoonB)*u_AtmNoonI,
            vec3(u_AtmNightR,u_AtmNightG,u_AtmNightB)*u_AtmNightI,
            vec3(u_AtmRainR,u_AtmRainG,u_AtmRainB)*u_AtmRainI);
#endif
    PlagueSurfaceLighting colours = plagueSurfaceLighting(lighting,skyColours,sunDir,sunDirTrue,
            rain,atmColorMult,u_SunDirection.w,u_CameraAbs.y,vec3(1));
    // Not the eye-to-water air. A wider voxel window must never push the engine's border out.
    float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y,32.0);

    vec3 traceOrigin = origin+receiverNormal*PLAGUE_COVERAGE_EPSILON;
    vec3 throughput = vec3(1.0);
    vec3 radiance = vec3(0.0);
    int glassEntry = -1;
    // Up to three see-through blocks, then a solid hit or the sky.
    for (int layer = 0; layer < 4; ++layer) {
        vec3 point,faceNormal,local; uint colour; int entry;
        float state = plagueVoxelTraceMaterial(traceOrigin,rayDirection,point,faceNormal,colour,entry,local);
#if PLAGUE_VOXEL_PROFILE_STAGE == 1
        // Consume the trace outputs so a prefix draw retains the work its later stages would use.
        // Integer scales come from the uint32 colour word and the low uint16 entry lane.
        fragColor = vec4(point + faceNormal + local,
                state + float(entry & 65535)/65535.0 + float(colour)/4294967295.0);
        return;
#endif
        if (state!=1.0) {
            if (layer==0) return;
            // Past glass the grid ran out clear: the same sky or ground the secondary bounce uses.
            if (state==5.0) {
                radiance += throughput*(rayDirection.y >= 0.0
                        ? plagueAtmoSkyView(rayDirection,sunDirTrue,plagueAtmoCameraRadius()).rgb
                                *atmColorMult*colours.skyReflectionLift
                        : PLAGUE_ENV_GROUND*colours.ambientColour);
            }
            break;
        }
        PlagueVoxelSurface surface;
        if (!plagueVoxelSurfaceAt(point,faceNormal,colour,entry,local,surface)) {
            if (layer==0) return;
            break;
        }
#if PLAGUE_VOXEL_PROFILE_STAGE == 2
        // This is an observable sink, not a colour approximation. It keeps decoded fields live.
        fragColor = vec4(surface.position + surface.normal + surface.geometricNormal + surface.albedo
                + vec3(surface.light,surface.ao), surface.emission + surface.material.alpha
                + surface.material.f0 + surface.material.porosity + surface.material.subsurface
                + float(surface.material.conductor) + surface.material.metalness
                + float(surface.material.namedMetal) + float(surface.material.metalIndex));
        return;
#endif
        vec3 specularAlbedo;
        vec3 viewDir = normalize(origin-point);
        vec3 shaded = plagueVoxelSurfaceDirect(surface,viewDir,sunDir,lighting,colours,specularAlbedo);
#if PLAGUE_VOXEL_PROFILE_STAGE == 3
        fragColor = vec4(shaded + specularAlbedo,1.0);
        return;
#endif
        if (any(greaterThan(specularAlbedo,vec3(0)))) {
            vec3 reflected = plagueVoxelSurfaceReflection(surface,viewDir,sunDir,sunDirTrue,
                    skyColours,lighting,colours,atmColorMult,renderDistance);
            float specularAO = plagueSpecularOcclusion(surface.ao,clamp(dot(surface.normal,viewDir),0.0,1.0),
                    sqrt(clamp(surface.material.alpha,0.0,1.0)));
            shaded += reflected*specularAlbedo*specularAO;
        }
        shaded = plagueVoxelReflectionFog(shaded,origin,point,surface.light.y,
                lighting,atmColorMult,sunDirTrue,renderDistance);
        float a = clamp(surface.coverage,0.0,1.0);
        // 0.99: an 8-bit atlas alpha of 255 is solid; anything lower is a see-through texel.
        // Cutout and cross entries already passed their own alpha test in the trace.
        bool cutoutEntry = (texelFetch(u_VoxelPalette,entry*16).r & 0xc0000000u) != 0u;
        if (a >= 0.99 || cutoutEntry) { radiance += throughput*shaded; break; }
        // The main view blends glass over what is behind it; the reflection does the same.
        // The same entry again is a joined pane with no face drawn between, so no second blend.
        if (entry != glassEntry) {
            radiance += throughput*a*shaded;
            throughput *= 1.0-a;
        }
        glassEntry = entry;
        // Leave this cell along the ray; local is the hit point inside the unit cell.
        float exitDistance = 1e30;
        for (int k = 0; k < 3; ++k) {
            if (abs(rayDirection[k]) < 1e-6) continue;
            exitDistance = min(exitDistance,
                    ((rayDirection[k] > 0.0 ? 1.0 : 0.0) - local[k])/rayDirection[k]);
        }
        traceOrigin = point + rayDirection*(max(exitDistance,0.0) + PLAGUE_COVERAGE_EPSILON);
    }
    fragColor = vec4(radiance,1.0);
#endif
}
