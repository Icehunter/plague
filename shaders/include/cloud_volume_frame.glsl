#ifndef PLAGUE_CLOUD_VOLUME_FRAME
#define PLAGUE_CLOUD_VOLUME_FRAME
// Shared frame inputs/setup for candidate construction and visible integration. Resolving decks
// differently in the two passes could incorrectly cull real cloud density without a compile error.
#define FORNAX_COMPUTE_GLOBALS
#define FORNAX_GLOBALS_BINDING 0
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:sky.glsl>
#moj_import <fornax_runtime:cloud_history.glsl>

// Common inputs keep graph bindings 0..6: globals, options, two volumes,
// precipitation, sky view and atmosphere transmittance. Outputs belong to each entry point.
layout(set = 0, binding = 2) uniform sampler3D u_CloudBaseShapeVolume;
layout(set = 0, binding = 3) uniform sampler3D u_CloudDetailShapeVolume;
layout(std430, set = 0, binding = 4) readonly buffer PrecipCoarseClipmap {
    int words[];
} precipCoarseClipmap;
// Filled by the atmosphere passes before the cloud march.
layout(rgba16f, set = 0, binding = 5) uniform readonly image2D u_SkyView;
layout(rgba16f, set = 0, binding = 6) uniform readonly image2D u_Transmittance;
#ifdef PLAGUE_CLOUD_CANDIDATE_CACHE_READ
// Atlas is appended after all original inputs; the marcher outputs start at binding 8.
layout(r32f, set = 0, binding = 7) uniform readonly image2D u_CloudCandidateMask;
#endif

#define PLAGUE_CLOUD_NOISE_3D(uvw) texture(u_CloudBaseShapeVolume, uvw)
#define PLAGUE_CLOUD_DETAIL_3D(uvw) texture(u_CloudDetailShapeVolume, uvw)
#define PLAGUE_PRECIP_CLIPMAP(slot) precipCoarseClipmap.words[slot]
#define PLAGUE_ATMO_READS_SKYVIEW
#define PLAGUE_ATMO_READS_TRANSMITTANCE
#if PLAGUE_CLOUD_TEMPORAL == 2
#define PLAGUE_CLOUD_REDUCED_MARCH
#endif
#moj_import <fornax_runtime:clouds.glsl>

vec4 plagueAtmoFetchSkyView(vec2 uv) {
    ivec2 i0;
    ivec2 i1;
    vec2 f;
    plagueAtmoBilinearSetup(uv, imageSize(u_SkyView), i0, i1, f);
    return plagueAtmoBilinearMix(imageLoad(u_SkyView, i0), imageLoad(u_SkyView, ivec2(i1.x, i0.y)),
                                 imageLoad(u_SkyView, ivec2(i0.x, i1.y)), imageLoad(u_SkyView, i1), f);
}

vec4 plagueAtmoFetchTransmittance(vec2 uv) {
    ivec2 i0;
    ivec2 i1;
    vec2 f;
    plagueAtmoBilinearSetup(uv, imageSize(u_Transmittance), i0, i1, f);
    return plagueAtmoBilinearMix(imageLoad(u_Transmittance, i0),
                                 imageLoad(u_Transmittance, ivec2(i1.x, i0.y)),
                                 imageLoad(u_Transmittance, ivec2(i0.x, i1.y)),
                                 imageLoad(u_Transmittance, i1), f);
}

#if CLOUDS_VOLUMETRIC
// Every value here comes from frame uniforms or the atmosphere tables, never the ray.
// One invocation computes them for the whole workgroup; main's barrier shares the result.
shared PlagueLighting lighting;
shared PlagueCloudDeck convectiveDeck, stratiformDeck, sheetDeck, rollDeck;
shared PlagueCloudDeck cirrusDeck, cirrocumulusDeck, altocumulusDeck;
shared vec3 sunDirTrue, atmColorMult, ambientDome, upperMasks;
shared float syncedTime, localRain, localThunder, stratiform, renderDistance;
shared float lowSheet, lowRolls, cumulusOn, rainOn;

void plaguePrepareCloudWorkgroup() {
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

    // Compute passes never receive the fullscreen PassParams push constant's derived sun-elevation
    // sine: that push constant's base 32 bytes carry texelSize/param2/param3/sunDir.xyz only, per
    // ComputePassRunner, and .w is never written for a compute dispatch. Re-derived here from the
    // true sun direction below: the Y component
    // of a unit direction vector is the sine of its elevation by definition, so this is the exact
    // same value under a different name, not an approximation.
    sunDirTrue = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
    float sunElevationSine = sunDirTrue.y;

    syncedTime = u_SkyState.w * 0.05;

    localRain = clamp(u_SkyState.x, 0.0, 1.0);
    localThunder = clamp(u_FrameState.z, 0.0, 1.0);
    float localSnowWeight = int(u_CameraSkyLight.y + 0.5) == 2 ? 1.0 : 0.0;

    lighting = plagueOverworldLighting(
            max(u_SkyColor.rgb, vec3(0.0)), sunElevationSine, u_SkyState.y,
            localRain, u_ScreenBrightness, palette);

    stratiform = plagueCloudTransitionDecks(
            localRain,
            localThunder,
            clamp(u_FrameState.w, 0.0, 1.0),
            localSnowWeight,
            sunElevationSine,
            syncedTime,
            convectiveDeck,
            stratiformDeck);

    // u_Param2 is filled by the engine BY PASS NAME (see ComputePassRunner); this pass's name is
    // not one the engine recognizes, so u_Param2 reads 0 here and this falls back to fog render
    // distance.
    renderDistance = max(u_RenderFog.y, 32.0);

    atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
            vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
            vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
            vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif

    ambientDome = plagueAtmoSkyHemisphere(sunDirTrue, plagueAtmoCameraRadius());

    // Three contributors, each marched only when it has something to draw: the convective low
    // deck, the low etage's smooth forms, the deep precipitating object. Compositing premultiplied
    // in ray order IS the union 1 - prod(1 - a), so forms coexist rather than trade. The smooth
    // forms need their own march because deck.cell is five times coarser for a sheet and cannot
    // move: a world-coordinate divisor rephases the field around world origin.
    lowSheet = plagueCloudLowStratiform(localSnowWeight, sheetDeck);

    lowRolls = plagueCloudStratocumulus(localSnowWeight, rollDeck);

    plagueCloudUpperDecks(cirrusDeck, cirrocumulusDeck, altocumulusDeck, upperMasks);

    cumulusOn = (u_CloudTierCumulus > 0.5 ? 1.0 : 0.0);
    rainOn = (u_CloudTierNimbostratus > 0.5 ? 1.0 : 0.0);

    // The End drops the two weather decks and keeps the sheets. A cumulus needs warm ground to rise
    // off and a nimbostratus needs rain to drop, and a fair-weather heap over the void reads as a
    // piece of the Overworld that followed you through the portal. Sheets carry no such claim: they
    // pass as torn layers of the same medium the sky is made of, and without them the End has no
    // cloud at all, since the high decks are thin and often not overhead.
    float weatherDecks = u_WorldBounds.w == 3.0 ? 0.0 : 1.0;
    cumulusOn *= weatherDecks;
    rainOn *= weatherDecks;
    plagueCloudCandidateOrigins[0] = plagueCloudCandidateOrigin(convectiveDeck);
    plagueCloudCandidateOrigins[1] = plagueCloudCandidateOrigin(sheetDeck);
    plagueCloudCandidateOrigins[2] = plagueCloudCandidateOrigin(stratiformDeck);
    plagueCloudCandidateOrigins[3] = plagueCloudCandidateOrigin(rollDeck);
    plagueCloudCandidateOrigins[4] = plagueCloudCandidateOrigin(altocumulusDeck);
    plagueCloudCandidateOrigins[5] = plagueCloudCandidateOrigin(cirrocumulusDeck);
    plagueCloudCandidateOrigins[6] = plagueCloudCandidateOrigin(cirrusDeck);
}
#endif

#endif
