#ifndef PLAGUE_ENV_BRDF
#define PLAGUE_ENV_BRDF

/**
 * Lazarov's analytic split-sum BRDF fit (SIGGRAPH 2013, "Getting More Physical in Call of Duty:
 * Black Ops II"). Returns (scale, bias) for `F0 * scale + bias`; takes PERCEPTUAL roughness, not
 * alpha — the fit is stated against that parameterisation.
 */
vec2 plagueEnvBrdfApprox(float nDotV, float perceptualRoughness) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = perceptualRoughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * nDotV)) * r.x + r.y;
    vec2 scaleBias = vec2(-1.04, 1.04) * a004 + r.zw;

    // Self-occlusion mask on the bias term (`.y`) only — `.x` (F0-multiplied scale) is untouched.
    // Evaluated MIRROR-CONFIGURED (nDotL = nDotV) via plagueVisibilitySmithGGX's own alpha->0
    // limit, so it needs no new tunable and is exactly 1.0 for a smooth surface. See
    // tools/verify_env_bias_mask.py for the numeric derivation and why `.y` specifically. Do not
    // describe this as fixing grazing sheen — it corrects the bias term's own occlusion, unrelated.
    float alpha = perceptualRoughness * perceptualRoughness;
    float occlusion = nDotV / sqrt(nDotV * nDotV * (1.0 - alpha * alpha) + alpha * alpha);
    return vec2(scaleBias.x, scaleBias.y * occlusion);
}

/**
 * The split-sum fit above plus the energy its single-scatter form loses to multiple bounces
 * (Fdez-Aguera, "A Multiple-Scattering Microfacet Model for Real-Time Image Based Lighting",
 * JCGT 2019), tinted each bounce by Favg = F0 + (1-F0)/21. Keeps a rough conductor its own colour
 * instead of flattening toward the fit's achromatic bias as roughness rises.
 */
vec3 plagueEnvSpecularAlbedo(vec3 f0, float nDotV, float perceptualRoughness) {
    vec2 fit = plagueEnvBrdfApprox(nDotV, perceptualRoughness);
    vec3 fssEss = f0 * fit.x + fit.y;
    float essTotal = fit.x + fit.y;
    float ems = 1.0 - essTotal;
    vec3 fAvg = f0 + (vec3(1.0) - f0) / 21.0;
    vec3 fms = fssEss * fAvg / (vec3(1.0) - ems * fAvg);
    return clamp(fssEss + fms * ems, vec3(0.0), vec3(1.0));
}

/**
 * How much of the ENVIRONMENT lobe an occlusion scalar is entitled to cut. Raw diffuse-hemisphere
 * AO over-darkens a near-mirror lobe, worst on conductors where the environment term is the
 * entire appearance. Lagarde/Frostbite fit: tends to `ao` as roughness rises, to 1.0 as it falls.
 *
 * max(ao, fit) is a deliberate safety clamp, not physics: the fit's low-AO grazing corner can dip
 * below `ao`, and this makes the change provably one-directional (brighten or bit-identical),
 * never a source of new darkening.
 */
float plagueSpecularOcclusion(float ao, float nDotV, float perceptualRoughness) {
    float fit = clamp(pow(nDotV + ao, exp2(-16.0 * perceptualRoughness - 1.0)) - 1.0 + ao,
                      0.0, 1.0);
    return max(ao, fit);
}
// An F0-referenced clamp was evaluated here and held in reserve, not added — this fit needed none.

// Widest mip a fully rough surface may sample. 5.0 is a 32-texel footprint per axis, where a
// screen-space chain stops approximating a hemisphere and starts averaging unrelated geometry —
// deliberately below the engine's full chain (MipchainRunner builds down to 1x1 regardless).
const float PLAGUE_REFL_MAX_LOD = 5.0;

/**
 * Perceptual roughness to prefiltered-reflection mip level: linear in perceptual roughness (not
 * alpha), the same shape as plagueWaterEnvironmentLod (water_reflection.glsl). LOD 0 is exact at
 * roughness 0 since the chain's seed mip is a texel-exact copy of `ssr`.
 */
float plagueReflectionLod(float perceptualRoughness) {
    return clamp(perceptualRoughness, 0.0, 1.0) * PLAGUE_REFL_MAX_LOD;
}

#endif // PLAGUE_ENV_BRDF
