#ifndef PLAGUE_BRDF
#define PLAGUE_BRDF

// Implemented from the papers below, not from any renderer's source.
//   D:  Trowbridge-Reitz / GGX .......... Walter et al. 2007, "Microfacet Models for Refraction"
//   V:  Smith height-correlated ......... Heitz 2014, "Understanding the Masking-Shadowing Function"
//   F:  Schlick ......................... Schlick 1994; exact dielectric from the Fresnel equations
//   F:  conductors ...................... Fresnel equations for complex IOR; n/k are measured data
//   Fd: Hammon diffuse .................. Hammon 2017 (GDC), "PBR Diffuse Lighting for GGX+Smith"

const float PLAGUE_PI = 3.14159265359;

// The sun's angular radius in radians (~0.267 degrees). Floors alpha so no reflection is sharper
// than the sun's own disc — the cheapest correct sphere-light approximation (Karis 2013).
const float PLAGUE_SUN_ANGULAR_RADIUS = 0.00465;

// Cap on the specular term: pi^4, far more headroom than the 3.0 it replaces. Still needed despite
// the height-correlated visibility term cancelling the grazing-angle division — a near-delta GGX
// lobe against a directional light is legitimately this bright and has nowhere else to put the
// energy. Worth revisiting now that bloom exists to spread it; not yet tested.
const float PLAGUE_SPECULAR_MAX = 97.409;

// --- labPBR material decode -------------------------------------------------------------------

// Measured n/k (refractive index, extinction coefficient) for labPBR's eight named metals, in
// F0-byte order 230..237: iron, gold, aluminium, chrome, copper, lead, platinum, silver. From
// refractiveindex.info / standard optical tables, kept in linear sRGB to match this pipeline.
const vec3 PLAGUE_METAL_N[8] = vec3[8](
    vec3(2.9114,  2.9497,  2.5845),   // iron
    vec3(0.18299, 0.42108, 1.3734),   // gold
    vec3(1.3456,  0.96521, 0.61722),  // aluminium
    vec3(3.1071,  3.1812,  2.3230),   // chrome
    vec3(0.27105, 0.67693, 1.3164),   // copper
    vec3(1.9100,  1.8300,  1.4400),   // lead
    vec3(2.3757,  2.0847,  1.8453),   // platinum
    vec3(0.15943, 0.14512, 0.13547)   // silver
);
const vec3 PLAGUE_METAL_K[8] = vec3[8](
    vec3(3.0893, 2.9318, 2.7670),     // iron
    vec3(3.4242, 2.3459, 1.7704),     // gold
    vec3(7.4746, 6.3995, 5.3031),     // aluminium
    vec3(3.3314, 3.3291, 3.1350),     // chrome
    vec3(3.6092, 2.6248, 2.2921),     // copper
    vec3(3.5100, 3.4000, 3.1800),     // lead
    vec3(4.2655, 3.7153, 3.1365),     // platinum
    vec3(3.9291, 3.1900, 2.3808)      // silver
);

struct PlagueMaterial {
    float alpha;        // GGX alpha = perceptualRoughness^2
    float f0;           // dielectric reflectance at normal incidence
    float porosity;     // 0..1, from _s blue bytes 0..64; zero when the byte encodes subsurface
    float subsurface;   // 0..1, from _s blue bytes 65..255; zero when the byte encodes porosity
    bool conductor;     // F0 byte >= 230, for plagueMaterialF0's decode ONLY, never downstream
    float metalness;    // same fact as `conductor`, as 0/1 — the composite multiplies by this
                        // rather than branching on the bool
    bool namedMetal;    // F0 byte in 230..237, so measured n/k apply
    int metalIndex;     // index into the tables above, valid only when namedMetal
};

// Linear remap of x from [lo, hi] to [0, 1], clamped. Not smoothstep: labPBR's byte ranges are
// defined as linear mappings, so easing the ends would misread the format.
float plagueLinStep(float x, float lo, float hi) {
    return clamp((x - lo) / (hi - lo), 0.0, 1.0);
}

/**
 * Decodes labPBR's specular channels.
 *
 * @param smoothness  the map's red channel, PERCEPTUAL smoothness
 * @param f0Raw       the map's green channel, 0..1 as sampled (byte/255 on the way in)
 * @param bRaw        the map's BLUE channel, 0..1 as sampled; porosity AND subsurface share it
 *
 * alpha = (1 - smoothness)^2, floored at PLAGUE_SUN_ANGULAR_RADIUS rather than an arbitrary
 * constant — forbids only lobes narrower than the sun itself. F0 is the raw green byte with no
 * floor: zero is a valid dielectric F0 and also Fornax's missing-sidecar identity.
 */
PlagueMaterial plagueDecodeMaterial(float smoothness, float f0Raw, float bRaw) {
    PlagueMaterial m;

    float perceptualRoughness = 1.0 - smoothness;
    m.alpha = max(perceptualRoughness * perceptualRoughness, PLAGUE_SUN_ANGULAR_RADIUS);
    m.f0 = f0Raw;

    // One byte encodes two quantities, split at 64.5: 0..64 is porosity, 65..255 is subsurface.
    // Reading it as a single 0..1 scalar makes every porous surface read as translucent too.
    float bByte = bRaw * 255.0;
    m.porosity   = bByte <= 64.5 ? plagueLinStep(bByte, 0.0, 64.0) : 0.0;
    m.subsurface = plagueLinStep(bByte, 65.0, 255.0);

    // Rounded, not truncated: float error can land a value a hair under its integer, and
    // truncating would misread a texel authored as 230 as 229.
    int f0Byte = int(f0Raw * 255.0 + 0.5);

    // labPBR reserves 230..255 for metals: 230..237 are named with measured n/k, 238..255 are
    // unnamed and carry their reflectance in the albedo (see plagueFresnelTinted).
    m.conductor = f0Byte >= 230;
    m.metalness = m.conductor ? 1.0 : 0.0;
    m.namedMetal = m.conductor && f0Byte <= 237;
    m.metalIndex = clamp(f0Byte - 230, 0, 7);

    return m;
}

// --- Fresnel ----------------------------------------------------------------------------------

/** Schlick's approximation. Used for the diffuse term's edge factors, where exactness buys nothing. */
float plagueFresnelSchlick(float f0, float cosTheta) {
    float m = clamp(1.0 - cosTheta, 0.0, 1.0);
    float m2 = m * m;
    return f0 + (1.0 - f0) * (m2 * m2 * m); // (1-cos)^5 without pow()
}

// Exact dielectric Fresnel, unpolarised — Schlick drifts at grazing angles, exactly where water
// and glass are most visible. IOR recovered from F0 by inverting F0 = ((n-1)/(n+1))^2.
float plagueFresnelDielectric(float cosTheta, float f0) {
    float sqrtF0 = min(sqrt(f0), 0.99999);
    float n = (1.0 + sqrtF0) / (1.0 - sqrtF0);

    float sinI = sqrt(clamp(1.0 - cosTheta * cosTheta, 0.0, 1.0));
    float sinT = sinI / max(n, 1e-6);
    if (sinT >= 1.0) {
        return 1.0; // total internal reflection
    }
    float cosT = sqrt(clamp(1.0 - sinT * sinT, 0.0, 1.0));

    float rs = (cosTheta - n * cosT) / max(cosTheta + n * cosT, 1e-6);
    float rp = (cosT - n * cosTheta) / max(cosT + n * cosTheta, 1e-6);

    return clamp(0.5 * (rs * rs + rp * rp), 0.0, 1.0);
}

// Conductor Fresnel for complex IOR n-ik, per channel — a metal's reflectance varies with
// wavelength and angle, which no scalar F0 plus albedo tint can reproduce. Standard closed form.
vec3 plagueFresnelConductor(float cosTheta, vec3 n, vec3 k) {
    float cos2 = cosTheta * cosTheta;
    float sin2 = 1.0 - cos2;

    vec3 n2 = n * n;
    vec3 k2 = k * k;

    vec3 t0 = n2 - k2 - vec3(sin2);
    vec3 a2b2 = sqrt(max(t0 * t0 + 4.0 * n2 * k2, 0.0));
    vec3 t1 = a2b2 + vec3(cos2);
    vec3 a = sqrt(max(0.5 * (a2b2 + t0), 0.0));
    vec3 t2 = 2.0 * a * cosTheta;
    vec3 rs = (t1 - t2) / max(t1 + t2, vec3(1e-6));

    vec3 t3 = cos2 * a2b2 + vec3(sin2 * sin2);
    vec3 t4 = t2 * sin2;
    vec3 rp = rs * (t3 - t4) / max(t3 + t4, vec3(1e-6));

    return clamp(0.5 * (rs + rp), 0.0, 1.0);
}

// Reflectance for an unnamed metal (F0 byte 238..255), where albedo carries the colour. Derived
// via an effective per-channel IOR so falloff behaves like a conductor's, not like Schlick on a
// tinted F0.
vec3 plagueFresnelTinted(float cosTheta, vec3 tint) {
    vec3 t = sqrt(clamp(tint, vec3(0.0), vec3(0.99)));
    vec3 n = (vec3(1.0) + t) / (vec3(1.0) - t);
    vec3 g = sqrt(max(n * n + vec3(cosTheta * cosTheta) - 1.0, 0.0));

    vec3 a = (g - vec3(cosTheta)) / max(g + vec3(cosTheta), vec3(1e-6));
    vec3 b = ((g + vec3(cosTheta)) * cosTheta - 1.0)
           / max((g - vec3(cosTheta)) * cosTheta + 1.0, vec3(1e-6));

    return clamp(0.5 * a * a * (1.0 + b * b), 0.0, 1.0);
}

// F0 (reflectance at normal incidence) for every labPBR material, as a colour. Must be head-on,
// not at NdotV — an angle-evaluated F0 fed to an environment-lobe integral double-applies the
// grazing Fresnel rise.
// All metal/dielectric branching lives HERE, not downstream: three shipped regressions (chrome
// hoppers, pale chalk, powder-blue coat) were each a branch drifting out of sync between paths.

// Strength of albedo re-hue on named metals: 1.0 takes the albedo's hue fully, 0.0 is strict-spec
// (n/k only, albedo ignored). MUST stay a plain constant, not a runtime option: terrain.fsh must
// hand-declare any uniform this file gets in its own block, and an option here compiled fine
// offline but crashed at runtime ("undeclared identifier") in the terrain fragment shader. Also
// never write an option-annotation-shaped comment near this constant: Fornax's option scanner
// matches the syntax anywhere in a file and once mistook one for a malformed option, refusing to
// load the pack.
const float u_MetalAlbedoTint = 1.0;

// Near-black guard for the hue normalize, same role as PLAGUE_EMISSION_HUE_FLOOR in emission.glsl:
// a texel with no colour left resolves to neutral rather than to float noise.
const float PLAGUE_METAL_TINT_HUE_FLOOR = 0.001;
const vec3 PLAGUE_LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);

// Re-hues a named metal's F0 toward its albedo, holding F0's LUMINANCE exactly: n/k decide how
// reflective the surface is, albedo only its colour. Needed because labPBR's named metals
// otherwise discard albedo entirely, which is wrong for textured work (e.g. copper door tiers that
// share one F0 byte and carry their weathering only in albedo). Scale-invariant against the
// shaded albedo's own luminance, so per-face shading can't skew the tint. Clamping to keep
// reflectance <= 1 can only ever darken the result, never brighten past what n/k allows.
// A deliberate spec deviation; u_MetalAlbedoTint 0 restores the literal reading.
vec3 plagueConductorAlbedoTint(vec3 f0, vec3 albedo) {
    vec3 safeAlbedo = max(albedo, vec3(PLAGUE_METAL_TINT_HUE_FLOOR));
    float albedoLuma = max(dot(safeAlbedo, PLAGUE_LUMA_WEIGHTS), PLAGUE_METAL_TINT_HUE_FLOOR);
    float f0Luma = dot(f0, PLAGUE_LUMA_WEIGHTS);
    // The albedo's hue carried at exactly f0's luminance.
    vec3 tinted = safeAlbedo * (f0Luma / albedoLuma);
    return clamp(mix(f0, tinted, clamp(u_MetalAlbedoTint, 0.0, 1.0)), vec3(0.0), vec3(1.0));
}

vec3 plagueMaterialF0(PlagueMaterial m, vec3 albedo) {
    if (!m.conductor) {
        return vec3(m.f0);
    }
    return m.namedMetal
            ? plagueConductorAlbedoTint(
                    plagueFresnelConductor(1.0, PLAGUE_METAL_N[m.metalIndex],
                                           PLAGUE_METAL_K[m.metalIndex]),
                    albedo)
            : clamp(albedo, vec3(0.0), vec3(1.0));
}

/** Reflectance for whichever kind of surface this is, at a given cosine. */
vec3 plagueFresnel(PlagueMaterial m, vec3 albedo, float cosTheta) {
    if (m.conductor) {
        // Same re-hue as plagueMaterialF0, so one material has one colour instead of an
        // untinted highlight against a tinted reflection.
        return m.namedMetal
                ? plagueConductorAlbedoTint(
                        plagueFresnelConductor(cosTheta, PLAGUE_METAL_N[m.metalIndex],
                                               PLAGUE_METAL_K[m.metalIndex]),
                        albedo)
                : plagueFresnelTinted(cosTheta, albedo);
    }
    return vec3(plagueFresnelDielectric(cosTheta, m.f0));
}

// --- Microfacet terms ---------------------------------------------------------------------------

/** Trowbridge-Reitz (GGX) normal distribution. Takes alpha, not perceptual roughness. */
float plagueDistributionGGX(float nDotH, float alpha) {
    float a2 = alpha * alpha;
    float d = nDotH * nDotH * (a2 - 1.0) + 1.0;
    return a2 / max(PLAGUE_PI * d * d, 1e-8);
}

// Smith height-correlated VISIBILITY (Heitz 2014): the geometry term with the 1/(4 NdotL NdotV)
// denominator already folded in and cancelled analytically, so the result is bounded by
// construction and needs no grazing-angle clamp. Exact form, not the Schlick k-approximation.
float plagueVisibilitySmithGGX(float nDotV, float nDotL, float alpha) {
    float a2 = alpha * alpha;
    float lambdaV = nDotL * sqrt(nDotV * nDotV * (1.0 - a2) + a2);
    float lambdaL = nDotV * sqrt(nDotL * nDotL * (1.0 - a2) + a2);
    return 0.5 / max(lambdaV + lambdaL, 1e-6);
}

// Hammon's diffuse term (GDC 2017), roughness-aware where Lambert is not: interpolates between a
// smooth Fresnel response and a rough facing-dependent one, plus a multi-scatter term. Returns the
// diffuse response INCLUDING the N.L cosine — callers must not apply it again.
float plagueDiffuseHammon(vec3 normal, vec3 viewDir, vec3 lightDir, float alpha) {
    float nDotL = max(dot(normal, lightDir), 0.0);
    if (nDotL <= 0.0) {
        return 0.0;
    }
    float nDotV = max(dot(normal, viewDir), 0.0);
    float lDotV = max(dot(lightDir, viewDir), 0.0);

    vec3 halfDir = normalize(viewDir + lightDir);
    float nDotH = max(dot(normal, halfDir), 0.0);

    float facing = 0.5 * lDotV + 0.5;

    float rough = facing * (0.9 - 0.4 * facing) * ((0.5 + nDotH) / max(nDotH, 0.02));
    float smoothTerm = 1.05 * (1.0 - plagueFresnelSchlick(0.0, nDotL))
                            * (1.0 - plagueFresnelSchlick(0.0, nDotV));

    float single = clamp(mix(smoothTerm, rough, alpha) / PLAGUE_PI, 0.0, 1.0);
    float multi = 0.1159 * alpha;

    return clamp((multi + single) * nDotL, 0.0, 1.0);
}

// --- Evaluation ---------------------------------------------------------------------------------

struct PlagueBrdf {
    vec3 diffuse;   // multiply by albedo and incoming radiance
    vec3 specular;  // multiply by incoming radiance
};

// Full direct-lighting response for one light. Both terms already carry N.L — the caller applies
// shadowing and light colour but not the cosine again.
PlagueBrdf plagueEvaluateBrdf(PlagueMaterial m, vec3 albedo, vec3 normal, vec3 viewDir, vec3 lightDir) {
    PlagueBrdf result;
    result.diffuse = vec3(0.0);
    result.specular = vec3(0.0);

    float nDotL = max(dot(normal, lightDir), 0.0);
    if (nDotL <= 0.0) {
        return result;
    }
    float nDotV = max(dot(normal, viewDir), 1e-4);

    vec3 halfDir = normalize(viewDir + lightDir);
    float nDotH = max(dot(normal, halfDir), 0.0);
    float vDotH = max(dot(viewDir, halfDir), 0.0);

    float d = plagueDistributionGGX(nDotH, m.alpha);
    float v = plagueVisibilitySmithGGX(nDotV, nDotL, m.alpha);
    vec3 f = plagueFresnel(m, albedo, vDotH);
    // Fornax binds an all-zero material sample when `_s` is absent: gate on the material itself
    // rather than let exact dielectric Fresnel invent a highlight at its undefined grazing limit.
    vec3 f0Present = step(vec3(0.5 / 255.0), plagueMaterialF0(m, albedo));
    f *= f0Present;

    result.specular = min(d * v * nDotL, PLAGUE_SPECULAR_MAX) * f;

    // A conductor's transmitted light is absorbed rather than scattered back out, so metalness
    // (not a branch) zeroes its diffuse lobe.
    result.diffuse = vec3(plagueDiffuseHammon(normal, viewDir, lightDir, m.alpha))
                   * (1.0 - m.metalness);
    return result;
}

#endif // PLAGUE_BRDF
