#version 330

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:brdf.glsl>
#moj_import <fornax_runtime:env_brdf.glsl>
#moj_import <fornax_runtime:atmosphere.glsl>
#moj_import <fornax_runtime:sky.glsl>
#define PLAGUE_ATMO_READS_SKYVIEW
#define PLAGUE_ATMO_READS_AERIAL
#moj_import <fornax_runtime:atmo_lut.glsl>
#moj_import <fornax_runtime:stars.glsl>
#moj_import <fornax_runtime:nebula.glsl>
#moj_import <fornax_runtime:shooting_stars.glsl>
#moj_import <fornax_runtime:celestials.glsl>
#moj_import <fornax_runtime:aurora.glsl>
#moj_import <fornax_runtime:main_lighting.glsl>
// After sky.glsl: fog colour calls plagueGetSky along the view ray. water_composite.fsh imports
// the same file.
#moj_import <fornax_runtime:fog.glsl>
#moj_import <fornax_runtime:fog_aerial.glsl>
#moj_import <fornax_runtime:ocean_caustics.glsl>
#moj_import <fornax_runtime:end_sky.glsl>
#moj_import <fornax_runtime:surface_lighting.glsl>

// Draws fog strength instead of the world, to check against tools/plague_atmo_lut.py. Declared
// here, not in fog_options.glsl: terrain.fsh imports that and is built with no options block.
#define u_FogOpacityView 0 //[0 1] runtime "Fog Opacity View" {0="Off" 1="On"}

uniform sampler2D u_Input0; // builtin.gNormal
#define G_NORMAL u_Input0
// A "consolidate" pass (graph.toml) packs three builtins into one sampler slot, one per array
// layer. See docs/PACK-FORMAT.md, "consolidate exists for the sampler budget".
uniform sampler2DArray u_Input1; // layer 0 = gAlbedo   (rgb albedo, a = sky light)
                                  // layer 1 = gMaterial (r = smoothness, g = F0, b = porosity/SSS, a = block light)
                                  // layer 2 = gAo       (r = per-texel AO, g = emission,
                                  //                      b = parallax self-shadow, a = surface class)
#define G_BUF u_Input1
uniform sampler2D u_Input2; // builtin.depth
#define G_DEPTH u_Input2
uniform sampler2D u_Input3; // builtin.lightmap, vanilla's own light-colour LUT
#define VANILLA_LIGHTMAP u_Input3
// Bound by the engine as a hardware COMPARISON sampler, so this must be sampler2DShadow: texture()
// returns the depth-test result, not the stored depth.
uniform sampler2DShadow u_Input4; // sunShadowMap
#define SUN_SHADOW_MAP u_Input4
uniform sampler2D u_Input5; // ssao. 1.0 unoccluded, 0.0 fully occluded
#define SSAO_TEX u_Input5

uniform sampler2D u_Input6; // builtin.gMotion, debug views only
#define G_MOTION u_Input6
uniform sampler2D u_Input7; // builtin.celestials, vanilla's sun + 8 moon-phase sprite atlas
#define CELESTIALS_ATLAS u_Input7
uniform sampler2D u_Input8; // builtin.noise, engine's 512x512 tileable RGBA noise (R smooth, B fbm)
#define NOISE_TEX u_Input8
// Level 0 is a texel-exact copy of `ssr`; higher mips are the environment convolved to roughness,
// see plagueReflectionLod.
uniform sampler2D u_Input9; // ssrPrefilter. rgb = reflected colour, a = hit confidence, mipped.
#define SSR_PREFILTER u_Input9
// Appended, not inserted: u_InputN is positional, so inserting one shifts every later binding.
uniform sampler2D u_Input10; // builtin.waterDepth. Reversed-Z, 0.0 = no water surface here.
#define WATER_DEPTH_TEX u_Input10
uniform sampler2D u_Input11; // causticsTexture
#define CAUSTICS_TEX u_Input11
// Aliases sunShadowMap to a plain sampler2D under a second target string (graph.toml):
// FullscreenPassRunner keys the comparison-sampler branch on that exact string, so this reads raw
// stored depth where SUN_SHADOW_MAP can only return a pass/fail compare.
uniform sampler2D u_Input12; // sunShadowMapRaw (raw, non-comparison. Debug only, see DBG_SHADOW_QUERY_3)
#define SUN_SHADOW_MAP_RAW u_Input12
uniform sampler2D u_Input13; // moonAlbedo, equirectangular, near side centred
#define MOON_ALBEDO u_Input13
uniform sampler2D u_Input14; // moonNormal, tangent-space relief for the same projection
#define MOON_NORMAL u_Input14
// cloudShadowMask, quarter scale. How much sun gets past the cloud: 1.0 full sun, less is shaded.
uniform sampler2D u_Input15;
#define CLOUD_SHADOW_MASK u_Input15
uniform sampler2D u_Input16; // atmoSkyView, the marched dome (atmo_lut.glsl); zero under Palette
#define ATMO_SKY_VIEW u_Input16

vec4 plagueAtmoFetchSkyView(vec2 uv) {
    return texture(ATMO_SKY_VIEW, uv);
}
uniform sampler2D u_Input17; // atmoAerial, in-scatter and transmittance per screen froxel; zero under Palette
#define ATMO_AERIAL u_Input17

vec4 plagueAtmoFetchAerial(vec2 uv) {
    return texture(ATMO_AERIAL, uv);
}

// Metal allows 16 samplers per fragment function, counting only the ones read.
// tools/check_metal_pipelines.py counts 14 here under Scattering, 12 under Palette. The debug-only
// reads below add 2, so Scattering with the views on sits right at the ceiling and any new input to
// this pass has to displace a read. Past the ceiling the pipeline refuses to build, with nothing in
// the log but a pipeline error.
//#define PLAGUE_DEBUG_VIEWS //[] compile "Motion and Shadow-Map Debug Views"

// Must follow NOISE_TEX: PLAGUE_CLOUD_NOISE expands inline where clouds.glsl calls it, so an
// earlier import would name NOISE_TEX before it exists. clouds.glsl also declares
// CLOUDS_VOLUMETRIC/u_CloudAltitude/u_CloudAmount/u_CloudSpeed/CLOUD_RESOLUTION, byte-identical to
// clouds_march.fsh (the option scanner merges same-name declarations).
#define PLAGUE_CLOUD_NOISE(uv) texture(NOISE_TEX, uv)
// The cloud-shadow query here cannot bind a real sampler3D: Vulkan's fullscreen-pipeline
// reflection step refuses any non-2D/Cube sampler, so only the compute march reads the real 3D
// volumes. This folds height into a 2D plagueSkyFbm instead: a rough stand-in, not a constant.
#define PLAGUE_CLOUD_NOISE_3D(uvw) vec4(plagueSkyFbm((uvw).xz + (uvw).y, 4))
#define PLAGUE_CLOUD_DETAIL_3D(uvw) vec4(plagueSkyFbm((uvw).xz * 3.0 + (uvw).y, 2))
#moj_import <fornax_runtime:clouds.glsl>

// Debug view selection arrives live from the engine (u_PassParams.u_Param3, a GBufferDebugView
// ordinal), not as a compile option. These ordinals must track GBufferDebugView's declaration order.
#define DBG_NORMALS     1
#define DBG_ALBEDO      2
#define DBG_MATERIAL    3
#define DBG_MOTION      4
#define DBG_SSAO        5
#define DBG_AO          7
#define DBG_BLOCK_LIGHT 8
#define DBG_RT_SHADOW  12
// Appended last: GBufferDebugView.java is a lockstep enum, so inserting mid-list shifts every
// later ordinal out from under each shader's branch numbers.
//
// Number carrier, not a picture: EnvSpecularRatioReadback.java (Fornax) reads fragColor back at
// the crosshair. Deep branch: it dispatches after the material/lighting decode, since its inputs
// do not exist in the early G-buffer block. Both caveats hold for every DBG_ENV_*/DBG_CONDUCTOR_*
// below.
#define DBG_ENV_SPEC_RATIO 21
// The terms the ratio is built from, split across ordinals since one vec4 cannot hold them all.
#define DBG_ENV_DECOMP_SKY 22
#define DBG_ENV_DECOMP_MIX 23
#define DBG_ENV_DECOMP_MAT 24
#define DBG_ENV_DECOMP_LOCAL 25
#define DBG_ENV_DECOMP_AO 26
#define DBG_ENV_DECOMP_RESIDUAL 27

// gAlbedo's raw byte and v_RawTint at runtime. Split across two ordinals: seven numbers do not fit
// two vec4s, and 29 needs terrain.fsh's u_AlbedoIdentityDebug while 28 does not.
#define DBG_ALBEDO_WRITE_VS_READ 28
#define DBG_ALBEDO_IDENTITY_INPUTS 29

// Number carrier, deep branch (see DBG_ENV_SPEC_RATIO). Reads the submerged-terrain branch, gated
// on fragSubmerged and not on the water mesh, so aim the crosshair at submerged ground. Reads
// 0,0,0,0 otherwise.
#define DBG_UW_CLOSURE 30

// Number carrier, deep branch (see DBG_ENV_SPEC_RATIO): these three do not exist until the SHADOWS
// block computes visibility()/ndotl/worldPos/sunDir. Aim the crosshair at the fragment in question.
#define DBG_SHADOW_QUERY_1 31
#define DBG_SHADOW_QUERY_2 32
#define DBG_SHADOW_QUERY_3 33

// Full-screen view of the shadow map's own contents, not a crosshair readback: splits "write-side"
// (caster absent from the map) from "read-side" (caster present, addressed wrong) in one look.
#define DBG_SHADOW_MAP_VIEW 40

// Seven number-carrier ordinals walking one pixel's specular chain: decoded F0, split-sum energy,
// mirror content, wide content and its trust, the environment term, the direct sun term, the final
// HDR value. Ids 68-74 continue GBufferDebugView's shaderId range (64-67 are the water shafts).
// Same caveats as DBG_ENV_SPEC_RATIO.
#define DBG_CONDUCTOR_F0 68
#define DBG_CONDUCTOR_ENERGY 69
#define DBG_CONDUCTOR_MIRROR 70
#define DBG_CONDUCTOR_WIDE 71
#define DBG_CONDUCTOR_ENV 72
#define DBG_CONDUCTOR_DIRECT 73
#define DBG_CONDUCTOR_LIT 74

// Declared here as well as in ssao.fsh, byte-identical (the loader requires that): without this
// line the #ifdef below never fires and SSAO is computed every frame and thrown away.
#define SSAO_ENABLED //[] compile "Ambient Occlusion"

#moj_import <fornax_runtime:material_options.glsl>
#moj_import <fornax_runtime:water_options.glsl>

// Read BY THE ENGINE, by name (ParticleEngineRainImpactMixin); nothing in this file consumes it.
// Vanilla's splash spawns on the tick path, not the weather render pass this replaces, so leaving
// it enabled doubles with this pack's own impact rings.
#define PACK_RAIN_IMPACTS //[] compile "Pack Rain Impacts"

// Scaled by each texel's labPBR POROSITY so porous stone soaks up and glazed terracotta barely
// changes. Driven by the engine's ACCUMULATED wetness (not instantaneous rain), so surfaces darken
// and dry gradually.
#define PLAGUE_WETNESS_PCT 75 //[0 25 50 75 100 125 150 200] compile "Wet Surfaces and Puddles" {0="Off" 25="Barely" 50="Damp" 75="Wet" 100="Very Wet" 125="Soaked" 150="Drenched" 200="Flooded"}

// SSR_QUALITY is declared byte-identically in ssr_trace.fsh, ssr_blur.fsh, terrain.fsh and the
// water shaders (option-scanner merge contract), and the ENGINE also reads this exact name to
// gate the water pre-pass.
#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="Fancy" 2="Fast"}
#define u_SsrStrength 1.15 //[0.0..1.5 step 0.05] runtime "Reflection Strength"

// The ENGINE reads this exact name to cancel vanilla's sky pass (GraphRunner.packOwnsSky). Off:
// vanilla's sky shows through and this shader discards those fragments.
#define SKY_PROCEDURAL //[] compile "Procedural Sky"

// Which dome the sky, the reflection probe and the screen-space miss sample: the five-key palette
// in sky.glsl, or the scattering tables in atmo_lut.glsl. Declared byte-identically in
// water_environment.fsh. Under Scattering the halo and sunset-band sliders do not reach the dome:
// the aureole is the aerosol's own forward lobe and the band is the air.
#define PLAGUE_SKY_MODEL 1 //[0 1] compile "Sky Model" {0="Palette" 1="Scattering"}

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    // Preferred over u_SkyCelestial: filled for every pack, where the globals sky block means
    // something only once a pack owns the sky. xyz is the active light (sun by day, moon once it
    // sets): right for shading, wrong for "is it day", since the moon at midnight sits where the
    // noon sun does. w is the TRUE sun elevation, positive only while the sun is up.
    vec4  u_SunDirection;

    // This frame's sun and moon sprite rects {u0, v0, u1, v1} in builtin.celestials. Minecraft 26.2
    // gives each moon phase its own atlas sprite, so a disc pass cannot work out the sub-region
    // itself; the engine hands it over via CelestialSprites. Widening this block to 64 bytes is
    // legal: the engine binds the whole u_PassParams buffer whatever a shader's block covers.
    // Zero-rect when the atlas was never captured, guarded at the draw site.
    vec4  u_SunSpriteRect;
    vec4  u_MoonSpriteRect;
};

// Manual bilinear: the engine binds every fullscreen-pass input NEAREST, but this 16x16 lookup
// table needs LINEAR (vanilla's own filtering) or the 16 discrete steps show as quad-outline seams.
vec3 sampleLightmap(sampler2D lut, vec2 uv) {
    vec2 size = vec2(textureSize(lut, 0));
    vec2 pos = uv * size - 0.5;
    vec2 f = fract(pos);
    vec2 base = (floor(pos) + 0.5) / size;
    vec2 texel = 1.0 / size;

    vec3 c00 = texture(lut, base).rgb;
    vec3 c10 = texture(lut, base + vec2(texel.x, 0.0)).rgb;
    vec3 c01 = texture(lut, base + vec2(0.0, texel.y)).rgb;
    vec3 c11 = texture(lut, base + texel).rgb;

    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

in vec2 texCoord;
out vec4 fragColor;

#ifdef SHADOWS
// Sun visibility at a camera-relative world position, 1.0 lit, 0.0 fully shadowed. The shadow map
// is written with a radial distortion (u_ShadowMapParams.x) that must be matched on read, or every
// off-centre sample lands on the wrong texel and shows up as acne.
//
// Trap: moving this into shadow.glsl as a wrapper turned every lit surface black. Suspected cause
// is a sampler2DShadow crossing a function-parameter boundary, a rough edge in some GLSL->SPIR-V
// lowering. Check in a running client, not just check_shaders.sh, before trying again.

// Golden-angle (Vogel) disk PCF, radius ~ (i/N)^p, with p and the per-count radius fitted against a
// committed fixture (tools/verify_shadow_filter.py re-checks it). Vogel 1979. Each sample is a
// +/-offset pair, halving noise for the same taps. Reads SUN_SHADOW_MAP as a global, for the same
// reason this function is kept inline.

// radius_i = diskRadius * (i / SHADOW_SAMPLES)^p. Fitted jointly across all four sample counts.
const float PLAGUE_SHADOW_RADIAL_EXPONENT = 1.266505;

// Disk outer radius per sample count, in (u_ShadowSoftness / SHADOW_RESOLUTION) texel units.
// Growing with N is expected: more rings reach further out for the same profile width.
#if SHADOW_SAMPLES == 2
const float PLAGUE_SHADOW_DISK_RADIUS = 1.358320;
#elif SHADOW_SAMPLES == 4
const float PLAGUE_SHADOW_DISK_RADIUS = 1.677305;
#elif SHADOW_SAMPLES == 8
const float PLAGUE_SHADOW_DISK_RADIUS = 1.942500;
#else // SHADOW_SAMPLES == 16
const float PLAGUE_SHADOW_DISK_RADIUS = 2.046826;
#endif

// Angular step between consecutive Vogel-disk taps: 2*pi * (1 - 1/phi).
const float PLAGUE_SHADOW_GOLDEN_ANGLE = 2.39996323;

const float PLAGUE_SHADOW_TWO_PI = 6.28318531;

// Wider than the sun-disc penumbra: a caster blocks the sky dome broadly, and the fill-light
// darkening needs a smooth signal or the sharp per-pixel visibility blotches it.
const float PLAGUE_SHADOW_AMBIENT_BROADEN = 4.0;

// Overcast rain is a larger, softer light source, so the penumbra widens with the square of rain
// intensity (matched to the fixture's recorded full-rain d-scale).
const float PLAGUE_SHADOW_RAIN_WIDEN_SCALE = 3.0;

// temporalNoise rotates the whole disk each frame (interleaved gradient noise stepped by the
// golden-ratio fraction, Jimenez 2014), so the rotation spreads evenly around the circle over many
// frames (Weyl equidistribution): the condition the radii above were fitted under.
float plagueSunVisibilityFiltered(vec2 shadowUv, float refDepth, float texelScale,
                                  float temporalNoise, float rainFactor) {
    float rainScale = 1.0 + (PLAGUE_SHADOW_RAIN_WIDEN_SCALE - 1.0) * rainFactor * rainFactor;
    float diskRadiusTexels = PLAGUE_SHADOW_DISK_RADIUS * rainScale;
    float frameAngle = temporalNoise * PLAGUE_SHADOW_TWO_PI;

    float visSum = 0.0;
    for (int i = 1; i <= SHADOW_SAMPLES; ++i) {
        float t = float(i) / float(SHADOW_SAMPLES);
        float radius = diskRadiusTexels * pow(t, PLAGUE_SHADOW_RADIAL_EXPONENT);
        float angle = float(i) * PLAGUE_SHADOW_GOLDEN_ANGLE + frameAngle;

        vec2 offset = vec2(cos(angle), sin(angle)) * radius * texelScale;

        visSum += texture(SUN_SHADOW_MAP, vec3(shadowUv + offset, refDepth));
        visSum += texture(SUN_SHADOW_MAP, vec3(shadowUv - offset, refDepth));
    }

    return visSum / float(2 * SHADOW_SAMPLES);
}

float sunVisibilityAt(vec3 worldPos, vec3 normal, vec3 sunDir, float rainFactorForShadow,
                      float radiusScale) {
    // Offset along the normal before projecting. Depth bias alone cannot fix acne on surfaces
    // near-parallel to the light: the bias needed there runs to infinity, where a normal offset
    // stays bounded and scales with texel size.
    float slope = 1.0 - abs(dot(normal, sunDir));
    vec3 biased = worldPos + normal * (0.05 + 0.35 * slope);

    // On top of the normal offset, not instead of it: that offset moves the compared depth by
    // dot(normal, sunDir), which goes to zero at grazing angles, exactly where slope above is
    // largest. sunDir is unit length, so this term does not depend on angle and covers the gap.
    biased += sunDir * 0.05;

    vec4 lightClip = u_SunViewProj * vec4(biased, 1.0);
    vec3 lightNdc = lightClip.xyz / lightClip.w;

    float radius = length(lightNdc.xy);
    float distortFactor = radius * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    vec2 shadowUv = (lightNdc.xy / distortFactor) * 0.5 + 0.5;

    float rawDepth = lightNdc.z;
    if (shadowUv.x <= 0.0 || shadowUv.x >= 1.0 || shadowUv.y <= 0.0 || shadowUv.y >= 1.0
            || rawDepth <= 0.0 || rawDepth >= 1.0) {
        return 1.0; // outside the map: unshadowed rather than guessing
    }
    // The write side stores gl_Position.z unscaled, so no conversion sits between the two.
    float refDepth = rawDepth;

    // Interleaved gradient noise (Jimenez 2014), advanced per frame by the golden-ratio fraction so
    // TAA resolves the dither into a smooth penumbra instead of a repeating pattern. Frame counter
    // wrapped at 4096 to stay inside float precision; dense enough to be invisible.
    float gradientNoise = fract(52.9829189 * fract(0.06711056 * gl_FragCoord.x
                                                   + 0.00583715 * gl_FragCoord.y));
    const float goldenRatioFrac = 0.61803398875;
    float temporalNoise = fract(gradientNoise + goldenRatioFrac * mod(u_FrameState.x, 4096.0));

    // Divides by SHADOW_RESOLUTION, not a literal 2048.0: the map does resize, and a constant
    // would detach softness from texel size at 1024/4096.
    float texelScale = (u_ShadowSoftness / float(SHADOW_RESOLUTION)) * radiusScale;

    return plagueSunVisibilityFiltered(shadowUv, refDepth, texelScale, temporalNoise,
                                       rainFactorForShadow);
}

float sunVisibility(vec3 worldPos, vec3 normal, vec3 sunDir, float rainFactorForShadow) {
    return sunVisibilityAt(worldPos, normal, sunDir, rainFactorForShadow, 1.0);
}

#if WATER_CAUSTICS
// One-tap visibility for water-volume samples. Unlike sunVisibility(), a position outside the
// covered shadow volume reads dark rather than inventing sunlight.
float plagueWaterSunVisibility(vec3 worldPos, vec3 sunDir) {
    vec3 biased = worldPos + sunDir * 0.08;
    vec4 lightClip = u_SunViewProj * vec4(biased, 1.0);
    vec3 lightNdc = lightClip.xyz / max(lightClip.w, 1e-6);

    float radius = length(lightNdc.xy);
    float distortFactor = radius * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    vec2 shadowUv = (lightNdc.xy / distortFactor) * 0.5 + 0.5;
    if (shadowUv.x <= 0.0 || shadowUv.x >= 1.0 || shadowUv.y <= 0.0 || shadowUv.y >= 1.0
            || lightNdc.z <= 0.0 || lightNdc.z >= 1.0) {
        return 0.0; // volumetrics outside the covered shadow volume must not invent sunlight
    }
    return texture(SUN_SHADOW_MAP, vec3(shadowUv, lightNdc.z));
}
#endif
#endif

#if PLAGUE_UNDERWATER && WATER_SUN_TINT
// Turns caustic focus (`pattern`, 0 unfocused, 1 full focus) into a sun-colour tint: Beer-Lambert
// absorption along the in-water path, red dying fastest and blue slowest (Mobley 1994 ch. 3; Pope
// & Fry 1997 absorption spectrum). Two terms per channel: GLOW grows as pattern^0.75 over the
// whole range, since weak focus still gathers light; CORE stays at zero until a per-channel
// threshold (blue lowest, red highest, matching blue's longer reach) then grows as
// (pattern - threshold)^~1.75, the exponent above 1 keeping the join smooth. The levels, blue's
// above-1 peak included, restore the caustic swing this pack's display pipeline would otherwise
// squash; fitted by tools/fit_uw_sun_tint_parity.py against the committed fixture.
const float PLAGUE_UW_SUN_GLOW_EXPONENT = 0.75;
const vec3 PLAGUE_UW_SUN_GLOW_AMPLITUDE = vec3(0.1422373, 0.23921368, 0.51084074);

const vec3 PLAGUE_UW_SUN_CORE_THRESHOLD = vec3(0.19582903, 0.09963111, 0.03660827);
const vec3 PLAGUE_UW_SUN_CORE_AMPLITUDE = vec3(0.12392300, 0.41866890, 2.44904798);
const vec3 PLAGUE_UW_SUN_CORE_EXPONENT  = vec3(1.78380639, 1.75960677, 1.74949274);

vec3 plagueUnderwaterSunTint(float pattern) {
    vec3 p3 = vec3(pattern);

    vec3 glow = PLAGUE_UW_SUN_GLOW_AMPLITUDE * pow(p3, vec3(PLAGUE_UW_SUN_GLOW_EXPONENT));

    vec3 coreInput = max(p3 - PLAGUE_UW_SUN_CORE_THRESHOLD, 0.0);
    vec3 core = PLAGUE_UW_SUN_CORE_AMPLITUDE * pow(coreInput, PLAGUE_UW_SUN_CORE_EXPONENT);

    return glow + core;
}
#endif

void main() {
    // Reversed-Z: the buffer clears to 0.0 = far, so depth zero means nothing was drawn here. Let
    // vanilla's sky show through rather than painting over it when this pack does not own the sky.
    float depth = texture(G_DEPTH, texCoord).r;

    vec4 normalSample = texture(G_NORMAL, texCoord);
    vec4 albedoSample = texture(G_BUF, vec3(texCoord, 0.0));

int debugView = int(u_Param3 + 0.5);
    if (debugView != 0) {
        if (debugView == DBG_NORMALS)  { fragColor = vec4(normalSample.xyz * 0.5 + 0.5, 1.0); return; }
        if (debugView == DBG_ALBEDO)   { fragColor = vec4(albedoSample.rgb, 1.0); return; }
        if (debugView == DBG_MATERIAL) { fragColor = vec4(texture(G_BUF, vec3(texCoord, 1.0)).rgb, 1.0); return; }
#ifdef PLAGUE_DEBUG_VIEWS
        if (debugView == DBG_MOTION)   { fragColor = vec4(abs(texture(G_MOTION, texCoord).rg) * 40.0, 0.0, 1.0); return; }
#endif
        if (debugView == DBG_SSAO)     { fragColor = vec4(vec3(texture(SSAO_TEX, texCoord).r), 1.0); return; }
        if (debugView == DBG_AO)       { fragColor = vec4(vec3(texture(G_BUF, vec3(texCoord, 2.0)).r), 1.0); return; }
        if (debugView == DBG_RT_SHADOW) {
            // Sun visibility alone: white lit, black shadowed. Isolates the shadow map from the
            // lightmap/ambient, which can mask a missing caster in the lit image.
#ifdef SHADOWS
            vec4 dbgClip = vec4(texCoord * 2.0 - 1.0, depth, 1.0);
            vec4 dbgWorldH = u_InvProjModelView * dbgClip;
            vec3 dbgWorld = dbgWorldH.xyz / dbgWorldH.w;
            vec3 dbgN = normalSample.xyz;
            vec3 dbgNormal = dot(dbgN, dbgN) > 1e-6 ? normalize(dbgN) : vec3(0.0, 1.0, 0.0);
            vec3 dbgS = u_SunDirection.xyz;
            vec3 dbgSun = dot(dbgS, dbgS) > 1e-6 ? normalize(dbgS) : normalize(vec3(0.3, 0.9, 0.2));
            fragColor = vec4(vec3(sunVisibility(dbgWorld, dbgNormal, dbgSun, clamp(u_SkyState.x, 0.0, 1.0))), 1.0);
#else
            fragColor = vec4(1.0);
#endif
            return;
        }
        if (debugView == DBG_SHADOW_MAP_VIEW) {
            // texCoord is the shadow map's own UV: this is the light's view, so a caster's outline
            // here does not line up with where it sits on screen.
            //
            // No linearization: ShadowCamera is orthographic (setOrtho), so the stored value is
            // already linear. Forward-Z, clear = 1.0.
            //
            // Remapped to be readable: real geometry measures into about the bottom fifth of the
            // range (SHADOW_MAP_VIEW_OCCUPIED, measured; retune if ShadowCamera.java's
            // depthHalfExtent changes), and a plain ramp would crush every caster near black. The
            // clear value gets its own colour so "nothing drawn" cannot read as "far geometry".
#ifdef SHADOWS
            const float SHADOW_MAP_VIEW_OCCUPIED = 0.2;
            const vec3 SHADOW_MAP_VIEW_CLEAR_COLOR = vec3(1.0, 0.0, 0.7);
#ifdef PLAGUE_DEBUG_VIEWS
            ivec2 dbgShadowMapTexel = ivec2(texCoord * vec2(textureSize(SUN_SHADOW_MAP_RAW, 0)));
            float dbgShadowMapDepth = texelFetch(SUN_SHADOW_MAP_RAW, dbgShadowMapTexel, 0).r;
#else
            // Without the raw shadow-map read compiled in, the view shows its clear sentinel.
            float dbgShadowMapDepth = 1.0;
#endif
            if (dbgShadowMapDepth >= 0.999) {
                fragColor = vec4(SHADOW_MAP_VIEW_CLEAR_COLOR, 1.0);
            } else {
                float dbgShadowMapRescaled = clamp(dbgShadowMapDepth / SHADOW_MAP_VIEW_OCCUPIED, 0.0, 1.0);
                fragColor = vec4(vec3(dbgShadowMapRescaled), 1.0);
            }
#else
            fragColor = vec4(1.0);
#endif
            return;
        }
        if (debugView == DBG_BLOCK_LIGHT) {
            fragColor = vec4(vec3(texture(G_BUF, vec3(texCoord, 1.0)).a), 1.0);
            return;
        }
    }

    // --- Time-of-day drivers and light colours ----------------------------------------------------
    //
    // Computed before the sky: the sky is a function of these same values, so the dome and the
    // ground light under it can never disagree about the time of day.
    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);

    // u_SunDirection.xyz is the active light, which reads as "sun overhead" at midnight. .w is the
    // true sun elevation, so it answers "is it day".
    float trueSunHeight = u_SunDirection.w;
    // Below the horizon the sun contributes nothing, with a soft edge so dusk is not a hard switch.
    float dayFactor = smoothstep(-0.08, 0.08, trueSunHeight);

    // u_SkyColor.rgb is filled for every pack (Fornax's SkyProbe), unlike u_SkyCelestial, which
    // needs sky ownership. Clamped: vanilla's sky colour nears zero in a thunderstorm and pow() of
    // a negative is NaN. Built whatever CUSTOM_LIGHT_COLORS selects, since callers read
    // .light/.ambient either way.
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
    PlagueLighting lighting = plagueOverworldLighting(
            max(u_SkyColor.rgb, vec3(0.0)),
            trueSunHeight,
            u_SkyState.y,
            rainFactor,
            u_ScreenBrightness,
            palette);

    vec3 sunDirTrue = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
    PlagueSkyColors skyColours = plagueSkyColors(max(u_SkyColor.rgb, vec3(0.0)),
            sunDirTrue, lighting.sunVisibility, rainFactor, u_CameraAbs.y);
    float plagueSunVisibility = lighting.sunVisibility;
    float plagueSunFactor = lighting.sunFactor;
    float plagueNightFactor = lighting.nightFactor;

    // Computed before the sky branch, which returns before the fog block runs, so the dome, the
    // haze and the fog border all grade off one value. Every plagueGetSky caller here reads it.
    vec3 atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
            vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
            vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
            vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif
    // --- Sky ---------------------------------------------------------------------------------------
    //
    // Reversed-Z: depth clears to 0.0 = far, so depth zero means nothing was drawn here. With
    // SKY_PROCEDURAL the engine cancels vanilla's sky pass and this paints the dome in its place.
    if (depth <= 0.0) {
#ifdef SKY_PROCEDURAL
        // Unprojects at a far but finite depth (0.0001, reversed-Z), not the true far plane (0.0,
        // where posH.w is 0). Unprojecting near the eye would turn Minecraft's view-bob translation
        // (it rides in the projection matrix) into a large false rotation of the ray; far keeps
        // that translation small against the distance, leaving the real ~0.25 degree bob. Same
        // constant as motion_fill.fsh's SKY_PROXY_DEPTH.
        vec4 skyClip = vec4(texCoord * 2.0 - 1.0, 0.0001, 1.0);
        vec4 skyWorldH = u_InvProjModelView * skyClip;
        vec3 viewRay = normalize(skyWorldH.xyz / skyWorldH.w);

        // Against the true sun, not the active light: the warm band and glare stay on the sun's
        // side of the sky after the moon takes over.
        float skyDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));

        vec3 skyOut;
        vec3 auroraTerm = vec3(0.0);

#if PLAGUE_UNDERWATER
        // A submerged no-hit ray is a water ray at full length, not a sky ray to paint over: it
        // takes the water path instead of building and throwing away the dome and everything on it.
        if (u_WaterState.x > 0.5) {
            float uwRenDis = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0);
            // Same darkening the geometry and closed-volume veils take; all three sites must agree
            // or the disagreement shows as a seam where they meet.
            vec3 uwVeil = plagueWaterFogColor(lighting)
                        * plagueWaterVeilDarkness(viewRay * uwRenDis,
                                                  plagueChunksToBlocks(u_WaterDistanceFog),
                                                  plagueChunksToBlocks(u_WaterDarknessDepth),
                                                  u_WaterDistanceDarkness, u_WaterDepthDarkness)
                        * plagueAuthoredToLinear(
                              plagueUnderwaterMult(uwRenDis, uwRenDis, u_DepthDarkness, lighting, vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB))
                                      * 0.85);
            skyOut = plagueUnderwaterClosedRadiance(viewRay, uwVeil, lighting.sunFactor,
                                                    plagueChunksToBlocks(u_WaterDistanceFog));

        } else
#endif
        {
            float VdotU = viewRay.y;
            float VdotS = dot(viewRay, sunDirTrue);

            // Graded so the dome agrees with the haze and border fog it fades into; all three read
            // atmColorMult. The additive stars/nebula/discs/aurora below are light sources, not
            // haze, and stay ungraded. nightGate is how much of that night sky shows: under the
            // marched dome it rides the sun's elevation through twilight (atmo_lut.glsl), so stars
            // wait for the sky to darken rather than for the palette's night factor.
            float nightGate = 1.0;
#if PLAGUE_SKY_MODEL == 1
            // The tables assume an overhead sun and a Rayleigh atmosphere; the Nether has neither,
            // so an ungated sample paints Overworld daylight through every gap in its ceiling.
            // u_FogColor is vanilla's per-dimension fog tint and stands in until the atmosphere
            // carries a real per-dimension aerosol profile. No stars either: nightGate goes to 0.
            if (u_WorldBounds.w == 2.0) {
                skyOut = u_FogColor.rgb * atmColorMult;
                nightGate = 0.0;
            } else if (u_WorldBounds.w == 3.0) {
                // The End lights itself; see end_sky.glsl. No stars either: its clock is frozen, so
                // nightGate would hold one value for ever.
                skyOut = plagueEndSky(viewRay, plagueEndSkyLevel()) * atmColorMult;
                nightGate = 0.0;
                skyOut = max(skyOut + (skyDither - 0.5) / 128.0, vec3(0.0));
            } else {
                // One table read, dithered like plagueGetSky: a smooth gradient is where banding
                // shows first. Warmed by the pack's sunset band (sky.glsl) before atmColorMult: a
                // clear physical sky goes white well before it goes dark, since the reddened light
                // that colours it sits in a shrinking band near the sun.
                vec3 skyPhysical = plagueAtmoSkyView(viewRay, sunDirTrue, plagueAtmoCameraRadius()).rgb;
                skyPhysical = plagueWarmSkyBand(skyPhysical, VdotU, VdotS, sunDirTrue.y);
                skyPhysical = plagueStormDarkenSky(skyPhysical, VdotU, VdotS, sunDirTrue.y,
                                                   rainFactor, clamp(u_FrameState.z, 0.0, 1.0));
                skyOut = skyPhysical * atmColorMult;
                nightGate = plagueAtmoNightGate(sunDirTrue.y);
                skyOut = max(skyOut + (skyDither - 0.5) / 128.0, vec3(0.0));
            }
#else
            // Same two dimensions the scattering arm gates, for the same reason: the palette is an
            // Overworld sky and neither of these has one.
            if (u_WorldBounds.w == 2.0) {
                skyOut = u_FogColor.rgb * atmColorMult;
            } else if (u_WorldBounds.w == 3.0) {
                skyOut = plagueEndSky(viewRay, plagueEndSkyLevel()) * atmColorMult;
            } else {
                skyOut = plagueGetSky(skyColours, VdotU, VdotS, skyDither, true, false)
                       * atmColorMult;
            }
#endif

            // Additive, not blended: stars are emitters seen through the atmosphere, so a bright
            // sky washes them out via the day/night term inside plagueGetStars.
            float invNoonFactor = 1.0 - lighting.noonFactor;
            float syncedTime = u_SkyState.w * 0.05;
            vec2 starCoord = plagueStarCoord(viewRay, PLAGUE_STAR_SPHERENESS, syncedTime);
            skyOut += plagueGetStars(starCoord, VdotU, VdotS, 1.0, 0.0,
                                     invNoonFactor * invNoonFactor,
                                     plagueSunVisibility, 1.0 - rainFactor, u_SunriseColor.w) * nightGate;

            // Own coords (sphereness 0.75, not the star field's 0.5); order against stars is free.
            if (u_WorldBounds.w == 3.0) {
                // The End's own cloud. Every gate the Overworld one uses is dead here: no night, no
                // rain, no clock. It rides the same path length the sky does, so it is thickest
                // where the medium is and the two read as one thing. Its cores burn the violet
                // pair, not oxygen's green; see nebula.glsl.
                float endDepth = plagueEndPathLength(clamp(viewRay.y, -1.0, 1.0));
                float endFullDepth = PLAGUE_END_REACH / PLAGUE_END_SLAB_HALF;
                float endVisible = clamp(endDepth / endFullDepth, 0.0, 1.0);
                PlagueNebulaTuning endTune = PlagueNebulaTuning(
                        u_EndNebulaIntensity, u_EndNebulaZoom, u_EndNebulaAmount,
                        u_EndNebulaCoreOnset, u_EndNebulaCoreWidth, u_EndNebulaDrift,
                        u_EndNebulaStarGlow);
                skyOut += plagueGetNebulaField(plagueEndTurn(viewRay), endVisible, VdotS,
                                               syncedTime, PLAGUE_NEBULA_H_GAMMA,
                                               plagueEndSkyLevel(), endTune);
            } else {
                skyOut += plagueGetNightNebula(viewRay, VdotU, VdotS, syncedTime,
                                               plagueNightFactor, 1.0 - rainFactor,
                                               u_SunriseColor.w) * nightGate;
            }

            // Reuses starCoord so meteors travel the stars' own plane. u_SkyCelestial.w is the moon
            // phase: a new moon lets more through. u_WorldClock.x/.y pick tonight's pattern and are
            // passed separately, never summed; see plagueGetShootingStars.
            skyOut += plagueGetShootingStars(starCoord, VdotU, VdotS, syncedTime,
                                             u_WorldClock.x, u_WorldClock.y,
                                             invNoonFactor * invNoonFactor, plagueSunVisibility,
                                             1.0 - rainFactor, u_SunriseColor.w, u_SkyCelestial.w) * nightGate;

            // --- Sun and moon discs -------------------------------------------------------------
            //
            // Drawn from the real celestials atlas, so a resource pack's own sun and moon art keeps
            // working. SKY_PROCEDURAL cancels vanilla's own draw of these. Moon visibility rides
            // the moon's own elevation (-trueSunDir), not nightFactor, so it stays up whenever it
            // is above the horizon.
            float plagueMoonDiscGlow = smoothstep(-0.03, 0.08, -sunDirTrue.y)
                                      * (1.0 - plagueSunVisibility);
            // Same radiances the world is lit by, so the disc and its shadows agree about colour
            // and it reddens through sunset. plagueSunColor clamps its own light loss at the
            // horizon (atmosphere.glsl), so nothing upstream dims the disc once it sets and it
            // would sit at full brightness on the water after the sky went dark. Faded out over the
            // 0.833 degrees that define sunset: 34 arcmin of horizontal refraction plus the sun's
            // own 16 arcmin radius.
            vec3 discEyePos = plagueAirEyePos(u_CameraAbs.y);
            // Nothing in the sky in the End: the clock is frozen, so the gate below would hold open
            // for ever on a disc vanilla never draws there.
            float dimensionDiscGate = u_WorldBounds.w == 3.0 ? 0.0 : 1.0;
            float sunSetGate = smoothstep(-0.014535, 0.0, sunDirTrue.y) * dimensionDiscGate;
            skyOut += plagueCelestialDiscs(viewRay, sunDirTrue, u_SkyCelestial.w,
                                           u_WorldClock.x, u_WorldClock.y,
                                           MOON_ALBEDO, MOON_NORMAL,
                                           1.0 - rainFactor, plagueMoonDiscGlow,
                                           plagueSunColor(discEyePos, sunDirTrue) * sunSetGate,
                                           plagueMoonColor(discEyePos, -sunDirTrue)
                                                   * dimensionDiscGate);

            // Marches the flattened view ray, so it's the only sky element with a real cost curve;
            // gated to zero for daylight, rain, and anything but a full moon by default.
            if (u_WorldBounds.w == 3.0) {
                // Curtains reach higher here than an aurora. An aurora sits in a shell overhead and
                // thins toward the zenith; these fronts are in the same medium the camera is in, so
                // they run most of the way up the sky.
                float stormVisible = clamp(VdotU / max(u_EndStormReach, 0.05), 0.0, 1.0);
                // The storm sits over the middle island. Out in the outer islands it falls behind,
                // on top of the dimming the whole sky gets there.
                float endStormPlace = mix(1.0, 1.0 - clamp(u_EndOuterStormFade, 0.0, 1.0),
                                          plagueEndOuterFactor());
                PlagueCurtainTuning endStorm = PlagueCurtainTuning(
                        PLAGUE_END_STORM_LOW, PLAGUE_END_STORM_BODY, PLAGUE_END_STORM_HIGH,
                        u_EndStormSize,
                        u_EndStormIntensity * plagueEndSkyLevel() * endStormPlace,
                        0.18, 0.62, 0.30, u_EndStormSurge);
                auroraTerm = plagueMarchCurtains(plagueEndTurn(viewRay), stormVisible, skyDither,
                                                 u_CameraAbs.xz, syncedTime, NOISE_TEX, endStorm);
            } else {
                auroraTerm = plagueGetAurora(viewRay, VdotU, skyDither, u_CameraAbs.xz, syncedTime,
                                             plagueSunVisibility, rainFactor, u_SkyCelestial.w,
                                             NOISE_TEX) * nightGate;
            }
            skyOut += auroraTerm;
        }

#ifdef PLAGUE_DEBUG_AURORA_ONLY
        // See aurora.glsl: isolates the march from everything drawn over it.
        fragColor = vec4(auroraTerm * u_AuroraDebugGain, 1.0);
#else
        fragColor = vec4(skyOut, 1.0);
#endif
#else
        // Pack does not own the sky: keep vanilla's.
        discard;
#endif
        return;
    }

    // gAlbedo holds a display-encoded byte: the geometry stages decode their texture sample,
    // multiply by vertex colour/tint/shade, then re-encode (decode(tex*k) != decode(tex)*k for
    // sRGB). This is the one place that recovers linear reflectance. gMaterial/gAo/gNormal and .a
    // (sky light, not colour) are plain data and must not be decoded.
    vec3 albedo    = plagueSrgbToLinear(albedoSample.rgb);
    float skyLight = albedoSample.a;

    // normalize() of a zero-length vector is NaN, which survives max()/multiplication/the final
    // write, so an unpopulated uniform would silently black out the whole frame with no error.
    vec3 n = normalSample.xyz;
    vec3 normal = dot(n, n) > 1e-6 ? normalize(n) : vec3(0.0, 1.0, 0.0);

    vec3 s = u_SunDirection.xyz;
    vec3 sunDir = dot(s, s) > 1e-6 ? normalize(s) : normalize(vec3(0.3, 0.9, 0.2));

    float ndotl = max(dot(normal, sunDir), 0.0);

    // gMaterial.a packs block light and intrinsic emission as two 4-bit nibbles, matching
    // Minecraft's own light-level precision.
    float blockLight = texture(G_BUF, vec3(texCoord, 1.0)).a;

    // Emitter luminance, 0..1: gAo is RGBA8_UNORM, so PLAGUE_EMISSION_MAGNITUDE is applied later in
    // plagueEmittedRadiance, whose saturation ramp needs the unscaled value.
    float emitterLum = texture(G_BUF, vec3(texCoord, 2.0)).g;   // gAo.g

    // Block light uses this pack's own curve and colour (main_lighting.glsl), not vanilla's
    // lightmap. sampleLightmap() is unused, kept for the engine's binding.

    // Per-texel AO (labPBR _n blue) darkens indirect light only: applying it to direct sun would
    // double-darken surfaces the sun can plainly see.
    float ao = texture(G_BUF, vec3(texCoord, 2.0)).r;
    // Parallax self-shadow occludes direct sun, so it multiplies the shadow term rather than AO: it
    // must survive full daylight, where crevice shadow reads strongest.
    float pomShadow = texture(G_BUF, vec3(texCoord, 2.0)).b;   // gAo.b

#ifdef SSAO_ENABLED
    // Multiplies the per-texel labPBR AO rather than replacing it: different scales (surface detail
    // vs scene geometry), both real.
    ao *= texture(SSAO_TEX, texCoord).r;
#endif

    // Outside the shadow block: the specular term below needs worldPos whether or not SHADOWS is
    // compiled in.
    vec4 clip = vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec4 worldH = u_InvProjModelView * clip;
    vec3 worldPos = worldH.xyz / worldH.w;

#if PLAGUE_UNDERWATER
    // Distance to the water surface on this pixel's ray, or 1e9 if it crosses none. Shared by the
    // caustic submersion gate and the fog site's in-water leg below.
    float uwSurfDist = 1e9;
    float uwSurfWorldY = -1e9;
    {
        float uwSurfDepth = texelFetch(WATER_DEPTH_TEX, ivec2(gl_FragCoord.xy), 0).r;
        if (uwSurfDepth > 0.0) {
            vec4 uwSurfH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, uwSurfDepth, 1.0);
            vec3 uwSurfPos = uwSurfH.xyz / uwSurfH.w;
            uwSurfDist = length(uwSurfPos);
            uwSurfWorldY = u_CameraAbs.y + uwSurfPos.y;
        }
    }
    // Consumed by sunColour; identity on every dry path. Declared here, not in the caustic block,
    // so the SHADOWS-off build, which leaves the whole builder out, keeps it defined.
    vec3 uwSunTint = vec3(1.0);
    // Added to the lit scene before fog; 0 on every dry/gated path.
    float uwWeb = 0.0;
    // Separate from the web itself so bloom can be tuned without changing caustic light output.
    float uwWebBloom = 0.0;
    // Narrow by construction (smoothstep(0.52,0.90) squared): lifts filament cores past display
    // white without touching the body.
    float uwWebHot = 0.0;

    // Submerged: from in the water, everything nearer than the surface is in the volume; from dry
    // air, everything past it. Both arms also require the fragment below the crossing, since a ray
    // crossing an inlet or a wave crest can carry on to dry terrain above the waterline.
    float uwFragDist = length(worldPos);
    float uwDirY = worldPos.y / max(uwFragDist, 1e-4);
    float uwFragWorldY = u_CameraAbs.y + worldPos.y;
    // The dry-eye test uses this pixel's own surface crossing, not u_WaterState.z: that global is
    // scanned in the camera's column alone, so it misses water beside an island camera.
    //
    // uwNearWaterlineFallback covers the prepass missing a surface at the bobbing waterline
    // (uwSurfDist stuck at 1e9). Bounded to camera altitude near the waterline, not a bare
    // direction test, which would read dry caves below sea level as underwater.
    bool uwHasSubmergedSurfaceCrossing = uwSurfDist < 1e8 && uwSurfDist < uwFragDist
            && uwFragWorldY < uwSurfWorldY;
    bool uwNearWaterlineFallback = abs(u_CameraAbs.y - u_WaterState.z) <= 0.35 && uwDirY < -1e-4;
    bool fragSubmerged = u_WaterState.x > 0.5
            ? (uwFragDist < uwSurfDist && uwFragWorldY < u_WaterState.z)
            : (uwHasSubmergedSurfaceCrossing || (uwNearWaterlineFallback
               && uwFragWorldY < u_WaterState.z));
#endif

#ifdef SHADOWS
    // Queried always, not behind ndotl > 0.0: that gate is harmless for the diffuse term (N.L
    // zeroes it anyway) but wrong for specular, fill light, cloud shadow and water glitter, which
    // would all read a self-shadowed slope as fully lit.
    //
    // The acne offset must ride the geometric surface, not the bumped normal: a normal-mapped
    // groove would wobble the sample point per texel and paint occlusion that follows the texture.
    // Screen derivatives of the position give the true face plane, falling back to the shading
    // normal where the cross product degenerates.
    vec3 shadowGeomNormal = cross(dFdx(worldPos), dFdy(worldPos));
    float shadowGeomLen = length(shadowGeomNormal);
    shadowGeomNormal = shadowGeomLen > 1e-6 ? shadowGeomNormal / shadowGeomLen : normal;
    if (dot(shadowGeomNormal, normal) < 0.0) {
        shadowGeomNormal = -shadowGeomNormal;
    }
    float visibility = sunVisibility(worldPos, shadowGeomNormal, sunDir, rainFactor);
    // Queried at PLAGUE_SHADOW_AMBIENT_BROADEN times the filter radius: the sky guess below rides
    // this at every slider position, and sharp per-pixel visibility would paint ink patches on any
    // surface made of reflections.
    float ambientVisibility = sunVisibilityAt(worldPos, shadowGeomNormal, sunDir, rainFactor,
                                              PLAGUE_SHADOW_AMBIENT_BROADEN);

    // A local copy of sunVisibilityAt's bias and projection maths, not a call into it; see that
    // function's own trap note above.
    if (debugView == DBG_SHADOW_QUERY_1) {
        fragColor = vec4(sunDir, ndotl);
        return;
    }
    if (debugView == DBG_SHADOW_QUERY_2 || debugView == DBG_SHADOW_QUERY_3) {
        float dbgSlope = 1.0 - abs(dot(normal, sunDir));
        vec3 dbgBiased = worldPos + normal * (0.05 + 0.35 * dbgSlope) + sunDir * 0.05;
        vec4 dbgLightClip = u_SunViewProj * vec4(dbgBiased, 1.0);
        vec3 dbgLightNdc = dbgLightClip.xyz / dbgLightClip.w;
        float dbgRadius = length(dbgLightNdc.xy);
        float dbgDistort = dbgRadius * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
        vec2 dbgShadowUv = (dbgLightNdc.xy / dbgDistort) * 0.5 + 0.5;
        float dbgRawDepth = dbgLightNdc.z;
        bool dbgInRange = dbgShadowUv.x > 0.0 && dbgShadowUv.x < 1.0
                && dbgShadowUv.y > 0.0 && dbgShadowUv.y < 1.0
                && dbgRawDepth > 0.0 && dbgRawDepth < 1.0;
        if (debugView == DBG_SHADOW_QUERY_2) {
            fragColor = vec4(dbgShadowUv, dbgInRange ? 1.0 : 0.0, visibility);
            return;
        }
        // DBG_SHADOW_QUERY_3: the stored depth at dbgShadowUv, read through SUN_SHADOW_MAP_RAW,
        // since SUN_SHADOW_MAP can only return a pass/fail compare. The clamped UV means this only
        // means anything when QUERY_2's inRange was 1.0.
#ifdef PLAGUE_DEBUG_VIEWS
        ivec2 dbgShadowTexel = ivec2(clamp(dbgShadowUv, 0.0, 1.0) * vec2(textureSize(SUN_SHADOW_MAP_RAW, 0)));
        float dbgStoredDepth = texelFetch(SUN_SHADOW_MAP_RAW, dbgShadowTexel, 0).r;
#else
        float dbgStoredDepth = 0.0;
#endif
        // Red = the depth this query compares, blue = what the map holds there, green empty.
        // Matching red and blue means the comparison would pass.
        fragColor = vec4(dbgRawDepth, 0.0, dbgStoredDepth, 0.0);
        return;
    }

    // Fades shadows over the last quarter of shadow distance rather than a hard map-boundary circle
    // sweeping across the ground as the player moves.
    float shadowDist = length(worldPos);
    float fadeStart = u_ShadowDistance * 0.75;
    visibility = mix(visibility, 1.0,
                     clamp((shadowDist - fadeStart) / max(u_ShadowDistance - fadeStart, 1e-4), 0.0, 1.0));
    // Real moonlight is about a millionth of sunlight, so a low moon's shadows should be a hint,
    // not a hard edge. Faded, not switched, so the sun-to-moon handoff does not snap.
    float casterStrength = mix(0.18, 1.0, dayFactor);
    // skyLight drops one level per water block and is zero by ~15 blocks down, which would throw
    // away a correct shadow map underwater. Below the surface the underwater arm's own curve
    // (exp(-d/24)) is used instead: it answers how much sun reaches the fragment, where the
    // lightmap answers how much medium sits in front of it.
    //
    // max(), not a swap: near the surface the lightmap stays in charge. Keyed on the fragment's
    // own depth, not the camera's, so a seabed seen from a boat still gets shadows.
    float shadowFragAltitude = u_CameraAbs.y + worldPos.y;
    float shadowSubmergedDepth = max(u_WaterState.z - shadowFragAltitude, 0.0);
    float shadowSkyGate = shadowSubmergedDepth > 0.0
            ? max(skyLight, exp(-shadowSubmergedDepth / 24.0))
            : skyLight;
    // Clamped: mix() extrapolates, and a strength above 1.0 drives `shadow` negative across the
    // deep half of every penumbra, subtracting light instead of removing it. Above 1.0 belongs to
    // shadowFade at the end, never here.
    float shadow = mix(1.0, visibility,
                       clamp(u_ShadowStrength, 0.0, 1.0) * shadowSkyGate * casterStrength)
                 * pomShadow;

    // Separate from sunVisibility(): the shadow map knows only opaque terrain, never the cloud
    // volume, so this multiplies in on its own. Computed in cloud_shadow_mask.fsh at quarter
    // scale, since it has no detail finer than a cloud cell and cost hundreds of hashes here.
    float cloudShadow = 1.0;
#if CLOUD_SHADOWS && CLOUDS_VOLUMETRIC
    cloudShadow = clamp(texture(CLOUD_SHADOW_MASK, texCoord).r, 0.0, 1.0);
#endif
    shadow *= cloudShadow;

#if PLAGUE_UNDERWATER
    // --- Submerged sunlight: the sun's own in-water leg ----------------------------------------
    //
    // Direct sunlight reaching a submerged fragment is coloured by its own path through the water,
    // a leg apart from the eye path water_composite handles, so nothing is counted twice. Built
    // here and multiplied into sunColour below. Reads one flat focus value (0.5775) on purpose:
    // the animated web is a separate scene add and does not ride this tint.
    {
        float fragDist = uwFragDist;
        if (fragSubmerged) {
            // The web is added over a neutral tint, not multiplied into it: the pattern is sparse
            // by design (mean 0.01), so multiplying the direct term by it is a flat darkening.
            float pattern = 0.5775;
#if WATER_CAUSTICS
            // Cost gate (four wave-field evaluations per fragment): dayFactor, since night light
            // is moonlight-weak, and 152 blocks, since the falloff has flattened the fine octaves
            // by then. fragSubmerged already proved the pixel is in the volume, so this does not
            // re-gate on sky light or camera altitude, both of which can be zero over a real pond.
            if (dayFactor > 0.02 && fragDist < 152.0) {
                // Faded, not cut: a hard edge at the 96-block fps bound draws a visible line across
                // the seabed when looking down from above water.
                float causticRangeFade = 1.0 - smoothstep(112.0, 152.0, fragDist);
                // Caustic contrast washes out with depth faster than sun transmission does
                // (exp(-depth/24) dims 25% over 8 blocks; real caustic contrast is gone by ~15m),
                // so it gets its own steeper falloff.
                float uwCFragY = worldPos.y + u_CameraAbs.y;
                float uwCSurfY = u_WaterState.x > 0.5
                        ? u_WaterState.z
                        : uwHasSubmergedSurfaceCrossing ? uwSurfWorldY : u_WaterState.z;
                float uwCDepth = max(uwCSurfY - uwCFragY, 0.0);
                // The fade rides the fragment's own depth, which is the physics: the same seabed
                // looks the same whether the camera floats or dives; what changes it is how much
                // water sits above the sand. Judge it shore against deep, not by bobbing over one
                // spot.

                // Sun-directed projection: push the fragment back along the sun ray to the surface
                // point whose refracted light reaches it, so floors and the walls beside them
                // share one moving web. Same wave clock the visible surface runs (u_SkyState.w/20).
                vec3 causticWorldPos = worldPos + u_CameraAbs;
                // A wall's along-the-wall axis reaches the field for free at gain 1: moving along
                // the wall moves worldPos.xz. The vertical axis only reaches it through this
                // shear, so its gain has to be 1 as well or that axis alone reads as stretched.
                // sunDir.xz/sunDir.y is tan(sun zenith), which explodes near the horizon and
                // collapses toward noon; taking direction from the sun's azimuth with the
                // magnitude fixed at 1 keeps both wall axes in proportion at every sun angle.
                vec2 sunAzimuthRaw = sunDir.xz;
                float sunAzimuthLen = length(sunAzimuthRaw);
                vec2 sunAzimuth = sunAzimuthLen > 1e-4 ? sunAzimuthRaw / sunAzimuthLen : vec2(1.0, 0.0);
                causticWorldPos.xz += sunAzimuth * uwCDepth;
                // One sun-projected field for every face, see plagueCausticsProjected: three
                // independent triplanar projections would be three animations, not one pattern.
                // Runtime options arrive as floats in u_PackOptions, and DefineRewriter strips the
                // #define at pack build, so a toggle is tested > 0.5, never against an int
                // literal. Offline the #define is still here, so an int compare passes
                // check_shaders.sh and fails only in a running client.
                float causticRate = (u_CausticSpeed * 0.01)
                                  * (u_CausticSyncWaves > 0.5 ? u_WaveSpeed : 1.0);
                float causticSize = u_CausticScale * 0.01;
                float causticP01 = plagueCausticsProjected(CAUSTICS_TEX, causticWorldPos,
                                                           (u_SkyState.w / 20.0) * causticRate,
                                                           causticSize);

                // A low sun meets the surface at a grazing angle and passes almost nothing through
                // to focus: at sunset the submerged direct term is two orders under noon, so
                // without this gate the web shows with no sunlight behind it.
                float sunElevationGate = smoothstep(0.12, 0.35, sunDir.y);

                // Depth shapes caustics, it does not delete them: they should show wherever a
                // shadow does not, at any depth. Occlusion decides whether a caustic lands, and
                // that is causticShadow's job. Near the surface the column has not yet smeared
                // what the waves focused, so peaks stay sharp; with depth that averages to a glow.
                float shimmerDepth = max(plagueChunksToBlocks(u_CausticGlowDepth), 1.0);
                float shimmerFall = exp(-uwCDepth / shimmerDepth);
                // No synthetic twinkle: a sine over world position and time is a second pattern
                // unrelated to the wave field that focuses the light. Squared in causticP01 so the
                // gain lands on peaks rather than lifting the whole web, which is what makes it
                // bloom (the bloom pass is unthresholded). Depth dims to 50% and stops there: a
                // deep seabed should still read caustics, only fainter.
                float causticDepthDim = mix(1.0, 0.5, clamp(uwCDepth / shimmerDepth, 0.0, 1.0));

                // Shaping lives in the pattern (a 0.72 cellular body plus 0.28 filament split,
                // full range), not in a curve bolted on here: sharpening with a smoothstep and a
                // gain throws away the mid-range the cells live in, leaving thin dots with no body.
                float shaped = causticP01 * causticDepthDim * causticRangeFade;

                // A separate five-tap dilation of the hot crests, anchored by screen derivatives
                // so the halo stays compact. Fragment stage only (dFdx/dFdy): both files importing
                // ocean_caustics.glsl are .fsh.
                uwWebBloom = plagueCausticsBloomProjected(CAUSTICS_TEX, causticWorldPos,
                                                          (u_SkyState.w / 20.0) * causticRate,
                                                          causticSize)
                           * causticDepthDim * causticRangeFade;

                // The HDR seed: bloom strength times HDR strength tops out near 0.51, so without
                // this term nothing crosses display white at any slider setting. Hot crests alone.
                uwWebHot = plagueCausticsBloomSeed(causticP01) * causticDepthDim
                         * causticRangeFade;

                uwWeb = shaped * sunElevationGate * smoothstep(0.02, 0.15, dayFactor);
            }
#endif
            // WATER_SUN_TINT is a bisection switch, see underwater.glsl. Gated apart from
            // WATER_CAUSTICS: this recolours the sun's own in-water path, the web is a scene add.
            // Off, uwSunTint stays vec3(1.0) and the later multiply does nothing.
#if WATER_SUN_TINT
            // plagueUnderwaterSunTint, above main: the pack's fitted focus-to-colour curve, in
            // linear light. Its level folds in the measured display pipeline, solved by contrast
            // ratio from the frozen captures (the shaping curve saturates past ~gain 120, contrast
            // stalling near 3.3%), so the caustic contrast has to come from this direct term.
            uwSunTint = plagueUnderwaterSunTint(pattern);
            // The web does not ride this tint: the submerged direct term is already tiny after
            // transmission, the water tint and the shadow, so multiplying it stays tiny whatever
            // the factor. The web is added to the scene at the fog site instead.
#endif
        }
    }
#endif
#else
    float shadow = 1.0;
#endif

    // Shared with voxel material hits so the two paths use identical frame light colours.
    vec3 surfaceSunTint = vec3(1.0);
#if PLAGUE_UNDERWATER
    surfaceSunTint = uwSunTint;
#endif
    PlagueSurfaceLighting surfaceLighting = plagueSurfaceLighting(lighting, skyColours,
            sunDir, sunDirTrue, rainFactor, atmColorMult, trueSunHeight, u_CameraAbs.y,
            surfaceSunTint);
    vec3 sunColour = surfaceLighting.sunColour;
    vec3 ambientColour = surfaceLighting.ambientColour;
    vec3 blockLightColour = surfaceLighting.blockLightColour;
    float skyReflectionLift = surfaceLighting.skyReflectionLift;

    // --- Material and BRDF ----------------------------------------------------------------------
    //
    // GGX distribution, Smith height-correlated visibility, exact dielectric Fresnel, measured
    // complex-IOR Fresnel for the eight metals labPBR names, Hammon diffuse. See brdf.glsl, which
    // is written from the papers. It needs no NdotV floor: the height-correlated visibility term
    // cancels the 4*NdotL*NdotV denominator, so nothing divides by ~0 at grazing angles. It caps
    // specular at pi^4, since a near-delta lobe against a directional light is that bright.
    vec3 material = texture(G_BUF, vec3(texCoord, 1.0)).rgb;
    PlagueMaterial mat = plagueDecodeMaterial(material.r, material.g, material.b);

    // Wetness is applied in terrain.fsh, not here: the puddle model needs the height map and has
    // to flatten the normal before the G-buffer write, neither of which a deferred pass can do. It
    // is driven by u_FrameState.w (accumulated wetness), not u_SkyState.x, whose rain level snaps.
    //
    // Nothing is re-applied here on purpose: `mat` already carries it. A second application would
    // darken soaked albedo twice and push smoothed material past mirror.

    // Snow is drawn in the geometry stage, not here: only that stage can shape a normal before the
    // G-buffer records it. Two traps a deferred blend hit: positional gates (column, height,
    // facing) paint a mob standing in a field as snow-covered, so read gAo.a's surface class
    // instead (terrain.fsh 1.0 solid / 0.5 cutout, entities.fsh 0.75, block_entities.fsh 0.0); and
    // snow caught on foliage is a different material from snow lying flat, or spruce leaves come
    // back as grey smears.

    // worldPos is camera-relative, so the direction back to the eye is its negation.
    vec3 viewDir = normalize(-worldPos);

    PlagueBrdf brdf = plagueEvaluateBrdf(mat, albedo, normal, viewDir, sunDir);

    // --- One labPBR surface response, shared by the diffuse and the reflection ---------------------
    //
    // Everything below composites from these four lines, and nothing below asks what kind of
    // material this is: material class is a property of the decode, and past that point there is
    // one set of equations. A metal/dielectric branch here is what produced chrome hoppers, pale
    // chalk and a powder-blue coat, one after the other.
    //
    // reflSmoothness comes from the wetted material, matching what ssr_trace/ssr_blur keyed off:
    // terrain.fsh bakes puddle wetness into gMaterial before the write, so mat.alpha carries rain.
    float reflSmoothness = clamp(1.0 - sqrt(clamp(mat.alpha, 0.0, 1.0)), 0.0, 1.0);
    float NdotV = clamp(dot(normal, viewDir), 0.0, 1.0);

    // F0 comes only from the `_s` green byte (or the conductor decode). Wetness may change it
    // earlier; dry orientation and sky access must not invent a film the resource pack never wrote.
    vec3 surfaceF0 = plagueMaterialF0(mat, albedo);

    // The split-sum environment response with multiple scattering: the one place energy is decided
    // for every material. The multi-scatter term keeps a rough conductor coloured and lit rather
    // than grey and collapsing (see brdf.glsl).
    vec3 specularAlbedo = plagueEnvSpecularAlbedo(surfaceF0, NdotV, 1.0 - reflSmoothness);
    // The analytic fit assumes a reflective interface and retains grazing bias at F0=0. labPBR
    // allows an exact zero, and Fornax uses it for an absent `_s`, so zero must stay zero per channel.
    vec3 f0Present = step(vec3(0.5 / 255.0), surfaceF0);
    specularAlbedo *= f0Present;

    // What is not reflected is transmitted: a dielectric scatters it back out as diffuse, a
    // conductor absorbs it. Neither is a branch.
    vec3 kD = (1.0 - specularAlbedo) * (1.0 - mat.metalness);

    // Both BRDF terms already carry N.L, so only visibility and light colour apply here; adding
    // the cosine again would square it.
    //
    // Underwater, skyLight is the wrong signal for sun reach: vanilla drops it ~1 level per water
    // block, so a seabed 12 blocks down reads 0.2 and the specular is 5x weak before a caustic can
    // ride it. The gate is exp(-depth/24) instead (blue reaches ~24m), with the shadow map still
    // owning occlusion. The fill light keeps the real sky light everywhere.
    if (debugView == DBG_CONDUCTOR_F0) {
        fragColor = vec4(surfaceF0, mat.metalness);
        return;
    }
    if (debugView == DBG_CONDUCTOR_ENERGY) {
        fragColor = vec4(specularAlbedo, reflSmoothness);
        return;
    }

    float uwSunGate = -1.0; // < 0: the standard gates stand (dry fragments, underwater off)
    // Submerged rock sits in the same scattering medium plagueWaterFogColor already prices for the
    // eye-to-point veil, so it must not go black the way a dry sealed room does. Reuses
    // plagueWaterFogColor, so floor and veil share a colour, scaled by the same exp(-depth/24).
    //
    // Limits: the floor knows the fragment's depth, not whether the water above reaches open sky,
    // so a sealed flooded cavern reads like a sunlit overhang; and it is a height test, not a water
    // mask, so a drained air pocket seen through glass still reads as water. Both need an engine
    // signal, not a shader guess.
    vec3 uwAmbientFloor = vec3(0.0);
#if PLAGUE_UNDERWATER
    if (fragSubmerged) {
        float uwFragWorldY = worldPos.y + u_CameraAbs.y;
        float uwSurfaceY = u_WaterState.x > 0.5
                ? u_WaterState.z
                : u_CameraAbs.y + worldPos.y * (uwSurfDist / max(uwFragDist, 1e-4));
        float uwSubmergedDepth = max(uwSurfaceY - uwFragWorldY, 0.0);
        uwSunGate = exp(-uwSubmergedDepth / 24.0);
        // WATER_AMBIENT_FLOOR is a bisection switch, see underwater.glsl. Gated separately from
        // uwSunGate above, which the specular term still needs regardless of this switch's state.
#if WATER_AMBIENT_FLOOR
        uwAmbientFloor = plagueWaterFogColor(lighting) * max(uwSunGate, 0.0);
#endif
    }
#endif
    float sunVisibilityHere = shadow * (uwSunGate >= 0.0 ? uwSunGate : skyLight);
    vec3 specular = brdf.specular * sunVisibilityHere * sunColour;
    if (debugView == DBG_CONDUCTOR_DIRECT) {
        fragColor = vec4(specular, sunVisibilityHere);
        return;
    }

    // --- The lighting composite ------------------------------------------------------------------
    //
    // main_lighting.glsl owns the composite: sources are mixed in squared space and the result
    // square-rooted (they add in quadrature), so two maxed sources cannot sum to double.
    //
    // AO is labPBR texture AO times SSAO, not vanilla's per-vertex AO: Fornax does not forward
    // glColor.a to a deferred pass, so there is no G-buffer channel for it.
    //
    // Moon phase (u_SkyCelestial.w) scales night light: full moon lights the world, new moon not.
    float moonPhaseInf = plagueMoonPhaseInfluence(u_SkyCelestial.w, lighting.sunVisibility2);

    // Identity vec3(1.0) when LIGHT_COLOR_MULTS is off, so plagueDoLighting never needs to
    // special-case the option's absence.
    vec3 lightColorMult = vec3(1.0);
#ifdef LIGHT_COLOR_MULTS
    lightColorMult = plagueLightColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_LightMorningR, u_LightMorningG, u_LightMorningB) * u_LightMorningI,
            vec3(u_LightNoonR, u_LightNoonG, u_LightNoonB) * u_LightNoonI,
            vec3(u_LightNightR, u_LightNightG, u_LightNightB) * u_LightNightI,
            vec3(u_LightRainR, u_LightRainG, u_LightRainB) * u_LightRainI);
#endif

    // One smooth field drives every shadow-keyed modifier, shaped so only confident occlusion
    // darkens and capped before black: sharp per-pixel visibility would paint ink patches on a
    // metal whose whole appearance rides these terms.
    //
    // The slider's above-1.0 range lives in shadowFade alone: a fill-light cut here would darken
    // the dielectric world differently from the traced image metals mirror, diverging as it moves.
    float envShadowDim = 0.0;
    float shadowFade = 1.0;
#ifdef SHADOWS
    const float PLAGUE_AMBIENT_SHADOW_MAX = 0.75;
    float shadowOcclusion = smoothstep(0.2, 0.9, 1.0 - ambientVisibility)
            * shadowSkyGate * casterStrength * PLAGUE_AMBIENT_SHADOW_MAX;
    // A caster blocks the sun, not the sky, so the fill mostly survives. One flat factor for the
    // caster's share of the hemisphere, no slider: the conductor chain holds no u_ShadowStrength.
    envShadowDim = shadowOcclusion * 0.25;
    // The whole above-1.0 range in one number. The torch guard keeps locally-lit shadow readable:
    // block light is light the caster never blocked, and it rides the smooth lightmap.
    float torchShare = plagueBlockLightCurve(blockLight, u_ScreenBrightness);
    shadowFade = 1.0 - max(u_ShadowStrength - 1.0, 0.0) * shadowOcclusion
            * (1.0 - clamp(torchShare, 0.0, 1.0));
#endif

    PlagueLitResult litResult = plagueDoLighting(
            sunColour, ambientColour,
            normal, sunDir,
            shadow, blockLight, skyLight,
            ao, emitterLum, albedo, specular, blockLightColour,
            lighting.noonFactor, lighting.sunVisibility2, lighting.rainFactor,
            u_ScreenBrightness, moonPhaseInf, lightColorMult, uwSunGate, uwAmbientFloor);

    // Held light, added in the same squared space the composite mixes in (plagueHeldLighting).
    // Coloured by the same blockLightColour plagueDoLighting got, so a torch in hand matches one
    // on the ground whichever model resolved that colour.
    vec3 heldLight = plagueHeldLighting(worldPos, u_HeldLight.x, u_HeldLight.y, blockLightColour);
#if PLAGUE_UNDERWATER && WATER_HELD_LIGHT_FILTER
    // Red-heavy Beer-Lambert over the light's round trip: water absorbs red within metres, so a
    // submerged lantern throws a warm core falling off teal, not a whole-frame warm flood.
    // WATER_HELD_LIGHT_FILTER is a bisection switch, see underwater.glsl.
    if (u_WaterState.x > 0.5) {
        const vec3 PLAGUE_UW_HELD_EXTINCTION = vec3(0.30, 0.12, 0.06);
        heldLight *= exp(-length(worldPos) * PLAGUE_UW_HELD_EXTINCTION);
    }
#endif
    vec3 diffuseWithHeld = sqrt(max(litResult.diffuse * litResult.diffuse
                                  + heldLight * heldLight, vec3(0.0)));

    // Emission joins in quadrature, not inside diffuseWithHeld: it is already built from albedo's
    // hue (emission.glsl), so albedo would be applied twice. Branched rather than sqrt(x*x)
    // always, since GLSL's sqrt() allows up to 3 ULP of error and the branch makes "emission 0
    // changes nothing" exact.
    //
    // kD takes a conductor's diffuse to zero (free electrons absorb what is not reflected); a
    // dielectric keeps ~96%. Emission stays reachable, only the diffuse lobe goes.
    //
    // shadowFade rides every non-emission term and not the emitted radiance: a glowing block glows
    // in the deepest shadow. Applied before the join so the exemption is structural.
    vec3 litDiffuse = kD * albedo * diffuseWithHeld * shadowFade;
    vec3 lit = (emitterLum > 0.0
                    ? sqrt(max(litDiffuse * litDiffuse
                               + litResult.emitted * litResult.emitted, vec3(0.0)))
                    : litDiffuse)
             + litResult.highlight * shadowFade
             // Moon phase enters the highlight twice, an authored falloff: a thin crescent should
             // keep faint diffuse moonlight but lose the glint first.
             * moonPhaseInf * moonPhaseInf;

    // Vanilla sets ambient_light 0.25 in the End (the_end.json), so nothing there is fully dark.
    // This pack never reads vanilla's lightmap, so it loses that floor, and with no sun either a
    // surface facing away from everything reads as a hole. Floored against the sky's own colour,
    // the only thing giving off light there.
    if (u_WorldBounds.w == 3.0) {
        lit = max(lit, albedo * ambientColour * PLAGUE_END_AMBIENT_FLOOR);
    }

    // --- Reflections ------------------------------------------------------------------------------
    //
    // An energy-conserving mix, never an addition: the reflected term replaces a Fresnel-weighted
    // fraction of the shaded surface rather than piling light on top of it.
    //
    // Misses fall back to the sky: without it a horizontal mirror renders as dark silhouettes
    // where a ray hit and flat metal where one missed. Two guards on that fallback: a
    // sky-visibility gate, so a ray with no sky access adds nothing rather than black, and no
    // celestial glare, since reflecting the discs through a crude dome aliases into sparkle on
    // block edges as the view moves.
    //
    // SSR_QUALITY off drops only the traced image; the wide lobe below must stay, since kD has
    // already reserved that specular energy.
    //
    // Two samples of one buffer at two widths. `ssrSample` is the mirror image at LOD 0 (the seed
    // level is a texel-exact copy of `ssr`). `ssrWideSample` is the same reflection prefiltered to
    // this material's roughness: ssr_blur's kernel caps at 7x7, so past that cap this mip is what
    // lets authored roughness reach the environment lobe. One buffer at two mips, not two content
    // sources, which is also why wideTraceTrust below needs no roughness term.
    vec4 ssrSample = vec4(0.0);
    vec4 ssrWideSample = vec4(0.0);
#if SSR_QUALITY != 0
    ssrSample = textureLod(SSR_PREFILTER, texCoord, 0.0);
    ssrWideSample = textureLod(SSR_PREFILTER, texCoord, plagueReflectionLod(1.0 - reflSmoothness));
#endif

    // Energy is `specularAlbedo`, decided once above, and roughness is spent on lobe width below.
    // No second smoothness curve may dim a ray that landed.

    // Same sky the pack paints, sampled once along the mirror direction, celestial disc suppressed.
    // Graded so a reflection miss agrees with the dome it is reflecting.
    vec3 reflDir = reflect(-viewDir, normal);
#if PLAGUE_SKY_MODEL == 1
    // Nether reflections read vanilla's own fog tint rather than an Overworld daylight table; see
    // the sky branch's own comment on why the table cannot speak for a dimension with no sun.
    vec3 skyMiss = u_WorldBounds.w == 2.0 ? u_FogColor.rgb * atmColorMult
            : u_WorldBounds.w == 3.0 ? plagueEndSky(reflDir, plagueEndSkyLevel()) * atmColorMult
            : plagueAtmoSkyView(reflDir, sunDirTrue, plagueAtmoCameraRadius()).rgb * atmColorMult;
#else
    vec3 skyMiss = plagueGetSky(skyColours, reflDir.y, dot(reflDir, sunDirTrue), 0.5,
                                false, true) * atmColorMult;
#endif
    // Same night correction the diffuse path takes (skyReflectionLift), applied before the warm
    // pull and the underwater override so every consumer of the sky guess agrees. 1.0 in daylight.
    skyMiss *= skyReflectionLift;
    // Same ground-bounce pull as the fill light: raw zenith saturation as reflection content keeps
    // shadowed metal blue at every setting. Real hits stay faithful; only this dry-dome estimate
    // is warmed, and the underwater override below replaces it.
    float skyGuessLuma = dot(skyMiss, vec3(0.2126, 0.7152, 0.0722));
    vec3 skyGuessWarm = PLAGUE_GROUND_BOUNCE_TINT
                      * (skyGuessLuma / dot(PLAGUE_GROUND_BOUNCE_TINT,
                                            vec3(0.2126, 0.7152, 0.0722)));
    skyMiss = mix(skyMiss, skyGuessWarm, u_AmbientBounceWarmth * plagueSunFactor);
#if PLAGUE_UNDERWATER
    // The sky arm's override above does not reach a reflected ray, so a missed reflection needs
    // its own closed open-water radiance or it shows a flat patch, or sky and stars.
    if (u_WaterState.x > 0.5) {
        vec3 uwMirrorVeil = plagueWaterFogColor(lighting)
                           * plagueAuthoredToLinear(plagueUnderwaterMult(
                      u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0),
                      u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0),
                      u_DepthDarkness, lighting, vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB)) * 0.85);
        skyMiss = plagueUnderwaterClosedRadiance(reflDir, uwMirrorVeil, lighting.sunFactor,
                                                 plagueChunksToBlocks(u_WaterDistanceFog));
    }
#endif

    // How much sky this ray could have reached. A surface with no sky access reflects none
    // whatever its direction; that half is the lightmap term.
    //
    // A horizontal ray points at the horizon, which is sky, so the gate must not be zero there: a
    // metal wall or door has a horizontal mirror direction, and scoring it 0 collapses reflTotalW,
    // and with it sharpAvail and wideTraceTrust, onto the flat enclosure guess, which renders
    // copper doors as grey chrome whatever their wear.
    //
    // Hoisted here so the wide lobe below shares the shape: 0.5 at the horizon, falling off either
    // side. Downward rays keep a small share, since a hard cut re-textures the transition.
    float reflHorizon = smoothstep(-0.35, 0.35, reflDir.y);
    float reflSkyVis = reflHorizon * smoothstep(0.1, 0.7, skyLight);

    // Confidence-weighted blend, not a second mix(): a miss with no sky visibility must contribute
    // nothing, not black, which `mix(reflection, sky, 1 - confidence)` would give.
    float reflHitW = clamp(ssrSample.a, 0.0, 1.0);
    // A single mirror-direction sky lookup is only valid for a narrow lobe; handing it to rough
    // materials makes medium-rough iron look sky-textured whenever SSR misses. Dielectrics only:
    // on a metal this gate zeroes the environment on rough misses (~75-87% of texels on real
    // iron/hopper blocks) with no diffuse card underneath. Conductors take the sharp/wide split
    // below instead, a blurrier environment rather than nothing.
    //
    // envAccess is how much of the environment reaches this fragment, normalised so a fully open,
    // unshadowed outdoor fragment is 1.0. The numerator is what the fragment really gets (fill
    // light through the lightmap, sun through the shadow map, block light including held), the
    // denominator the same fragment fully open, so a sealed room lit by one torch still scores
    // real access. It is also where shadow lines reach the reflection: an environment fill blind
    // to sun occlusion swamps the direct highlight.
    float openLight = dot(ambientColour + sunColour, vec3(0.2126, 0.7152, 0.0722));
    // The denominator stays the fully-open daylight norm, so this cannot inflate an outdoor
    // fragment past 1.0: a torch pushes the numerator up, the clamp takes it back to 1.0.
    float hereLight = dot(ambientColour * plagueSmoothstep1(skyLight)
                              + sunColour * shadow * skyLight
                              + blockLightColour
                                    * plagueBlockLightCurve(blockLight, u_ScreenBrightness)
                              + heldLight,
                          vec3(0.2126, 0.7152, 0.0722));
    // AO is a diffuse answer and this is a specular question, see plagueSpecularOcclusion for the
    // derivation of why its max() makes this one-directional.
    float specAo = plagueSpecularOcclusion(ao, NdotV, 1.0 - reflSmoothness);
    float envAccess = clamp(specAo * hereLight / max(openLight, 1e-4), 0.0, 1.0);

    // A missed ray is only entitled to open sky if open sky is reachable from here, for every
    // material alike: rough stone in a shadowed corridor gets the same treatment iron does.
    float skyMirrorCompetence = envAccess;
    // Not dimmed by sun-shadow: a caster blocks the sun, not the sky. The sky-light gate inside
    // reflSkyVis still kills the guess where the sky is genuinely unreachable.
    float reflSkyW = (1.0 - reflHitW) * reflSkyVis * skyMirrorCompetence;
    float reflTotalW = reflHitW + reflSkyW;
    vec3 reflColor = reflTotalW > 1e-4
            ? (ssrSample.rgb * reflHitW + skyMiss * reflSkyW) / reflTotalW
            : ssrSample.rgb;

    // Same construction against the prefiltered sample, with its own confidence (the mip averages
    // its neighbourhood's alpha too, so one lucky hit cannot speak for the whole lobe). skyMiss is
    // reused unfiltered: an analytic dome has no high frequencies to convolve away.
    float reflHitWWide = clamp(ssrWideSample.a, 0.0, 1.0);
    float reflSkyWWide = (1.0 - reflHitWWide) * reflSkyVis * skyMirrorCompetence;
    float reflTotalWWide = reflHitWWide + reflSkyWWide;
    vec3 reflColorWide = reflTotalWWide > 1e-4
            ? (ssrWideSample.rgb * reflHitWWide + skyMiss * reflSkyWWide) / reflTotalWWide
            : ssrWideSample.rgb;

    // The environment specular term, for every labPBR material. Adds to the direct highlight
    // rather than mixing against a substrate: different incoming radiance, and kD already took
    // this term's share out of the diffuse lobe, so nothing counts twice.
    //
    // Energy is `specularAlbedo`; content and lobe width are decided here. `sharpShare` is
    // x*(2-x) on squared smoothness, a quadratic ease reaching full weight at s=1 with zero slope:
    // the share of a lobe this narrow that survives as a coherent image (iron's 0.489 keeps 42%,
    // the rest smeared into the wide term).
    //
    // The wide lobe must be directional, not a flat fill: a reflection hemisphere is about half
    // sky and half ground, and which half a face sees is what makes a solid object read as solid.
    // Sky content fades to the enclosure guess as access drops rather than gating to zero, since
    // an upward lobe indoors sees the ceiling.
    //
    // This two-lobe estimate stands in wherever the screen-space trace has no data.
    //
    // PLAGUE_ENV_FILL is declared unused: it doubled a discount PLAGUE_ENV_GROUND already applies
    // to the enclosure arm (tools/verify_conductor_hue.py). One word to reinstate if an enclosed
    // scene reads too bright.
    const float PLAGUE_ENV_FILL = 0.45;
    // Sky-facing share of the wide lobe, kept out of FILL: a smeared reflection of open sky is
    // still sky-bright, since blurring keeps the hemisphere average, and discounting it by FILL
    // stepped conductor luma 4.7x between polished and worn texels under one sky. 0.80, not 1.0,
    // stays conservative for the rest; numbers fitted in tools/verify_conductor_hue.py.
    const float PLAGUE_ENV_SKY = 0.80;
    const vec3 PLAGUE_ENV_GROUND = vec3(0.085, 0.090, 0.070);
    float sharpShare = reflSmoothness * reflSmoothness;
    sharpShare = sharpShare * (2.0 - sharpShare);

    // One slider meaning for every material: it picks content, never energy. Both shares sum to
    // one, so energy holds at every position (1.0 is the spec result, 0.0 is matte but lit).
    float sharpAvail = 0.0;
#if SSR_QUALITY != 0
    sharpAvail = clamp(sharpShare * reflTotalW * u_SsrStrength, 0.0, 1.0);
#endif

    // A lantern belongs in the wide lobe's radiance, not just its gate: through diffuseWithHeld
    // alone it is 3.8% of the same irradiance once kD takes a conductor's diffuse card away.
    //
    // Not multiplied by PLAGUE_ENV_GROUND: that product is terrain lit by local light bouncing
    // back, but a lantern is the light itself. No material branch: a dielectric gets this too,
    // bounded by its own small F0.
    //
    // PLAGUE_ENV_BLOCK is the share of the reflection hemisphere the emitter and its lit
    // surroundings fill, a solid angle, not a brightness (distance falloff is in the lightmap
    // curve). Laddered on the lantern-on-iron scene in tools/out/labpbr_unified.png.
    const float PLAGUE_ENV_BLOCK = 0.25;
    vec3 blockRadiance = blockLightColour * plagueBlockLightCurve(blockLight, u_ScreenBrightness)
                       + heldLight;

    // Shared with reflSkyVis above rather than a second, independently-drifting expression.
    float wideHorizon = reflHorizon;
    vec3 wideEnclosure = diffuseWithHeld * PLAGUE_ENV_GROUND;
    // Not dimmed by sun-shadow, same as reflSkyW: the dome is still overhead in a shadow.
    float wideSkyShare = wideHorizon * smoothstep(0.1, 0.7, skyLight) * envAccess;
    // No FILL on top of GROUND: a rough conductor's kD is zero, so this estimate is its whole
    // appearance when the trace misses and sky is out of reach, and a double discount leaves it
    // near black whatever its specularAlbedo can reflect.
    vec3 wideEstimate = mix(wideEnclosure, skyMiss * PLAGUE_ENV_SKY, wideSkyShare);
    // Content continuity for conductors: ssr_blur owns the roughness spread, so `reflColor` is the
    // roughness-matched image of the surroundings wherever the trace or sky guess has an answer.
    // Rides `metalness` like kD: a dielectric's sheen sits on its diffuse card and can take
    // estimator error, a conductor has no other card. Falls back where the trace does.
    float wideTraceTrust = clamp(reflTotalW * u_SsrStrength, 0.0, 1.0) * mat.metalness;
    // reflColorWide, not reflColor: the wide lobe gets the reflection convolved to this material's
    // roughness instead of the mirror image.
    vec3 reflWide = mix(wideEstimate, reflColorWide, wideTraceTrust);
    // blockRadiance is added past every content mix above: a nearby emitter's solid-angle share,
    // there whichever content won. Bounded by specularAlbedo below like the rest of reflEnv.
    vec3 reflEnv = reflColor * sharpAvail + reflWide * (1.0 - sharpAvail) + blockRadiance * PLAGUE_ENV_BLOCK;
    // One flat dim, real hits included: per-texel handling here would re-texture the shadow
    // instead of darkening it. envShadowDim has no material term and is capped before black.
    reflEnv *= 1.0 - envShadowDim;

    if (debugView == DBG_CONDUCTOR_MIRROR) {
        fragColor = vec4(reflColor, sharpAvail);
        return;
    }
    if (debugView == DBG_CONDUCTOR_WIDE) {
        fragColor = vec4(reflWide, wideTraceTrust);
        return;
    }
    if (debugView == DBG_CONDUCTOR_ENV) {
        fragColor = vec4(reflEnv, envShadowDim);
        return;
    }

    // Invalid over water and translucents: water_composite.fsh runs after this pass and overwrites
    // water pixels with no debug-view awareness, so aim the crosshair at opaque geometry.
    const vec3 DBG_LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);
    if (debugView == DBG_ENV_SPEC_RATIO) {
        float envSpecLuma = dot(reflEnv * specularAlbedo, DBG_LUMA_WEIGHTS);
        float diffuseLuma = dot(litDiffuse, DBG_LUMA_WEIGHTS);
        float envSpecRatio = envSpecLuma / max(envSpecLuma + diffuseLuma, 1e-4);
        fragColor = vec4(envSpecLuma, diffuseLuma, envSpecRatio, 1.0);
        return;
    }

    // Same caveats as DBG_ENV_SPEC_RATIO. The ratio put the specular path ~50x over the diffuse
    // path for the same surroundings; these ordinals report every term it is built from, luma-
    // reduced, so the wrong factor is read off the crosshair. One vec4 cannot hold eleven values,
    // so select one at a time with the engine's Debug View Cycle, matching
    // EnvSpecularRatioReadback.java's labelling.
    if (debugView == DBG_ENV_DECOMP_SKY) {
        // skyMiss and ambientColour both describe the same sky. If ambientColour is a hemisphere
        // average and skyMiss a raw dome sample, the two are in different units, and whichever is
        // larger could drive the ~50x gap alone.
        fragColor = vec4(dot(skyMiss, DBG_LUMA_WEIGHTS), dot(ambientColour, DBG_LUMA_WEIGHTS),
                          dot(wideEnclosure, DBG_LUMA_WEIGHTS), dot(reflWide, DBG_LUMA_WEIGHTS));
        return;
    }
    if (debugView == DBG_ENV_DECOMP_MIX) {
        fragColor = vec4(dot(reflColor, DBG_LUMA_WEIGHTS), sharpAvail,
                          dot(reflEnv, DBG_LUMA_WEIGHTS), dot(specularAlbedo, DBG_LUMA_WEIGHTS));
        return;
    }
    if (debugView == DBG_ENV_DECOMP_MAT) {
        // .a unused: three values, not four.
        fragColor = vec4(NdotV, mat.alpha, dot(surfaceF0, DBG_LUMA_WEIGHTS), 0.0);
        return;
    }
    if (debugView == DBG_ENV_DECOMP_LOCAL) {
        // The diffuse path's own local-light and sky-access inputs, for comparison against the
        // specular/wide path's use of the same surroundings (DBG_ENV_DECOMP_SKY, ordinal 22).
        fragColor = vec4(dot(diffuseWithHeld, DBG_LUMA_WEIGHTS), dot(blockRadiance, DBG_LUMA_WEIGHTS),
                          skyLight, envAccess);
        return;
    }
    if (debugView == DBG_ENV_DECOMP_AO) {
        // B = litResult.vanillaAO (the diffuse path's reshaped occlusion), A = raw `ao` (what
        // envAccess reads). A large gap means the two paths disagree about occlusion.
        fragColor = vec4(wideHorizon, dot(litDiffuse, DBG_LUMA_WEIGHTS), litResult.vanillaAO, ao);
        return;
    }
    if (debugView == DBG_ENV_DECOMP_RESIDUAL) {
        // dot(a*b*c, w) != dot(a,w)*dot(b,w)*dot(c,w) unless the three share hue, so the separate
        // lumas cannot rebuild litDiffuse exactly. This packs each factor plus the residual.
        float albedoLuma = dot(albedo, DBG_LUMA_WEIGHTS);
        float kDLuma = dot(kD, DBG_LUMA_WEIGHTS);
        float diffuseWithHeldLuma = dot(diffuseWithHeld, DBG_LUMA_WEIGHTS);
        float litDiffuseLuma = dot(litDiffuse, DBG_LUMA_WEIGHTS);
        float residual = litDiffuseLuma / max(albedoLuma * kDLuma * diffuseWithHeldLuma, 1e-6);
        fragColor = vec4(albedoLuma, kDLuma, diffuseWithHeldLuma, residual);
        return;
    }

    // `albedoSample.rgb` is the raw encoded byte in gAlbedo, `albedo` is it decoded. Only valid
    // with u_AlbedoIdentityDebug off; on, terrain.fsh has repainted gAlbedo with diagnostic floats.
    if (debugView == DBG_ALBEDO_WRITE_VS_READ) {
        float rawWrittenLuma = dot(albedoSample.rgb, DBG_LUMA_WEIGHTS);
        float decodedAlbedoLuma = dot(albedo, DBG_LUMA_WEIGHTS);
        fragColor = vec4(rawWrittenLuma, decodedAlbedoLuma, 0.0, 0.0);
        return;
    }

    // Companion to DBG_ALBEDO_WRITE_VS_READ, testing texLuma * tintLuma == albedoLuma. Reads
    // gAlbedo raw, since these are terrain.fsh's diagnostic floats, not colour, and means
    // something only with u_AlbedoIdentityDebug on: terrain.fsh cannot see u_Param3 at all.
    if (debugView == DBG_ALBEDO_IDENTITY_INPUTS) {
        fragColor = vec4(albedoSample.r, albedoSample.g, albedoSample.b, albedoSample.a);
        return;
    }

    // Unconditional: a term this central gets no user-visible kill switch. A stale off state in an
    // options file compiles the whole environment term out with no sign of it.
    lit += reflEnv * specularAlbedo * shadowFade;
    if (debugView == DBG_CONDUCTOR_LIT) {
        fragColor = vec4(lit, dot(lit, vec3(0.2126, 0.7152, 0.0722)));
        return;
    }

    // --- Fog --------------------------------------------------------------------------------------
    //
    // Last, after the reflection mix: fog is a veil in front of the finished surface, dimming a
    // bright and a dark reflection by the same fraction. See fog.glsl and tools/verify_fog.py.
    //
    // The reflection is not fogged twice: `ssr` traced last frame's finished sceneHdr, which
    // already carries the reflected surface's own fog. No correction for the extra path length:
    // the error is near zero wherever a screen-space reflection is readable.
#if PLAGUE_UNDERWATER && defined(SHADOWS) && WATER_CAUSTICS
    // Added to the scene in linear before fog, so distance veils it like everything else. Anchored
    // to what the sun delivers here (shadow map plus the depth gate), sized so bright lines land
    // 3-5x the sand they dance on.
    if (uwWeb > 0.0) {
        // Sunlight, not blue light: a caustic is focused sunlight, warm-white a block or two down,
        // turning teal only as the water filters red out with depth.
        float uwWFragY = worldPos.y + u_CameraAbs.y;
        float uwWDepth = max((u_WaterState.x > 0.5
                ? u_WaterState.z
                : u_CameraAbs.y + worldPos.y * (uwSurfDist / max(uwFragDist, 1e-4))) - uwWFragY,
                0.0);
        // Normalised by the brightest channel: keeps the extinction's hue shift (red dies within a
        // few blocks) without also dimming brightness, which is already handled elsewhere.
        vec3 uwWebAtt = exp(-uwWDepth * vec3(0.18, 0.06, 0.03));
        float uwWebPeak = max(max(uwWebAtt.r, uwWebAtt.g), max(uwWebAtt.b, 1e-4));
        vec3 uwWebSun = plagueAuthoredToLinear(vec3(0.98, 0.99, 0.92)) * (uwWebAtt / uwWebPeak);
        // Light needs a surface facing the sun: without this, back faces and near-vertical walls
        // glow as if the caustic image were pasted on them.
        float causticIncidence = smoothstep(0.03, 0.35, ndotl);
        // cloudShadow belongs inside this visibility: a caustic is the focused beam, and an
        // overcast deck scatters that beam into flat light with nothing left to focus. Terrain and
        // cloud block the same sun. 1.0 when CLOUD_SHADOWS is off.
        float causticShadow = plagueWaterSunVisibility(worldPos, sunDir) * pomShadow * cloudShadow;
        // Three terms off one visibility, so bloom and bounce cannot appear where the direct
        // caustic cannot. Not fed back into extinction or fog: this adds light, it does not change
        // the medium.
        float causticVis = causticShadow * u_CausticStrength;

        // 1. Direct: the focused light itself, on surfaces facing the sun.
        lit += uwWebSun * uwWeb * causticVis * causticIncidence * 1.15;

        // 2. Local bloom: a compact halo on the hot filaments only, pushed past display white so
        //    the unthresholded bloom pass spreads it.
        lit += uwWebSun * uwWebBloom * causticVis * causticIncidence
             * u_CausticGlow * CAUSTICS_BLOOM_STRENGTH * CAUSTICS_HDR_STRENGTH;

        // 2b. HDR crests: the only term deliberately allowed past 1.0, making a filament core read
        //     as a light source rather than a bright surface. Narrow seed keeps surrounding cells
        //     from washing out.
        lit += uwWebSun * uwWebHot * causticVis * causticIncidence
             * u_CausticGlow * CAUSTICS_HDR_STRENGTH * 2.2;

        // 3. Bounce: weak secondary spill onto nearby vertical/downward faces, so walls beside a
        //    glowing seabed don't read as flat cutouts. Not gated by causticIncidence: the point is
        //    reaching faces the sun misses.
        float causticBounce = smoothstep(0.18, 0.80, uwWebBloom)
                            * plagueCausticsBounceReceiver(normal);
        vec3 causticBounceTint = mix(vec3(1.0), albedo, 0.30);
        lit += uwWebSun * causticBounceTint * causticBounce * causticVis
             * u_CausticBounce * CAUSTICS_BOUNCE_STRENGTH;
    }
#endif

#if PLAGUE_FOG
    // Ungated on u_WaterState: plagueFogTerms itself carries the eye-in-water arm (fog.glsl).
    {
        // u_RenderFog.y is the headless fallback, not the primary: it tracks fog attribute
        // distances rather than the chunk grid, so the veil can sit below 1.0 where geometry ends.
        float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0);
        // Same interleaved-gradient noise the sky branch dithers its dome with, so fog and the sky
        // it converges to break banding identically rather than crossing patterns.
        float fogDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));
        // atmColorMult is computed above the sky branch (see there) so the dome and the fog it
        // fades into agree.
#if PLAGUE_SKY_MODEL == 1
        // The marched air along this pixel's froxel, and the sky it dissolves into, from the tables
        // (fog_aerial.glsl). texCoord is the froxel coordinate: the same NDC the ray came from.
        float fogDist = length(worldPos);
        float fogFar = plagueAtmoAerialFar();
        vec4 fogAerial = plagueAtmoAerial(texCoord, fogDist, fogFar);
        float fogNearT = plagueAtmoAerial(texCoord, max(fogDist - PLAGUE_FOG_SKY_LIGHT_REACH, 0.0), fogFar).a;
        vec3 fogDir = worldPos / max(fogDist, 1e-4);
        // Same Nether gate as the sky branch: the table assumes an Overworld sun, so this would
        // fade toward daylight otherwise.
        vec3 fogSky;
        if (u_WorldBounds.w == 2.0) {
            // Varied by noise on the wind clock so it drifts. Stands in until a real aerosol
            // profile.
            float syncedTime = u_SkyState.w * 0.05;
            vec2 driftUv = fogDir.xz * 0.8 + vec2(syncedTime * 0.012, -syncedTime * 0.008);
            float drift = texture(NOISE_TEX, driftUv).r;
            fogSky = u_FogColor.rgb * mix(0.55, 1.15, drift);
        } else if (u_WorldBounds.w == 3.0) {
            // Terrain fades into the same sky it sits under, so the far islands and the medium
            // behind them meet instead of showing an edge.
            fogSky = plagueEndSky(fogDir, plagueEndSkyLevel());
        } else {
            fogSky = plagueAtmoSkyView(fogDir, sunDirTrue, plagueAtmoCameraRadius()).rgb;
            // Same warmth the open dome gets (sky.glsl), sampled along the border's own ray:
            // without it, geometry fades into a sky warm above eye level and flat white below.
            fogSky = plagueWarmSkyBand(fogSky, fogDir.y, dot(fogDir, sunDirTrue), sunDirTrue.y);
            fogSky = plagueStormDarkenSky(fogSky, fogDir.y, dot(fogDir, sunDirTrue), sunDirTrue.y,
                                          rainFactor, clamp(u_FrameState.z, 0.0, 1.0));
            // The same darkening on the air, not only on the sky it fades into. The table marches
            // plain air and knows nothing about a storm, so the near air keeps tracking the real
            // sun while the far sky sits on the storm swatch, up to 16 times apart.
            fogAerial.rgb = plagueStormDarkenSky(fogAerial.rgb, fogDir.y, dot(fogDir, sunDirTrue),
                                                 sunDirTrue.y, rainFactor,
                                                 clamp(u_FrameState.z, 0.0, 1.0));
        }
        PlagueFogDrive fogDrive = PLAGUE_FOG_DRIVE(lighting);
        PlagueFogTerms fogTerms = plagueFogTermsAerial(worldPos, skyLight, u_CameraSkyLight.x,
                                                 renderDistance, fogAerial, fogNearT, fogSky,
                                                 plagueAtmoAerialChroma(texCoord), fogDrive,
                                                 u_FogBorderDensity, u_DepthDarkness,
                                                 plagueChunksToBlocks(u_UnderwaterFogStart),
                                                 plagueChunksToBlocks(u_WaterDistanceFog),
                                                 plagueChunksToBlocks(u_WaterDepthFog),
                                                 vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB),
                                                 vec3(u_WaterDistanceDarkness, u_WaterDepthDarkness,
                                                      plagueChunksToBlocks(u_WaterDarknessDepth)), lighting, atmColorMult);
#else
        PlagueFogTerms fogTerms = plagueFogTerms(worldPos, skyLight, u_CameraSkyLight.x,
                                                 renderDistance, u_CameraAbs.y, fogDither,
                                                 skyColours, lighting, sunDirTrue,
                                                 u_FogDensity, u_FogBorderDensity, u_DepthDarkness,
                                                 plagueChunksToBlocks(u_UnderwaterFogStart),
                                                 plagueChunksToBlocks(u_WaterDistanceFog),
                                                 plagueChunksToBlocks(u_WaterDepthFog),
                                                 vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB),
                                                 vec3(u_WaterDistanceDarkness, u_WaterDepthDarkness,
                                                      plagueChunksToBlocks(u_WaterDarknessDepth)), atmColorMult);
#endif
        // No cap on the in-water leg: this fogs the whole eye-to-fragment ray. The water term is
        // the only thing that seals the horizon underwater, since the border curve
        // (d/renderDistance)^16 gives nothing below ~160 blocks.
        if (u_FogOpacityView > 0.5) {
            // Red edge fog, green distance fog, blue how far the pixel is as a share of the
            // render distance. Blue is there so strength and distance can be read off one still.
            fragColor = vec4(clamp(fogTerms.border, 0.0, 1.0),
                             clamp(dot(fogTerms.atm, vec3(0.3333)), 0.0, 1.0),
                             clamp(length(worldPos) / max(renderDistance, 1.0), 0.0, 1.0), 1.0);
            return;
        }
        lit = mix(lit, fogTerms.atmColor, clamp(fogTerms.atm, 0.0, 1.0));
        // plagueBorderColorWeight (fog.glsl): squared so a bright sun-side sky reading doesn't
        // glow in ahead of the render cutoff. See its own comment for why.
        lit = mix(lit, fogTerms.borderColor, plagueBorderColorWeight(fogTerms.border));
        lit = mix(lit, fogTerms.waterColor, clamp(fogTerms.water, 0.0, 1.0));

        lit = max(lit, vec3(0.0));
        lit *= fogTerms.uwTint;

#if PLAGUE_UNDERWATER
        // Exponential water fog only approaches closure, leaving loaded chunks as rectangles
        // against the depth<=0 branch; this hands the far field over before the render-distance
        // boundary, leaving the near 72% alone.
        //
        // uwClosureScale takes the shorter of render distance and (Water Distance Fog x
        // uwVisibilityMult), so a tight visibility setting closes the horizon near itself. 3x/6x
        // (night-or-rain/clear-noon) is where the veil above is already ~95% opaque on its own.
        //
        // Pure exponential (plagueGetWaterFog), not a near/far smoothstep band: smoothstep on
        // length(worldPos) is a sphere test against camera-relative position, and a sphere cutting
        // the frustum draws a curved, camera-following edge no retuning removes.
        //
        // Always on rather than a player option: it is redundant whenever distanceFog <=
        // renderDistance and does real work only past that, so "Water Distance Fog alone decides
        // underwater visibility" has to hold either way.
        if (u_WaterState.x > 0.5 && fragSubmerged) {
            float uwClearNoon = lighting.noonFactor * (1.0 - clamp(lighting.rainFactor, 0.0, 1.0));
            float uwVisibilityMult = mix(3.0, 6.0, uwClearNoon);
            float uwClosureScale = min(renderDistance,
                    plagueChunksToBlocks(u_WaterDistanceFog) * uwVisibilityMult);
            float uwClosureDist = length(worldPos);
            float horizonClosure = plagueGetWaterFog(uwClosureDist, uwClosureScale);
            if (debugView == DBG_UW_CLOSURE) {
                fragColor = vec4(uwClosureScale, uwClosureDist, horizonClosure, uwVisibilityMult);
                return;
            }
            // Same darkening the geometry veil takes (fog.glsl's terms.waterColor), or the two
            // paths disagree in brightness the moment the ramps do anything.
            vec3 closedVeil = plagueWaterFogColor(lighting)
                            * plagueWaterVeilDarkness(worldPos,
                                                      plagueChunksToBlocks(u_WaterDistanceFog),
                                                      plagueChunksToBlocks(u_WaterDarknessDepth),
                                                      u_WaterDistanceDarkness, u_WaterDepthDarkness)
                            * plagueAuthoredToLinear(
                                  plagueUnderwaterMult(renderDistance, renderDistance,
                                                       u_DepthDarkness, lighting, vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB)) * 0.85);
            vec3 closedRadiance = plagueUnderwaterClosedRadiance(
                    normalize(worldPos), closedVeil, lighting.sunFactor,
                    plagueChunksToBlocks(u_WaterDistanceFog));
            lit = mix(lit, closedRadiance, horizonClosure);
        }
#endif
    }
#endif

    fragColor = vec4(lit, 1.0);
}
