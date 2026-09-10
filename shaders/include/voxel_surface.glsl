#ifndef PLAGUE_VOXEL_SURFACE
#define PLAGUE_VOXEL_SURFACE
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:brdf.glsl>
#moj_import <fornax_runtime:env_brdf.glsl>
#moj_import <fornax_runtime:material_options.glsl>
#moj_import <fornax_runtime:voxel_lightmap.glsl>

#define PLAGUE_LOCAL_LIGHTING 0 //[0 1] compile "Local Coloured Light" {0="Off" 1="Experimental"}
#if PLAGUE_LOCAL_LIGHTING != 0
uniform usamplerBuffer u_Input17;
uint plagueLocalSourceWord(int word) { return texelFetch(u_Input17,word).r; }
int plagueLocalSourceSize() { return textureSize(u_Input17); }
#moj_import <fornax_runtime:voxel_local_light.glsl>
#endif

struct PlagueVoxelSurface {
    vec3 position;
    vec3 normal;
    vec3 geometricNormal;
    vec3 albedo;
    vec2 light;
    float ao;
    float emission;
    PlagueMaterial material;
};

bool plagueVoxelSurfaceAt(vec3 point, vec3 faceNormal, uint colour, int entry, vec3 local,
        out PlagueVoxelSurface surface) {
    surface.position = point;
    surface.normal = faceNormal;
    surface.geometricNormal = faceNormal;
    surface.ao = 1.0;
    vec4 material = vec4(0,0,0,1); // what the engine sends with no material map; alpha 255 means nobody wrote it
    uint flags = texelFetch(u_Input5,entry*16).r;
    // Low four bits count boxes, bit31 marks crossed planes. Test only those: the cutout and
    // extinction bits would send a cube with overlays to read its own dark inside.
    vec3 lightPoint = ((flags & 0x8000000fu) == 0u) ? point + faceNormal * PLAGUE_COVERAGE_EPSILON
            : point - faceNormal * PLAGUE_COVERAGE_EPSILON;
    if (!plagueVoxelLightAt(lightPoint,surface.light)) return false;
    vec2 uv; vec3 tintColour,tangent,bitangent;
    if (plagueVoxelFaceMapping(entry,local,faceNormal,uv,tintColour,tangent,bitangent)) {
        vec4 texel = textureLod(u_Input9,uv,0.0);
        // Same tint multiply as terrain.fsh, in linear space. On encoded RGB it shifts leaf hue.
        surface.albedo = plagueSrgbToLinear(texel.rgb) * plagueSrgbToLinear(tintColour);
        material = textureLod(u_Input13,uv,0.0);
        vec3 nTex = textureLod(u_Input12,uv,0.0).rgb;
        // labPBR's exact neutral byte128, same decode as parallax_terrain.glsl.
        vec2 xy = all(lessThan(nTex,vec3(0.003))) ? vec2(0.0)
                : (nTex.xy * (255.0/127.0) - (128.0/127.0)) * clamp(u_BumpStrength,0.0,2.0);
        surface.normal = normalize(tangent*xy.x + bitangent*xy.y
                + faceNormal*sqrt(max(1.0-dot(xy,xy),0.0)));
        surface.ao = mix(1.0,nTex.b,u_AOStrength);
    } else {
        if ((colour >> 24) == 0u) return false;
        surface.albedo = plagueSrgbToLinear(vec3((colour>>16)&255u,(colour>>8)&255u,colour&255u)/255.0);
    }
    surface.material = plagueDecodeMaterial(material.r,material.g,material.b);
    // Palette word15 holds the block's own glow. Block light falling on a surface is not glow.
    float intrinsic = float(texelFetch(u_Input5,entry*16+15).r & 255u)/255.0;
    surface.emission = plagueSourceLuminance(surface.albedo, intrinsic, material.a,
            u_AuthoredEmission);
    return true;
}

float plagueVoxelSurfaceShadow(vec3 point, vec3 normal, vec3 sunDir) {
#ifdef SHADOWS
    // The same surface and slope bias, and the same round projection, as the deferred pass.
    float slope = 1.0-abs(dot(normal,sunDir));
    vec3 biased = point + normal*(0.05+0.35*slope) + sunDir*0.05;
    vec4 clip = u_SunViewProj*vec4(biased,1.0);
    vec3 coord = clip.xyz/clip.w;
    float distortion = length(coord.xy)*u_ShadowMapParams.x+(1.0-u_ShadowMapParams.x);
    coord.xy = coord.xy/distortion*0.5+0.5;
    if (all(greaterThan(coord,vec3(0))) && all(lessThan(coord,vec3(1))))
        return texture(u_Input8,coord);
    // Past the shadow map, ask the grid what blocks the sun rather than guessing lit or dark.
    vec3 p,n,l; uint c; int e;
    float state = plagueVoxelTraceMaterial(point+normal*PLAGUE_COVERAGE_EPSILON,sunDir,p,n,c,e,l);
    return state == 5.0 ? 1.0 : 0.0;
#else
    return 1.0;
#endif
}

vec3 plagueVoxelSurfaceDirect(PlagueVoxelSurface surface, vec3 viewDir, vec3 sunDir,
        PlagueLighting lighting, PlagueSurfaceLighting colours, out vec3 specularAlbedo) {
    float shadow = plagueVoxelSurfaceShadow(surface.position,surface.geometricNormal,sunDir);
    PlagueBrdf brdf = plagueEvaluateBrdf(surface.material,surface.albedo,surface.normal,viewDir,sunDir);
    vec3 f0 = plagueMaterialF0(surface.material,surface.albedo);
    specularAlbedo = plagueEnvSpecularAlbedo(f0,clamp(dot(surface.normal,viewDir),0.0,1.0),
            sqrt(clamp(surface.material.alpha,0.0,1.0))) * step(vec3(0.5/255.0),f0);
    vec3 kD = (vec3(1)-specularAlbedo)*(1.0-surface.material.metalness);
    vec3 lightMult = vec3(1.0);
#ifdef LIGHT_COLOR_MULTS
    lightMult = plagueLightColorMult(lighting.noonFactor,lighting.sunVisibility2,lighting.rainFactor,
            vec3(u_LightMorningR,u_LightMorningG,u_LightMorningB)*u_LightMorningI,
            vec3(u_LightNoonR,u_LightNoonG,u_LightNoonB)*u_LightNoonI,
            vec3(u_LightNightR,u_LightNightG,u_LightNightB)*u_LightNightI,
            vec3(u_LightRainR,u_LightRainG,u_LightRainB)*u_LightRainI);
#endif
    float moon = plagueMoonPhaseInfluence(u_SkyCelestial.w,lighting.sunVisibility2);
    vec3 specular = brdf.specular*shadow*surface.light.y*colours.sunColour;
    float blockLight = surface.light.x;
    vec3 localRadiance = vec3(0.0);
    float localBlockLight = blockLight;
#if PLAGUE_LOCAL_LIGHTING != 0
    // The camera-column water height cannot classify a reflected surface (dry caves may be below
    // zero). Water reflection recovery already bypasses wet eyes; keep that same boundary here.
    if (u_WaterState.x >= 0.5
            || !plagueLocalLight(surface.position,surface.geometricNormal,surface.normal,viewDir,
                    surface.material,surface.albedo,localRadiance)) localRadiance=vec3(0.0);
#endif
    PlagueLitResult lit = plagueDoLighting(colours.sunColour,colours.ambientColour,
            surface.normal,sunDir,shadow,localBlockLight,surface.light.y,surface.ao,surface.emission,
            surface.albedo,specular,colours.blockLightColour,lighting.noonFactor,lighting.sunVisibility2,
            lighting.rainFactor,u_ScreenBrightness,moon,lightMult,-1.0,vec3(0));
    vec3 held = plagueHeldLighting(surface.position,u_HeldLight.x,u_HeldLight.y,colours.blockLightColour);
    vec3 diffuse = kD*surface.albedo*sqrt(max(lit.diffuse*lit.diffuse+held*held,vec3(0)));
    return (surface.emission>0.0 ? sqrt(max(diffuse*diffuse+lit.emitted*lit.emitted,vec3(0))) : diffuse)
            + lit.highlight*moon*moon + localRadiance;
}

// One extra bounce, so metals are not painted as diffuse. Four GGX samples is the work budget:
// roughness moves where they point, never how much light comes back. A rough sum, not path tracing.
vec3 plagueVoxelSurfaceReflection(PlagueVoxelSurface surface, vec3 viewDir, vec3 sunDir,
        vec3 sunDirTrue, PlagueSkyColors skyColours, PlagueLighting lighting,
        PlagueSurfaceLighting colours, vec3 atmColorMult, float renderDistance) {
    vec3 axis = abs(surface.normal.y) < abs(surface.normal.x) ? vec3(0,1,0) : vec3(1,0,0);
    vec3 tangent = normalize(cross(axis,surface.normal));
    vec3 bitangent = cross(surface.normal,tangent);
    vec3 sum = vec3(0); float weight = 0.0;
    for (int sampleIndex=0; sampleIndex<4; ++sampleIndex) {
        // GGX inverse CDF (Walter 2007). Sampling at midpoints keeps the two ends out of trouble.
        float u = (float(sampleIndex)+0.5)/4.0;
        float v = float((sampleIndex & 1)*2 + (sampleIndex >> 1))/4.0;
        float alpha2 = surface.material.alpha*surface.material.alpha;
        float cosine = sqrt((1.0-u)/(1.0+(alpha2-1.0)*u));
        float sine = sqrt(max(1.0-cosine*cosine,0.0));
        float phi = 2.0*PLAGUE_PI*v;
        vec3 halfway = tangent*(sine*cos(phi)) + bitangent*(sine*sin(phi)) + surface.normal*cosine;
        vec3 direction = reflect(-viewDir,halfway);
        float w = max(dot(surface.normal,direction),0.0);
        if (w<=0.0) continue;
        vec3 point,normal,local; uint colour; int entry;
        float state = plagueVoxelTraceMaterial(surface.position+surface.geometricNormal*PLAGUE_COVERAGE_EPSILON,
                direction,point,normal,colour,entry,local);
        vec3 incoming = vec3(0);
        if (state==1.0) {
            PlagueVoxelSurface secondary;
            if (plagueVoxelSurfaceAt(point,normal,colour,entry,local,secondary)) {
                vec3 unused;
                incoming = plagueVoxelSurfaceDirect(secondary,-direction,sunDir,lighting,colours,unused);
                incoming = plagueVoxelReflectionFog(incoming,surface.position,point,secondary.light.y,
                        lighting,atmColorMult,sunDirTrue,renderDistance);
            }
        } else if (state==5.0) {
            // Clear as far as the grid goes, no further. Waiting or bad data cannot open sky.
            incoming = plagueAtmoSkyView(direction,sunDirTrue,plagueAtmoCameraRadius()).rgb;
            incoming *= atmColorMult*colours.skyReflectionLift;
        }
        sum += incoming*w; weight += w;
    }
    return weight>0.0 ? sum/weight : vec3(0);
}
#endif
