#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "Voxel SSR Recovery" {0="Off" 1="On"}
// The stand-in sprite's alpha keeps leaves; see-through texels fall through to the background.
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
uniform sampler2D u_Input0; // water normal
uniform sampler2D u_Input1; // water depth
uniform sampler2D u_Input2; // opaque depth
#moj_import <fornax_runtime:voxel_coverage.glsl>
uniform sampler2D u_Input7; // current SSR
uniform sampler2DShadow u_Input8; // sun shadow map
uniform sampler2D u_Input12; // normal atlas
uniform sampler2D u_Input13; // material atlas
uniform sampler2D u_Input14; // atmospheric transmittance
uniform sampler2D u_Input15; // atmospheric multiscatter
uniform sampler2D u_Input16; // atmospheric sky view
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

bool plagueVoxelFallbackNeeded(vec2 uv) {
    ivec2 size = textureSize(u_Input7, 0);
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
            if (texelFetch(u_Input7, pixel, 0).a > 0.5) continue;
            float depth = texelFetch(u_Input1, pixel, 0).r;
            if (depth > 0.0 && texelFetch(u_Input2, pixel, 0).r < depth
                    && abs(texelFetch(u_Input0, pixel, 0).a) >= 0.5) return true;
        }
    }
    return false;
}

void main() {
    fragColor = vec4(0.0);
#if PLAGUE_VOXEL_REFLECTIONS != 0
    if (u_WaterState.x > 0.5) return;
    vec3 normal; float roughness,flags;
    plagueDecodeWaterReflectionSurface(texture(u_Input0,texCoord),normal,roughness,flags);
    float depth = texture(u_Input1,texCoord).r;
    if (abs(flags)<0.5 || depth<=0.0 || texture(u_Input2,texCoord).r>=depth) return;
    if (!plagueVoxelFallbackNeeded(texCoord)) return;
    vec4 h = u_InvProjModelView*vec4(texCoord*2.0-1.0,depth,1.0);
    vec3 origin = h.xyz/h.w;
    vec3 point,faceNormal,local; uint colour; int entry;
    float state = plagueVoxelTraceMaterial(origin+normal*PLAGUE_COVERAGE_EPSILON,
            reflect(normalize(origin),normal),point,faceNormal,colour,entry,local);
#if PLAGUE_VOXEL_PROFILE_STAGE == 1
    // Consume the trace outputs so a prefix draw retains the work its later stages would use.
    // Integer scales come from the uint32 colour word and the low uint16 entry lane.
    fragColor = vec4(point + faceNormal + local,
            state + float(entry & 65535)/65535.0 + float(colour)/4294967295.0);
    return;
#endif
    if (state!=1.0) return;
    PlagueVoxelSurface surface;
    if (!plagueVoxelSurfaceAt(point,faceNormal,colour,entry,local,surface)) return;
#if PLAGUE_VOXEL_PROFILE_STAGE == 2
    // This is an observable sink, not a colour approximation. It keeps decoded fields live.
    fragColor = vec4(surface.position + surface.normal + surface.geometricNormal + surface.albedo
            + vec3(surface.light,surface.ao), surface.emission + surface.material.alpha
            + surface.material.f0 + surface.material.porosity + surface.material.subsurface
            + float(surface.material.conductor) + surface.material.metalness
            + float(surface.material.namedMetal) + float(surface.material.metalIndex));
    return;
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
    vec3 specularAlbedo;
    vec3 viewDir = normalize(origin-point);
    vec3 radiance = plagueVoxelSurfaceDirect(surface,viewDir,sunDir,lighting,colours,specularAlbedo);
#if PLAGUE_VOXEL_PROFILE_STAGE == 3
    fragColor = vec4(radiance + specularAlbedo,1.0);
    return;
#endif
    // Not the eye-to-water air. A wider voxel window must never push the engine's border out.
    float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y,32.0);
    if (any(greaterThan(specularAlbedo,vec3(0)))) {
        vec3 reflected = plagueVoxelSurfaceReflection(surface,viewDir,sunDir,sunDirTrue,
                skyColours,lighting,colours,atmColorMult,renderDistance);
        float specularAO = plagueSpecularOcclusion(surface.ao,clamp(dot(surface.normal,viewDir),0.0,1.0),
                sqrt(clamp(surface.material.alpha,0.0,1.0)));
        radiance += reflected*specularAlbedo*specularAO;
    }
    radiance = plagueVoxelReflectionFog(radiance,origin,point,surface.light.y,
            lighting,atmColorMult,sunDirTrue,renderDistance);
    fragColor = vec4(radiance,1.0);
#endif
}
