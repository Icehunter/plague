#ifndef PLAGUE_ATMO_TRANSPORT
#define PLAGUE_ATMO_TRANSPORT

// Shared medium and ray integration for the aerial compute writer and opaque fragment consumer.
// Each stage supplies LUT and shadow callbacks; all six transport channels remain unchanged.
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:fog_options.glsl>
#moj_import <fornax_runtime:sky.glsl>
#moj_import <fornax_runtime:fog_model.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:atmo_debug_options.glsl>
#define PLAGUE_ATMO_READS_TRANSMITTANCE
#define PLAGUE_ATMO_READS_MULTISCATTER
#define PLAGUE_ATMO_READS_SKYVIEW
#define PLAGUE_ATMO_LOCAL_MIST
#define PLAGUE_ATMO_LOCAL_STEPS
#ifdef SHADOWS
#define PLAGUE_ATMO_SHADOWED
#endif
#moj_import <fornax_runtime:atmo_lut.glsl>
#moj_import <fornax_runtime:atmo_mist.glsl>
#moj_import <fornax_runtime:end_sky.glsl>

vec3 plagueAtmoComputeSunDirection() {
    // Same invalid-celestial fallback as the sky tables: a finite overhead direction.
    return dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
}

PlagueAtmoAir plagueAtmoComputeAir(vec3 sunDir, float rain, float thunder) {
    // The aerial medium: fog-drive mist sets its optical depth and e-folding height.
    PlagueLighting lighting = plagueOverworldLighting(max(u_SkyColor.rgb, vec3(0.0)), sunDir.y,
                                                      u_SkyState.y, rain, u_ScreenBrightness);
    PlagueFogDrive drive = PLAGUE_FOG_DRIVE(lighting);
    return plagueAtmoAirWithMist(plagueAtmoAir(rain, thunder), 1.6 * drive.mist,
                                 u_FogDensity, drive.H * (1.0 + drive.rainDepth * drive.rain));
}

vec4 plagueAtmoComputeTransport(vec3 dir, vec3 sunDir, float r, PlagueAtmoAir air, float distanceBlocks,
                               out vec3 transmittance) {
    // The End's self-emitting medium has a closed-form integral, shared by both endpoint writers.
    if (u_WorldBounds.w == 3.0) {
        float through = plagueEndTransmittance(distanceBlocks);
        transmittance = vec3(through);
        vec3 gained = plagueEndSky(dir, plagueEndSkyLevel()) * (1.0 - through);
        return vec4(gained, through);
    }
    float end = distanceBlocks * PLAGUE_ATMO_METRES_PER_BLOCK;
    return plagueAtmoMarchTo(vec3(0.0, r, 0.0), dir, sunDir, plagueAtmoSunRadiance(sunDir),
                             plagueAtmoMoonRadiance(), air, end, PLAGUE_ATMO_AERIAL_STEPS, transmittance);
}

// Atlas consumers retain their scalar transmission ABI. Opaque pixels preserve all three
// channels: a local neutral aerosol cannot be reconstructed with the distant sky's chroma.
vec4 plagueAtmoComputeTransport(vec3 dir, vec3 sunDir, float r, PlagueAtmoAir air, float distanceBlocks) {
    vec3 transmittance;
    return plagueAtmoComputeTransport(dir, sunDir, r, air, distanceBlocks, transmittance);
}

#endif
