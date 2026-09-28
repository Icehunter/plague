#ifndef PLAGUE_MICROFACET_NORMAL_MAP_GLSL
#define PLAGUE_MICROFACET_NORMAL_MAP_GLSL

// A model of a bumped surface as two flat sides, checked against the true flat surface underneath.
// From Schussler, Heitz, Hanika, Dachsbacher, "Microfacet-based Normal Mapping for Robust Monte
// Carlo Path Tracing", ACM Transactions on Graphics 36(6), 2017.
//
// A bumped point on the surface is treated as a small V-shaped groove with two sides: the bumped
// side wp (the normal map's own direction) and a second side wt, picked so the two sides' average
// points the same way as the true flat surface ng (paper section 4.1). Section 6.2 treats the
// second side as a plain mirror: a light or view ray that would hit it instead gets one more look
// at the real material's own shine, from a direction bounced off wt (equation 23, "single and
// double bounce"). This is what stops a plain bumped-normal shine from sending back too much or
// too little light when wp leans away from ng.

#moj_import <fornax_runtime:brdf.glsl>

// Above this closeness to flat, the second side's direction breaks down (the vector normalized in
// plagueTangentFacet is near zero length), so plagueEvaluateBrdfMicrofacetNormal returns the plain,
// one-sided result instead of dividing by that near-zero length. This only stops a divide-by-zero;
// it is not that the full formula breaks here, since the three-part result does settle on the same
// value as wp gets close to ng, for any view that is not itself near a steep edge-on angle. Near
// such an angle the two do not match closely right up to this point (real behavior of the model,
// not a bug), so a bump this close to flat can still show a visible jump at steep viewing angles;
// this has not been checked against a real screenshot yet. A safety number, not one from the paper.
const float PLAGUE_MICROFACET_FLAT_COS = 0.9999;

// The second side's direction (paper section 4.1: "at a right angle to the true surface", meaning
// wt lies flat against ng, dot(wt, ng) == 0). It is the flat-against-the-surface part of wp,
// flipped and made unit length: the groove's far wall, leaning the opposite way from wp.
vec3 plagueTangentFacet(vec3 ng, vec3 wp) {
    vec3 tangential = dot(wp, ng) * ng - wp;
    float len = length(tangential);
    // Only reached if a caller skips the flat check above. ng is a safe stand-in for the truly
    // broken case wp == +-ng; it is never actually used there, since every later use of wt is
    // scaled by a value that is itself zero in that case.
    return len > 1e-5 ? tangential / len : ng;
}

// Equation 6: how much of the bumped side faces direction w, scaled so this equals 1 when w
// matches ng. The small floor number stops a divide by a huge number when wp and ng point almost
// at a right angle to each other.
float plagueFacetAp(vec3 w, vec3 ng, vec3 wp) {
    float wpDotNg = max(dot(wp, ng), 1e-3);
    return max(dot(w, wp), 0.0) / wpDotNg;
}

// Equation 7: how much of the second side faces direction w.
float plagueFacetAt(vec3 w, vec3 ng, vec3 wp, vec3 wt) {
    float wpDotNg = max(dot(wp, ng), 1e-3);
    float sinTerm = sqrt(clamp(1.0 - wpDotNg * wpDotNg, 0.0, 1.0));
    return max(dot(w, wt), 0.0) * sinTerm / wpDotNg;
}

// Equations 8-9: the chance that a ray from direction w hits the bumped side rather than the
// second side, based on how much each side faces that way. If both are zero, this falls back to
// "the bumped side gets it all" instead of dividing by zero.
float plagueFacetLambdaP(vec3 w, vec3 ng, vec3 wp, vec3 wt) {
    float ap = plagueFacetAp(w, ng, wp);
    float at = plagueFacetAt(w, ng, wp, wt);
    float denom = ap + at;
    return denom > 1e-6 ? ap / denom : 1.0;
}

// Equation 13: how much of one named side (m is either wp or wt) is actually visible from
// direction w, and not blocked by the groove. Zero if w is behind that side. Capped so the groove
// never shows more surface than a flat ng would.
float plagueFacetG1(vec3 w, vec3 ng, vec3 wp, vec3 wt, vec3 m) {
    if (dot(w, m) <= 0.0) {
        return 0.0;
    }
    float ap = plagueFacetAp(w, ng, wp);
    float at = plagueFacetAt(w, ng, wp, wt);
    float denom = ap + at;
    if (denom <= 1e-6) {
        return 0.0;
    }
    return min(1.0, max(dot(w, ng), 0.0) / denom);
}

// The bumped side's plain shine value, with the usual light-angle scaling divided back out, since
// plagueEvaluateBrdf always folds that scaling in. Equation 23's fp(.,.) is meant to be this plain
// value; each place that calls this puts back the exact scaling the paper's formula wants, which is
// not always the same one plagueEvaluateBrdf would have used on its own.
vec3 plagueFacetBrdfRaw(PlagueMaterial m, vec3 albedo, vec3 facetNormal, vec3 viewArg, vec3 lightArg) {
    // Small floor number, the same one plagueEvaluateBrdf itself uses for steep angles (brdf.glsl),
    // so this division never sees a smaller number than that function already allows inside itself.
    float nDotL = max(dot(facetNormal, lightArg), 1e-4);
    return plagueEvaluateBrdf(m, albedo, facetNormal, viewArg, lightArg).specular / nDotL;
}

// Equation 23 (the mirror-second-side case, paper section 6.2): the full single- and double-bounce
// shine of the two-sided bump model. Returns a value ready to multiply straight by the light's
// color and shadow amount, in place of plagueEvaluateBrdf(...).specular. The true-surface angle
// scaling the paper's fix needs (section 3.1) is applied once, at the end.
vec3 plagueEvaluateBrdfMicrofacetNormal(
        PlagueMaterial m, vec3 albedo, vec3 ng, vec3 wp, vec3 viewDir, vec3 lightDir) {
    // Light coming from below the true surface cannot land on either side.
    if (dot(lightDir, ng) <= 0.0) {
        return vec3(0.0);
    }

    float wpDotNg = dot(wp, ng);
    if (abs(wpDotNg) >= PLAGUE_MICROFACET_FLAT_COS) {
        return plagueEvaluateBrdf(m, albedo, wp, viewDir, lightDir).specular;
    }

    vec3 wt = plagueTangentFacet(ng, wp);

    float lambdaP = plagueFacetLambdaP(lightDir, ng, wp, wt);
    float lambdaT = 1.0 - lambdaP; // only two facets share the incident ray

    // Path 1 (i -> p -> o): the direct term, equation 23 line 1.
    vec3 fpDirect = plagueFacetBrdfRaw(m, albedo, wp, viewDir, lightDir);
    float g1ViewP = plagueFacetG1(viewDir, ng, wp, wt, wp);
    vec3 term1 = lambdaP * fpDirect * max(dot(viewDir, wp), 0.0) * g1ViewP;

    // Path 2 (i -> p -> t -> o): the view ray leaves the bumped side, bounces off the second side's
    // mirror, and comes back out toward viewDir. Equation 23 line 2 checks fp using the outgoing
    // direction bounced off wt.
    vec3 term2 = vec3(0.0);
    vec3 viewViaWt = reflect(viewDir, wt);
    if (dot(viewViaWt, wp) > 0.0) {
        vec3 fpViaWt = plagueFacetBrdfRaw(m, albedo, wp, viewViaWt, lightDir);
        float g1ViaWtP = plagueFacetG1(viewViaWt, ng, wp, wt, wp);
        float g1ViewT = plagueFacetG1(viewDir, ng, wp, wt, wt);
        term2 = lambdaP * fpViaWt * max(dot(viewViaWt, wp), 0.0) * (1.0 - g1ViaWtP) * g1ViewT;
    }

    // Path 3 (i -> t -> p -> o): the light ray bounces off the second side's mirror before it ever
    // reaches the bumped side. Equation 23 line 3 checks fp with the light direction bounced off wt,
    // view direction unchanged.
    vec3 term3 = vec3(0.0);
    vec3 lightViaWt = reflect(lightDir, wt);
    if (dot(lightViaWt, wp) > 0.0) {
        vec3 fpLightViaWt = plagueFacetBrdfRaw(m, albedo, wp, viewDir, lightViaWt);
        term3 = lambdaT * fpLightViaWt * max(dot(viewDir, wp), 0.0) * g1ViewP;
    }

    // Small floor number, same purpose as plagueFacetBrdfRaw's floor above.
    float outgoingGeomCos = max(dot(viewDir, ng), 1e-4);
    vec3 f2 = (term1 + term2 + term3) / outgoingGeomCos;
    return f2 * max(dot(lightDir, ng), 0.0);
}

#endif // PLAGUE_MICROFACET_NORMAL_MAP_GLSL
