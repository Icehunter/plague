#ifndef PLAGUE_ATMO_SHADOW
#define PLAGUE_ATMO_SHADOW

#ifndef PLAGUE_ATMO_SHADOW_UNKNOWN
// Where the map has no answer the caller may supply a longer-range source; the default keeps
// the analytic unshadowed atmosphere.
#define PLAGUE_ATMO_SHADOW_UNKNOWN(posBlocks, lightDir) vec2(1.0, 0.0)
#endif

/**
 * Whether plagueAtmoShadowAt has an answer for this point.
 *
 * False means that function takes one of its early exits and hands back the same no-shadow (1,0)
 * everywhere in that region. It sits right above this one and uses the same bias and the same
 * three tests: the pair is only any use while they agree, so a change to one is a change to both.
 */
bool plagueAtmoShadowBoxCovers(vec3 posBlocks, vec3 lightDir) {
    vec4 clip = u_SunViewProj
            * vec4(posBlocks + lightDir * PLAGUE_ATMO_SHADOW_BIAS_BLOCKS, 1.0);
    if (!(abs(clip.w) > 0.0)) return false;
    vec3 ndc = clip.xyz / clip.w;
    return all(lessThan(abs(ndc.xy), vec2(1.0))) && ndc.z > 0.0 && ndc.z < 1.0;
}

// x is visibility; y certifies captured light-volume coverage. Unknown hands the point to
// PLAGUE_ATMO_SHADOW_UNKNOWN; it is not a measured clear ray and needs wider caster coverage.
vec2 plagueAtmoShadowAt(vec3 posBlocks, vec3 lightDir) {
    vec4 clip = u_SunViewProj
            * vec4(posBlocks + lightDir * PLAGUE_ATMO_SHADOW_BIAS_BLOCKS, 1.0);
    if (!(abs(clip.w) > 0.0)) return PLAGUE_ATMO_SHADOW_UNKNOWN(posBlocks, lightDir);
    vec3 ndc = clip.xyz / clip.w;

    // Caster capture uses the unwarped orthographic box. Radial distortion can put exterior
    // points inside the texture; that does not make their missing casters a valid lit miss.
    if (!(all(lessThan(abs(ndc.xy), vec2(1.0))) && ndc.z > 0.0 && ndc.z < 1.0))
        return PLAGUE_ATMO_SHADOW_UNKNOWN(posBlocks, lightDir);
    float distortion = length(ndc.xy) * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    if (!(distortion > 0.0)) return PLAGUE_ATMO_SHADOW_UNKNOWN(posBlocks, lightDir);
    vec2 uv = ndc.xy / distortion * 0.5 + 0.5;
    if (!(all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))))
        return PLAGUE_ATMO_SHADOW_UNKNOWN(posBlocks, lightDir);

    // A receiver can be far along a captured light ray. Camera distance cannot invalidate its
    // blocker; the shared lookup still owns certified RT replacement and raster/entity fallback.
    //
    // Fade to open sky over the last quarter of the box instead of cutting off at its wall. A
    // hard cut jumps from full shade to full light with nothing between, and with a low sun that
    // jump lands beside a hill, where it looks like the hill is failing to shade the air next to
    // it. ndc.xy is 0 at the camera and 1 at the wall, so the fade follows the box that was
    // really captured, long side toward the sun and all. Past the wall the fade lands on
    // PLAGUE_ATMO_SHADOW_UNKNOWN's answer rather than a bare 1.0, so a longer-range source keeps
    // authority right up to the box edge.
    float edge = max(abs(ndc.x), abs(ndc.y));
    float open = smoothstep(0.75, 1.0, edge);
    float measured = plagueShadowLookupPoint(posBlocks, uv, ndc.z);
    // Skip the macro entirely where the fade weight is zero: most in-box samples never reach the
    // last quarter of the wall, and the caller's answer can be a texture fetch of its own.
    return vec2(open > 0.0 ? mix(measured, PLAGUE_ATMO_SHADOW_UNKNOWN(posBlocks, lightDir).x, open)
                          : measured, 1.0);
}

#endif
