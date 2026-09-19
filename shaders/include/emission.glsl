// Owns per-texel luminance shaping, scalar source construction and coloured emitted radiance.
// Callers supply the albedo and authored scale so existing surface policies remain explicit.
//
// Hue is the direction of linear albedo, decoupled from magnitude (the luminance argument), so a
// neutral-grey material can't blow out to full-strength white the way max-channel normalization would.

#ifndef PLAGUE_EMISSION_INCLUDE
#define PLAGUE_EMISSION_INCLUDE

#moj_import <fornax_runtime:local_light_mode.glsl>

// How fast a glowing block's own brightness falls away from its brightest texels.
//
// A pack that ships no emission map leaves the shader guessing which texels glow, and the only
// signal left is how bright they are in the texture. That guess is generous: a campfire's pale logs
// read as most of the way to its flame, so the whole block glows. Tighter settings pull the dim
// texels down and leave the bright ones, without changing how bright the block is.
//
// Compile-time, because this is read in a geometry stage, where a runtime option has no uniform
// block to arrive in and its name would be left undefined.
//
// Applies to CUTOUT blocks only. A solid cube that glows, a glowstone or a sea lantern, really does
// glow over its whole face, and tightening it there would be wrong. A torch, a lantern or a
// campfire is a cutout draw: a bright part mounted on something that is not meant to glow at all.
// The draw class is the signal, not the block, so nothing here knows or cares which block it is.
//
// Even is the identity, which is the point: the curve underneath was fitted, and this rides on top.
#ifndef PLAGUE_EMITTER_FALLOFF
#define PLAGUE_EMITTER_FALLOFF 1 //[1 2 3 4] compile "Glow Falloff" {1="Even" 2="Softer" 3="Tighter" 4="Tightest"}
#endif

// Engine-driven lane only: reconstructs per-texel shape from a block's flat emission level (never
// applied to the authored per-texel lane, which already has real artist-drawn shape).

// Authored (not fit): weights max-channel brightness over flat average so one bright fleck (a lamp's
// flame pixel) dominates a mostly-dark texture rather than being averaged away.
const float PLAGUE_EMITTER_LUM_MAX_BIAS = 0.75;

// sqrt-safety floor only; distinct from PLAGUE_EMISSION_HUE_FLOOR below, which serves normalize()
// instead and need not share this value.
const float PLAGUE_EMITTER_LUM_STABILITY_FLOOR = 1e-4;

float plagueEmitterLuminance(vec3 albedoLinear, bool cutout) {
    vec3 a = max(albedoLinear, vec3(0.0));
    float avg = (a.x + a.y + a.z) / 3.0;
    float mx = max(a.x, max(a.y, a.z));

    float shapeFromMax = mix(avg, mx, PLAGUE_EMITTER_LUM_MAX_BIAS);

    // Weight toward the compressive sqrt term is the max-channel brightness itself, not a second
    // tuned constant, so bright texels self-scale toward the compressive curve.
    float safeMx = max(mx, PLAGUE_EMITTER_LUM_STABILITY_FLOOR);
    float compressed = mix(shapeFromMax, sqrt(safeMx), mx);

    // Glow Falloff rides on top of the fitted curve rather than replacing it: at Even this is the
    // identity and the fit stands. Tighter, dim texels drop away faster than bright ones, which is
    // what separates a flame from the pale wood it sits on when a pack authors no emission map.
    float shaped = clamp(compressed, 0.0, 1.0);
#if PLAGUE_EMITTER_FALLOFF > 1
    if (cutout) {
        shaped = pow(shaped, float(PLAGUE_EMITTER_FALLOFF));
    }
#endif
    return shaped;
}

// Material alpha byte 255 is the atlas's unauthored sentinel; authored bytes 0..254 span 0..1.
// Preserve the existing terrain/voxel max of independent intrinsic and authored emission lanes.
float plagueSourceLuminance(vec3 albedoLinear, float intrinsicEmission, float materialAlpha,
        float authoredScale, bool cutout) {
    bool unauthored = materialAlpha >= (254.5 / 255.0);
    float intrinsicShape = unauthored ? 1.0 : materialAlpha;
    float authored = unauthored ? 0.0 : min(materialAlpha * (255.0 / 254.0), 1.0);
    return max(plagueEmitterLuminance(albedoLinear, cutout) * intrinsicEmission * intrinsicShape,
            authored * authoredScale);
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

// tools/derive_local_emission.py: a white unit face one block from a neutral rough wall matches
// the legacy block-14 reference luminance. These scene units apply to source and receiver alike.
const float PLAGUE_LOCAL_EMISSION_MAGNITUDE = 15.638055;

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

#if PLAGUE_LOCAL_LIGHTING != 0
    return blendedHue * lum * PLAGUE_LOCAL_EMISSION_MAGNITUDE;
#else
    return blendedHue * lum * PLAGUE_EMISSION_MAGNITUDE;
#endif
}

#endif // PLAGUE_EMISSION_INCLUDE
