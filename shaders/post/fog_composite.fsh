#version 330

// Material resolve and this fog pass use the same current graphics depth and reconstruction.
// Keeping transport here avoids a separately submitted endpoint read and fits the sampler budget.
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:water_options.glsl>
#define PLAGUE_ATMO_READS_AERIAL
// Interleaved gradient noise (Jimenez 2014), fixed per pixel. It slides the march's eight shadow
// checks inside their slots, so the edge of a light shaft breaks up across a block instead of
// stepping over it as the sun crosses a check. The same every frame: there is no pass behind this
// one to clean up a moving pattern, and an uncleaned one flickers. Must come before the transport
// import, where the march that uses it lives. One line, no backslash: GLSL 330 cannot wrap a
// define over two lines and the engine throws the shader out.
#define PLAGUE_ATMO_SHADOW_JITTER fract(52.9829189 * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y))
#moj_import <fornax_runtime:atmo_transport.glsl>
#moj_import <fornax_runtime:fog_aerial.glsl>

#define u_FogOpacityView 0 //[0 1] runtime "Fog Thickness View" {0="Off" 1="On"}

// Positional graph ABI: the scene and its depth are read together, before any later composition.
uniform sampler2D u_SceneHdrUnfogged; // sceneHdrUnfogged
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2DArray u_ConsolidatedGbuf; // consolidatedGbuf, layer 0 alpha = sky light
uniform sampler2D u_WaterDepth; // builtin.waterDepth
uniform sampler2D u_AtmoTransmittance; // atmoTransmittance
uniform sampler2D u_AtmoMultiScatter; // atmoMultiScatter
uniform sampler2D u_AtmoSkyView; // atmoSkyView
uniform sampler2D u_AtmoAerial; // atmoAerial, enclosure metadata only
uniform sampler2D u_Noise; // builtin.noise
uniform sampler2DShadow u_SunShadowMap; // sunShadowMap
uniform sampler2D u_SunShadowMapRaw; // sunShadowMapRaw
uniform sampler2D u_RtTerrainShadowDepth; // rtTerrainShadowDepth
uniform sampler2D u_SunEntityShadowMapRaw; // sunEntityShadowMapRaw
#define G_DEPTH u_Depth
#define WATER_DEPTH_TEX u_WaterDepth
#define NOISE_TEX u_Noise
#define SHADOW_COMPARISON_MAP u_SunShadowMap
#define SHADOW_RAW_MAP u_SunShadowMapRaw
#define RT_TERRAIN_SHADOW_DEPTH u_RtTerrainShadowDepth
#define ENTITY_SHADOW_RAW_MAP u_SunEntityShadowMapRaw
#moj_import <fornax_runtime:shadow_handoff.glsl>
#ifdef SHADOWS
#moj_import <fornax_runtime:atmo_shadow.glsl>
float plagueAtmoSunShadow(vec3 posBlocks, vec3 sunDir) {
    return plagueAtmoShadowAt(posBlocks, sunDir).x;
}
bool plagueAtmoShadowCovers(vec3 posBlocks, vec3 sunDir) {
    return plagueAtmoShadowBoxCovers(posBlocks, sunDir);
}
#endif

vec4 plagueAtmoFetchTransmittance(vec2 uv) { return texture(u_AtmoTransmittance, uv); }
vec4 plagueAtmoFetchMultiScatter(vec2 uv) { return texture(u_AtmoMultiScatter, uv); }
vec4 plagueAtmoFetchSkyView(vec2 uv) { return texture(u_AtmoSkyView, uv); }
vec4 plagueAtmoFetchAerial(vec2 uv) { return texture(u_AtmoAerial, uv); }

// Same fullscreen uniform ABI as material resolve; supplied for the resolve_hdr pass name.
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

// GBufferDebugView ordinal ABI; closure data is produced by the moved fog block below.
#define DBG_UW_CLOSURE 30
in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec4 scene = texture(u_SceneHdrUnfogged, texCoord);
#if !PLAGUE_FOG || PLAGUE_AIR_SHADOW_DEBUG
    fragColor = scene;
    return;
#else
    int debugView = int(u_Param3 + 0.5);
    if (debugView != 0 && debugView != DBG_UW_CLOSURE) {
        fragColor = scene;
        return;
    }
    float depth = texture(G_DEPTH, texCoord).r;
    if (depth <= 0.0) {
        fragColor = scene;
        return;
    }
    vec4 worldH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec3 worldPos = worldH.xyz / worldH.w;
    float skyLight = texture(u_ConsolidatedGbuf, vec3(texCoord, 0.0)).a;
    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);
    float trueSunHeight = u_SunDirection.w;
    vec3 sunDirTrue = plagueAtmoComputeSunDirection();
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

    vec3 atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
            vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
            vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
            vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif
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

    vec3 lit = scene.rgb;
#if PLAGUE_FOG
    // Ungated on u_WaterState: plagueFogTerms itself carries the eye-in-water arm (fog.glsl).
    {
        // u_RenderFog.y is the headless fallback, not the primary: it tracks fog attribute
        // distances rather than the chunk grid, so the veil can sit below 1.0 where geometry ends.
        float renderDistance = u_Param2 > 1.0 ? u_Param2 : max(u_RenderFog.y, 32.0);
        // Integrate and compose at this fragment's current depth. No intermediate endpoint
        // image or cumulative-volume interpolation can import light from another surface.
        float fogDist = length(worldPos);
        float fogFar = plagueAtmoAerialFar();
        vec3 fogTransmittance;
        PlagueAtmoAir air = plagueAtmoComputeAir(sunDirTrue, rainFactor,
                                                clamp(u_FrameState.z, 0.0, 1.0));
        vec4 fogAerial = plagueAtmoComputeTransport(worldPos / max(fogDist, 1e-4), sunDirTrue,
                plagueAtmoCameraRadius(), air, fogDist, fogTransmittance);
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
        PlagueFogTerms fogTerms = plagueFogTermsAerialPath(worldPos, worldPos, skyLight, u_CameraSkyLight.x,
                                                 renderDistance, fogAerial, fogNearT, fogSky,
                                                 fogTransmittance, fogDrive,
                                                 u_FogBorderDensity, u_DepthDarkness,
                                                 plagueChunksToBlocks(u_UnderwaterFogStart),
                                                 plagueChunksToBlocks(u_WaterDistanceFog),
                                                 plagueChunksToBlocks(u_WaterDepthFog),
                                                 vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB),
                                                 vec3(u_WaterDistanceDarkness, u_WaterDepthDarkness,
                                                      plagueChunksToBlocks(u_WaterDarknessDepth)), lighting, atmColorMult);
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

    fragColor = vec4(lit, scene.a);
#endif
}
