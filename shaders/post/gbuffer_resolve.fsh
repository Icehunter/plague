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
#moj_import <fornax_runtime:stars.glsl>
#moj_import <fornax_runtime:nebula.glsl>
#moj_import <fornax_runtime:shooting_stars.glsl>
#moj_import <fornax_runtime:celestials.glsl>
#moj_import <fornax_runtime:aurora.glsl>
#moj_import <fornax_runtime:main_lighting.glsl>
// Imported after sky.glsl: fog colour samples plagueGetSky along the view ray, which is why the
// render-distance edge disappears rather than hardening. water_composite.fsh imports the same file.
#moj_import <fornax_runtime:fog.glsl>
#moj_import <fornax_runtime:ocean_caustics.glsl>

uniform sampler2D u_Input0; // builtin.gNormal
uniform sampler2D u_Input1; // builtin.gAlbedo   (rgb albedo, a = sky light)
uniform sampler2D u_Input2; // builtin.gMaterial (r = smoothness, g = F0, b = porosity/SSS, a = block light)
uniform sampler2D u_Input3; // builtin.gAo       (r = per-texel AO, g = emission,
                            //                    b = parallax self-shadow, a = surface class)
uniform sampler2D u_Input4; // builtin.depth
uniform sampler2D u_Input5; // builtin.lightmap, vanilla's own light-colour LUT
// Bound by the engine as a hardware COMPARISON sampler, so this must be sampler2DShadow: texture()
// returns the depth-test result, not the stored depth.
uniform sampler2DShadow u_Input6; // sunShadowMap
uniform sampler2D u_Input7; // ssao. 1.0 unoccluded, 0.0 fully occluded

uniform sampler2D u_Input8; // builtin.gMotion, debug views only
uniform sampler2D u_Input9; // builtin.celestials, vanilla's sun + 8 moon-phase sprite atlas
uniform sampler2D u_Input10; // builtin.noise, engine's 512x512 tileable RGBA noise (R smooth, B fbm)
// Level 0 is a texel-exact copy of `ssr`; higher mips are the environment convolved to roughness,
// see plagueReflectionLod.
uniform sampler2D u_Input11; // ssrPrefilter. rgb = reflected colour, a = hit confidence, mipped.
// Appended, not inserted: u_InputN is positional, so inserting one shifts every later binding.
uniform sampler2D u_Input12; // builtin.waterDepth. Reversed-Z, 0.0 = no water surface here.
uniform sampler2D u_Input13; // causticsTexture
// Aliases sunShadowMap to a plain sampler2D via a different target string (graph.toml):
// FullscreenPassRunner keys the comparison-sampler branch on the exact string, so this reads raw
// stored depth where u_Input6's sampler2DShadow can only return a pass/fail compare.
uniform sampler2D u_Input14; // sunShadowMapRaw (raw, non-comparison. Debug only, see DBG_SHADOW_QUERY_3)

// Must come after u_Input10's declaration: PLAGUE_CLOUD_NOISE expands inline wherever clouds.glsl
// calls it, so an earlier import would reference u_Input10 before it exists. Also declares
// CLOUDS_VOLUMETRIC/u_CloudAltitude/u_CloudAmount/u_CloudSpeed/CLOUD_QUALITY, byte-identical to
// clouds_march.fsh's own copy (the option scanner merges same-name declarations).
#define PLAGUE_CLOUD_NOISE(uv) texture(u_Input10, uv)
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
// Appended last: GBufferDebugView.java is a lockstep enum, and inserting mid-list would shift
// every later ordinal out from under every shader's hardcoded branch numbers.
//
// Number carrier, not a visual: fragColor is read back at the crosshair by
// EnvSpecularRatioReadback.java (Fornax), and on-screen appearance is meaningless. Deep branch:
// dispatches after the material/lighting decode, not in the early G-buffer-read block above,
// since its inputs don't exist yet there. Same two caveats apply to every DBG_ENV_*/DBG_CONDUCTOR_*
// ordinal below.
#define DBG_ENV_SPEC_RATIO 21
// Every term the ratio above is built from, split across ordinals since one vec4 cannot hold
// them all; see each branch below for what it packs.
#define DBG_ENV_DECOMP_SKY 22
#define DBG_ENV_DECOMP_MIX 23
#define DBG_ENV_DECOMP_MAT 24
#define DBG_ENV_DECOMP_LOCAL 25
#define DBG_ENV_DECOMP_AO 26
#define DBG_ENV_DECOMP_RESIDUAL 27

// gAlbedo's raw byte and v_RawTint at runtime, measured rather than assumed. Split across two
// ordinals: seven raw numbers do not fit two vec4s, and 29 needs terrain.fsh's cooperation
// (u_AlbedoIdentityDebug) while 28 does not.
#define DBG_ALBEDO_WRITE_VS_READ 28
#define DBG_ALBEDO_IDENTITY_INPUTS 29

// Number carrier, deep branch (see DBG_ENV_SPEC_RATIO above). Reads the opaque-terrain-while-
// submerged branch (gated on fragSubmerged, not on the water surface mesh), so point the
// crosshair at submerged seabed/terrain. Reads 0,0,0,0 if not underwater-eligible when selected.
#define DBG_UW_CLOSURE 30

// Number carrier, deep branch (see DBG_ENV_SPEC_RATIO above): these three don't exist as values
// until the SHADOWS block's visibility()/ndotl/worldPos/sunDir are computed. Point the crosshair
// at the fragment under investigation.
#define DBG_SHADOW_QUERY_1 31
#define DBG_SHADOW_QUERY_2 32
#define DBG_SHADOW_QUERY_3 33

// Full-screen view of the shadow map's own contents, not a crosshair readback: splits "write-side"
// (caster absent from the map) from "read-side" (caster present, addressed wrong) in one look.
#define DBG_SHADOW_MAP_VIEW 40

// Seven number-carrier ordinals walking one pixel's specular chain end to end (decoded F0,
// split-sum energy, mirror content, wide content and its trust, the post-cut environment term,
// the direct sun term, the final HDR value). Ids 68-74 continue GBufferDebugView's shaderId range
// (64-67 are the water-shaft views). Same number-carrier/deep-branch caveats as DBG_ENV_SPEC_RATIO.
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

// Zenith-direction sample of the pack's own sky function, evaluated directly rather than through a
// LUT: cheaper and exact for the single direction ambient needs.
#define SKY_AMBIENT //[] compile "Ambient From Sky"
// How far sky-sampled ambient and the guessed-sky reflection content pull toward a sunlit-ground
// bounce hue. Luminance-preserving and sun-gated at both sites.
#define u_AmbientBounceWarmth 0.35 //[0.0..1.0 step 0.05] runtime "Ground Bounce Warmth"
const vec3 PLAGUE_GROUND_BOUNCE_TINT = vec3(1.30, 1.00, 0.62);

// For the Physical model (CUSTOM_LIGHT_COLORS off). Raising it cools torchlight toward daylight.
#define u_BlockLightTemp 2200.0 //[1500.0..8000.0 step 100.0] runtime "Block Light Temperature"

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    // Preferred over u_SkyCelestial: populated for every pack, whereas the globals sky block only
    // means anything once a pack owns the sky.
    //
    // xyz is the active light (sun by day, moon once it sets) — right for shading, wrong for
    // asking "is it day" (the moon at midnight sits where the sun sits at noon). w carries the
    // TRUE sun elevation, positive only while the sun is genuinely up.
    vec4  u_SunDirection;

    // This frame's sun and phase-indexed moon sprite rects {u0, v0, u1, v1} in builtin.celestials.
    // Minecraft 26.2 stores each moon phase as its own atlas sprite, so a disc pass cannot compute
    // its sub-region itself; the engine hands it over via CelestialSprites.
    //
    // Widens this block from 32 to 64 bytes; legal, since the engine always binds the full
    // u_PassParams buffer regardless of how much a given shader's block covers. Zero-rect when the
    // atlas has never been captured, guarded at the draw site.
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
// is written with a radial distortion (u_ShadowMapParams.x) that must be matched on read or every
// off-centre sample lands on the wrong texel, failing as acne rather than anything structural.
//
// Kept inline, not shared through shadow.glsl: extracting this into a thin wrapper over
// plagueSunVisibilityAt once turned every lit surface black with no provable logic difference
// found by static tracing — suspected cause is a sampler2DShadow passed across a function-parameter
// boundary, a known rough edge in some GLSL->SPIR-V lowering. Verify in a running client, not just
// check_shaders.sh, before re-attempting.

// Point-symmetric golden-angle (Vogel) disk PCF, radius ~ (i/N)^p with p and per-count disk radius
// fitted against a committed behaviour fixture (tools/verify_shadow_filter.py re-checks on every
// run). Vogel 1979. Each sample taken as a symmetric +/-offset pair, halving shot noise for the
// same tap budget. Reads u_Input6 as a global rather than a parameter, for the same reason this
// function is kept inline above.

// radius_i = diskRadius * (i / SHADOW_SAMPLES)^p. Fitted jointly across all four sample counts.
const float PLAGUE_SHADOW_RADIAL_EXPONENT = 1.266505;

// Disk outer radius per sample count, in (u_ShadowSoftness / SHADOW_RESOLUTION) texel units.
// Growing with N is expected: more rings need to reach further out to reproduce the same profile
// width with fewer discretization artifacts near the disk edge.
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

// Wider than the sun-disc penumbra: a caster occludes the sky dome broadly, and the ambient
// darkening needs a low-frequency signal or the sharp per-pixel visibility's noise blotches it.
const float PLAGUE_SHADOW_AMBIENT_BROADEN = 4.0;

// Overcast rain is a larger, softer light source, so the penumbra widens with the square of rain
// intensity (matched to the fixture's recorded full-rain d-scale).
const float PLAGUE_SHADOW_RAIN_WIDEN_SCALE = 3.0;

// temporalNoise rigidly rotates the whole disk per frame (interleaved gradient noise advanced by
// the golden-ratio fraction, Jimenez 2014), so the rotation equidistributes across the circle over
// many frames (Weyl equidistribution) — the condition the disk radii above were fitted under.
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

        visSum += texture(u_Input6, vec3(shadowUv + offset, refDepth));
        visSum += texture(u_Input6, vec3(shadowUv - offset, refDepth));
    }

    return visSum / float(2 * SHADOW_SAMPLES);
}

float sunVisibilityAt(vec3 worldPos, vec3 normal, vec3 sunDir, float rainFactorForShadow,
                      float radiusScale) {
    // Offset along the surface normal before projecting. Depth bias alone cannot fix acne on
    // surfaces near-parallel to the light: the required bias there approaches infinity, whereas a
    // normal offset stays bounded and scales naturally with texel size.
    float slope = 1.0 - abs(dot(normal, sunDir));
    vec3 biased = worldPos + normal * (0.05 + 0.35 * slope);

    // Added on top of the normal offset, not replacing it: the normal offset's effect on the
    // compared depth is proportional to dot(normal, sunDir), which goes to zero at grazing
    // incidence — exactly where slope above maximizes the world-space offset but its depth-axis
    // effect collapses to nothing. sunDir is unit length, so this term is angle-immune and closes
    // that gap without touching the normal offset's footprint-scaling job.
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

    // Divides by the declared resolution, not a literal 2048.0: the map really does resize per
    // SHADOW_RESOLUTION, and a hardcoded constant would detach softness from texel size at 1024/4096.
    float texelScale = (u_ShadowSoftness / float(SHADOW_RESOLUTION)) * radiusScale;

    return plagueSunVisibilityFiltered(shadowUv, refDepth, texelScale, temporalNoise,
                                       rainFactorForShadow);
}

float sunVisibility(vec3 worldPos, vec3 normal, vec3 sunDir, float rainFactorForShadow) {
    return sunVisibilityAt(worldPos, normal, sunDir, rainFactorForShadow, 1.0);
}

#if WATER_CAUSTICS
// One-tap visibility for water-volume samples. Unlike sunVisibility(), a position outside the
// covered shadow volume reads dark rather than inventing sunlight with no occlusion evidence.
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
    return texture(u_Input6, vec3(shadowUv, lightNdc.z));
}
#endif
#endif

#if PLAGUE_UNDERWATER && WATER_SUN_TINT
// Per-channel multiplier turning caustic focus (`pattern`, 0 = unfocused, 1 = full focus) into a
// sun-colour tint: wavelength-dependent Beer-Lambert absorption along the in-water path (red
// attenuates fastest, blue slowest — Mobley 1994 ch. 3; Pope & Fry 1997 absorption spectrum).
//
// Two additive terms per channel: GLOW grows as pattern^0.75 across the whole range (weak
// convergence still gathers light before tight focus); CORE stays zero until a per-channel
// threshold (blue lowest, red highest, matching blue's longer attenuation length) then grows as
// (pattern - threshold)^~1.75 — exponent above 1 keeps the join smooth, not kinked.
//
// Absolute levels (including the above-1 blue peak) are the calibration that restores the caustic
// swing this pack's display pipeline would otherwise compress, fitted by
// tools/fit_uw_sun_tint_parity.py against the committed fixture.
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
    // vanilla's own sky show through rather than painting over it when this pack does not own the sky.
    float depth = texture(u_Input4, texCoord).r;

    vec4 normalSample = texture(u_Input0, texCoord);
    vec4 albedoSample = texture(u_Input1, texCoord);

int debugView = int(u_Param3 + 0.5);
    if (debugView != 0) {
        if (debugView == DBG_NORMALS)  { fragColor = vec4(normalSample.xyz * 0.5 + 0.5, 1.0); return; }
        if (debugView == DBG_ALBEDO)   { fragColor = vec4(albedoSample.rgb, 1.0); return; }
        if (debugView == DBG_MATERIAL) { fragColor = vec4(texture(u_Input2, texCoord).rgb, 1.0); return; }
        if (debugView == DBG_MOTION)   { fragColor = vec4(abs(texture(u_Input8, texCoord).rg) * 40.0, 0.0, 1.0); return; }
        if (debugView == DBG_SSAO)     { fragColor = vec4(vec3(texture(u_Input7, texCoord).r), 1.0); return; }
        if (debugView == DBG_AO)       { fragColor = vec4(vec3(texture(u_Input3, texCoord).r), 1.0); return; }
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
            // texCoord is the shadow map's own UV: this is the light's view, not the camera's, so a
            // caster's silhouette here will not line up with where it sits on screen anywhere else.
            //
            // No linearization needed: ShadowCamera projects orthographically (setOrtho), so the raw
            // stored value already varies linearly. Forward-Z, clear = 1.0.
            //
            // Remapped for legibility: real geometry measures into roughly the bottom fifth of the
            // stored range (SHADOW_MAP_VIEW_OCCUPIED, empirical — retune if ShadowCamera.java's
            // depthHalfExtent changes) while the clear sentinel sits at the top; a naive grayscale
            // ramp crushes every real caster near-black. The clear sentinel gets its own synthetic
            // colour so "nothing rasterized" can't be misread as "far geometry".
#ifdef SHADOWS
            const float SHADOW_MAP_VIEW_OCCUPIED = 0.2;
            const vec3 SHADOW_MAP_VIEW_CLEAR_COLOR = vec3(1.0, 0.0, 0.7);
            ivec2 dbgShadowMapTexel = ivec2(texCoord * vec2(textureSize(u_Input14, 0)));
            float dbgShadowMapDepth = texelFetch(u_Input14, dbgShadowMapTexel, 0).r;
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
            fragColor = vec4(vec3(texture(u_Input2, texCoord).a), 1.0);
            return;
        }
    }

    // --- Time-of-day drivers and light colours ----------------------------------------------------
    //
    // Computed before the sky: the sky is a function of these same values, so the dome and the
    // ground light under it can never disagree about the time of day.
    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);

    // u_SunDirection.xyz is the active light (sun by day, moon once it sets), which at midnight
    // reads as "sun overhead" if used to decide day/night. u_SunDirection.w is the TRUE sun's
    // elevation regardless of which body is lighting the scene, so it answers "is it day".
    float trueSunHeight = u_SunDirection.w;
    // Below the horizon the sun contributes nothing, with a soft edge so dusk is not a hard switch.
    float dayFactor = smoothstep(-0.08, 0.08, trueSunHeight);

    // u_SkyColor.rgb is populated for every pack (Fornax's SkyProbe reads it off the camera's
    // environment probe), unlike u_SkyCelestial which needs sky ownership. Clamped since vanilla's
    // sky colour goes near-zero in a thunderstorm and pow() of a negative is NaN.
    //
    // Built unconditionally from this file's runtime options regardless of which model
    // CUSTOM_LIGHT_COLORS selects: downstream consumers read .light/.ambient unconditionally.
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
    // --- Sky ---------------------------------------------------------------------------------------
    //
    // Reversed-Z: depth clears to 0.0 = far, so depth zero means nothing was drawn here. With
    // SKY_PROCEDURAL the engine cancels vanilla's sky pass and this paints the dome in its place.
    if (depth <= 0.0) {
#ifdef SKY_PROCEDURAL
        // Unprojects at a far-but-finite depth (0.0001, reversed-Z) rather than the true far plane
        // (0.0, degenerate — posH.w is 0 there). Unprojecting near the eye instead of far amplifies
        // Minecraft's view-bob translation (which lives in the projection matrix, not the
        // model-view) into a large spurious rotation of the reconstructed ray; far-but-finite keeps
        // that translation negligible against the distance, leaving only the real ~0.25 degree bob.
        // Same constant as motion_fill.fsh's SKY_PROXY_DEPTH for the identical problem.
        vec4 skyClip = vec4(texCoord * 2.0 - 1.0, 0.0001, 1.0);
        vec4 skyWorldH = u_InvProjModelView * skyClip;
        vec3 viewRay = normalize(skyWorldH.xyz / skyWorldH.w);

        // Against the true sun, not the active light: the warm band and glare stay on the sun's
        // side of the sky even after the moon takes over lighting duty.
        float skyDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));

        vec3 skyOut;
        vec3 auroraTerm = vec3(0.0);

#if PLAGUE_UNDERWATER
        // A submerged no-hit ray is a water ray of maximum length, not a sky ray to paint over
        // afterward: it takes the water path directly rather than computing and discarding the
        // dome/stars/nebula/discs/aurora.
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

            skyOut = plagueGetSky(skyColours, VdotU, VdotS, skyDither, true, false);

            // Additive, not blended: stars are emitters seen through the atmosphere, so a bright
            // sky washes them out via the day/night term inside plagueGetStars.
            float invNoonFactor = 1.0 - lighting.noonFactor;
            float syncedTime = u_SkyState.w * 0.05;  // ticks to seconds; see stars.glsl's header
            vec2 starCoord = plagueStarCoord(viewRay, PLAGUE_STAR_SPHERENESS, syncedTime);
            skyOut += plagueGetStars(starCoord, VdotU, VdotS, 1.0, 0.0,
                                     invNoonFactor * invNoonFactor,
                                     plagueSunVisibility, 1.0 - rainFactor, u_SunriseColor.w);

            // Own coords (sphereness 0.75, not the star field's 0.5); additive order vs. stars
            // doesn't matter.
            skyOut += plagueGetNightNebula(viewRay, VdotU, VdotS, syncedTime,
                                           plagueNightFactor, 1.0 - rainFactor, u_SunriseColor.w);

            // Reuses starCoord so meteors travel the same projected plane as the stars. moon phase
            // index (u_SkyCelestial.w): a new moon lets more of them through.
            skyOut += plagueGetShootingStars(starCoord, VdotU, VdotS, syncedTime,
                                             invNoonFactor * invNoonFactor, plagueSunVisibility,
                                             1.0 - rainFactor, u_SunriseColor.w, u_SkyCelestial.w);

            // --- Sun and moon discs -------------------------------------------------------------
            //
            // Drawn from the real celestials atlas, not procedural blobs, so a resource pack's own
            // sun/moon art keeps working. SKY_PROCEDURAL cancels vanilla's own draw of these.
            //
            // Moon visibility is driven from the moon's actual elevation (-trueSunDir), not just
            // nightFactor, so the atlas moon stays present whenever it's geometrically above the
            // horizon rather than vanishing on a stale time driver.
            float plagueMoonDiscGlow = smoothstep(-0.03, 0.08, -sunDirTrue.y)
                                      * (1.0 - plagueSunVisibility);
            // Same radiances the world is lit by, so the disc and its shadows can never disagree
            // about colour, and it reddens through sunset because its light does.
            vec3 discEyePos = plagueAirEyePos(u_CameraAbs.y);
            skyOut += plagueCelestialDiscs(viewRay, sunDirTrue, u_Input9,
                                           u_SunSpriteRect, u_MoonSpriteRect,
                                           1.0 - rainFactor, plagueMoonDiscGlow,
                                           plagueSunColor(discEyePos, sunDirTrue),
                                           plagueMoonColor(discEyePos, -sunDirTrue));

            // Marches the flattened view ray, so it's the only sky element with a real cost curve;
            // gated to zero for daylight, rain, and anything but a full moon by default.
            auroraTerm = plagueGetAurora(viewRay, VdotU, skyDither, u_CameraAbs.xz, syncedTime,
                                         plagueSunVisibility, rainFactor, u_SkyCelestial.w,
                                         u_Input10);
            skyOut += auroraTerm;
        }

#ifdef PLAGUE_DEBUG_AURORA_ONLY
        // See aurora.glsl: isolates the march from everything drawn over it.
        fragColor = vec4(auroraTerm * u_AuroraDebugGain, 1.0);
#else
        fragColor = vec4(skyOut, 1.0);
#endif
#else
        // Pack does not own the sky: keep vanilla's, as before.
        discard;
#endif
        return;
    }

    // gAlbedo holds a display-encoded byte: terrain/entities/block_entities each decode their raw
    // texture sample, multiply by vertex colour/tint/shade, then re-encode before writing (see
    // terrain.fsh's `rawAlbedo` — `decode(tex*k) != decode(tex)*k` for sRGB, so multiplying in
    // display space first is wrong). This is the one place that recovers the true linear
    // reflectance every computation below needs; gMaterial/gAo/gNormal and .a (sky light, not
    // colour) are plain data and must not be decoded.
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
    float blockLight = texture(u_Input2, texCoord).a;

    // Normalised 0..1 emitter luminance: gAo is RGBA8_UNORM, so the scale (PLAGUE_EMISSION_MAGNITUDE)
    // is applied downstream in plagueEmittedRadiance instead, where the nonlinear saturation ramp
    // needs the normalised value rather than an already-scaled one.
    float emitterLum = texture(u_Input3, texCoord).g;   // gAo.g

    // NOTE: vanilla's lightmap is no longer sampled for lighting; block light uses this pack's own
    // fitted curve and colour (main_lighting.glsl). sampleLightmap() is kept for the engine's binding
    // but unused today.

    // Per-texel AO (labPBR _n blue) darkens indirect light only: applying it to direct sun would
    // double-darken surfaces the sun can plainly see.
    float ao = texture(u_Input3, texCoord).r;
    // Parallax self-shadow occludes direct sun, so it multiplies the shadow term rather than AO: it
    // must survive full daylight, where crevice shadow reads strongest.
    float pomShadow = texture(u_Input3, texCoord).b;   // gAo.b

#ifdef SSAO_ENABLED
    // Multiplies the per-texel labPBR AO rather than replacing it: different scales (surface detail
    // vs scene geometry), both real.
    ao *= texture(u_Input7, texCoord).r;
#endif

    // Outside the shadow block: the specular term below needs worldPos regardless of whether
    // SHADOWS is compiled in. Verified with glslangValidator in both configurations.
    vec4 clip = vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec4 worldH = u_InvProjModelView * clip;
    vec3 worldPos = worldH.xyz / worldH.w;

#if PLAGUE_UNDERWATER
    // Distance to the water surface on this pixel's ray, or 1e9 if it crosses none. Shared by the
    // caustic submersion gate and the fog site's in-water leg below.
    float uwSurfDist = 1e9;
    float uwSurfWorldY = -1e9;
    {
        float uwSurfDepth = texelFetch(u_Input12, ivec2(gl_FragCoord.xy), 0).r;
        if (uwSurfDepth > 0.0) {
            vec4 uwSurfH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, uwSurfDepth, 1.0);
            vec3 uwSurfPos = uwSurfH.xyz / uwSurfH.w;
            uwSurfDist = length(uwSurfPos);
            uwSurfWorldY = u_CameraAbs.y + uwSurfPos.y;
        }
    }
    // Consumed by sunColour; identity on every dry path. Declared here (not just in the caustic
    // block) so the SHADOWS-off build — which compiles the whole builder out — keeps this as a
    // no-op rather than undefined.
    vec3 uwSunTint = vec3(1.0);
    // Added to the lit scene before fog; 0 on every dry/gated path.
    float uwWeb = 0.0;
    // Separate from the web itself so bloom can be tuned without changing caustic light output.
    float uwWebBloom = 0.0;
    // Narrow by construction (smoothstep(0.52,0.90) squared): lifts filament cores past display
    // white without touching the body.
    float uwWebHot = 0.0;

    // Submerged: from in the water, everything closer than the surface (or any ray crossing none)
    // is in the volume; from dry air, everything beyond the surface is. Both arms additionally
    // require the fragment to sit below the crossing (the dry-land pin below): "the ray crossed a
    // water surface" is not "the fragment is under water" — a ray crossing an inlet or wave crest
    // can carry on to dry terrain above the waterline.
    float uwFragDist = length(worldPos);
    float uwDirY = worldPos.y / max(uwFragDist, 1e-4);
    float uwFragWorldY = u_CameraAbs.y + worldPos.y;
    // Dry-eye classification uses the real surface crossing on this pixel (reconstructed from
    // waterDepth above), deliberately independent of u_WaterState.z: that global is scanned only in
    // the camera's column, so it misses neighbouring water a standing-on-island camera can't see.
    //
    // uwNearWaterlineFallback below covers the case the translucent prepass legitimately misses a
    // surface at the bobbing waterline (uwSurfDist stuck at its 1e9 sentinel): bounded to the
    // camera-column altitude near the waterline, not an unbounded direction test, which would
    // misclassify dry caves below sea level as underwater.
    bool uwHasSubmergedSurfaceCrossing = uwSurfDist < 1e8 && uwSurfDist < uwFragDist
            && uwFragWorldY < uwSurfWorldY;
    bool uwNearWaterlineFallback = abs(u_CameraAbs.y - u_WaterState.z) <= 0.35 && uwDirY < -1e-4;
    bool fragSubmerged = u_WaterState.x > 0.5
            ? (uwFragDist < uwSurfDist && uwFragWorldY < u_WaterState.z)
            : (uwHasSubmergedSurfaceCrossing || (uwNearWaterlineFallback
               && uwFragWorldY < u_WaterState.z));
#endif

#ifdef SHADOWS
    // Queried unconditionally, not gated behind ndotl > 0.0: that gate is harmless for the diffuse
    // term (N.L already zeroes it) but wrong for specular/ambient/cloud-shadow/water-glitter, which
    // all read a self-shadowed slope as fully lit regardless of true occlusion. Faded separately
    // where there's no sky access below, so an indoor fragment isn't double-darkened.
    //
    // The acne offset must ride the geometric surface, not the bumped normal: a normal-mapped
    // groove would wobble the projected sample point per texel and paint patchy occlusion
    // following the texture. Screen-space derivatives of the reconstructed position give the true
    // face plane; falls back to the shading normal where the cross product degenerates (depth edges).
    vec3 shadowGeomNormal = cross(dFdx(worldPos), dFdy(worldPos));
    float shadowGeomLen = length(shadowGeomNormal);
    shadowGeomNormal = shadowGeomLen > 1e-6 ? shadowGeomNormal / shadowGeomLen : normal;
    if (dot(shadowGeomNormal, normal) < 0.0) {
        shadowGeomNormal = -shadowGeomNormal;
    }
    float visibility = sunVisibility(worldPos, shadowGeomNormal, sunDir, rainFactor);
    // Queried at PLAGUE_SHADOW_AMBIENT_BROADEN times the filter radius; the guessed-sky
    // desaturation below rides this field at every slider position, and the sharp per-pixel
    // visibility's noise would paint ink patches on any surface whose appearance is the
    // reflection chain.
    float ambientVisibility = sunVisibilityAt(worldPos, shadowGeomNormal, sunDir, rainFactor,
                                              PLAGUE_SHADOW_AMBIENT_BROADEN);

    // A read-only, debug-branch-local mirror of sunVisibilityAt's bias/projection math, not a
    // call into it: touching that function once already shipped a black-screen regression (see its
    // own comment above).
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
        // DBG_SHADOW_QUERY_3: the actual stored depth at dbgShadowUv, read through u_Input14 as a
        // plain sampler2D — u_Input6's sampler2DShadow can only return a pass/fail compare, never
        // the raw texel. Clamped UV means this is only meaningful when QUERY_2's inRange was 1.0.
        ivec2 dbgShadowTexel = ivec2(clamp(dbgShadowUv, 0.0, 1.0) * vec2(textureSize(u_Input14, 0)));
        float dbgStoredDepth = texelFetch(u_Input14, dbgShadowTexel, 0).r;
        // Red = the depth this query compares (the raw light-clip z, the write side stores it
        // unscaled), blue = what the map actually holds there; green intentionally empty. Matching
        // red/blue means the comparison would pass.
        fragColor = vec4(dbgRawDepth, 0.0, dbgStoredDepth, 0.0);
        return;
    }

    // Fades shadows over the last quarter of shadow distance rather than a hard map-boundary circle
    // sweeping across the ground as the player moves.
    float shadowDist = length(worldPos);
    float fadeStart = u_ShadowDistance * 0.75;
    visibility = mix(visibility, 1.0,
                     clamp((shadowDist - fadeStart) / max(u_ShadowDistance - fadeStart, 1e-4), 0.0, 1.0));
    // Real moonlight is roughly a millionth of sunlight, so shadows from a low moon should read as
    // a suggestion, not a noon-hard edge. Faded rather than switched so the sun-to-moon handoff at
    // dusk doesn't snap.
    float casterStrength = mix(0.18, 1.0, dayFactor);
    // skyLight (vanilla's sky lightmap) attenuates one level per water block and hits zero by ~15
    // blocks down, which would discard the shadow map's result entirely underwater even though the
    // map itself is correct. Below the surface, use the same transmission curve the rest of the
    // underwater arm gates on (exp(-d/24)) instead — that answers "how much sun reaches this
    // fragment", where the lightmap answers "how many blocks of medium is it behind".
    //
    // max(), not a replacement: above water and near the surface the lightmap stays in charge.
    // Keyed on the fragment's own depth, not camera submersion, so a seabed seen from a boat still
    // gets its shadows.
    float shadowFragAltitude = u_CameraAbs.y + worldPos.y;
    float shadowSubmergedDepth = max(u_WaterState.z - shadowFragAltitude, 0.0);
    float shadowSkyGate = shadowSubmergedDepth > 0.0
            ? max(skyLight, exp(-shadowSubmergedDepth / 24.0))
            : skyLight;
    // Clamped: GLSL mix() extrapolates past its endpoint, and an unclamped strength above 1.0
    // drives `shadow` negative across the deep half of every penumbra, which then subtracts light
    // instead of removing it. Above 1.0 belongs to the uniform end-stage shadowFade, never to
    // extrapolation here.
    float shadow = mix(1.0, visibility,
                       clamp(u_ShadowStrength, 0.0, 1.0) * shadowSkyGate * casterStrength)
                 * pomShadow;

    // A separate query from sunVisibility() above: the sun shadow map only knows about opaque
    // terrain, never the cloud volume, so this multiplies in as its own factor.
    //
    // Beer-Lambert on the genus table's `tau` (optical depth straight down through the slab,
    // tools/derive_cloud_types.py). The slab thickness cancels algebraically (extinction/block =
    // tau/depth, slant path = depth/sunDir.y, product = tau/sunDir.y), which is why this is three
    // multiplies and not a march, and why a low sun is shadowed by a longer path with no thickness
    // constant to retune.
    //
    // Mean of three heights, not max: optical depth is a path average by definition, so max would
    // overstate the shadow by however much the cloud varies vertically. Quarter-height samples
    // avoid both faces where the profile is ramping.
    //
    // Coarse field, same reason clouds.glsl's own sun march uses it: an integral doesn't care about
    // the high-frequency detail, and the four-octave erosion field would be the most expensive
    // thing here at full resolution.
    float cloudShadow = 1.0;
#if CLOUD_SHADOWS && CLOUDS_VOLUMETRIC
    if (sunDir.y > 1e-3) {
        vec3 fragAbsPos = u_CameraAbs.xyz + worldPos;
        float syncedTime = u_SkyState.w * 0.05;
        // The same deck the march resolves, from the same signals, so a shadow can never fall from a
        // cloud that is not in the sky. This is the call site the driver signature was fixed early
        // to protect, since it is the one nobody remembers to update.
        PlagueCloudDeck shadowDeck = plagueCloudLowDeck(
                rainFactor,
                clamp(u_FrameState.z, 0.0, 1.0),
                clamp(u_FrameState.w, 0.0, 1.0),
                int(u_CameraSkyLight.y + 0.5),
                u_SunDirection.w,
                syncedTime);
        vec2 shadowDrift = plagueCloudDrift(shadowDeck, syncedTime);

        float meanDensity = 0.0;
        for (int i = 0; i < 3; i++) {
            float sampleY = shadowDeck.base + shadowDeck.depth * (0.25 + 0.25 * float(i));
            float t = (sampleY - fragAbsPos.y) / sunDir.y;
            // t <= 0: this height is below the fragment (above the deck, or on a mountain inside
            // it), so skip rather than sample behind the fragment.
            if (t > 0.0) {
                meanDensity += plagueCloudDensityCoarse(fragAbsPos + sunDir * t,
                                                        shadowDeck, shadowDrift);
            }
        }
        meanDensity /= 3.0;

        cloudShadow = exp(-shadowDeck.tau * meanDensity / max(sunDir.y, 1e-3));
    }
#endif
    shadow *= cloudShadow;

#if PLAGUE_UNDERWATER
    // --- Submerged sunlight: the sun's own in-water leg ----------------------------------------
    //
    // Direct sunlight reaching a submerged fragment is coloured by its own path through the water —
    // a leg separate from the eye's path that water_composite's absorption handles, so no double
    // count. Built here and multiplied into sunColour below (the variable both specular and diffuse
    // direct terms read). Reads the flat representative focus (0.5775) deliberately: the animated
    // web is a separate scene-add and no longer rides this tint.
    {
        float fragDist = uwFragDist;
        if (fragSubmerged) {
            // The web is additive over a neutral tint. The pattern is sparse by design (mean 0.01,
            // meant to be added, not multiplied), and multiplying the direct term by
            // (0.35 + 0.65*p01) was a 65% flat darkening wearing a caustic's name, with the
            // depth fade inverted around a midpoint constant inherited from the retired shaping
            // curve. The absorption tint stays the flat physical constant below; the web rides
            // as (1 + web) on top: neutral where the texture is dark, focused light where it
            // is bright, fading to neutral with depth in the correct direction.
            float pattern = 0.5775;
#if WATER_CAUSTICS
            // Cost gate (four wave-field evaluations per fragment): dayFactor since night light is
            // moonlight-weak, and 152 blocks since the falloff has flattened the fine octaves by
            // then anyway. fragSubmerged already proved this pixel is in the water volume, so this
            // does not re-gate on vanilla's attenuated sky light or camera-column altitude — both
            // can be zero with a valid pond crossing still present.
            if (dayFactor > 0.02 && fragDist < 152.0) {
                // Faded, not cut: a hard edge at the 96-block fps bound draws a visible line across
                // the seabed when looking down from above water.
                float causticRangeFade = 1.0 - smoothstep(112.0, 152.0, fragDist);
                // Caustic contrast washes out with depth much faster than sun transmission does
                // (exp(-depth/24) dims only 25% over 8 blocks; real caustic contrast is gone by
                // ~15m), so this uses its own, steeper falloff (exp(-depth/12)).
                float uwCFragY = worldPos.y + u_CameraAbs.y;
                float uwCSurfY = u_WaterState.x > 0.5
                        ? u_WaterState.z
                        : uwHasSubmergedSurfaceCrossing ? uwSurfWorldY : u_WaterState.z;
                float uwCDepth = max(uwCSurfY - uwCFragY, 0.0);
                // The falloff scale moved from 12 to 8 once it was clear caustics still were not
                // reading noticeably shinier closer to the surface: at /12 an 8-block seabed sat
                // at 0.51 vs a 2-block shore's 0.85, a 1.7x ratio the eye reads as "same". At /8
                // the same pair is 0.37 vs 0.78, 2.1x, and a 15-block floor is at 0.15. Note the
                // fade rides the fragment's depth, which is the physics: the same seabed looks the
                // same whether the camera floats or dives; what changes it is how much water sits
                // above the sand. Judge it shore-vs-deep, not by bobbing over one spot. It then
                // moved from 8 to 14 once caustics were reading as barely visible at all, and from
                // 14 to 10 alongside the water-optics patch below, whose sun-projected sampling
                // concentrates the web enough that the faster fade reads as "brighter near the
                // surface" instead of "gone everywhere".

                // Sun-directed projection: project the fragment back along the incoming sun ray to
                // the surface point whose refracted light reaches it. Sampling raw fragment xyz
                // glued the pattern independently to every wall; this shift is why floors and the
                // walls beside them now share one moving web. Same wave clock the visible surface
                // runs (terrain.vsh's u_SkyState.w / 20).
                vec3 causticWorldPos = worldPos + u_CameraAbs;
                // A wall's horizontal (along-the-wall) axis reaches the field for free: moving
                // along the wall moves worldPos.xz directly, gain 1. The vertical axis only reaches
                // the field through this shear term, so its gain has to match that same 1 or that
                // axis alone reads as stretched. An earlier magnitude, sunDir.xz/sunDir.y, is
                // tan(sun zenith angle): it explodes near the horizon (shear into "zebra" stripes)
                // and collapses toward noon (vertical gain going to 0 while the horizontal axis
                // stays at 1), which is what made vertical faces stretch the caustic texture
                // instead of a uniform stretch. Splitting direction (still the sun's azimuth, so
                // streaks still rotate with the sun) from magnitude (fixed at 1, matching the
                // horizontal axis) keeps both wall axes proportioned the same at every sun angle
                // instead of swinging between those two failure modes.
                vec2 sunAzimuthRaw = sunDir.xz;
                float sunAzimuthLen = length(sunAzimuthRaw);
                vec2 sunAzimuth = sunAzimuthLen > 1e-4 ? sunAzimuthRaw / sunAzimuthLen : vec2(1.0, 0.0);
                causticWorldPos.xz += sunAzimuth * uwCDepth;
                // One sun-projected field for every face, see plagueCausticsProjected. The
                // triplanar's three independent projections are why floors drifted diagonally and
                // walls ran top-to-bottom: three animations, not one pattern.
                // Runtime options arrive as floats in u_PackOptions: PackOptionsLayout types every
                // one of them float, and DefineRewriter strips the #define at pack build. So a
                // toggle is tested > 0.5, never against an int literal, and no float() cast is
                // needed. Offline this file still has its #define, so an int comparison compiles
                // clean in check_shaders.sh and fails only in a running client.
                float causticRate = (u_CausticSpeed * 0.01)
                                  * (u_CausticSyncWaves > 0.5 ? u_WaveSpeed : 1.0);
                float causticSize = u_CausticScale * 0.01;
                float causticP01 = plagueCausticsProjected(u_Input13, causticWorldPos,
                                                           (u_SkyState.w / 20.0) * causticRate,
                                                           causticSize);

                // Low sun crosses the surface at grazing incidence and transmits almost nothing
                // to focus (the patch's elevation gate), and it is half of the measured
                // "web with no sunlight behind it" defect: at sunset the submerged direct term
                // is two orders under noon while the web previously rendered at full strength.
                float sunElevationGate = smoothstep(0.12, 0.35, sunDir.y);

                // Caustics no longer fade with depth on their own. causticContrast used to be
                // exp(-depth/10), which is 0.05 by thirty blocks, and it was only one of three
                // depth terms multiplying this same contribution (the spectral extinction below,
                // and uwSunGate at the composition site), so the product was ~0.006 and caustics
                // simply did not exist below the shallows. The requirement is the opposite: they
                // should show everywhere a shadow does not, regardless of depth. Occlusion is what
                // should decide whether a caustic lands, and that is causticShadow's job, not depth's.
                //
                // Depth now shapes them instead of deleting them. Near the surface the water column
                // has not yet smeared the light the waves focused, so peaks stay sharp and flare;
                // with depth that sharpening averages out and the same web reads as a steady glow.
                // The twinkle is a cheap world-anchored oscillation rather than a second texture
                // fetch: the triplanar sample is eight taps and this rides the one already taken.
                float shimmerDepth = max(plagueChunksToBlocks(u_CausticGlowDepth), 1.0);
                float shimmerFall = exp(-uwCDepth / shimmerDepth);
                // No synthetic twinkle: a sine over world position and time was a second,
                // unrelated pattern laid over the caustics. It read as an oscillating wash rather
                // than as light, because nothing in it came from the wave field that actually
                // focuses the light. Shaping the real pattern is what produces the effect.
                // Squared in causticP01 so the gain lands on peaks rather than lifting the whole
                // web, which is what makes it bloom (the bloom pass is unthresholded, so brighter
                // peaks glow on their own) instead of just getting brighter overall.
                // Depth dims to 50% and stops there, not to zero: the deep seabed should still
                // read caustics, just fainter, so it keeps half-strength caustics however far down
                // it is, where before three multiplied exponentials had taken it to 0.006 by thirty
                // blocks.
                float causticDepthDim = mix(1.0, 0.5, clamp(uwCDepth / shimmerDepth, 0.0, 1.0));

                // Shaping: near the surface the water column has not yet smeared what the waves
                // focused, so the web is high contrast, narrow bright filaments against near-dark
                // between them. With depth that averages out into an even wash. smoothstep over the
                // upper part of the range is that contrast: it keeps the peaks and drops the
                // low-amplitude noise, and mixing toward it by shimmerFall makes the transition a
                // property of depth rather than a switch.
                // Shaping now lives in the pattern, not in a curve bolted on here. The base field
                // was 0.60 * softCell + 0.25 * filament, topping out near 0.85 before glimmer, so
                // every downstream threshold collapsed it toward isolated sparkles, which showed up
                // clearly in renders as thin sparkle dots rather than a connected web. It is
                // 0.72 + 0.28 now, a full-range cellular-body plus filament split, so the connected
                // cell structure survives.
                //
                // An earlier attempt sharpened with a smoothstep here and multiplied a gain on
                // top. That was the wrong place: it threw away the mid-range the cells live in and
                // then tried to recover brightness, which is how the web ended up as thin dots with
                // no body. Shape the field, do not rescue it afterwards.
                float shaped = causticP01 * causticDepthDim * causticRangeFade;

                // The bloom field is a separate five-tap dilation of only the hot crests, world-
                // attached via screen derivatives so the halo stays compact instead of becoming a
                // world-space smear. Fragment stage only (dFdx/dFdy), verified that the two files
                // importing ocean_caustics.glsl are both .fsh.
                uwWebBloom = plagueCausticsBloomProjected(u_Input13, causticWorldPos,
                                                          (u_SkyState.w / 20.0) * causticRate,
                                                          causticSize)
                           * causticDepthDim * causticRangeFade;

                // The package's optional HDR seed, left unwired at first, is the piece that
                // produces the look. Bloom strength times HDR strength tops out near
                // 0.51, so nothing ever crossed display white and the shine this term exists to
                // produce was unreachable at any slider setting. This term is the hot crests alone.
                uwWebHot = plagueCausticsBloomSeed(causticP01) * causticDepthDim
                         * causticRangeFade;

                uwWeb = shaped * sunElevationGate * smoothstep(0.02, 0.15, dayFactor);
            }
#endif
            // WATER_SUN_TINT is a bisection switch, see underwater.glsl's own comment. Default on;
            // gated independently of WATER_CAUSTICS above: this recolours the sun's own in-water
            // path, the caustic web above is a separate scene-add. Off: uwSunTint keeps its
            // declared vec3(1.0) identity, so sunColour's later multiply is a no-op and this leg
            // contributes nothing, same as a dry fragment.
#if WATER_SUN_TINT
            // The tint itself lives at file scope (plagueUnderwaterSunTint, above main): the
            // pack's fitted focus-to-colour curve, in linear light directly. It multiplies
            // sunColour, and its absolute level already folds in the measured display-pipeline
            // calibration (solved by contrast ratio from the user's frozen captures: the shaping
            // curve saturates past ~gain 120, contrast asymptoting near 3.3%, so the caustic
            // contrast the accepted look shows has to come from this direct term).
            uwSunTint = plagueUnderwaterSunTint(pattern);
            // The web does not ride this tint any more, because a sparse caustic pattern has to be
            // added to the scene, not multiplied into it: multiplying the submerged direct term
            // instead (a value already shrunk by transmission, the water tint and the shadow)
            // multiplies something tiny and stays tiny, however large the factor, invisible
            // against the sand even when the ratio between web and direct term looked correct.
            // The web is applied as a scene add at the fog site instead.
#endif
        }
    }
#endif
#else
    float shadow = 1.0;
#endif

    // --- Sun and sky as two separate colours ---------------------------------------------------
    //
    // This is where a shaderpack's character actually comes from, and using one light colour for
    // everything is why this looked washed out however the tonemap was tuned. Direct sun and sky
    // ambient are separate, differently coloured, and the sun is intense: warm key against cool
    // fill is the whole effect, and a single averaged colour cannot produce it at any exposure.
    //
    // What used to sit here was a hand-authored sketch of that idea: the right structure, one
    // correct constant, and everything else invented, including the entire ambient system. It has
    // been replaced by the pack's own fitted colour model: see
    // shaders/include/light_and_ambient_colors.glsl, accepted in game, with its own drivers, its
    // own day/night curve, its own rain branch and its own reference intensities.
    //
    // Every input is read from vanilla through the engine (sky colour, sun angle, sun elevation,
    // rain), so time of day and weather are accounted for rather than approximated by a clock this
    // shader keeps itself.

#if CUSTOM_LIGHT_COLORS
    vec3 sunColour = lighting.light;
#else
    // Physically derived. u_SunDirection.xyz is the active light, sun by day, moon once it sets,
    // so the transmittance integration is fed whichever body is actually lighting the scene, and the
    // illuminance constant is chosen to match. That keeps one light direction driving both the colour
    // and the shadowing, which is what stopped midnight being lit as noon in the first place.
    vec3 airEyePos = plagueAirEyePos(u_CameraAbs.y);
    vec3 sunColour = trueSunHeight > 0.0
            ? plagueSunColor(airEyePos, sunDir)
            : plagueMoonColor(airEyePos, sunDir);
    // Rain still flattens the direct term. That is weather, not atmosphere, so it belongs
    // here on the direct light rather than in the air model. 0.95 leaves a twentieth of the
    // direct sun at full rain: overcast is not black, and the residual keeps shadows readable.
    sunColour *= 1.0 - rainFactor * 0.95;
#endif
#if PLAGUE_UNDERWATER
    // Submerged fragments take the sun through the water: the tint built above. One site, so the
    // specular and the diffuse direct term cannot disagree about it.
    sunColour *= uwSunTint;
#endif
    // The direct light takes the same warmth, from the same control, so a scene cannot end up with
    // warm bounce and neutral key light or the reverse.
    sunColour = plagueWarmLowSun(sunColour, sunDirTrue.y);

#ifdef SKY_AMBIENT
    // Ambient sampled from the sky this pack now renders. One way to get there is sampling the
    // rendered sky texture at the straight-up direction and scaling by pi; that needs a LUT when a
    // pipeline samples the sky in many directions, but ambient needs exactly one direction,
    // straight up, so the sky function is evaluated directly here instead. Cheaper and exact rather
    // than filtered.
    //
    // No glare and no ground: this is the sky's own light, not a view of it. Dither is zero for the
    // same reason: a per-pixel dither belongs on a gradient being looked at, not on a light colour,
    // where it would just add noise to every surface in frame.
    // The hemisphere, not the zenith, and the comment below is kept because it records exactly why
    // that was wrong. A surface sees the whole dome. At sunset the dome is dominated by a bright warm
    // band low on the sun's side while the zenith is at its deepest blue, so sampling straight up lit
    // the world with the single direction least representative of it, precisely when the difference
    // was largest, with no warm bounce off water or open ground through the whole of a sunset. The
    // scalar that used to compensate for "a surface sees the whole dome, not one sample" is still
    // here for magnitude, but the direction problem it was standing in for is solved rather than
    // scaled.
    vec3 zenithSky = mix(plagueGetSky(skyColours, 1.0, dot(vec3(0.0, 1.0, 0.0), sunDirTrue), 0.5,
                                      false, false),
                         plagueSkyHemisphere(skyColours, sunDirTrue.y),
                         u_AmbientSkyBleed);
    // Scaled to the ambient magnitude the table it replaces established, measured: at noon against a
    // typical plains sky the zenith value is (0.284, 0.493, 0.810), luminance 0.471, against that
    // table's 0.607. Ratio 1.29. Integrating over the hemisphere, since a surface sees the whole
    // dome, not one sample, is the same idea a `* pi` factor captures elsewhere; this is that factor
    // sized against the table it replaces, so switching changes the ambient's colour without also
    // changing exposure.
    //
    // Note the hue difference the numbers show: the sky's own zenith is markedly bluer than the table
    // it replaces (0.284 red against 0.480), a stated, deliberate divergence: that table warms its
    // ambient on purpose, and the rendered sky is left to its own hue instead.
    //
    // The 1.29 is the table ratio measured at noon, and at night it is computed live instead.
    // The stated design of this path is hue from the sky, magnitude from the table it replaces, so
    // switching changes the ambient's colour without also changing exposure. The frozen 1.29
    // delivered that only at the time of day it was measured: at night the sky model's zenith is
    // a further ~2.4x dimmer relative to that table's night values, a deficit the general
    // over-brightness used to hide. Once the night/sunset decode landed, this showed up as a 5.8x
    // display drop on night terrain against the photographed 2.5x.
    //
    // So the night arm now scales the sky's zenith to the luminance of lighting.ambient, the
    // decoded table, vsBrightness fold included, which also restores the brightness slider's
    // authored effect on night ambient. The day arm keeps the measured constant, and the blend
    // runs on the same sunFactor as the sky's own day/night mix: at noon this is 1.29 exactly and
    // the result bit-identical to before the decode round.
    // The measured day anchor, named rather than repeated: the reflection lift below divides by it
    // to normalise itself, so writing 1.29 twice would let the two drift apart silently.
    const float PLAGUE_SKY_AMBIENT_DAY_SCALE = 1.29;
    float zenithLuma = dot(zenithSky, vec3(0.2126, 0.7152, 0.0722));
    float tableLuma = dot(lighting.ambient, vec3(0.2126, 0.7152, 0.0722));
    float ambientScale = mix(tableLuma / max(zenithLuma, 1e-5),
                             PLAGUE_SKY_AMBIENT_DAY_SCALE, plagueSunFactor);
    vec3 ambientColour = zenithSky * ambientScale;
    // The two paths must not hold two opinions about how bright the sky is.
    //
    // Everything above resolves a disagreement between the sky model and the ambient table in the
    // table's favour, for the reason the comment above states: at night the model's zenith runs
    // ~2.4x dim against the table. That correction reaches the diffuse half of the frame and stops
    // there; the reflection half samples plagueGetSky raw, further down. A dielectric never
    // notices, because its diffuse card carries it. A conductor's kD is exactly zero, so the
    // corrected answer never reaches it at all and it is lit solely by the uncorrected one. That is
    // why metals go black at night while the terrain around them stays visible.
    //
    // Normalised on the day arm, so this moves night and nothing else. At noon ambientScale is
    // PLAGUE_SKY_AMBIENT_DAY_SCALE by construction, the ratio is exactly 1.0, and every daylight
    // reflection in the pack is bit-identical to before this line existed. What is left is purely
    // the night-vs-day relative correction the diffuse path already takes.
    float skyReflectionLift = ambientScale / PLAGUE_SKY_AMBIENT_DAY_SCALE;
    ambientColour = plagueWarmLowSun(ambientColour, sunDirTrue.y);
    // Ground bounce: the dome is only half of what fills a shadow. The other half is sunlight
    // that has already struck the surrounding terrain and arrives pre-tinted by it, which is why
    // real open-air shadows read neutral-warm while a pure zenith sample reads deep blue. One
    // luminance-preserving hue pull toward a sunlit-earth bounce colour, scaled by the same
    // sunFactor as the sky's own day/night mix. Exposure is untouched at every slider position
    // (both mix endpoints carry identical luminance), night ambient keeps the moon's cool hue
    // (the bounce follows the sun to zero), and 0.0 is bit-identical to the bare sky sample.
    float ambientLumaHere = dot(ambientColour, vec3(0.2126, 0.7152, 0.0722));
    vec3 groundBounce = PLAGUE_GROUND_BOUNCE_TINT
                      * (ambientLumaHere / dot(PLAGUE_GROUND_BOUNCE_TINT,
                                               vec3(0.2126, 0.7152, 0.0722)));
    ambientColour = mix(ambientColour, groundBounce,
                        u_AmbientBounceWarmth * plagueSunFactor);
#else
    // The Custom palette's own ambient table (light_and_ambient_colors.glsl), read unconditionally
    // whenever the sky-sampled ambient path above is off, see plagueOverworldLighting's own
    // header on why .ambient stays live-correct regardless of which model CUSTOM_LIGHT_COLORS
    // currently selects.
    vec3 ambientColour = lighting.ambient;
    // No lift on this arm, and that is correct rather than a gap: the disagreement being corrected
    // is between the sky model and the ambient table, and this path never consults the sky model,
    // it reads the table directly, so both halves already agree.
    float skyReflectionLift = 1.0;
#endif

    // Block light colour. The Custom palette authors a warm constant; the Physical model takes
    // whatever a 4000 K emitter actually looks like. Rescaled to the Custom palette's luminance
    // either way, so the block-light CURVE keeps meaning the same thing and only the hue moves
    // between models.
#if CUSTOM_LIGHT_COLORS
    vec3 blockLightColour = PLAGUE_BLOCKLIGHT_COL;
#else
    vec3 blockBody = plagueBlackbody(u_BlockLightTemp);
    vec3 blockLightColour = blockBody
            * (dot(PLAGUE_BLOCKLIGHT_COL, vec3(0.2126, 0.7152, 0.0722))
             / max(dot(blockBody, vec3(0.2126, 0.7152, 0.0722)), 1e-6));
#endif

    // --- Material and BRDF ----------------------------------------------------------------------
    //
    // The G-buffer has carried smoothness and F0 since terrain first wrote it. What reads them now
    // is a real BRDF: GGX distribution, Smith height-correlated visibility, exact dielectric
    // Fresnel, measured complex-IOR Fresnel for the eight metals labPBR names, and Hammon diffuse
    // in place of Lambert. See shaders/include/brdf.glsl, which is written from the papers.
    //
    // What was here before was hand-rolled, and its own comments admitted as much: a Schlick
    // geometry approximation with a k it made up, a hard min(specular, 3.0), and an ndotv floor "at
    // a real angle rather than an epsilon". The floor is gone: the height-correlated visibility
    // term cancels the 4*NdotL*NdotV denominator analytically, so nothing divides by ~0 at grazing
    // angles any more. A cap survives, at pi^4 rather than 3.0, because a near-delta lobe against a
    // directional light really is that bright and has nowhere to go without bloom. Both live in
    // brdf.glsl next to the reasoning.
    vec3 material = texture(u_Input2, texCoord).rgb;
    PlagueMaterial mat = plagueDecodeMaterial(material.r, material.g, material.b);

    // Wetness, applied before the BRDF because it changes the inputs the BRDF reads: albedo,
    // roughness and F0 all move. Applying it to the BRDF's output instead would darken the specular
    // highlight along with the surface, which is backwards: a wet surface is darker and shinier.
    //
    // Driven by u_FrameState.w (accumulated wetness), not u_SkyState.x (instantaneous rain). See the
    // lane's own doc in globals.glsl: rain level snaps, so surfaces would flick wet and dry.
    // Moved to terrain.fsh (puddles). Wetness used to be applied here, uniformly, to every
    // sky-facing surface, which made the whole world go evenly glossy in rain rather than pooling
    // water where it would actually collect. The puddle model needs the height map and must flatten
    // the normal before it reaches the G-buffer, neither of which is possible from a deferred pass,
    // so the terrain stage now writes the wetted albedo, smoothness and normal directly.
    //
    // Nothing is re-applied here on purpose: `mat` already carries it. Reinstating a second
    // application would darken soaked albedo twice and drive already-smoothed material past mirror.

    // No snow here any more. A settled-snow material blend used to sit at this point, reading a compute
    // pass's accumulation field and an overhead sky-exposure map. It is gone (see graph.toml's note),
    // and two things it learned the hard way belong wherever the replacement lands:
    //
    //   * A mob standing in a field rendered snow-covered. Every gate the blend applied was
    //     positional (column, surface height, facing), and a mob standing on snowy ground passes
    //     all three, because it is at that height, on that column, with an upward-facing back. No
    //     amount of tuning positional gates could fix it; the pass simply did not know a mob was a
    //     mob. gAo.a carries a surface-class lane for exactly this (terrain.fsh writes 1.0 solid /
    //     0.5 cutout, entities.fsh writes 0.75, block_entities.fsh writes 0.0); the temporal
    //     accumulator now consumes the animated-entity class rather than re-deriving it.
    //   * Spruce leaves came back as grey smears when foliage was shaded with the constants that
    //     describe snow lying flat on ground. Snow caught on foliage is a different material.
    //
    // The replacement drives the dusting per-fragment in the geometry stage instead, from the per-block
    // precipitation type in a_Normal.w plus v_SkyLight, which is also the only stage that can touch a
    // normal before the G-buffer records it, and so the only one that can ever give snow a shape.

    // worldPos is camera-relative, so the direction back to the eye is its negation.
    vec3 viewDir = normalize(-worldPos);

    PlagueBrdf brdf = plagueEvaluateBrdf(mat, albedo, normal, viewDir, sunDir);

    // --- One labPBR surface response, shared by the diffuse and the reflection ---------------------
    //
    // These four lines are the architecture. Everything below composites from them and nothing below
    // asks what kind of material this is, because the answer is already a number.
    //
    // Why the seam had to go: three shipped regressions in a row were the same failure wearing
    // different clothes: chrome hoppers (a "metal path" that discarded authored roughness), pale
    // chalk (a diffuse card under a dulled mirror, because the metal path and the diffuse path
    // disagreed about whether metals have one), and a powder-blue coat (a metal path whose
    // environment was directionless while the dielectric path's was not). Every fix moved the seam
    // and the next frame broke somewhere else along it. A material class is a property of the
    // decode; past that point there is one set of equations.
    //
    // reflSmoothness comes from the wetted material, matching what ssr_trace/ssr_blur keyed off:
    // terrain.fsh bakes puddle wetness into gMaterial before the G-buffer write, so mat.alpha
    // already carries the rain.
    float reflSmoothness = clamp(1.0 - sqrt(clamp(mat.alpha, 0.0, 1.0)), 0.0, 1.0);
    float NdotV = clamp(dot(normal, viewDir), 0.0, 1.0);

    // The material's F0 comes only from its `_s` green byte (or the conductor decode). Wetness may
    // alter it earlier through the explicitly weather-gated transform; dry orientation and sky
    // access must not infer a film that the resource pack did not author.
    vec3 surfaceF0 = plagueMaterialF0(mat, albedo);

    // The split-sum environment response with multiple scattering: the one place energy is decided
    // for every material. The multi-scatter term inside the helper keeps a rough conductor
    // coloured and lit rather than grey and collapsing (see brdf.glsl).
    vec3 specularAlbedo = plagueEnvSpecularAlbedo(surfaceF0, NdotV, 1.0 - reflSmoothness);
    // The analytic fit assumes a reflective interface and retains grazing bias at F0=0. labPBR
    // allows an exact zero, and Fornax uses it for an absent `_s`, so zero must stay zero per channel.
    vec3 f0Present = step(vec3(0.5 / 255.0), surfaceF0);
    specularAlbedo *= f0Present;

    // Energy conservation, from the same numbers. What is not reflected is transmitted; of that, a
    // dielectric scatters it back out as diffuse and a conductor absorbs it. Both facts are here,
    // and neither is a branch.
    vec3 kD = (1.0 - specularAlbedo) * (1.0 - mat.metalness);

    // Both BRDF terms already carry N.L, so only visibility and light colour apply here;
    // reintroducing the cosine would square it.
    //
    // Underwater, skyLight is the wrong sun-penetration signal: vanilla decrements it ~1 level per
    // water block, so a seabed 12 blocks down reads 0.2, weakening the specular 5x before any
    // caustic could ride it. The honest gate is transmission, exp(-depth/24) (blue attenuation
    // length ~24m), with the shadow map still owning occlusion. Depth uses the engine's real
    // surface altitude when the camera is wet, the ray's own crossing when it's dry. Ambient
    // deliberately keeps the real sky light everywhere — only the sun's reach changed.
    if (debugView == DBG_CONDUCTOR_F0) {
        fragColor = vec4(surfaceF0, mat.metalness);
        return;
    }
    if (debugView == DBG_CONDUCTOR_ENERGY) {
        fragColor = vec4(specularAlbedo, reflSmoothness);
        return;
    }

    float uwSunGate = -1.0; // < 0: the standard gates stand (dry fragments, underwater off)
    // Submerged rock sits inside the same in-scattering medium plagueWaterFogColor already prices
    // for the eye-to-point veil, so it must not go vacuum-black the way a dry sealed room correctly
    // does. Reuses plagueWaterFogColor rather than a new constant, so the floor and the veil are the
    // same colour by construction. Scaled by the same exp(-depth/24) transmission the sun gate above
    // already computes.
    //
    // Known limitation: this floor only knows the fragment's own depth, not whether the water above
    // connects to open sky, so a sky-sealed flooded cavern reads the same as a sunlit overhang. Also
    // only a height test (fragWorldY < u_WaterState.z), not a real water mask, so a drained air
    // pocket seen through glass from outside still reads as water ambient. Fixing either needs an
    // engine-level signal, not a shader heuristic.
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
    // shaders/include/main_lighting.glsl owns the composite: light sources are mixed in squared
    // space and the result square-rooted (sources add in quadrature), so two independently-maxed
    // sources cannot sum to double and blow out the way a linear add did.
    //
    // AO uses labPBR texture AO times SSAO, not vanilla's per-vertex AO: Fornax does not forward
    // glColor.a to a deferred pass, so there's no G-buffer channel for it.
    //
    // Moon phase (u_SkyCelestial.w) scales night lighting: full moon lights the world, new moon
    // barely at all.
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

    // One smooth field drives every shadow-keyed appearance modifier, shaped so only confident
    // occlusion darkens and capped before black: the sharp per-pixel visibility's noise would
    // paint ink patches on a metal whose whole appearance rides these terms.
    //
    // The strength slider's above-1.0 regime lives in exactly one place, the uniform end-stage
    // shadowFade below: a per-input ambient cut here would darken the dielectric world differently
    // than the traced imagery metals mirror (ssr reads last frame), diverging as the slider moves.
    float envShadowDim = 0.0;
    float shadowFade = 1.0;
#ifdef SHADOWS
    const float PLAGUE_AMBIENT_SHADOW_MAX = 0.75;
    float shadowOcclusion = smoothstep(0.2, 0.9, 1.0 - ambientVisibility)
            * shadowSkyGate * casterStrength * PLAGUE_AMBIENT_SHADOW_MAX;
    // A caster blocks the sun, not the sky: the fill mostly survives shadow, exactly as a
    // mirror in shade does. One mild flat factor for the caster's hemisphere occupancy, no
    // slider term here, by explicit design: the conductor chain contains no u_ShadowStrength.
    envShadowDim = shadowOcclusion * 0.25;
    // The whole above-1.0 semantics, in one number. The torch guard keeps locally-lit shadow
    // regions readable: block light is real light the caster never blocked, and it rides the
    // smooth lightmap so the guard cannot couple to any material texture.
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

    // Held light, added in the same squared space the composite mixes in, see plagueHeldLighting.
    // Inert until the engine grew u_HeldLight; vanilla surfaces no such value. Coloured by the same
    // resolved blockLightColour plagueDoLighting above already received, so a torch in the player's
    // hand matches one placed on the ground regardless of which model resolved that colour.
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

    // Emission joins in quadrature (RMS, matching the composite's own placement of it above), not
    // inside diffuseWithHeld: it's a radiance built from albedo's hue at emission-driven luminance
    // (emission.glsl), so applying albedo again here would apply it twice. Branched, not
    // `sqrt(x*x)` unconditionally, because GLSL's sqrt() permits up to 3 ULP of error — the branch
    // makes "emission 0 changes nothing" exact rather than approximately true.
    //
    // kD carries a conductor's diffuse to zero (its free electrons absorb what isn't reflected, no
    // subsurface scattering to re-emit); a dielectric keeps ~96%. Emission stays reachable — only
    // the diffuse lobe goes.
    //
    // shadowFade rides every non-emission term (here, the highlight below, the environment addition
    // at its own site) and deliberately not the emitted radiance: a glowing block glows in the
    // deepest shadow. Applied before the RMS join so the exemption is structural.
    vec3 litDiffuse = kD * albedo * diffuseWithHeld * shadowFade;
    vec3 lit = (emitterLum > 0.0
                    ? sqrt(max(litDiffuse * litDiffuse
                               + litResult.emitted * litResult.emitted, vec3(0.0)))
                    : litDiffuse)
             + litResult.highlight * shadowFade
             // The moon phase enters the highlight twice, an authored falloff: the sparkle should
             // die out faster than the glow that casts it, so a thin crescent keeps faint diffuse
             // moonlight but loses the glint first.
             * moonPhaseInf * moonPhaseInf;

    // --- Reflections ------------------------------------------------------------------------------
    //
    // An energy-conserving mix, never an addition: the reflected term replaces a Fresnel-weighted
    // fraction of the shaded surface rather than piling light on top of it.
    //
    // Misses fall back to the sky: without it a horizontal mirror (nearly every upward ray leaves
    // the screen) renders as dark silhouettes wherever a ray hit and flat unreflective metal
    // wherever one missed. Two guards on that fallback: a sky-visibility gate (a ray with no sky
    // access contributes nothing rather than black), and no celestial glare (reflecting the sun/moon
    // disc through a crude directional-sky approximation aliases into sun-correlated sparkle on
    // block edges as the view moves).
    //
    // SSR_QUALITY off disables only the traced screen-space image; the wide environment lobe below
    // must remain, since kD has already reserved that material-authored specular energy elsewhere.
    //
    // Two samples of one buffer at two convolution widths. `ssrSample` is the mirror image at LOD 0
    // (the chain's seed level is a texel-exact copy of `ssr`). `ssrWideSample` is the same
    // reflection prefiltered to this material's roughness: ssr_blur's kernel caps at 7x7, so beyond
    // that cap this mip is what lets authored roughness reach the environment lobe rather than every
    // roughness rendering alike. One buffer at two mip levels, not two different content sources, so
    // a rough face shows one blurrier world rather than two different worlds — also why
    // wideTraceTrust below needs no roughness term.
    vec4 ssrSample = vec4(0.0);
    vec4 ssrWideSample = vec4(0.0);
#if SSR_QUALITY != 0
    ssrSample = textureLod(u_Input11, texCoord, 0.0);
    ssrWideSample = textureLod(u_Input11, texCoord, plagueReflectionLod(1.0 - reflSmoothness));
#endif

    // Energy is `specularAlbedo` (decided once above), and authored roughness is spent entirely on
    // lobe width below — no second smoothness curve may attenuate a ray that actually landed.

    // Same sky the pack paints, sampled once along the mirror direction, celestial disc suppressed.
    vec3 reflDir = reflect(-viewDir, normal);
    vec3 skyMiss = plagueGetSky(skyColours, reflDir.y, dot(reflDir, sunDirTrue), 0.5,
                                false, true);
    // Same night correction the diffuse path takes (skyReflectionLift), applied before the warm
    // pull and the underwater override so every consumer of the sky guess agrees. 1.0 in daylight.
    skyMiss *= skyReflectionLift;
    // Same ground-bounce pull as the ambient: the zenith's raw saturation as reflection content
    // kept shadowed metal blue at every ambient setting. Real screen-space hits stay faithful; only
    // this estimate is warmed, and only the dry dome — the underwater override below replaces it.
    float skyGuessLuma = dot(skyMiss, vec3(0.2126, 0.7152, 0.0722));
    vec3 skyGuessWarm = PLAGUE_GROUND_BOUNCE_TINT
                      * (skyGuessLuma / dot(PLAGUE_GROUND_BOUNCE_TINT,
                                            vec3(0.2126, 0.7152, 0.0722)));
    skyMiss = mix(skyMiss, skyGuessWarm, u_AmbientBounceWarmth * plagueSunFactor);
#if PLAGUE_UNDERWATER
    // The sky arm's total override above does not reach a REFLECTED ray, so a missed reflection
    // needs its own closed, angular open-water radiance or it reverts to a flat patch or visible
    // sky/stars.
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

    // How much sky this ray could plausibly have reached. A surface with no sky access (indoors, in
    // a cave) reflects none regardless of direction; that half is the lightmap term.
    //
    // A horizontal ray points at the horizon, which is sky, so the gate must not be zero there: a
    // metal wall or door has a horizontal mirror direction, and scoring it 0 collapses reflTotalW
    // (and with it sharpAvail/wideTraceTrust) to the flat enclosure guess, which is why the pack's
    // copper doors used to render as the same achromatic grey chrome regardless of wear.
    //
    // plagueReflHorizon shape, hoisted here so the wide lobe below shares it rather than restating
    // it inconsistently: 0.5 at the horizon, falling off smoothly either side. Downward rays keep a
    // small share rather than a hard zero, since a hard cut re-textures the transition.
    float reflHorizon = smoothstep(-0.35, 0.35, reflDir.y);
    float reflSkyVis = reflHorizon * smoothstep(0.1, 0.7, skyLight);

    // Confidence-weighted blend, not a second mix(): a miss with no sky visibility must contribute
    // nothing, not black, which `mix(reflection, sky, 1 - confidence)` would give.
    float reflHitW = clamp(ssrSample.a, 0.0, 1.0);
    // A single mirror-direction sky lookup is only valid for a narrow lobe; feeding it to rough
    // materials made medium-rough iron look sky-textured whenever SSR missed.
    //
    // Dielectric-only: for a metal, this same gate used to zero the environment on rough misses
    // entirely (measured ~75-87% of texels on real iron/hopper blocks) with no diffuse card to fall
    // back to. Conductors get the sharp/wide split below instead — a blurrier environment, never
    // nothing. A dielectric's diffuse lobe makes this cheap gate still the right answer for it.
    //
    // How much of the environment actually reaches this fragment, normalized so a fully open,
    // unshadowed outdoor fragment is exactly 1.0. Built from the pack's own light rather than a
    // constant: numerator is what this fragment really gets (ambient through the lightmap, sun
    // through the shadow map, block light including held), denominator is the same fragment fully
    // open, so a sealed room lit only by a torch still scores real envAccess instead of near-zero.
    //
    // This is also where shadow lines return to the reflection: the direct GGX highlight was
    // already gated by `shadow`, but an environment fill blind to sun occlusion swamped it; dimming
    // the fill in shadow lets both the highlight and the reflected scene's own shadowing read.
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
    // its neighbourhood's alpha too, so a lucky hit or a stray miss can't speak for the whole lobe).
    // skyMiss is reused unfiltered: it's an analytic dome with no high frequencies for a
    // convolution to remove.
    float reflHitWWide = clamp(ssrWideSample.a, 0.0, 1.0);
    float reflSkyWWide = (1.0 - reflHitWWide) * reflSkyVis * skyMirrorCompetence;
    float reflTotalWWide = reflHitWWide + reflSkyWWide;
    vec3 reflColorWide = reflTotalWWide > 1e-4
            ? (ssrWideSample.rgb * reflHitWWide + skyMiss * reflSkyWWide) / reflTotalWWide
            : ssrWideSample.rgb;

    // The environment specular term, for every labPBR material. Adds to the direct highlight
    // rather than mixing against a substrate: different incoming radiance (a light source vs.
    // everything else), and kD above already removed this term's share from the diffuse lobe, so
    // nothing double-counts. Replaces an earlier `mix(lit, reflection, weight)` energy swap that
    // could not express a metal at all.
    //
    // Energy is `specularAlbedo` (decided once above); content and lobe width are decided here.
    // `sharpShare` is x*(2-x) on squared smoothness — a quadratic ease reaching full weight at s=1
    // with zero slope — and is the fraction of a lobe this narrow that survives as a coherent
    // image (iron's 0.489 keeps 42%; the rest is smeared, served by the wide term, not missing).
    //
    // The wide lobe must be directional, not a flat fill: a reflection hemisphere is roughly half
    // sky, half ground, and which half a face sees is what makes a solid object read as solid
    // rather than painted. Sky content fades to the enclosure guess as access drops, rather than
    // gating to zero, since an upward lobe indoors sees the ceiling, not nothing.
    //
    // A forced approximation: ssr_blur's kernel caps at 7x7, so beyond that this two-lobe estimate
    // stands in for a real convolution. The prefiltered `ssrPrefilter` sample is screen-space and
    // can't invent data where the trace has none, so this estimate remains the fallback there.
    //
    // Retired, kept declared unused: PLAGUE_ENV_FILL doubled a discount PLAGUE_ENV_GROUND already
    // applied to the enclosure arm (tools/verify_conductor_hue.py). Reinstating it is a one-word
    // edit if an enclosed scene ever reads too bright.
    const float PLAGUE_ENV_FILL = 0.45;
    // Sky-facing share of the wide lobe, kept separate from FILL: a smeared reflection of open sky
    // is still sky-bright since blurring preserves the hemisphere average, and discounting it by
    // FILL stepped conductor luma 4.7x between polished and worn texels under an unchanged sky.
    // 0.80 (not 1.0) keeps the estimator conservative for the non-sky remainder; numbers fitted in
    // tools/verify_conductor_hue.py.
    const float PLAGUE_ENV_SKY = 0.80;
    const vec3 PLAGUE_ENV_GROUND = vec3(0.085, 0.090, 0.070);
    float sharpShare = reflSmoothness * reflSmoothness;
    sharpShare = sharpShare * (2.0 - sharpShare);

    // One slider semantics for every material: it selects content, never energy — both shares sum
    // to one, so energy is conserved at every slider position (1.0 is the spec result exactly, 0.0
    // is matte-but-lit).
    float sharpAvail = 0.0;
#if SSR_QUALITY != 0
    sharpAvail = clamp(sharpShare * reflTotalW * u_SsrStrength, 0.0, 1.0);
#endif

    // A lantern belongs in the wide lobe's radiance, not merely its gate: block light previously
    // reached a surface only through diffuseWithHeld, which is 3.8% of the same irradiance once
    // kD takes a conductor's diffuse card away entirely.
    //
    // Not multiplied by PLAGUE_ENV_GROUND: that product is "terrain lit by local light reflecting
    // back", but a lantern is the light itself, already a radiance, not something that reflects.
    // No material branch: a dielectric receives this too, bounded by its own (small) F0, so the
    // asymmetry with a metal's larger share is physics, not a special case.
    //
    // PLAGUE_ENV_BLOCK is the fraction of the reflection hemisphere the emitter and its lit
    // surroundings occupy — a solid-angle share, not a brightness (distance falloff is already in
    // the lightmap curve). Laddered on the lantern-on-iron scene in tools/out/labpbr_unified.png.
    const float PLAGUE_ENV_BLOCK = 0.25;
    vec3 blockRadiance = blockLightColour * plagueBlockLightCurve(blockLight, u_ScreenBrightness)
                       + heldLight;

    // Shared with reflSkyVis above rather than a second, independently-drifting expression.
    float wideHorizon = reflHorizon;
    vec3 wideEnclosure = diffuseWithHeld * PLAGUE_ENV_GROUND;
    // Not dimmed by sun-shadow, same reasoning as reflSkyW: the dome is still overhead in a
    // sun-shadow.
    float wideSkyShare = wideHorizon * smoothstep(0.1, 0.7, skyLight) * envAccess;
    // No longer takes FILL on top of GROUND (removes a double discount, not a tuned reduction): a
    // rough conductor's kD is exactly zero, so this estimate is its entire appearance whenever the
    // trace misses and sky is unreachable — a double discount left it near-black regardless of its
    // specularAlbedo's true capacity to reflect.
    vec3 wideEstimate = mix(wideEnclosure, skyMiss * PLAGUE_ENV_SKY, wideSkyShare);
    // Content continuity for conductors: ssr_blur already owns the roughness spread, so `reflColor`
    // is the roughness-matched image of the real surroundings wherever the trace or sky guess has
    // an answer. Rides `metalness` like kD does: a dielectric's sheen sits atop its diffuse card
    // and can tolerate estimator error; a conductor has no other card. Falls back to the estimate
    // exactly where the trace does: enclosed, shadowed, or SSR off.
    float wideTraceTrust = clamp(reflTotalW * u_SsrStrength, 0.0, 1.0) * mat.metalness;
    // reflColorWide, not reflColor: the wide lobe gets the reflection convolved to this material's
    // roughness instead of the mirror image.
    vec3 reflWide = mix(wideEstimate, reflColorWide, wideTraceTrust);
    // blockRadiance added past every content mix above: a real nearby emitter's solid-angle share,
    // present regardless of which content won the sky/enclosure or SSR-trust argument. Bounded by
    // specularAlbedo at the consumption site below like every other term in reflEnv.
    vec3 reflEnv = reflColor * sharpAvail + reflWide * (1.0 - sharpAvail) + blockRadiance * PLAGUE_ENV_BLOCK;
    // One uniform dim, real hits included: per-texel special-casing here would re-texture the
    // shadow instead of darkening it. envShadowDim has no material dependence and is capped before
    // black at every slider position (defined beside the ambient cut above).
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

    // Invalid over water/translucent surfaces: water_composite.fsh runs after this pass and
    // unconditionally overwrites water pixels with no debug-view awareness, so point the crosshair
    // at opaque geometry.
    const vec3 DBG_LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);
    if (debugView == DBG_ENV_SPEC_RATIO) {
        float envSpecLuma = dot(reflEnv * specularAlbedo, DBG_LUMA_WEIGHTS);
        float diffuseLuma = dot(litDiffuse, DBG_LUMA_WEIGHTS);
        float envSpecRatio = envSpecLuma / max(envSpecLuma + diffuseLuma, 1e-4);
        fragColor = vec4(envSpecLuma, diffuseLuma, envSpecRatio, 1.0);
        return;
    }

    // A decomposition with the same reasoning and number-carrier caveat as DBG_ENV_SPEC_RATIO
    // above: the ratio named the specular path as ~50x brighter than the diffuse path for the
    // same surroundings; these three ordinals report every term the ratio is built from, luma-
    // reduced, so the wrong factor is read off the crosshair rather than guessed at from source.
    // Split across three ordinals (one vec4 cannot hold eleven values), select one at a time with
    // the engine's Debug View Cycle, matching EnvSpecularRatioReadback.java's own per-ordinal
    // labelling, then cycle to the next and measure again. Same water caveat as the ratio view.
    if (debugView == DBG_ENV_DECOMP_SKY) {
        // The specific question this ordinal answers: skyMiss and ambientColour both describe the
        // same sky. ambientColour's own comment two screens up says it takes "hue from the sky,
        // magnitude from the table it replaces"; if that table is a hemisphere-integrated diffuse
        // ambient and skyMiss is a raw dome radiance sample, the two are in different units and
        // whichever is larger is a candidate for driving the ~50x gap on its own.
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
        // .a unused: three values, not four; left explicit rather than repeating an earlier one.
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
        // B/A is the AO comparison this exists for: B = litResult.vanillaAO (the diffuse path's
        // reshaped occlusion), A = raw `ao` (the specular/wide path's unreshaped input to
        // envAccess). If they differ substantially, the two paths disagree about occlusion.
        fragColor = vec4(wideHorizon, dot(litDiffuse, DBG_LUMA_WEIGHTS), litResult.vanillaAO, ao);
        return;
    }
    if (debugView == DBG_ENV_DECOMP_RESIDUAL) {
        // dot(a*b*c, w) != dot(a,w)*dot(b,w)*dot(c,w) unless a/b/c share hue, so a luma-reduced
        // readback of litDiffuse = kD*albedo*diffuseWithHeld can't reconstruct exactly from the
        // three separate lumas. This packs each factor's own luma plus the residual so that gap is
        // measured rather than estimated.
        float albedoLuma = dot(albedo, DBG_LUMA_WEIGHTS);
        float kDLuma = dot(kD, DBG_LUMA_WEIGHTS);
        float diffuseWithHeldLuma = dot(diffuseWithHeld, DBG_LUMA_WEIGHTS);
        float litDiffuseLuma = dot(litDiffuse, DBG_LUMA_WEIGHTS);
        float residual = litDiffuseLuma / max(albedoLuma * kDLuma * diffuseWithHeldLuma, 1e-6);
        fragColor = vec4(albedoLuma, kDLuma, diffuseWithHeldLuma, residual);
        return;
    }

    // `albedoSample.rgb` is the raw, still-encoded byte every writer put in gAlbedo; `albedo` is
    // that byte decoded. Only valid when u_AlbedoIdentityDebug is off — when on, terrain.fsh has
    // repainted gAlbedo with diagnostic floats (DBG_ALBEDO_IDENTITY_INPUTS below).
    if (debugView == DBG_ALBEDO_WRITE_VS_READ) {
        float rawWrittenLuma = dot(albedoSample.rgb, DBG_LUMA_WEIGHTS);
        float decodedAlbedoLuma = dot(albedo, DBG_LUMA_WEIGHTS);
        fragColor = vec4(rawWrittenLuma, decodedAlbedoLuma, 0.0, 0.0);
        return;
    }

    // Companion to DBG_ALBEDO_WRITE_VS_READ, testing texLuma * tintLuma == albedoLuma: reads gAlbedo
    // raw (no plagueSrgbToLinear — these are terrain.fsh's diagnostic floats, not colour), and only
    // means anything when u_AlbedoIdentityDebug is also on (a second toggle since terrain.fsh, a
    // geometry program, cannot see u_Param3/debugView at all).
    if (debugView == DBG_ALBEDO_IDENTITY_INPUTS) {
        fragColor = vec4(albedoSample.r, albedoSample.g, albedoSample.b, albedoSample.a);
        return;
    }

    // Unconditional: this once sat behind a leftover bisect toggle whose off state was sticky in
    // the user's options file, silently compiling the whole environment term out of the live build.
    // A term this central does not get a user-visible kill switch.
    lit += reflEnv * specularAlbedo * shadowFade;
    if (debugView == DBG_CONDUCTOR_LIT) {
        fragColor = vec4(lit, dot(lit, vec3(0.2126, 0.7152, 0.0722)));
        return;
    }

    // --- Fog --------------------------------------------------------------------------------------
    //
    // Last, after the reflection mix: fog is a veil in front of the finished surface, attenuating a
    // bright and dark reflection by the same fraction rather than dimming the highlight without
    // dimming what it sits on. See shaders/include/fog.glsl and tools/verify_fog.py.
    //
    // The reflection is not double-fogged: `ssr` was traced against last frame's finished
    // sceneHdr, which already carries the reflected surface's own fog. A reflection-aware
    // correction for the excess path length is deliberately not implemented — the error it would
    // fix is near zero wherever a screen-space reflection is legible.
#if PLAGUE_UNDERWATER && defined(SHADOWS) && WATER_CAUSTICS
    // Added to the scene in linear before fog, so distance veils it like everything else. Anchored
    // to what the sun can deliver here (shadow map + depth transmission gate), sized so bright
    // lines land 3-5x the sand they dance
    // on rather than 1.7x a direct term nobody can see.
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
        // Irradiance requires a surface facing the sun — without this, back faces and near-vertical
        // walls glow as if the caustic image were pasted on them.
        float causticIncidence = smoothstep(0.03, 0.35, ndotl);
        float causticShadow = plagueWaterSunVisibility(worldPos, sunDir) * pomShadow;
        // Three terms from one visibility (causticShadow, causticIncidence, the strength slider),
        // all gated by the same occlusion, so bloom and bounce can never appear where the direct
        // caustic cannot. Deliberately not fed back into extinction or fog: this adds light to the
        // scene, it does not change the medium.
        float causticVis = causticShadow * u_CausticStrength;

        // 1. Direct: the focused light itself, on surfaces facing the sun.
        lit += uwWebSun * uwWeb * causticVis * causticIncidence * 1.15;

        // 2. Local bloom: a compact halo on the hot filaments only, pushed past display white so
        //    the unthresholded bloom pass actually spreads it.
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
        // u_RenderFog.y is the headless/no-client-options fallback, not the primary: it tracks fog
        // attribute distances rather than the chunk grid, so it can leave the veil below 1.0 right
        // where geometry ends.
        float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0);
        // Same interleaved-gradient noise the sky branch dithers its dome with, so fog and the sky
        // it converges to break banding identically rather than crossing patterns.
        float fogDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));
        vec3 atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
        atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
                lighting.rainFactor,
                vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
                vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
                vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
                vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif
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
        // No in-water-leg cap on the veil: fogs the whole eye-to-fragment ray. The water term is
        // the only thing that seals the horizon underwater — the border curve (d/renderDistance)^16
        // contributes nothing below ~160 blocks — so capping it left the above-water leg with no
        // veil term of its own, and "no sky visible while under water" needs the full-ray answer.
        lit = mix(lit, fogTerms.atmColor, clamp(fogTerms.atm, 0.0, 1.0));
        lit = mix(lit, fogTerms.borderColor, clamp(fogTerms.border, 0.0, 1.0));
        lit = mix(lit, fogTerms.waterColor, clamp(fogTerms.water, 0.0, 1.0));

        lit = max(lit, vec3(0.0));
        lit *= fogTerms.uwTint;

#if PLAGUE_UNDERWATER
        // Exponential water fog approaches closure asymptotically, leaving loaded chunks as
        // rectangles against the depth<=0 closed-volume branch; this hands the far field to that
        // branch before the real render-distance boundary, leaving the near 72% unchanged.
        //
        // uwClosureScale takes whichever of render distance or (Water Distance Fog x
        // uwVisibilityMult) is shorter, so a tight visibility setting actually closes the horizon
        // near itself instead of deferring entirely to render-distance closure. 3x/6x
        // (night-or-rain/clear-noon) is where the exponential veil above is already ~95% opaque on
        // its own, so the handoff starts after the veil has done nearly all the work.
        //
        // Pure exponential (plagueGetWaterFog, underwater.glsl), not a near/far smoothstep band:
        // `smoothstep` on length(worldPos) is a sphere test against camera-relative position, and a
        // sphere intersecting the frustum draws a curved, camera-following edge no near/far retuning
        // can remove — only an unbounded curve has no edge to draw.
        //
        // WATER_CLOSURE folded in as an always-on guarantee rather than a player option: it's
        // redundant with the base veil whenever distanceFog <= renderDistance, and does real work
        // only when Water Distance Fog exceeds render distance, so "Water Distance Fog alone
        // determines underwater visibility" has to hold regardless — nothing here for a toggle to gate.
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
            // paths disagree again in brightness the moment the ramps do anything: the same
            // problem in a different currency.
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
