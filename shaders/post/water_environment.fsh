#version 330

// Compact directional sky radiance for water reflections. The two axes are dot products against
// the true sun and world up, which are the complete directional inputs used by Plague's sky dome.
// This is environment radiance only: no scene colour, geometry depth, water mask, or history enters.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:sky.glsl>
#define PLAGUE_ATMO_READS_SKYVIEW
#moj_import <fornax_runtime:atmo_lut.glsl>

uniform sampler2D u_AtmoSkyView; // atmoSkyView, the marched dome (atmo_lut.glsl)

vec4 plagueAtmoFetchSkyView(vec2 uv) {
    return texture(u_AtmoSkyView, uv);
}

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
    vec3 radiance = plagueAtmoSkyView(direction, trueSunDirection, plagueAtmoCameraRadius()).rgb;
    // The warmth and storm darkening the dome gets, applied before the mip chain blurs this
    // probe; without it rough water reflects a raw sky while the scene's sunset and weather
    // controls are on.
    radiance = plagueWarmSkyBand(radiance, direction.y, VdotS, trueSunDirection.y);
    radiance = plagueStormDarkenSky(radiance, direction.y, VdotS, trueSunDirection.y,
                                  rainFactor, clamp(u_FrameState.z, 0.0, 1.0));
    radiance *= atmColorMult;

    // Sky only, no cloud. This probe holds the sky by two numbers: how far a direction sits from
    // the sun, and how high it sits. Every direction sharing those two reads the same pixel, so a
    // cloud stored here comes back as a ring of copies around the sun, in a shape the real march
    // never drew, drawn over the reflected cloud the trace already found.

    fragColor = vec4(max(radiance, vec3(0.0)), 1.0);
}
