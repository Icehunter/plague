#ifndef PLAGUE_WATER_UNDERWATER_DISCS
#define PLAGUE_WATER_UNDERWATER_DISCS

#moj_import <fornax_runtime:celestials.glsl>

// Sun/moon disc through the Snell window: the same shapes celestials.glsl's
// plagueCelestialDiscs draws
// the primary sky's discs from, but with a soft SQUARE edge (the sprite art is square) instead of
// a hard UV-bounds cutoff. Kept local rather than changing that shared function, since a hard gate
// has never been a problem for the primary sky ray's smoothly-changing derivatives.
//
// Shades each tap then averages the shaded results, not the reverse: prefiltering the atlas before
// a sharp shading response is destructive out of proportion to the blur amount (a 15% change in
// input once moved the output by 7x against the mask this used at the time).
//
// Radiance is passed in per body (from the atmosphere) rather than a fixed tint: a zero-blue tint
// let water's faster red falloff invert the disc colour past ~5.78 blocks depth
// (ln(1.1/0.55)/(0.20-0.08)).

vec3 plagueUnderwaterSunDiscSample(vec2 centreUv, float softness,
                                   float rainFactor, vec3 sunRadiance) {
    const int TAP_COUNT = 5;
    const vec2 TAP_OFFSETS[5] = vec2[](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0)
    );
    float tapRadius = softness * 0.35;
    vec3 shadedSum = vec3(0.0);
    for (int i = 0; i < TAP_COUNT; i++) {
        // tapUv, not centreUv: the limb-darkening term is a function of where on the disc the
        // sample is, so a tap has to be shaded at its own position or the blur flattens the limb.
        vec2 tapUv = centreUv + TAP_OFFSETS[i] * tapRadius;
        shadedSum += plagueShadeSunDisc(tapUv, sunRadiance, rainFactor);
    }
    return shadedSum / float(TAP_COUNT);
}

vec3 plagueUnderwaterCelestialDiscs(vec3 viewRay, vec3 sunDirTrue, float moonPhaseIndex,
                                    float softness, float invRainFactor, float moonGlow) {
    // Edge fade width tracks softness (one knob for both), floored above zero so the on/off edge
    // always fades across a few samples even at softness 0.
    float edgeMargin = mix(0.03, 0.30, clamp(softness, 0.0, 1.0));

    vec3 result = vec3(0.0);

    if (plagueFacingCelestial(viewRay, sunDirTrue)) {
        vec2 uv = plagueCelestialUv(viewRay, sunDirTrue, max(u_SunDiscSize, 0.001));
        vec2 boxDist2 = abs(uv - 0.5) * 2.0;
        float boxDist = max(boxDist2.x, boxDist2.y);
        float coverage = 1.0 - smoothstep(1.0 - edgeMargin, 1.0 + edgeMargin, boxDist);
        if (coverage > 0.0) {
            // The atmosphere's own radiance for the sun, computed once per disc rather than once
            // per tap, and the same value the above-water disc and the world's lighting use.
            vec3 sunRadiance = plagueSunColor(plagueAirEyePos(u_CameraAbs.y), sunDirTrue);
            vec3 shaded = plagueUnderwaterSunDiscSample(uv, softness,
                    1.0 - invRainFactor, sunRadiance);
            result += shaded * (u_SunDiscBrightness * invRainFactor * coverage);
        }
    }

    // Softness widens the moon's edge rather than blurring it: a sphere is shaded once, where the
    // sun's disc still averages taps across its own face.
    vec3 moonDir = -sunDirTrue;
    if (plagueFacingCelestial(viewRay, moonDir)) {
        vec3 normal;
        float rim;
        if (plagueMoonSurface(viewRay, moonDir, max(u_MoonDiscSize, 0.001) * (1.0 + softness),
                              normal, rim)) {
            vec3 moonRadiance = plagueMoonColor(plagueAirEyePos(u_CameraAbs.y), moonDir);
            vec3 lightDir = plagueMoonLightDir(moonDir, moonPhaseIndex);
            result += plagueShadeMoonSphere(normal, rim, lightDir, moonRadiance,
                                            1.0 - invRainFactor)
                    * (u_MoonDiscBrightness * moonGlow * invRainFactor);
        }
    }

    return result;
}

#endif
