#ifndef PLAGUE_VOXEL_REFLECTION_FOG
#define PLAGUE_VOXEL_REFLECTION_FOG


// Import before anything else that uses atmo_lut: its include guard would otherwise drop the
// march functions with no error.
// The program binds transmittance/multiscatter/skyview at inputs 14/15/16 and shadow at input 8.
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:water_options.glsl>
#define PLAGUE_ATMO_READS_TRANSMITTANCE
#define PLAGUE_ATMO_READS_MULTISCATTER
#define PLAGUE_ATMO_READS_SKYVIEW
#ifdef SHADOWS
#define PLAGUE_ATMO_SHADOWED
#endif
#moj_import <fornax_runtime:atmo_lut.glsl>
#moj_import <fornax_runtime:fog_aerial.glsl>
#moj_import <fornax_runtime:end_sky.glsl>

vec4 plagueAtmoFetchTransmittance(vec2 uv) { return texture(u_Input14, uv); }
vec4 plagueAtmoFetchMultiScatter(vec2 uv) { return texture(u_Input15, uv); }
vec4 plagueAtmoFetchSkyView(vec2 uv) { return texture(u_Input16, uv); }

#ifdef SHADOWS
// Per-pixel state. The march callback gets sample points measured along the segment.
vec3 plagueVoxelFogOrigin;
float plagueAtmoSunShadow(vec3 posBlocks, vec3 sunDir) {
    posBlocks += plagueVoxelFogOrigin;
    float dist = length(posBlocks);
    float reach = max(u_ShadowDistance, 1.0);
    if (dist >= reach) return 1.0;
    vec4 lightClip = u_SunViewProj * vec4(posBlocks + sunDir * PLAGUE_ATMO_SHADOW_BIAS_BLOCKS, 1.0);
    vec3 ndc = lightClip.xyz / lightClip.w;
    float distortion = length(ndc.xy) * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    vec2 uv = (ndc.xy / distortion) * 0.5 + 0.5;
    if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0 || ndc.z <= 0.0 || ndc.z >= 1.0)
        return 1.0;
    // Same shadow-map boundary fade as atmo_aerial.comp; no reflection-specific tuning.
    return mix(texture(u_Input8, vec3(uv, ndc.z)), 1.0, smoothstep(reach * 0.75, reach, dist));
}
#endif

// Only how much light is lost. Same steps as plagueAtmoMarchTo, minus a round of table reads.
float plagueVoxelFogNearTransmittance(vec3 origin, vec3 dir, PlagueAtmoAir air, float end,
        float skyLight, PlagueFogDrive drive) {
    // Same gate as fog_aerial. Test the access, not the guard's edge; the two are edited apart.
    float access = smoothstep(mix(0.05, u_FogCaveGuardLo, drive.advanced),
                              mix(0.35, u_FogCaveGuardHi, drive.advanced),
                              clamp(skyLight, 0.0, 1.0));
    if (end <= 0.0 || access == 1.0) return 1.0;
    vec3 transmittance = vec3(1.0);
    float previous = 0.0;
    for (int i = 0; i < PLAGUE_ATMO_AERIAL_STEPS; ++i) {
        float fraction = float(i + 1) / float(PLAGUE_ATMO_AERIAL_STEPS);
        float next = end * fraction * fraction;
        float midpoint = 0.5 * (previous + next);
        float altitude = length(origin + dir * midpoint) - PLAGUE_PLANET_RADIUS;
        vec3 extinction = plagueAtmoExtinction(plagueAtmoDensity(altitude, air))
                + vec3(plagueAtmoMist(altitude, air));
        transmittance *= exp(-extinction * (next - previous));
        previous = next;
    }
    return dot(transmittance, vec3(0.2126, 0.7152, 0.0722));
}

// Water to hit only; the water composite owns eye to water. Border fog follows the camera's
// chunk cylinder, whatever the ray's length.
vec3 plagueVoxelReflectionFog(vec3 radiance, vec3 origin, vec3 hit, float skyLight,
        PlagueLighting lighting, vec3 atmColorMult, vec3 sunDirTrue, float renderDistance) {
#if PLAGUE_FOG
    vec3 segment = hit - origin;
    float distanceBlocks = length(segment);
    if (distanceBlocks < 1e-4) return radiance;
    vec3 dir = segment / distanceBlocks;
    float rain = clamp(u_SkyState.x, 0.0, 1.0);
    float thunder = clamp(u_FrameState.z, 0.0, 1.0);
    PlagueFogDrive drive = PLAGUE_FOG_DRIVE(lighting);
    // Same mist drive as the table producer; 1.6 is its conversion to mist scale.
    PlagueAtmoAir air = plagueAtmoAirWithMist(plagueAtmoAir(rain, thunder), 1.6 * drive.mist,
            u_FogDensity, drive.H * (1.0 + drive.rainDepth * drive.rain));
    float radius = PLAGUE_PLANET_RADIUS
            + plagueAtmoAltitude(u_CameraAbs.y + origin.y, plagueAtmoSeaLevel());
    vec3 airOrigin = vec3(0.0, radius, 0.0);
#ifdef SHADOWS
    plagueVoxelFogOrigin = origin;
#endif
    vec3 transmittance;
    vec4 aerial = plagueAtmoMarchTo(airOrigin, dir, sunDirTrue,
            plagueAtmoSunRadiance(sunDirTrue), plagueAtmoMoonRadiance(), air,
            distanceBlocks * PLAGUE_ATMO_METRES_PER_BLOCK, PLAGUE_ATMO_AERIAL_STEPS, transmittance);
    float nearDistance = max(distanceBlocks - PLAGUE_FOG_SKY_LIGHT_REACH, 0.0);
    float nearT = plagueVoxelFogNearTransmittance(airOrigin, dir, air,
            nearDistance * PLAGUE_ATMO_METRES_PER_BLOCK, skyLight, drive);
    vec3 sky;
    if (u_WorldBounds.w == 3.0) {
        // The End glows instead of scattering, on its own distance model.
        float through = plagueEndTransmittance(distanceBlocks);
        sky = plagueEndSky(dir, plagueEndSkyLevel());
        transmittance = vec3(through);
        aerial = vec4(sky * (1.0 - through), through);
        nearT = plagueEndTransmittance(nearDistance);
    } else if (u_WorldBounds.w == 2.0) {
        sky = u_FogColor.rgb;
    } else {
        sky = plagueAtmoSkyView(dir, sunDirTrue, plagueAtmoCameraRadius()).rgb;
        sky = plagueWarmSkyBand(sky, dir.y, dot(dir, sunDirTrue), sunDirTrue.y);
        sky = plagueStormDarkenSky(sky, dir.y, dot(dir, sunDirTrue), sunDirTrue.y, rain, thunder);
        aerial.rgb = plagueStormDarkenSky(aerial.rgb, dir.y, dot(dir, sunDirTrue),
                sunDirTrue.y, rain, thunder);
    }
    PlagueFogTerms terms = plagueFogTermsAerialPath(segment, hit, skyLight, u_CameraSkyLight.x,
            renderDistance, aerial, nearT, sky, transmittance, drive,
            u_FogBorderDensity, u_DepthDarkness,
            plagueChunksToBlocks(u_UnderwaterFogStart), plagueChunksToBlocks(u_WaterDistanceFog),
            plagueChunksToBlocks(u_WaterDepthFog), vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB),
            vec3(u_WaterDistanceDarkness, u_WaterDepthDarkness,
                 plagueChunksToBlocks(u_WaterDarknessDepth)), lighting, atmColorMult);
    radiance = mix(radiance, terms.atmColor, clamp(terms.atm, 0.0, 1.0));
    radiance = mix(radiance, terms.borderColor, plagueBorderColorWeight(terms.border));
#endif
    return radiance;
}

#endif
