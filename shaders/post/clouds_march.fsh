#version 330

// Volumetric cloud march. Writes premultiplied HDR colour + coverage into an offscreen target;
// clouds_composite.fsh blends it over the scene. Design lives in shaders/include/clouds.glsl and
// the genus table in shaders/include/cloud_types.glsl; this file is the pass.
//
// A separate pass rather than an arm of the resolve because clouds must appear IN FRONT of distant
// terrain (a cloud at 300 blocks is nearer than a mountain at 1000): the march needs the depth
// buffer as a ray limit, not an on/off test the resolve's sky-only branch would give it.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:sky.glsl>

uniform sampler2D u_Input0; // builtin.depth
uniform sampler2D u_Input1; // builtin.noise, 512x512 tileable RGBA, bound LINEAR + REPEAT

// Fullscreen pipelines cannot bind the true sampler3D volumes the live compute march uses. These
// ALU base/detail approximations keep this arm real and compile-checked instead of dead source.
#define PLAGUE_CLOUD_NOISE_3D(uvw) vec4(plagueSkyFbm((uvw).xz + (uvw).y, 4))
#define PLAGUE_CLOUD_DETAIL_3D(uvw) vec4(plagueSkyFbm((uvw).xz * 3.0 + (uvw).y, 2))
#moj_import <fornax_runtime:clouds.glsl>

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    // Active light in xyz, TRUE sun elevation (sine) in w. Only w is read here: it stays meaningful
    // once the moon takes over the lighting, where xyz does not.
    vec4  u_SunDirection;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
#if CLOUDS_VOLUMETRIC
    // u_SkyState.z is the engine's record that it actually cancelled vanilla's cloud pass this
    // frame; re-deriving "is CLOUDS_VOLUMETRIC on" instead can disagree with it when a competing
    // sky mod is present. Same contract u_SkyColor.w has for the sky in gbuffer_resolve.fsh.
    if (u_SkyState.z <= 0.5) { fragColor = vec4(0.0); return; }

    // Unprojected at a FAR-but-finite reversed-Z depth (0.0001, matching gbuffer_resolve.fsh):
    // unprojecting at the reversed-Z near plane (1.0) reconstructs a point ~5cm from the eye, where
    // view-bob translation swings the direction up to 56 degrees per footstep. Uses the JITTERED
    // inverse to match the depth buffer sampled below — the cloud field's coarsest feature has
    // nothing to wobble at sub-pixel scale, so agreeing with the G-buffer wins.
    vec4 clipPos = vec4(texCoord * 2.0 - 1.0, 0.0001, 1.0);
    vec4 worldH = u_InvProjModelView * clipPos;
    vec3 viewDir = normalize(worldH.xyz / worldH.w);

    // Reversed-Z: buffer clears to 0.0 = far, so depth 0 means unobstructed.
    float depth = texture(u_Input0, texCoord).r;
    float terrainDist = 1e9;
    if (depth > 0.0) {
        vec4 hitH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
        terrainDist = length(hitH.xyz / hitH.w);
    }

    // Jimenez's interleaved gradient noise (SIGGRAPH 2014, "Next Generation Post Processing in Call
    // of Duty: Advanced Warfare"), rotated per frame by the golden ratio so temporal AA turns the
    // step dither into a gradient rather than averaging one fixed pattern into itself. This pass
    // needs no history target of its own since the engine's TAA/upscale runs after the whole graph.
    const float goldenRatio = 1.61803398875;
    float dither = 52.9829189
            * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y);
    dither = fract(dither + goldenRatio * mod(u_FrameState.x, 3600.0));

    // Same colour tables the resolve builds, from the same uniforms, so clouds and sky can never
    // disagree about time of day or weather.
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
    // TRUE sun, never the active light: the silver lining stays on the sun's side of the sky even
    // once the moon has taken over the lighting.
    vec3 sunDirTrue = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
    PlagueSkyColors skyColours = plagueSkyColors(max(u_SkyColor.rgb, vec3(0.0)),
            sunDirTrue, lighting.sunVisibility, rainFactor, u_CameraAbs.y);

    // Same tick->second conversion stars.glsl and the wave field use, so drift rates agree.
    float syncedTime = u_SkyState.w * 0.05;

    // Only cumulus is resolved today; the full driver signature is passed now so adding further
    // genera is an edit inside cloud_types.glsl, not at every call site. u_FrameState.z is thunder
    // level (only signal reaching cumulonimbus); u_FrameState.w is accumulated wetness, which lags
    // rain in both directions; u_CameraSkyLight.y is vanilla's Biome.getPrecipitationAt (0/1/2),
    // the only available climate signal (rain vs. snow) for the genus choice.
    PlagueCloudDeck deck = plagueCloudLowDeck(
            rainFactor,
            clamp(u_FrameState.z, 0.0, 1.0),
            clamp(u_FrameState.w, 0.0, 1.0),
            int(u_CameraSkyLight.y + 0.5) == PLAGUE_PRECIP_SNOW ? 1.0 : 0.0,
            u_SunDirection.w,
            syncedTime);

    // Same anchor expression every fog site uses, so the cloud veil and terrain veil close together.
    float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0);

    // Same value every other pass reaches for, so the deck's fade-to-sky agrees with the dome and
    // the terrain fog it fades alongside.
    vec3 atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
            vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
            vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
            vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif
    float ignoredCloudFrontDistance;
    fragColor = plagueGetClouds(viewDir, u_CameraAbs, terrainDist, dither,
                                deck, skyColours, lighting, sunDirTrue, syncedTime,
                                renderDistance, atmColorMult, ignoredCloudFrontDistance);
#else
    // Graph gates this pass off entirely when CLOUDS_VOLUMETRIC is 0; this arm only exists so
    // check_shaders.sh compiles both.
    fragColor = vec4(0.0);
#endif
}
