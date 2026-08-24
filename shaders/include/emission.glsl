// Owns per-texel luminance shaping and coloured-radiance construction only; combining the
// engine/authored emission lanes and the sentinel/scale logic live upstream in terrain.fsh.
//
// Hue is the direction of linear albedo, decoupled from magnitude (the luminance argument), so a
// neutral-grey material can't blow out to full-strength white the way max-channel normalization would.

#ifndef PLAGUE_EMISSION_INCLUDE
#define PLAGUE_EMISSION_INCLUDE

// Engine-driven lane only: reconstructs per-texel shape from a block's flat emission level (never
// applied to the authored per-texel lane, which already has real artist-drawn shape).

// Authored (not fit): weights max-channel brightness over flat average so one bright fleck (a lamp's
// flame pixel) dominates a mostly-dark texture rather than being averaged away.
const float PLAGUE_EMITTER_LUM_MAX_BIAS = 0.75;

// sqrt-safety floor only; distinct from PLAGUE_EMISSION_HUE_FLOOR below, which serves normalize()
// instead and need not share this value.
const float PLAGUE_EMITTER_LUM_STABILITY_FLOOR = 1e-4;

float plagueEmitterLuminance(vec3 albedoLinear) {
    vec3 a = max(albedoLinear, vec3(0.0));
    float avg = (a.x + a.y + a.z) / 3.0;
    float mx = max(a.x, max(a.y, a.z));

    float shapeFromMax = mix(avg, mx, PLAGUE_EMITTER_LUM_MAX_BIAS);

    // Weight toward the compressive sqrt term is the max-channel brightness itself, not a second
    // tuned constant, so bright texels self-scale toward the compressive curve.
    float safeMx = max(mx, PLAGUE_EMITTER_LUM_STABILITY_FLOOR);
    float compressed = mix(shapeFromMax, sqrt(safeMx), mx);

    return clamp(compressed, 0.0, 1.0);
}

// Called with either magnitude lane already reduced to a single 0..1 luminance.

// Floors albedo before normalize(): prevents NaN on exact black (which blacks out the whole
// framebuffer downstream) and stops a near-black texel with one stray nonzero channel from reading
// as a fully saturated colour. Fit jointly with PLAGUE_EMISSION_MAGNITUDE below
// (tools/fit_emission_parity.py, RMS 5.8e-9 across the 3072-row emitted_radiance_surface table).
// Well above the ~0.0003 sRGB floor of the darkest real texel, so the fit dominates in practice.
const float PLAGUE_EMISSION_HUE_FLOOR = 0.001;

// Overall emission brightness scale. Fit jointly with the floor above, same script: RMS 5.8e-9.
const float PLAGUE_EMISSION_MAGNITUDE = 3.0;

vec3 plagueEmittedRadiance(vec3 albedoLinear, float emitterLum) {
    // Explicit early return rather than relying on arithmetic to fall out to zero: sqrt()-involving
    // identities aren't guaranteed bit-exact on a GPU, and a non-emissive fragment must be
    // bit-identical to a build with no emission code path at all.
    if (emitterLum <= 0.0) {
        return vec3(0.0);
    }
    float lum = min(emitterLum, 1.0);

    // Squaring the unit hue vector spreads its components apart, which is what makes the saturation
    // ramp below read as tinted-while-faint rather than a flat recolour.
    vec3 flooredAlbedo = max(albedoLinear, vec3(PLAGUE_EMISSION_HUE_FLOOR));
    vec3 hue = normalize(flooredAlbedo);
    vec3 squaredHue = hue * hue;

    // Weighted by sqrt(lum), matching how a real cooling emitter's colour saturates as it dims.
    float lumSqrt = sqrt(lum);
    vec3 blendedHue = mix(squaredHue, hue, lumSqrt);

    return blendedHue * lum * PLAGUE_EMISSION_MAGNITUDE;
}

#endif // PLAGUE_EMISSION_INCLUDE
