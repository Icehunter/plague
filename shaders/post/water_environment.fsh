#version 330

// Compact directional sky radiance for water reflections. The two axes are dot products against
// the true sun and world up, which are the complete directional inputs used by Plague's sky dome.
// This is environment radiance only: no scene colour, geometry depth, water mask, or history enters.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:sky.glsl>

uniform sampler2D u_Input0; // builtin.noise: the cloud field's erosion lattice

// The noise hook, per the contract at the top of clouds.glsl: defined over this pass's own input
// slot, after the sampler's declaration and before the import.
#define PLAGUE_CLOUD_NOISE(uv) texture(u_Input0, uv)
// This pass's cloud imposter (plagueCloudDensityCoarse, below) cannot bind a real sampler3D:
// Vulkan's fullscreen-pipeline shader-reflection step refuses any non-2D/Cube sampler outright, so
// only the compute-based direct-view march samples the real 3D volumes. This uses the same ALU
// approximation as the region field (plagueSkyFbm), folding height into the 2D coordinate for some
// vertical variance. A lower-fidelity stand-in for a reflection probe, never a bare constant; see
// clouds.glsl's own noise-hook contract doc for why.
#define PLAGUE_CLOUD_NOISE_3D(uvw) vec4(plagueSkyFbm((uvw).xz + (uvw).y, 4))
#define PLAGUE_CLOUD_DETAIL_3D(uvw) vec4(plagueSkyFbm((uvw).xz * 3.0 + (uvw).y, 2))
#moj_import <fornax_runtime:clouds.glsl>

#moj_import <fornax_runtime:light_options.glsl>
in vec2 texCoord;
out vec4 fragColor;

vec3 plagueEnvironmentDirection(float sunDot, float upDot, vec3 sunDirection) {
    const vec3 upDirection = vec3(0.0, 1.0, 0.0);
    float sunUp = clamp(dot(sunDirection, upDirection), -1.0, 1.0);
    vec3 projectedSun = sunDirection - upDirection * sunUp;
    float projectedLength = length(projectedSun);
    vec3 sunTangent = projectedLength > 1e-5
            ? projectedSun / projectedLength
            : vec3(1.0, 0.0, 0.0);
    vec3 sideTangent = normalize(cross(upDirection, sunTangent));

    float tangentDot = projectedLength > 1e-5
            ? (sunDot - upDot * sunUp) / projectedLength
            : 0.0;
    vec2 constrained = vec2(tangentDot, upDot);
    float constrainedLength = length(constrained);
    if (constrainedLength > 1.0) {
        constrained /= constrainedLength;
    }

    float sideDot = sqrt(max(1.0 - dot(constrained, constrained), 0.0));
    return normalize(sunTangent * constrained.x
            + upDirection * constrained.y
            + sideTangent * sideDot);
}

void main() {
    vec2 requestedDots = clamp(texCoord * 2.0 - 1.0, -1.0, 1.0);
    vec3 trueSunDirection = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz)
            : vec3(0.0, 1.0, 0.0);
    vec3 direction = plagueEnvironmentDirection(
            requestedDots.x, requestedDots.y, trueSunDirection);

    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);
    PlagueLighting lighting = plagueOverworldLighting(
            max(u_SkyColor.rgb, vec3(0.0)), u_SkyCelestial.y, u_SkyState.y,
            rainFactor, u_ScreenBrightness);
    PlagueSkyColors skyColours = plagueSkyColors(
            max(u_SkyColor.rgb, vec3(0.0)), trueSunDirection,
            lighting.sunVisibility, rainFactor, u_CameraAbs.y);
    float VdotS = dot(direction, trueSunDirection);

    // Graded so a water reflection agrees with the dome gbuffer_resolve.fsh paints; identity
    // vec3(1.0) when the option is off.
    vec3 atmColorMult = vec3(1.0);
#ifdef ATM_COLOR_MULTS
    atmColorMult = plagueAtmColorMult(lighting.noonFactor, lighting.sunVisibility2,
            lighting.rainFactor,
            vec3(u_AtmMorningR, u_AtmMorningG, u_AtmMorningB) * u_AtmMorningI,
            vec3(u_AtmNoonR, u_AtmNoonG, u_AtmNoonB) * u_AtmNoonI,
            vec3(u_AtmNightR, u_AtmNightG, u_AtmNightB) * u_AtmNightI,
            vec3(u_AtmRainR, u_AtmRainG, u_AtmRainB) * u_AtmRainI);
#endif
    vec3 radiance = plagueGetSky(
            skyColours, direction.y, VdotS, 0.5, false, true) * atmColorMult;

#if CLOUDS_VOLUMETRIC
    // A screen-space trace can never return the reflected sky (no depth to hit), so every
    // reflected-sky pixel resolves from this probe — a probe with no clouds meant reflections
    // showed clear sky under an overcast one. One coarse coverage sample at the mid-slab is enough
    // structure: this is a 128x128 probe the mip chain prefilters and waves ripple apart anyway.
    if (direction.y > 0.02) {
        float syncedTime = u_SkyState.w * 0.05;
        PlagueCloudDeck envDeck = plagueCloudActiveDeck(
                rainFactor,
                clamp(u_FrameState.z, 0.0, 1.0),
                clamp(u_FrameState.w, 0.0, 1.0),
                int(u_CameraSkyLight.y + 0.5) == 2 ? 1.0 : 0.0,
                u_SkyCelestial.y,
                syncedTime);
        float midSlab = envDeck.base + 0.5 * envDeck.depth;
        float dist = (midSlab - u_CameraAbs.y) / direction.y;
        if (dist > 0.0) {
            vec3 cloudPos = u_CameraAbs.xyz + direction * dist;
            vec2 drift = plagueCloudDrift(envDeck, syncedTime);
            float density = plagueCloudDensityCoarse(cloudPos, envDeck, drift);

            // Optical depth through the slanted slab, capped where the slant stops meaning
            // anything; reuses the deck's own tau so a storm deck reads darker and more opaque here
            // with no extra plumbing.
            float slant = clamp(1.0 / max(direction.y, 0.25), 1.0, 4.0);
            float alpha = 1.0 - exp(-envDeck.tau * density * slant * 0.5);

            // Flat two-term radiance (mid-dome ambient plus a modest sunward lift): an imposter for
            // a prefiltered probe, not a lit cloud — the march owns that.
            vec3 cloudCol = plagueSkyAnchorMiddle(skyColours, VdotS) * atmColorMult
                    * (1.15 + 0.35 * max(VdotS, 0.0) * lighting.sunVisibility);

            // Same air the direct-view clouds melt into, built by the same PLAGUE_FOG_DRIVE
            // expansion, so a horizon cloud fades out of the reflection exactly where it fades out
            // of the sky.
            PlagueFogDrive fogDrive = PLAGUE_FOG_DRIVE(lighting);
            float rainH = fogDrive.H * (1.0 + fogDrive.rainDepth * fogDrive.rain);
            float pathDepth = dist * plagueFogPathWeight(u_CameraAbs.y, cloudPos.y, rainH);
            float airOp = clamp(plagueFogAirOpacity(pathDepth, fogDrive,
                                                    max(u_RenderFog.y, 32.0)), 0.0, 1.0);

            radiance = mix(radiance, cloudCol, alpha * (1.0 - airOp));
        }
    }
#endif

    fragColor = vec4(max(radiance, vec3(0.0)), 1.0);
}
