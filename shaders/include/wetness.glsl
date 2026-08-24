#ifndef PLAGUE_WETNESS
#define PLAGUE_WETNESS

#moj_import <fornax_runtime:brdf.glsl>

// --- Wetness ------------------------------------------------------------------------------------
//
// Wet surfaces both DARKEN (multiple internal reflection at the water/air interface, the closed-form
// Saunderson correction to Kubelka-Munk reflectance — Saunderson 1942; Lekner & Dorf 1988, "Why some
// things are darker when wet") and SLICK (water film is smoother/more reflective than what it
// covers); both are needed or the surface reads as shiny-but-dry or muddy-but-matte.
//
// Constants fitted by tools/fit_wetness_parity.py against tools/fixtures/wetness-behavior-cf12372.json.

const vec3 PLAGUE_WET_LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);

const float PLAGUE_WET_SKY_EDGE0 = 0.8;
const float PLAGUE_WET_SKY_EDGE1 = 0.95;
const float PLAGUE_WET_NORMAL_EDGE0 = 0.5;
const float PLAGUE_WET_NORMAL_EDGE1 = 0.9;

const float PLAGUE_WET_GAMMA_BASE = 1.5;
const float PLAGUE_WET_GAMMA_LUMA_COUPLING = 0.5;
const float PLAGUE_WET_DESATURATION = 0.15;
const float PLAGUE_WET_BOUNCE_CEILING = 0.7;

const float PLAGUE_WET_F0 = 0.04;

// Gated by sky access AND facing-up, multiplied — without both, cave walls and overhangs slick up
// in a storm. engineWetness (u_FrameState.w) is accumulated, not the instantaneous rain level.
float plagueSurfaceWetness(float engineWetness, float skyLight, float normalY) {
    float skyGate = smoothstep(PLAGUE_WET_SKY_EDGE0, PLAGUE_WET_SKY_EDGE1, skyLight);
    float normalGate = smoothstep(PLAGUE_WET_NORMAL_EDGE0, PLAGUE_WET_NORMAL_EDGE1, normalY);
    return engineWetness * skyGate * normalGate;
}

// Darken (luminance-coupled power law), desaturate toward luma, then apply the collapsed
// internal-reflection series; denom is guarded near 0/0 as albedo->1 with bounce fraction at 1.
vec3 plagueFauxPorosity(vec3 albedo, float wetness, float porosity) {
    float luma = dot(albedo, PLAGUE_WET_LUMA_WEIGHTS);
    float gamma = PLAGUE_WET_GAMMA_BASE + PLAGUE_WET_GAMMA_LUMA_COUPLING * luma;
    vec3 darkened = pow(max(albedo, vec3(1e-5)), vec3(gamma));

    float darkenedLuma = dot(darkened, PLAGUE_WET_LUMA_WEIGHTS);
    vec3 desaturated = mix(darkened, vec3(darkenedLuma), PLAGUE_WET_DESATURATION);

    float bounceBack = porosity * PLAGUE_WET_BOUNCE_CEILING;
    vec3 denom = max(vec3(1.0) - bounceBack * desaturated, vec3(1e-4));
    vec3 wetAlbedo = desaturated * (1.0 - bounceBack) / denom;

    return mix(albedo, wetAlbedo, wetness);
}

// GGX alpha pulled toward zero with wetness, floored at PLAGUE_SUN_ANGULAR_RADIUS so the specular
// lobe never degenerates. F0 floored toward wet dielectric reflectance, but not for conductors —
// their F0 identifies the metal, and flooring it would turn iron into plastic.
void plagueApplyWetness(inout PlagueMaterial m, inout vec3 albedo, float wetness) {
    if (wetness <= 0.0) {
        return;
    }
    albedo = plagueFauxPorosity(albedo, wetness, m.porosity);
    m.alpha = max(mix(m.alpha, 0.0, wetness), PLAGUE_SUN_ANGULAR_RADIUS);
    if (!m.conductor) {
        m.f0 = max(m.f0, PLAGUE_WET_F0 * wetness);
    }
}

#endif // PLAGUE_WETNESS
