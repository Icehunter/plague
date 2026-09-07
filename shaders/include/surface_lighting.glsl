#ifndef PLAGUE_SURFACE_LIGHTING
#define PLAGUE_SURFACE_LIGHTING

// Fullscreen-only: uses runtime pack options. Geometry callers have no u_PackOptions block.
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:atmosphere.glsl>
#moj_import <fornax_runtime:sky.glsl>
#moj_import <fornax_runtime:main_lighting.glsl>
#moj_import <fornax_runtime:end_sky.glsl>

// Fill light needs one direction, so read the sky function, not a lookup table.
#define SKY_AMBIENT //[] compile "Ambient From Sky"
// Pull toward sun-lit ground, for fill light and guessed-sky reflections. Same brightness either
// way; zero at night.
#define u_AmbientBounceWarmth 0.35 //[0.0..1.0 step 0.05] runtime "Ground Bounce Warmth"
const vec3 PLAGUE_GROUND_BOUNCE_TINT = vec3(1.30, 1.00, 0.62);

// Physical model only. Higher is cooler torchlight.
#define u_BlockLightTemp 2200.0 //[1500.0..8000.0 step 100.0] runtime "Block Light Temperature"

struct PlagueSurfaceLighting {
    vec3 sunColour;
    vec3 ambientColour;
    vec3 blockLightColour;
    float skyReflectionLift;
};

// Frame light colours for drawn terrain and for reflected hits. Warm key against cool fill is the
// whole effect; one averaged colour cannot make it. Both paths start the air model at the camera.
PlagueSurfaceLighting plagueSurfaceLighting(PlagueLighting lighting, PlagueSkyColors skyColours,
        vec3 sunDir, vec3 sunDirTrue, float rainFactor, vec3 atmColorMult,
        float trueSunHeight, float cameraAltitude, vec3 underwaterSunTint) {
#if CUSTOM_LIGHT_COLORS
    vec3 sunColour = lighting.light;
#else
    // u_SunDirection is the sun by day, the moon after it sets. Colour and shadows follow the
    // same body.
    vec3 airEyePos = plagueAirEyePos(cameraAltitude);
    vec3 sunColour = trueSunHeight > 0.0
            ? plagueSunColor(airEyePos, sunDir)
            : plagueMoonColor(airEyePos, sunDir);
    // 0.95 leaves a twentieth of the sun in full rain: overcast is not black.
    sunColour *= 1.0 - rainFactor * 0.95;
#endif
    // Same water tint as the direct path. In air this is 1.
    sunColour *= underwaterSunTint;
    // Same warmth control as the bounce, so the two cannot disagree.
    sunColour = plagueWarmLowSun(sunColour, sunDirTrue.y);

    // The End's clock never moves. A sun there lights everything from one fixed angle for ever.
    if (u_WorldBounds.w == 3.0) {
        sunColour = vec3(0.0);
    }

#ifdef SKY_AMBIENT
    // The whole dome, not just straight up: at sunset the dome is a warm band low on the sun's
    // side while straight up is deep blue. Dither is zero; noise belongs on a fade you look at.
    vec3 zenithSky = mix(plagueGetSky(skyColours, 1.0, dot(vec3(0.0, 1.0, 0.0), sunDirTrue), 0.5,
                                      false, false),
                         plagueSkyHemisphere(skyColours, sunDirTrue.y),
                         u_AmbientSkyBleed) * atmColorMult;
    // Measured at noon over plains: straight up reads (0.284, 0.493, 0.810), brightness 0.471,
    // against the table's 0.607. Ratio 1.29, standing in for adding up the whole dome.
    // Day only: at night the sky model runs ~2.4x dim, so the night arm scales to
    // lighting.ambient, which also gives the brightness slider its effect at night.
    // Named because the lift below divides by it; two copies would drift apart.
    const float PLAGUE_SKY_AMBIENT_DAY_SCALE = 1.29;
    float zenithLuma = dot(zenithSky, vec3(0.2126, 0.7152, 0.0722));
    float tableLuma = dot(lighting.ambient, vec3(0.2126, 0.7152, 0.0722));
    float ambientScale = mix(tableLuma / max(zenithLuma, 1e-5),
                             PLAGUE_SKY_AMBIENT_DAY_SCALE, lighting.sunFactor);
    vec3 ambientColour = zenithSky * ambientScale;
    // Everything above needs a sun. The End's only light is the air.
    if (u_WorldBounds.w == 3.0) {
        ambientColour = plagueEndAmbient();
    }
    // The scale above reaches the diffuse half only; reflections read plagueGetSky raw. A metal's
    // kD is zero, so it gets the raw answer alone: that is why metals go black at night.
    float skyReflectionLift = ambientScale / PLAGUE_SKY_AMBIENT_DAY_SCALE;
    ambientColour = plagueWarmLowSun(ambientColour, sunDirTrue.y);
    // Half of a shadow's fill is sunlight already bounced off nearby ground, which is why open
    // shadows read warm, not blue. Both ends of the mix are equally bright.
    float ambientLumaHere = dot(ambientColour, vec3(0.2126, 0.7152, 0.0722));
    vec3 groundBounce = PLAGUE_GROUND_BOUNCE_TINT
                      * (ambientLumaHere / dot(PLAGUE_GROUND_BOUNCE_TINT,
                                               vec3(0.2126, 0.7152, 0.0722)));
    ambientColour = mix(ambientColour, groundBounce,
                        u_AmbientBounceWarmth * lighting.sunFactor);
#else
    // The Custom palette's own table. See plagueOverworldLighting's header for why .ambient stays
    // right whichever model CUSTOM_LIGHT_COLORS picks.
    vec3 ambientColour = lighting.ambient;
    // No lift: this path never reads the sky model, so both halves already agree.
    float skyReflectionLift = 1.0;
#endif

    // Custom writes a warm constant; Physical uses the colour of something glowing at
    // u_BlockLightTemp. Both rescaled to the Custom palette's brightness, so only the hue moves.
#if CUSTOM_LIGHT_COLORS
    vec3 blockLightColour = PLAGUE_BLOCKLIGHT_COL;
#else
    vec3 blockBody = plagueBlackbody(u_BlockLightTemp);
    vec3 blockLightColour = blockBody
            * (dot(PLAGUE_BLOCKLIGHT_COL, vec3(0.2126, 0.7152, 0.0722))
             / max(dot(blockBody, vec3(0.2126, 0.7152, 0.0722)), 1e-6));
#endif

    return PlagueSurfaceLighting(sunColour, ambientColour, blockLightColour, skyReflectionLift);
}

#endif
