#ifndef PLAGUE_ATMO_SHADOW
#define PLAGUE_ATMO_SHADOW

// x is visibility; y certifies captured light-volume coverage. Unknown retains the analytic
// unshadowed atmosphere (1,0); it is not a measured clear ray and needs wider caster coverage.
vec2 plagueAtmoShadowAt(vec3 posBlocks, vec3 lightDir) {
    vec4 clip = u_SunViewProj
            * vec4(posBlocks + lightDir * PLAGUE_ATMO_SHADOW_BIAS_BLOCKS, 1.0);
    if (!(abs(clip.w) > 0.0)) return vec2(1.0, 0.0);
    vec3 ndc = clip.xyz / clip.w;

    // Caster capture uses the unwarped orthographic box. Radial distortion can put exterior
    // points inside the texture; that does not make their missing casters a valid lit miss.
    if (!(all(lessThan(abs(ndc.xy), vec2(1.0))) && ndc.z > 0.0 && ndc.z < 1.0))
        return vec2(1.0, 0.0);
    float distortion = length(ndc.xy) * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    if (!(distortion > 0.0)) return vec2(1.0, 0.0);
    vec2 uv = ndc.xy / distortion * 0.5 + 0.5;
    if (!(all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))))
        return vec2(1.0, 0.0);

    // A receiver can be far along a captured light ray. Camera distance cannot invalidate its
    // blocker; the shared lookup still owns certified RT replacement and raster/entity fallback.
    //
    // Fade to open sky over the last quarter of the box instead of cutting off at its wall. A
    // hard cut jumps from full shade to full light with nothing between, and with a low sun that
    // jump lands beside a hill, where it looks like the hill is failing to shade the air next to
    // it. ndc.xy is 0 at the camera and 1 at the wall, so the fade follows the box that was
    // really captured, long side toward the sun and all.
    float edge = max(abs(ndc.x), abs(ndc.y));
    float open = smoothstep(0.75, 1.0, edge);
    return vec2(mix(plagueShadowLookup(posBlocks, uv, ndc.z), 1.0, open), 1.0);
}

#endif
