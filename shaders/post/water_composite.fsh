#version 330

// Shades the water surface, blended over the scene as a hardware TRANSLUCENT pass (src*a + dst*(1-a)).
// Writes to sceneHdrComposited, not sceneHdr, because ssr_trace_water reads sceneHdr and this pass
// depends on that trace (see scene_copy.fsh).
//
// The body colour is deliberately dark: that's what the reflection reads against, and it hides the
// screen-space trace's edge falloff (undamped, the sky fallback glows milky where rays leave screen).
//
// Distance fog runs here too, off the same u_Param2 anchor the resolve uses, so water and land
// dissolve at the same screen distance instead of seaming at the shoreline.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>
#moj_import <fornax_runtime:water_waves.glsl>
// plaguePuddleImpactGradient: same signed pressure field terrain puddles use, so open water and a
// puddle beside it read as being rained on by visibly the same rain.
#moj_import <fornax_runtime:puddles.glsl>
#moj_import <fornax_runtime:fog.glsl>
#define PLAGUE_ATMO_READS_SKYVIEW
#define PLAGUE_ATMO_READS_AERIAL
#moj_import <fornax_runtime:atmo_lut.glsl>
#moj_import <fornax_runtime:fog_aerial.glsl>
// plagueSunColor/plagueMoonColor: same per-body radiance gbuffer_resolve.fsh's Physical-model arm
// uses, so the glint's light matches every other lit surface in the scene.
#moj_import <fornax_runtime:atmosphere.glsl>
// stars.glsl: plagueStarCoord/plagueGetStars. celestials.glsl: disc primitives this file's own
// plagueUnderwaterCelestialDiscs builds on (not plagueCelestialDiscs directly — see that function's
// comment for why the underwater edge treatment stays local instead).
#moj_import <fornax_runtime:stars.glsl>
#moj_import <fornax_runtime:celestials.glsl>
// Underwater Snell-window sun/moon disc sampler, split out of this file into its own include; see
// its own header for why it stays separate from plagueCelestialDiscs.
#moj_import <fornax_runtime:water_underwater_discs.glsl>

uniform sampler2D u_Input0; // builtin.waterNormal: xyz = wave normal, a = signed flags (see terrain.fsh)
uniform sampler2D u_Input1; // builtin.waterDepth, reversed-Z, 0.0 = no water
uniform sampler2D u_Input2; // ssrWater: rgb = reflection, a = confidence
uniform sampler2D u_Input3; // builtin.depth, OPAQUE scene depth, for the occlusion re-test
uniform sampler2D u_Input4; // builtin.noise
uniform sampler2D u_Input5; // causticsTexture
// Screen-space active-light / true-sun / true-moon occlusion (glint_occlusion.fsh). The separate
// underwater lanes prevent a sunset handoff from borrowing the active moon's visibility.
uniform sampler2D u_Input6; // glintOcclusion
// Vanilla's sun + 8-moon-phase sprite atlas, same resource gbuffer_resolve.fsh paints the primary
// sky's discs from; see plagueUnderwaterCelestialDiscs.
uniform sampler2D u_Input7; // builtin.celestials
// Shoreline foam pattern (tools/generate_foam.py): a bubble-film web with darker holes, not a
// generic noise wash, since noise can't produce that cell structure.
uniform sampler2D u_Input8; // foamTexture
// Foam pattern's own normal map. GREEN POINTS DOWN — flipped at the read site before decoding.
uniform sampler2D u_Input9; // foamNormalTexture
// Foam relief height field (POM), built from the same source as the pattern/normal so all three
// agree by construction.
uniform sampler2D u_Input10; // foamHeightTexture
uniform sampler2D u_Input11; // waterEnvironment, filtered Plague sky radiance
uniform sampler2D u_Input12; // moonAlbedo, equirectangular, near side centred
uniform sampler2D u_Input13; // moonNormal, tangent-space relief for the same projection
uniform sampler2D u_Input14; // cloudFront: live tier's first-hit cloud distance (0.0 = empty ray)
uniform sampler2D u_Input15; // atmoSkyView, the marched dome (atmo_lut.glsl); zero under Palette
uniform sampler2D u_Input16; // atmoAerial, in-scatter and transmittance per screen froxel; zero under Palette

vec4 plagueAtmoFetchSkyView(vec2 uv) {
    return texture(u_Input15, uv);
}

vec4 plagueAtmoFetchAerial(vec2 uv) {
    return texture(u_Input16, uv);
}

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2; // terrain render distance in blocks (engine-supplied for this pass name)
    float u_Param3;
    // xyz is the ACTIVE light (sun by day, moon after it sets); w is the TRUE sun elevation, the
    // only correct "is it day" test — the moon at midnight sits where the sun sits at noon, so
    // building fog colour off xyz.y would light fog as noon at midnight.
    vec4  u_SunDirection;
    // {u0,v0,u1,v1} of the sun sprite / current moon-phase sprite in builtin.celestials. Widened
    // from 32 to 64 bytes: the engine already writes these fields every frame, this shader just
    // hadn't declared them (PassParams.java documents growing a declared block this way as safe).
    vec4  u_SunSpriteRect;
    vec4  u_MoonSpriteRect;
};

#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="Fancy" 2="Fast"}

// Byte-identical to gbuffer_resolve.fsh's declaration: the water's fog is the terrain's fog.
#define PLAGUE_SKY_MODEL 1 //[0 1] compile "Sky Model" {0="Palette" 1="Scattering"}
#define SSR_WATER_MODE 2 //[0 1 2] compile "Water Surface" {0="Vanilla" 1="Shaded" 2="Reflective"}
#define PLAGUE_WATER_REFLECTION_DEBUG 0 //[0 1 2 3 4] compile "Water Reflection View" {0="Off" 1="Roughness" 2="Trace Confidence" 3="Fallback Sky" 4="Source Mix"}
// Byte-identical to clouds.glsl's declaration: the option scanner merges same-name declarations
// and rejects any mismatch. Read here only to know whether cloudFront has a writer this build.
#define CLOUDS_VOLUMETRIC 1 //[0 1] compile "Volumetric Clouds" {0="Off" 1="On"}
#define WATER_FOAM //[] compile "Shoreline Foam"
// Must match terrain.vsh/terrain.fsh byte-identically: the settled-surface classification below
// undoes the wave lift before classifying, and needs to know whether the vertex stage applied one.
#define PLAGUE_WATER_MESH_DISPLACEMENT 1 //[0 1] compile "Water Mesh Displacement" {0="Off" 1="Standard"}
#moj_import <fornax_runtime:water_options.glsl>
#define PLAGUE_RAIN_SPLASHES //[] compile "Rain Splashes"
#moj_import <fornax_runtime:material_options.glsl>

// Deep-water tint: the colour of light that has scattered back out rather than been absorbed.
const vec3 WATER_TINT = vec3(0.02, 0.11, 0.16);
// Above-water body reads cyan in engine captures; filtered toward slate blue to match. Art
// direction, not a physics fit.
const vec3 WATER_SURFACE_TINT_FILTER = vec3(1.10, 0.59, 0.53);

// Beer-Lambert extinction per block/channel: red absorbs within ~1-2m, green within several, blue
// survives tens of metres — this is why water reads as water rather than uniform grey.
const vec3 WATER_EXTINCTION = vec3(0.46, 0.10, 0.055);

// How opaque water can ever get, so an abyss still hints at what's under it.
const float WATER_MAX_OPACITY = 0.96;

// Foam's ALBEDO, not its finished radiance: churned bubbles scatter broadly and shouldn't render
// unlit. Multiplied by ambient below rather than painted directly, so foam brightness follows time
// of day instead of reading identically bright at noon and midnight. tools/verify_fog.py's
// check_foam_brightness verifies this against real captures (+11.8/+5.7 night, +19.2/+5.9 sunset).
const vec3 FOAM_ALBEDO = vec3(0.85, 0.90, 0.92);

in vec2 texCoord;
out vec4 fragColor;

// Exact unpolarised dielectric Fresnel, valid from either side of the interface: (cos, 1.0, 1.333)
// is the air-side reflectance, (cos, 1.333, 1.0) returns exactly 1.0 past the critical angle (TIR
// falls out of the physics, not a hand-shaped window mask).
float plagueDielectricFresnel(float cosIncident, float etaIncident, float etaTransmitted) {
    float cI = clamp(abs(cosIncident), 0.0, 1.0);
    float eta = etaIncident / etaTransmitted;
    float sin2Transmitted = eta * eta * max(1.0 - cI * cI, 0.0);
    if (sin2Transmitted >= 1.0) {
        return 1.0;
    }

    float cT = sqrt(max(1.0 - sin2Transmitted, 0.0));
    float rs = (etaIncident * cI - etaTransmitted * cT)
             / max(etaIncident * cI + etaTransmitted * cT, 1e-5);
    float rp = (etaTransmitted * cI - etaIncident * cT)
             / max(etaTransmitted * cI + etaIncident * cT, 1e-5);
    return clamp(0.5 * (rs * rs + rp * rp), 0.0, 1.0);
}

vec3 worldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    return world.xyz / world.w;
}

// Foam UV is a flat world-space XZ planar projection, not a mesh-tangent UV, so the tangent frame
// is fixed and needs no reconstruction: tangent=world +X, bitangent=world +Z, normal=world +Y.
//
// Height convention (white=raised) is unverified against this asset; if relief reads inverted once
// visible, flip this one subtraction, not the frame or the march.
vec2 plagueFoamParallax(sampler2D heightTex, vec2 uv, vec3 viewDirWorld, float heightScale) {
    const int FOAM_POM_MAX_STEPS = 12;
    vec3 viewDirTS = vec3(viewDirWorld.x, viewDirWorld.z, max(viewDirWorld.y, 0.05));
    float numLayers = mix(12.0, 4.0, abs(viewDirTS.z));
    float layerDepth = 1.0 / numLayers;
    vec2 deltaUv = viewDirTS.xy * heightScale / viewDirTS.z / numLayers;

    vec2 currentUv = uv;
    float currentLayerDepth = 0.0;
    float currentHeight = 1.0 - texture(heightTex, currentUv).r;
    for (int i = 0; i < FOAM_POM_MAX_STEPS; i++) {
        if (currentLayerDepth >= currentHeight) {
            break;
        }
        currentUv -= deltaUv;
        currentHeight = 1.0 - texture(heightTex, currentUv).r;
        currentLayerDepth += layerDepth;
    }

    vec2 prevUv = currentUv + deltaUv;
    float afterDepth = currentHeight - currentLayerDepth;
    float beforeHeight = 1.0 - texture(heightTex, prevUv).r;
    float beforeDepth = beforeHeight - (currentLayerDepth - layerDepth);
    float weight = afterDepth / max(afterDepth - beforeDepth, 1e-5);
    return mix(currentUv, prevUv, clamp(weight, 0.0, 1.0));
}

// Underwater glint debug readback, ordinals 35-39 (continuing past GLINT_OCCLUSION_QUERY's own 34).
// 35 is true-sun alignment / moon alignment / interface Fresnel; 37 is the matching two glint
// lobes / configured strength. RGB only, A pinned to 1.0 since this pass blends. Confirm against
// the live GBufferDebugView enum before reusing.
#define DBG_UW_GLINT_1 35
#define DBG_UW_GLINT_2 36
#define DBG_UW_GLINT_3 37
#define DBG_UW_GLINT_4 38
// Orientation readback (waveNormal.y, NdotV, worldPos.y), read outside the underwater gate so a
// dry-camera reading returns a real value instead of falling through to the ordinary composite.
#define DBG_UW_GLINT_5 39

void main() {
    int debugView = int(u_Param3 + 0.5);
    // Sentinel value, not silent fallthrough: this pass discards non-water pixels, so a misplaced
    // debug crosshair must read back something unmistakable rather than whatever sceneHdrComposited
    // already held.
    bool uwGlintQueryActive = debugView == DBG_UW_GLINT_1 || debugView == DBG_UW_GLINT_2
            || debugView == DBG_UW_GLINT_3 || debugView == DBG_UW_GLINT_4
            || debugView == DBG_UW_GLINT_5;
    const vec4 UW_GLINT_QUERY_NOT_WATER = vec4(-1.0, -1.0, -1.0, 1.0);

    vec4 waterSample = texture(u_Input0, texCoord);
    vec3 waveNormal;
    float waterRoughness;
    float signedWaterFlags;
    plagueDecodeWaterReflectionSurface(
            waterSample, waveNormal, waterRoughness, signedWaterFlags);
    if (abs(signedWaterFlags) < 0.5) {
        if (uwGlintQueryActive) {
            fragColor = UW_GLINT_QUERY_NOT_WATER;
            return;
        }
        discard; // cleared texel: no water on this pixel
    }
    float waterDepth = texture(u_Input1, texCoord).r;
    if (waterDepth <= 0.0) {
        if (uwGlintQueryActive) {
            fragColor = UW_GLINT_QUERY_NOT_WATER;
            return;
        }
        discard;
    }

    // Occlusion re-test: the water pre-pass runs before opaque terrain, so it has no occluders and
    // will happily write water behind a wall or under a floor. Reversed-Z, so opaque wins ties:
    // `>=` not `>`, matching underwater_refraction.fsh's own tie-break, since a solid block resting
    // in water produces a real depth tie that must read as opaque, not let sky/sun through it.
    float opaqueDepth = texture(u_Input3, texCoord).r;
    if (opaqueDepth >= waterDepth) {
        if (uwGlintQueryActive) {
            fragColor = vec4(-2.0, -2.0, -2.0, 1.0); // was water, but occluded this frame
            return;
        }
        discard;
    }

#if CLOUDS_VOLUMETRIC
    // A cloud in front of the water hides it, and nothing else in this pass can know that. Clouds
    // composite into sceneHdr, ssr_trace_water reads sceneHdr, and this pass runs after that trace,
    // so a cloud is always already drawn and this blend would paint over it: from above the deck,
    // every lake would read as sitting on top of the cloud.
    //
    // Distances, not depths: cloudFront carries the march's own first-hit distance along the ray,
    // which has no depth buffer to compare against. 0.0 is its empty-ray sentinel, so a pixel whose
    // ray met no cloud must fall through rather than read as a cloud at the eye.
    //
    // Guarded on CLOUDS_VOLUMETRIC because the three tier copies are all gated on it: with clouds
    // off nothing writes cloudFront, and its contents are whatever the allocation left there.
    float cloudFrontDistance = texture(u_Input14, texCoord).r;
    if (cloudFrontDistance > 0.0
            && cloudFrontDistance < length(worldPosAt(texCoord, waterDepth))) {
        if (uwGlintQueryActive) {
            fragColor = vec4(-2.0, -2.0, -2.0, 1.0); // was water, but occluded this frame
            return;
        }
        discard;
    }
#endif

    float skyLight = (abs(signedWaterFlags) - 0.5) * 2.0;

    vec3 worldPos = worldPosAt(texCoord, waterDepth);

    // Classifies the actual fluid mesh geometry (source water ~8/9 height vs sloped/vertical flowing
    // faces), not the animated wave normal, so a distant flowing quad isn't mistaken for a lake just
    // because its wave happens to point upward.
    vec3 geomCross = cross(dFdx(worldPos), dFdy(worldPos));
    vec3 geometricNormal = dot(geomCross, geomCross) > 1e-10
            ? normalize(geomCross) : vec3(0.0, 1.0, 0.0);
    // Uses UNDISPLACED altitude: classification is a question about the block level, and the wave
    // field is a pure function of world XZ, so subtracting it recovers that level. Left raw, a wave
    // crest/trough wraps fract() and misclassifies flowing water as settled or vice versa, turning
    // shoreline foam/rain splashes on and off with the waves they're meant to decorate.
    float meshWaveLift = 0.0;
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    float fluidWaveClock = plagueWaveAnimatedTime(
            u_SkyState.w / 20.0, u_WaveStrength, u_WaveSpeed);
    meshWaveLift = plagueWaveSurfaceDisplacement(
            u_Input4, worldPos + u_CameraAbs.xyz, fluidWaveClock, 0.0, u_WaveStrength).y;
#endif
    float fluidSurfaceHeight = fract(worldPos.y + u_CameraAbs.y - meshWaveLift);
    float fullFluidLevel = smoothstep(0.83, 0.875, fluidSurfaceHeight);
    float horizontalFluidFace = smoothstep(0.90, 0.985, abs(geometricNormal.y));
    float settledSurface = fullFluidLevel * horizontalFluidFace;

#ifdef PLAGUE_RAIN_SPLASHES
    vec2 splashXZ = worldPos.xz + u_CameraAbs.xz;
    // Per-block rain mask arrives as the SIGN of signedWaterFlags (written by the pre-pass, which
    // has per-block data this pass doesn't): negative covers both "nothing falls" and "snow falls"
    // — neither puts raindrops on water.
    float localRain = u_SkyState.x * (signedWaterFlags > 0.0 ? 1.0 : 0.0);
    vec2 impactGradient = plaguePuddleImpactGradient(
            u_Input4, splashXZ, u_SkyState.w / 20.0, localRain, u_SplashDensity);
    // Faded with distance: the ring is ~8cm wide, subpixel within a couple chunks, and would only
    // alias without this.
    float impactFade = smoothstep(56.0, 20.0, length(worldPos));
    waveNormal = normalize(waveNormal
            + vec3(-impactGradient.x, 0.0, -impactGradient.y)
              * (0.35 * settledSurface * impactFade));
#endif
    vec3 viewDir = normalize(-worldPos);

    // Exact air->water Fresnel (not Schlick): near-zero head-on, mirror at grazing incidence — same
    // function runs in reverse below the surface for TIR.
    float NdotV = clamp(dot(waveNormal, viewDir), 0.0, 1.0);
    float fresnel = plagueDielectricFresnel(NdotV, 1.0, 1.333);

    // See DBG_UW_GLINT_5's own #define comment for why this reads here, unconditionally, rather
    // than inside the underwater branch below: waveNormal, NdotV and worldPos are all real by this
    // point in BOTH the wet and dry case, and that is the entire point of the ordinal.
    if (debugView == DBG_UW_GLINT_5) {
        fragColor = vec4(waveNormal.y, NdotV, worldPos.y, 1.0);
        return;
    }

    // Reflective only. Shaded draws the whole surface without a mirror: zero confidence here
    // leaves body, fog, glint and foam to shade it, so water keeps its waves and its sun track.
#if SSR_WATER_MODE > 1 && SSR_QUALITY != 0
    vec4 reflSample = texture(u_Input2, texCoord);
#else
    vec4 reflSample = vec4(0.0);
#endif

    // Shared day/night lighting model, built once before the reflection fallback and body use it,
    // so water is lit consistently with the sky instead of a fixed tint.
    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);
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
            max(u_SkyColor.rgb, vec3(0.0)), u_SunDirection.w, u_SkyState.y,
            rainFactor, u_ScreenBrightness, palette);
    vec3 trueSunDir = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
    PlagueSkyColors waterSky = plagueSkyColors(max(u_SkyColor.rgb, vec3(0.0)),
            trueSunDir, lighting.sunVisibility, rainFactor, u_CameraAbs.y);

    // Computed above every plagueGetSky consumer in this pass so all of them agree with
    // gbuffer_resolve.fsh's dome.
    vec3 atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
            vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
            vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
            vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif

    // glitterLightDir is the ACTIVE light (whichever body is actually casting light), distinct from
    // trueSunDir above which stays the true sun for sky-dome sampling. Glint terms need the former.
    vec3 glitterLightDir = u_SunDirection.xyz;

    // Per-body radiance matching gbuffer_resolve.fsh's Physical-model branch (gated on
    // u_SunDirection.w, not lighting.light, which is a sun-only crossfade badly wrong for moonlit
    // glint).
    vec3 glitterAirEyePos = plagueAirEyePos(u_CameraAbs.y);
    vec3 glitterRadiance = u_SunDirection.w > 0.0
            ? plagueSunColor(glitterAirEyePos, glitterLightDir)
            : plagueMoonColor(glitterAirEyePos, glitterLightDir);
    // Local mirrors of lighting.sunVisibility/sunFactor, sourced from glitterLightDir.y instead of
    // the true-sun-only u_SunDirection.w, so glitter doesn't zero out under a risen moon. Kept local
    // since the globals are shared elsewhere (fog, shadows) and can't be redefined.
    float glitterVisibility = clamp(glitterLightDir.y + 0.0625, 0.0, 0.125) / 0.125;
    float glitterSunFactor = glitterLightDir.y < 0.0
            ? clamp(glitterLightDir.y + 0.375, 0.0, 0.75) / 0.75
            : clamp(glitterLightDir.y + 0.03125, 0.0, 0.0625) / 0.0625;

    // Real screen-space occlusion raymarch (glint_occlusion.fsh) against opaque depth. The air-side
    // glitter keeps the active-light lane; underwater celestial lobes select their own direction.
    // Unguarded: glint_occlusion is a depth raymarch, not a reflection, and runs wherever this pass
    // does. The sun track belongs to the surface, so it survives every tier above Vanilla.
    vec3 glintVisibility = texture(u_Input6, texCoord).rgb;
    float glintShadowVis = glintVisibility.r;
    float uwSunShadowVis = glintVisibility.g;
    float uwMoonShadowVis = glintVisibility.b;

    // The mean normal chooses a reflection direction; unresolved wave slopes choose the width of
    // the prefiltered environment lobe. This keeps sub-pixel detail as reflection width instead of
    // collapsing it into alternating bright and dark mirror directions.
    vec3 reflectDir = reflect(-viewDir, waveNormal);
    vec2 environmentUv = plagueWaterEnvironmentUv(
            reflectDir, trueSunDir, vec3(0.0, 1.0, 0.0));
    float environmentLod = plagueWaterEnvironmentLod(waterRoughness);
    // The sky in the water, and the only reflection Shaded has. Unguarded: this is what makes a
    // surface read as water rather than as a black hole, and the probe it samples is a fixed
    // 128-square render that does not depend on opaque reflections. The LOD is chosen by the
    // surface's own roughness, so calm water mirrors and chop diffuses, from Shaded up.
    // Undamped. Whether the ray meets geometry is the trace's question; a miss means the probe is
    // the right sky at the right brightness. Damping by depth at the ray's infinity pixel is
    // meaningless there (every ray sits behind everything) and paints a half-dark ghost of what
    // the ray passed behind.
    vec3 environmentFallback = max(
            textureLod(u_Input11, environmentUv, environmentLod).rgb, vec3(0.0));

    // Rays that see no sky contribute nothing rather than contributing black: indoors and in caves
    // the fallback has to vanish, not darken the water.
    float skyVis = smoothstep(0.1, 0.7, skyLight);
    // Missed SSR rays have no fallback sky for flowing water at distance (steps/waterfalls become
    // solid sky panels), so phase out only the unoccluded fallback as flow becomes unresolvable,
    // preserving real hits and nearby flow.
    float distantFlow = (1.0 - settledSurface) * smoothstep(20.0, 80.0, length(worldPos));
    float fallbackAccess = 1.0 - distantFlow;
    float reflectionConfidence = clamp(reflSample.a, 0.0, 1.0);
    // Spatially reconstructed (neighbour-filled) pixels stay below 0.5 confidence; phase those out
    // at range on low-confidence flow while keeping high-confidence traced hits.
    float flowTraceAccess = mix(1.0, smoothstep(0.50, 0.85, reflectionConfidence),
                                distantFlow);
    reflectionConfidence *= flowTraceAccess;
    float normalizedRoughness = clamp(
            (waterRoughness - PLAGUE_WATER_MIN_ROUGHNESS)
            / (PLAGUE_WATER_MAX_ROUGHNESS - PLAGUE_WATER_MIN_ROUGHNESS),
            0.0, 1.0);
    float ssrTrust = mix(1.0, 0.62, normalizedRoughness);
    float resolvedConfidence = clamp(reflectionConfidence * ssrTrust, 0.0, 1.0);
    vec3 reflection = mix(environmentFallback * skyVis * fallbackAccess, reflSample.rgb,
                          resolvedConfidence);

#if PLAGUE_WATER_REFLECTION_DEBUG == 1
    fragColor = vec4(vec3(normalizedRoughness), 1.0);
    return;
#elif PLAGUE_WATER_REFLECTION_DEBUG == 2
    fragColor = vec4(vec3(resolvedConfidence), 1.0);
    return;
#elif PLAGUE_WATER_REFLECTION_DEBUG == 3
    fragColor = vec4(environmentFallback, 1.0);
    return;
#elif PLAGUE_WATER_REFLECTION_DEBUG == 4
    fragColor = vec4(resolvedConfidence, 0.0, 1.0 - resolvedConfidence, 1.0);
    return;
#endif
    // A valid SSR hit can still be the wrong visual model for a thin distant flow sheet — too small
    // to carry a lake-sized mirror lobe — so fade the full reflection there.
    float flowReflectionAttenuation = mix(1.0, 0.12, distantFlow);
    reflection *= flowReflectionAttenuation * u_WaterReflectionStrength;

    // One finite sun-directional glitter lobe, living inside `reflection` so the Fresnel below
    // weights it exactly once.
    float sunGlitterAlignment = clamp(dot(reflectDir, glitterLightDir), 0.0, 1.0);
    float sunGlitter = pow(sunGlitterAlignment, 640.0)
                     * glitterVisibility * glitterSunFactor * glintShadowVis
                     * (1.0 - rainFactor * 0.75) * skyVis;
    reflection += glitterRadiance * sunGlitter * 1.5 * u_WaterSunGlitterStrength
                * flowReflectionAttenuation;

    // Water thickness measured along the VIEW RAY (what absorption integrates over), not vertically
    // — a grazing view through a lake passes far more water than looking straight down at the bed.
    float thickness;
    if (opaqueDepth <= 0.0) {
        thickness = 64.0; // no floor found (open ocean to the horizon): treat as effectively deep
    } else {
        thickness = distance(worldPos, worldPosAt(texCoord, opaqueDepth));
    }
    // Kept before the clarity divide below: shoreline foam (WATER_FOAM) reads this raw geometric
    // distance, not the optical one, so raising Water Clarity can't make deep water numerically
    // shrink into the foam band and grow foam somewhere the shore never reaches.
    float rawThickness = thickness;
    thickness /= max(u_WaterClarity, 0.05);

    // Beer-Lambert. Transmittance is what SURVIVES the trip to the bed and back.
    vec3 transmittance = exp(-thickness * WATER_EXTINCTION);

    // Hardware blend is single-scalar alpha, so per-channel absorption must live in colour: alpha
    // carries average loss, body colour carries the resulting hue.
    float opacity = clamp(1.0 - dot(transmittance, vec3(1.0 / 3.0)), 0.0, WATER_MAX_OPACITY);

    // WATER_TINT is scattering colour, not emitted radiance — illuminate it with zenith sky,
    // normalized so noon brightness is unchanged but dawn/overcast/night genuinely dim it.
    vec3 zenithSky = plagueGetSky(waterSky, 1.0, trueSunDir.y, 0.5, false, false) * atmColorMult;
    const float WATER_NOON_ZENITH_LUMA = 0.471;
    float bodyIllumination = clamp(dot(zenithSky, vec3(0.2126, 0.7152, 0.0722))
            / WATER_NOON_ZENITH_LUMA, 0.035, 1.25);
    vec3 surfaceWaterTint = WATER_TINT * WATER_SURFACE_TINT_FILTER;
    float surfaceTintLuma = dot(surfaceWaterTint, vec3(0.2126, 0.7152, 0.0722));
    surfaceWaterTint = mix(vec3(surfaceTintLuma), surfaceWaterTint,
                           clamp(u_WaterTintSaturation, 0.0, 1.0));
    vec3 body = surfaceWaterTint
              * mix(0.15, 1.0, skyVis)
              * mix(0.35, 1.0, clamp(thickness * 0.18, 0.0, 1.0));
    body *= bodyIllumination;

#ifdef WATER_FOAM
    // Shoreline foam hugs every coastline/sandbar for free, since it's driven by the same distance
    // computed above rather than needing a separate edge-detection pass. Reads rawThickness, not
    // the optical thickness above: shore proximity is geometry, not a function of how clear the
    // water is, and dividing it by clarity first would let a high Water Clarity value paint foam
    // onto water that is not actually shallow.
    float shoreline = 1.0 - smoothstep(0.0, 1.6, rawThickness);
    // Leading-edge fade: `shoreline` alone peaks exactly at the waterline, reading as foam clipped
    // hard against dry land. Real foam sits set back from the edge.
    float leading = smoothstep(0.0, 0.35, rawThickness);
    float edge = shoreline * leading;

    // No open-water whitecaps: driving a foam mask off crest height/slope produced flat white slabs
    // across the swell, not torn spray (same failure as the interaction-wake foam WATER_TODO
    // records). Foam here is a shoreline phenomenon only.
    float foamAmount = clamp(u_WaterFoamAmount, 0.0, 2.0);
    float foam = 0.0;
    float shorelineFoam = 0.0;
    vec2 foamUv = (worldPos.xz + u_CameraAbs.xz) * u_FoamTextureScale;

    if (edge > 0.0) {

        // Bubble-film pattern texture (tools/generate_foam.py), not noise — noise can't produce
        // foam's cell-boundary shape. Two scrolled taps at different scale/direction avoid visible
        // repetition.
        //
        // Generator shapes fixed quantiles (7.4% film, 44.1% hole) that the smoothstep knee below is
        // tuned against — a different texture needs the knee retuned, not just remapped here.
        const float FOAM_TEX_LUMA_MIN = 0.0;
        const float FOAM_TEX_LUMA_MAX = 1.0;
        // Shifts the base UV by parallax before the scrolling taps read it, so animation is
        // untouched and only the lookup point moves. Skipped at depth 0.
        if (u_FoamPomDepth > 0.0) {
            foamUv = plagueFoamParallax(u_Input10, foamUv, viewDir, u_FoamPomDepth * u_FoamTextureScale);
        }
        vec3 foamTexA = texture(u_Input8, foamUv + vec2(u_SkyState.w * 0.004, 0.0)).rgb;
        vec3 foamTexB = texture(u_Input8, foamUv * 2.3 - vec2(0.0, u_SkyState.w * 0.006)).rgb;
        float foamLumaA = dot(foamTexA, vec3(0.2126, 0.7152, 0.0722));
        float foamLumaB = dot(foamTexB, vec3(0.2126, 0.7152, 0.0722));
        float foamPatternA = clamp((foamLumaA - FOAM_TEX_LUMA_MIN)
                / (FOAM_TEX_LUMA_MAX - FOAM_TEX_LUMA_MIN), 0.0, 1.0);
        float foamPatternB = clamp((foamLumaB - FOAM_TEX_LUMA_MIN)
                / (FOAM_TEX_LUMA_MAX - FOAM_TEX_LUMA_MIN), 0.0, 1.0);
        float foamPattern = (foamPatternA + foamPatternB * 0.5) / 1.5;

        // Subtractive compositing: edge falloff punched through by the texture's dark cells
        // (mask = 1-pattern), not additive — this is what carves real holes rather than a wash.
        // Smoothstep knee (0.75/1.5), not a hard clamp: widens the transition so typical shoreline
        // points read as visible foam at default amount, and raising amount toward 2.0 keeps
        // thickening weak spots instead of an already-saturated band doing nothing.
        shorelineFoam = smoothstep(0.75, 1.5, edge + foamPattern) * foamAmount;

        // Flowing water carries no foam: thin water over terrain reads near-zero thickness along
        // its length, so the shoreline term above would otherwise fire everywhere on a stream.
        // Gated by settledSurface (source blocks sit at fixed fill height 8/9; flowing levels step
        // down and slope), not a hard test, since Sodium's corner-interpolated flowing quads would
        // pop against one.
        //
        // u_CameraAbs (animated) is safe here for the same reason the fog below uses it: worldPos
        // comes from the depth buffer, so camera bob is on both sides and cancels.
        shorelineFoam *= settledSurface;
        foam = max(foam, shorelineFoam);

    }

    if (foam > 0.0) {

        // Foam roughens the surface, so coverage drives both the specular weight (fresnel) and the
        // reflection image down together, capped at 0.85 (not fully matte — aerated foam still
        // carries a faint wet sheen).
        //
        // 0.85 authored directly, not sampled: this pack's material maps aren't wired in here, and
        // a typical packed smoothness channel (0.749-0.898, i.e. roughness 0.10-0.25) would read
        // foam as near-mirror, which is physically backwards.
        float foamRoughening = clamp(foam, 0.0, 1.0) * 0.85;
        fresnel *= 1.0 - foamRoughening;
        reflection *= 1.0 - foamRoughening;

        // Normal map is tangent-space Z-up on a world-XZ planar UV, so tangent axes remap to world
        // space: tangent X -> world X, tangent Y -> world Z, tangent Z -> world Y.
        vec3 foamNormalTexel = texture(u_Input9, foamUv + vec2(u_SkyState.w * 0.004, 0.0)).rgb;
        foamNormalTexel.g = 1.0 - foamNormalTexel.g; // inverted relative to OpenGL (asset's own README)
        vec3 foamNormal = normalize(foamNormalTexel * 2.0 - 1.0);
        vec3 foamWorldNormal = normalize(vec3(foamNormal.x, foamNormal.z, foamNormal.y));
        float foamNdotL = max(dot(foamWorldNormal, glitterLightDir), 0.0);
        float foamSkyShape = mix(0.72, 1.05, clamp(foamWorldNormal.y, 0.0, 1.0));
        vec3 foamDirect = glitterRadiance * foamNdotL * glintShadowVis
                * (1.0 - rainFactor * 0.95) * 0.318309886 * 0.65;

        // Foam's removed mirror response isn't reused as diffuse light — a Lambert 1/pi cap uses the
        // same sun/moon radiance and occlusion as the water glint instead. Ambient luminance is
        // preserved but mostly desaturated: broad-scattering bubbles read as white water, not the
        // body's cyan tint.
        body = mix(body, FOAM_ALBEDO
                   * (mix(lighting.ambient, vec3(dot(lighting.ambient, vec3(0.2126, 0.7152, 0.0722))), 0.72)
                      * foamSkyShape + foamDirect)
                   * mix(0.35, 1.0, skyVis),
                   clamp(foam, 0.0, 1.0));
        // Foam is opaque in a way clear shallow water is not: it hides the bed it sits over.
        opacity = max(opacity, clamp(foam, 0.0, 1.0) * 0.9);
    }
#endif

    // Analytic interface solve for the fixed src*a+dst*(1-a) blend: alpha carries both interface
    // reflection and Beer-Lambert absorption, and colour is pre-divided by alpha so hardware
    // blending reconstructs L = F*Lreflection + (1-F)*[(1-T)*Lwater + T*Lbackground] exactly.
    float transmitMean = clamp(dot(transmittance, vec3(1.0 / 3.0)), 0.0, 1.0);
    float interfaceAlpha = 1.0 - (1.0 - fresnel) * transmitMean;
    vec3 interfaceNumerator = fresnel * reflection
                            + (1.0 - fresnel) * (1.0 - transmitMean) * body;
    vec3 surface = interfaceNumerator / max(interfaceAlpha, 1e-4);
    opacity = max(opacity, interfaceAlpha);

#if PLAGUE_UNDERWATER
    // Surface seen from below. Wave normal perturbs refraction, Fresnel and SSR direction only —
    // never converted to emissive slope shading (a prior arm's slope-band emission saturated to a
    // constant wash across the whole surface).
    if (u_WaterState.x > 0.5) {
        // Decoded mesh winding is not a safe optical-interface convention; using different normals
        // for Fresnel and refraction silently collapses the glint on an oppositely-wound surface.
        vec3 uwEyeRay = normalize(worldPos); // camera -> water surface, inside water
        vec3 uwInterfaceNormal = dot(uwEyeRay, waveNormal) > 0.0
                ? -waveNormal : waveNormal;
        float uwCosIncident = clamp(dot(-uwEyeRay, uwInterfaceNormal), 0.0, 1.0);
        float uwFresnel = plagueDielectricFresnel(uwCosIncident, 1.333, 1.0);

        // Downwelling sky radiance along the refracted eye ray — real directional structure, not a
        // flat tint. No cloud content (that's a separate volumetric march, uncallable along an
        // arbitrary ray).
        float uwCameraDepth = max(u_WaterState.z - u_CameraAbs.y, 0.0);
        vec3 uwEyeFilter = exp(-uwCameraDepth * vec3(0.20, 0.08, 0.04));
        vec3 uwExitRay = refract(uwEyeRay, uwInterfaceNormal, 1.333);
        vec3 uwDirectionalSky = plagueWaterFogColor(lighting);
        if (dot(uwExitRay, uwExitRay) > 1e-6) {
            vec3 uwExitDir = normalize(uwExitRay);
            uwDirectionalSky = plagueGetSky(waterSky, uwExitDir.y,
                    dot(uwExitDir, trueSunDir), 0.5, false, false) * atmColorMult;

            // Stars ride uwExitDir directly (band-limited, so no wave-normal jitter to alias) —
            // also a correctness check: a starfield in the wrong hemisphere is obvious at a glance.
            float uwSyncedTime = u_SkyState.w * 0.05;
            float uwInvNoonFactor = 1.0 - lighting.noonFactor;
            vec2 uwStarCoord = plagueStarCoord(uwExitDir, PLAGUE_STAR_SPHERENESS, uwSyncedTime);
            uwDirectionalSky += plagueGetStars(uwStarCoord, uwExitDir.y, dot(uwExitDir, trueSunDir),
                    1.0, 0.0, uwInvNoonFactor * uwInvNoonFactor,
                    lighting.sunVisibility, 1.0 - rainFactor, u_SunriseColor.w);

            // Real sun/moon disc, searched along the true (undamped) refracted uwExitDir — a damped
            // search direction was tried and rejected (owner: the wobble is real refraction, not an
            // artifact to hide). Anti-aliasing lives inside plagueUnderwaterCelestialDiscs as a
            // signal-domain prefilter; if the rim still shimmers, strengthen that, not damping.
            //
            // Softness scales with camera depth (more water = more scattering = blurrier disc); the
            // runtime slider is a multiplier/ceiling on that base, not a flat override.
            float uwDiscDepthFactor = clamp(uwCameraDepth / 8.0, 0.0, 1.0);
            float uwDiscSoftness = mix(u_UnderwaterDiscSoftness * 0.4, u_UnderwaterDiscSoftness,
                                       uwDiscDepthFactor);
            float uwMoonDiscGlow = smoothstep(-0.03, 0.08, -trueSunDir.y)
                                  * (1.0 - lighting.sunVisibility);
            uwDirectionalSky += plagueUnderwaterCelestialDiscs(uwExitDir, trueSunDir,
                    u_SkyCelestial.w, u_WorldClock.x, u_Input12, u_Input13, uwDiscSoftness,
                    1.0 - rainFactor, uwMoonDiscGlow);
        }
        vec3 uwSkyFill = mix(plagueWaterFogColor(lighting), uwDirectionalSky, 0.68);
        vec3 uwInside = uwSkyFill * uwEyeFilter * mix(0.90, 1.08, skyVis);

        // TIR mirror fallback outside the critical cone; kept quiet so a failed SSR ray doesn't
        // read as a bright marble stripe.
        vec3 uwMirrorFallback = plagueWaterFogColor(lighting) * uwEyeFilter * 0.30;
        vec3 uwOutside = mix(uwMirrorFallback, reflSample.rgb,
                             clamp(reflSample.a, 0.0, 1.0) * 0.88)
                       * u_WaterReflectionStrength;

        // The source directions remain tied to the true celestial pair. u_SunDirection becomes
        // the moon at sunset, so using it here would snap a still-visible sun glint across the
        // sky. The fade spans the existing sun-disc angular support: no new artistic horizon band.
        float uwSunHorizonSupport = sin(max(u_SunDiscSize, 0.001));
        float uwSunHorizonFade = smoothstep(-uwSunHorizonSupport, uwSunHorizonSupport, trueSunDir.y);
        float uwMoonHorizonFade = 1.0 - uwSunHorizonFade;
        vec3 uwMoonDir = -trueSunDir;

        // Two bounded lobes approximate each finite celestial disc plus a tighter core (a single
        // narrow pow() vanished at noon, subpixel against the sampling). Moving noise modulates
        // coverage only after physical alignment — no wave slope becomes emission.
        float uwSunAlignment = 0.0;
        float uwMoonAlignment = 0.0;
        float uwSolarLobe = 0.0;
        float uwMoonLobe = 0.0;
        float uwSunGlint = 0.0;
        float uwMoonGlint = 0.0;
        if (dot(uwExitRay, uwExitRay) > 1e-6) {
            uwSunAlignment = clamp(dot(normalize(uwExitRay), trueSunDir), 0.0, 1.0);
            uwMoonAlignment = clamp(dot(normalize(uwExitRay), uwMoonDir), 0.0, 1.0);
            uwSolarLobe = 0.72 * pow(uwSunAlignment, 72.0)
                        + 0.28 * pow(uwSunAlignment, 384.0);
            uwMoonLobe = 0.72 * pow(uwMoonAlignment, 72.0)
                       + 0.28 * pow(uwMoonAlignment, 384.0);
            vec2 uwGlintUv = (worldPos.xz + u_CameraAbs.xz) * 0.19;
            float uwGlintTime = u_SkyState.w / 20.0;
            float uwMicroA = texture(u_Input4,
                    uwGlintUv + vec2(0.017, -0.011) * uwGlintTime).r;
            float uwMicroB = texture(u_Input4,
                    uwGlintUv * 1.83 + vec2(-0.013, 0.019) * uwGlintTime).r;
            float uwMicroCoverage = smoothstep(0.48, 0.88, mix(uwMicroA, uwMicroB, 0.43));
            float uwMicroGlint = mix(0.32, 1.10, uwMicroCoverage) * (1.0 - uwFresnel);
            uwSunGlint = uwSolarLobe * uwSunHorizonFade * uwMicroGlint * uwSunShadowVis;
            uwMoonGlint = uwMoonLobe * uwMoonHorizonFade * uwMicroGlint * uwMoonShadowVis;
        }

        vec3 uwSunFiltered = plagueSunColor(glitterAirEyePos, trueSunDir) * uwEyeFilter;
        vec3 uwMoonFiltered = plagueMoonColor(glitterAirEyePos, uwMoonDir) * uwEyeFilter;
        vec3 uwGlintContribution = (uwSunFiltered * uwSunGlint + uwMoonFiltered * uwMoonGlint)
                * 2.0 * u_UnderwaterSunGlitterStrength * skyVis;

        surface = mix(uwInside, uwOutside, uwFresnel) + uwGlintContribution;
        // Overrides the air-side alpha computed above: it described the wrong side of the interface.
        opacity = mix(0.74, 0.98, uwFresnel);

        if (debugView == DBG_UW_GLINT_1) {
            fragColor = vec4(uwSunAlignment, uwMoonAlignment, uwFresnel, 1.0);
            return;
        }
        if (debugView == DBG_UW_GLINT_2) {
            fragColor = vec4(uwEyeFilter, 1.0);
            return;
        }
        if (debugView == DBG_UW_GLINT_3) {
            fragColor = vec4(uwSunGlint, uwMoonGlint, u_UnderwaterSunGlitterStrength, 1.0);
            return;
        }
        if (debugView == DBG_UW_GLINT_4) {
            fragColor = vec4(uwGlintContribution, 1.0);
            return;
        }
    }
#endif

    // Fog: COLOUR ONLY, alpha untouched. A forward pass would drive alpha toward 0 to fade a
    // translucent into the (already-fogged) background, but here the background is the seabed, so
    // fading alpha would let it show through in proportion to fog, worse the deeper the water.
    // Fogging only colour converges to the same result: at full fog both water and the already-
    // fogged seabed read as sky colour, so alpha stops mattering.
    //
    // The reflection inside `surface` already carries its own fog (traced against the resolve's
    // fogged sceneHdr), matching gbuffer_resolve.fsh's own approximation at its fog site.
#if PLAGUE_FOG
    // Ungated on u_WaterState: plagueFogTerms's eye-in-water arm already gives a submerged surface
    // the same veil/tint as terrain around it, and the dry path is unchanged.
    {
        // TRUE sun, never the active light — same rule the sky, clouds and resolve's fog all follow.
        vec3 fogSunDir = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
                ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
        PlagueSkyColors fogSky = plagueSkyColors(max(u_SkyColor.rgb, vec3(0.0)),
                fogSunDir, lighting.sunVisibility, rainFactor, u_CameraAbs.y);

        // u_Param2: the resolve's own anchor, kept identical here to avoid a seam at the shoreline.
        float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0);
        float fogDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));

        // atmColorMult is computed at the top of the pass (see there) so this fog term agrees
        // with the zenith and underwater-exit sky samples above.
#if PLAGUE_SKY_MODEL == 1
        // The same table reads the resolve makes for the terrain beside this water (fog_aerial.glsl).
        float fogDist = length(worldPos);
        float fogFar = plagueAtmoAerialFar();
        vec4 fogAerial = plagueAtmoAerial(texCoord, fogDist, fogFar);
        float fogNearT = plagueAtmoAerial(texCoord, max(fogDist - PLAGUE_FOG_SKY_LIGHT_REACH, 0.0), fogFar).a;
        vec3 fogDir = worldPos / max(fogDist, 1e-4);
        vec3 fogSkyAlong = plagueAtmoSkyView(fogDir, fogSunDir, plagueAtmoCameraRadius()).rgb;
        // Same warmth the resolve's border term gets (fog_aerial.glsl / sky.glsl), so the water's
        // own horizon does not disagree with the shoreline beside it.
        fogSkyAlong = plagueWarmSkyBand(fogSkyAlong, fogDir.y, dot(fogDir, fogSunDir), fogSunDir.y);
        PlagueFogDrive fogDrive = PLAGUE_FOG_DRIVE(lighting);
        PlagueFogTerms fogTerms = plagueFogTermsAerial(worldPos, skyLight, u_CameraSkyLight.x,
                                 renderDistance, fogAerial, fogNearT, fogSkyAlong,
                                 plagueAtmoAerialChroma(texCoord), fogDrive,
                                 u_FogBorderDensity, u_DepthDarkness,
                                 plagueChunksToBlocks(u_UnderwaterFogStart),
                                 plagueChunksToBlocks(u_WaterDistanceFog),
                                 plagueChunksToBlocks(u_WaterDepthFog),
                                                 vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB),
                                                 vec3(u_WaterDistanceDarkness, u_WaterDepthDarkness,
                                                      plagueChunksToBlocks(u_WaterDarknessDepth)), lighting, atmColorMult);
        surface = mix(surface, fogTerms.atmColor, clamp(fogTerms.atm, 0.0, 1.0));
        // plagueBorderColorWeight (fog.glsl): squared so a bright sun-side sky reading doesn't
        // glow in ahead of the render cutoff. See its own comment for why.
        surface = mix(surface, fogTerms.borderColor, plagueBorderColorWeight(fogTerms.border));
        surface = mix(surface, fogTerms.waterColor, clamp(fogTerms.water, 0.0, 1.0));
        surface *= fogTerms.uwTint;
#else
        surface = plagueApplyFog(surface, worldPos, skyLight, u_CameraSkyLight.x,
                                 renderDistance, u_CameraAbs.y,
                                 fogDither, fogSky, lighting, fogSunDir,
                                 u_FogDensity, u_FogBorderDensity, u_DepthDarkness,
                                 plagueChunksToBlocks(u_UnderwaterFogStart),
                                 plagueChunksToBlocks(u_WaterDistanceFog),
                                 plagueChunksToBlocks(u_WaterDepthFog),
                                                 vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB),
                                                 vec3(u_WaterDistanceDarkness, u_WaterDepthDarkness,
                                                      plagueChunksToBlocks(u_WaterDarknessDepth)), atmColorMult);
#endif

#if PLAGUE_UNDERWATER
        // Matches the resolve's own far-field water-fog handover exactly (byte-identical logic,
        // must move together) so a loaded water surface and a missing pre-pass texel converge to
        // one closed volume instead of outlining the translucent chunk grid. Visibility multiplier
        // is 3x baseline, 6x at clear noon. See the resolve's copy for why a sphere-test smoothstep
        // couldn't fix the curved-band artifact it replaced.
        if (u_WaterState.x > 0.5) {
            float uwClearNoon = lighting.noonFactor * (1.0 - clamp(lighting.rainFactor, 0.0, 1.0));
            float uwVisibilityMult = mix(3.0, 6.0, uwClearNoon);
            float uwClosureScale = min(renderDistance,
                    plagueChunksToBlocks(u_WaterDistanceFog) * uwVisibilityMult);
            float horizonClosure = plagueGetWaterFog(length(worldPos), uwClosureScale);
            vec3 closedVeil = plagueWaterFogColor(lighting)
                            * plagueAuthoredToLinear(
                                  plagueUnderwaterMult(renderDistance, renderDistance,
                                                       u_DepthDarkness, lighting, vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB)) * 0.85);
            vec3 closedRadiance = plagueUnderwaterClosedRadiance(
                    normalize(worldPos), closedVeil, lighting.sunFactor,
                    plagueChunksToBlocks(u_WaterDistanceFog));
            surface = mix(surface, closedRadiance, horizonClosure);
        }
#endif
    }
#endif

    fragColor = vec4(surface, opacity);
}
