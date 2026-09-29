#ifndef PLAGUE_VOXEL_SURFACE
#define PLAGUE_VOXEL_SURFACE
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:brdf.glsl>
#moj_import <fornax_runtime:env_brdf.glsl>
#moj_import <fornax_runtime:material_options.glsl>
#moj_import <fornax_runtime:voxel_lightmap.glsl>

#define PLAGUE_LOCAL_LIGHTING 0 //[0 1] compile "Local Coloured Light" {0="Off" 1="On"}
#ifndef PLAGUE_LOCAL_SHADOWS
#define PLAGUE_LOCAL_SHADOWS 0 //[0 1] compile "Traced Block Light" {0="Off" 1="On"}
#endif
#if PLAGUE_LOCAL_LIGHTING != 0 || (defined(PLAGUE_OPAQUE_REFLECTION) && PLAGUE_LOCAL_SHADOWS != 0)
uniform usamplerBuffer u_VoxelLocalRadiance;
uint plagueLocalSourceWord(int word) { return texelFetch(u_VoxelLocalRadiance,word).r; }
int plagueLocalSourceSize() { return textureSize(u_VoxelLocalRadiance); }
#moj_import <fornax_runtime:voxel_local_jitter.glsl>
#ifdef PLAGUE_OPAQUE_REFLECTION
// A world hit has no filtered screen visibility. Evaluate the existing finite source probes
// with its BRDF so a hidden lamp cannot shine through an opaque blocker in the recovered image.
#define PLAGUE_LOCAL_REFLECTED
#endif
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
    float coverage; // texel alpha: below 1 on glass, which the main view blends over what is behind
    PlagueMaterial material;
};

bool plagueVoxelSurfaceMapping(int entry, uint flags, vec3 local, vec3 normal,
        out vec2 uv, out vec3 tint, out vec3 tangent, out vec3 bitangent) {
    uv=vec2(0); tint=vec3(1); tangent=vec3(0); bitangent=vec3(0);
    vec3 lo=vec3(0), hi=vec3(1);
    int boxes=int(flags & 15u);
    bool crossed=(flags & 0x80000000u)!=0u;
    bool cutout=(flags & 0x40000000u)!=0u;
    // Palette words 7..14 hold eight boxes; cutouts reserve the last two for their sprite.
    if ((crossed && boxes!=1) || (cutout && boxes>6) || boxes>8) return false;
    bool found=boxes==0;
    for (int i=0; i<boxes; ++i) {
        uint packed=texelFetch(u_VoxelPalette,entry*16+7+i).r;
        vec3 a=vec3(packed&31u,(packed>>5)&31u,(packed>>10)&31u)/16.0;
        vec3 b=vec3((packed>>15)&31u,(packed>>20)&31u,(packed>>25)&31u)/16.0;
        if (any(lessThanEqual(b,a))) continue;
        vec3 boundary=mix(a,b,greaterThan(normal,vec3(0)));
        bool onFace=crossed || abs(dot(local-boundary,abs(normal)))<=PLAGUE_COVERAGE_EPSILON;
        if (onFace && all(greaterThanEqual(local,a-PLAGUE_COVERAGE_EPSILON))
                && all(lessThanEqual(local,b+PLAGUE_COVERAGE_EPSILON))) {
            lo=a; hi=b; found=true; break;
        }
    }
    if (!found) return false;
    if (crossed)
        return plagueVoxelCrossMapping(entry,local,normal,lo,hi,uv,tint,tangent,bitangent);
    // 0x21 admits the engine's legacy and explicit-boundary mappings only for material shading.
    return plagueVoxelBoundaryMapping(entry,local,normal,lo,hi,0x21u,uv,tint,tangent,bitangent);
}

bool plagueVoxelSurfaceAt(vec3 point, vec3 faceNormal, uint colour, int entry, vec3 local,
        out PlagueVoxelSurface surface) {
    surface.position = point;
    surface.normal = faceNormal;
    surface.geometricNormal = faceNormal;
    surface.ao = 1.0;
    surface.coverage = 1.0;
    vec4 material = vec4(0,0,0,1); // what the engine sends with no material map; alpha 255 means nobody wrote it
    uint flags = texelFetch(u_VoxelPalette,entry*16).r;
    // Low four bits count boxes, bit31 marks crossed planes. Test only those: the cutout and
    // extinction bits would send a cube with overlays to read its own dark inside.
    vec3 lightPoint = ((flags & 0x8000000fu) == 0u) ? point + faceNormal * PLAGUE_COVERAGE_EPSILON
            : point - faceNormal * PLAGUE_COVERAGE_EPSILON;
    if (!plagueVoxelLightAt(lightPoint,surface.light)) return false;
    vec2 uv; vec3 tintColour,tangent,bitangent;
    if (plagueVoxelSurfaceMapping(entry,flags,local,faceNormal,uv,tintColour,tangent,bitangent)) {
        vec4 texel = textureLod(u_Input9,uv,0.0);
        surface.coverage = texel.a;
        // Same tint multiply as terrain.fsh, in linear space. On encoded RGB it shifts leaf hue.
        surface.albedo = plagueSrgbToLinear(texel.rgb) * plagueSrgbToLinear(tintColour);
        material = textureLod(u_MaterialAtlas,uv,0.0);
        vec3 nTex = textureLod(u_NormalAtlas,uv,0.0).rgb;
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
    float intrinsic = float(texelFetch(u_VoxelPalette,entry*16+15).r & 255u)/255.0;
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
        return plagueShadowLookup(point, coord.xy, coord.z);
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
#if PLAGUE_LOCAL_LIGHTING != 0 || (defined(PLAGUE_OPAQUE_REFLECTION) && PLAGUE_LOCAL_SHADOWS != 0)
#ifdef PLAGUE_OPAQUE_REFLECTION
    localBlockLight = 0.0;
#endif
    vec3 reflectedUnshadowed;
    vec3 reflectedVisibility;
    // The camera-column water height cannot classify a reflected surface (dry caves may be below
    // zero). Water reflection recovery already bypasses wet eyes; keep that same boundary here.
    if (u_WaterState.x >= 0.5
            // A reflected surface has no screen-space neighbours to filter against, so it takes
            // the shaded answer whole and leaves the split to the primary view.
            // The middle of every quarter, with no dither. A reflected surface has no screen
            // neighbours to filter a dither against, and a derivative taken here would sit behind
            // this very branch, where it is not defined.
            || !plagueLocalLight(surface.position,surface.geometricNormal,surface.normal,viewDir,
                    surface.material,surface.albedo,vec2(0.5),localRadiance,reflectedUnshadowed,
                    reflectedVisibility)) localRadiance=vec3(0.0);
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

// Direct radiance along the final bounce. Alpha is coverage here, just as on the primary
// world ray; stopping at a fractional texel paints its pigment as a solid reflected object.
bool plagueVoxelSurfaceSecondary(vec3 origin, vec3 receiverNormal, vec3 direction, vec3 sunDir, vec3 sunDirTrue,
        PlagueLighting lighting, PlagueSurfaceLighting colours, vec3 atmColorMult,
        float renderDistance, out vec3 incoming) {
    incoming = vec3(0.0);
    float throughput = 1.0;
    vec3 traceOrigin = origin+receiverNormal*PLAGUE_COVERAGE_EPSILON;
    int previousEntry = -1;
    vec3 previousCell = vec3(0.0);
    bool previousFull = false;
    bool transmitted = false;
    int layers = 0;
    // A ray crosses at most the sum of the window's three 16*d axis extents. Interior joined
    // cells spend this geometric bound, not the primary path's four-surface shading budget.
    for (int stepIndex = 0; stepIndex < u_VoxelWindow.w * 48; ++stepIndex) {
        vec3 point,normal,local; uint colour; int entry;
        float state = plagueVoxelTraceMaterial(traceOrigin,direction,point,normal,colour,entry,local);
        if (state == 5.0) {
            incoming += throughput * (direction.y >= 0.0
                    ? plagueAtmoSkyView(direction,sunDirTrue,plagueAtmoCameraRadius()).rgb
                            * atmColorMult * colours.skyReflectionLift
                    : PLAGUE_ENV_GROUND * colours.ambientColour);
            return true;
        }
        // An unresolved continuation contributes only its known prefix, never invented sky.
        if (state != 1.0) return transmitted;
        uint flags = texelFetch(u_VoxelPalette,entry*16).r;
        bool full = (flags & 0xc000000fu) == 0u;
        vec3 cell = point-local;
        vec3 cellStep = abs(cell-previousCell);
        // Palette identity alone also matches separated panes. Require touching, face-adjacent
        // full cubes; the two nudges are the tracer's entry and this continuation's exit.
        bool joined = previousFull && full && entry == previousEntry
                && abs(dot(cellStep,vec3(1.0))-1.0) <= 2.0*PLAGUE_COVERAGE_EPSILON
                && length(point-traceOrigin) <= 2.0*PLAGUE_COVERAGE_EPSILON;
        if (!joined) {
            PlagueVoxelSurface secondary;
            if (!plagueVoxelSurfaceAt(point,normal,colour,entry,local,secondary)) return transmitted;
            // The trace already resolved cutout/cross alpha as binary coverage.
            float a = (flags & 0xc0000000u) != 0u ? 1.0 : clamp(secondary.coverage,0.0,1.0);
            if (a > 0.0) {
                if (layers >= 4) return transmitted;
                vec3 unused;
                vec3 shaded = plagueVoxelSurfaceDirect(secondary,-direction,sunDir,lighting,colours,unused);
                // Preserve the existing terminal-bounce environment floor for opaque metals.
                shaded = max(shaded,colours.ambientColour);
                shaded = plagueVoxelReflectionFog(shaded,origin,point,secondary.light.y,
                        lighting,atmColorMult,sunDirTrue,renderDistance);
                incoming += throughput*a*shaded;
                ++layers;
            }
            throughput *= 1.0-a;
            if (throughput <= 0.0) return true;
            transmitted = true;
        }
        previousEntry = entry;
        previousCell = cell;
        previousFull = full;
        float exitDistance = 1e30; // unbounded until the first unit-cell boundary
        for (int axis = 0; axis < 3; ++axis) {
            if (direction[axis] == 0.0) continue;
            exitDistance = min(exitDistance,
                    ((direction[axis] > 0.0 ? 1.0 : 0.0)-local[axis])/direction[axis]);
        }
        traceOrigin = point+direction*(max(exitDistance,0.0)+PLAGUE_COVERAGE_EPSILON);
    }
    return transmitted;
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
        // Weighted against the flat face, not the bump tilt: a corrugation ridge can slope up to
        // several tens of degrees, and gating on that normal instead of the geometric one zeroes
        // every one of the 4 samples at once on a steep facet, returning flat black for the whole
        // secondary bounce (metals have no diffuse term to fall back on).
        float w = max(dot(surface.geometricNormal,direction),0.0);
        if (w<=0.0) continue;
        vec3 incoming;
        bool answered = plagueVoxelSurfaceSecondary(
                surface.position,surface.geometricNormal,direction,sunDir,sunDirTrue,
                lighting,colours,atmColorMult,renderDistance,incoming);
        // A pending section, bad data, or a hit plagueVoxelSurfaceAt could not decode (states 3,
        // 4, 6, or a state-1 decode failure) is unanswered, not a measured zero. Folding it into
        // the average at full weight silently drags a real answer toward black; skip it instead,
        // the same as a sample the geometric gate above already rejected.
        if (!answered) continue;
        sum += incoming*w; weight += w;
    }
    if (weight>0.0) return sum/weight;
    // Every one of the 4 samples fell below the flat face at once (a true grazing facet, rare
    // with the weight gated on the flat face rather than the bump tilt): the same miss estimate the
    // loop above uses for state 5 (sky above the horizon, the tinted ground estimate below it),
    // instead of a black hole with no reflection at all.
    vec3 geometricMirror = reflect(-viewDir,surface.geometricNormal);
    if (geometricMirror.y >= 0.0) {
        return plagueAtmoSkyView(geometricMirror,sunDirTrue,plagueAtmoCameraRadius()).rgb
                *atmColorMult*colours.skyReflectionLift;
    }
    return PLAGUE_ENV_GROUND*colours.ambientColour;
}
#endif
