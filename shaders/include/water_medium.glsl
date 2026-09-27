#ifndef PLAGUE_WATER_MEDIUM
#define PLAGUE_WATER_MEDIUM
// One water, for every view of it. The surface seen from the air, the veil seen from under it,
// the light shafts and the light that reaches a sunken block all read the same three numbers per
// channel: how much the water absorbs, how much it scatters, and how the light from above falls
// off with depth. A second set of numbers anywhere is a second water, and the two show up as a
// lantern that changes colour when the camera crosses the surface.
//
// Blocks are metres here, the convention the whole pack uses for water.
//
// Absorption: Pope & Fry 1997 ("Absorption spectrum (380-700 nm) of pure water. II. Integrating
// cavity measurements", Appl. Opt. 36, 8710-8723), sampled near this pack's display primaries and
// converted from the published cm^-1 to m^-1:
//   630.0 nm (red)   -> 0.2916 m^-1  (1/e after ~3.4 blocks)
//   532.5 nm (green) -> 0.0447 m^-1  (1/e after ~22 blocks)
//   465.0 nm (blue)  -> 0.01011 m^-1 (1/e after ~99 blocks)
const vec3 PLAGUE_WATER_SIGMA_A = vec3(0.2916, 0.0447, 0.01011);
// Scattering: Petzold 1972 (suspended particulates, spectrally near flat), magnitude in the
// clear-lake band.
const vec3 PLAGUE_WATER_SIGMA_S = vec3(0.015);

// Normalized water-particle phase: a Kopelevich-style small-angle forward lobe mixed with a
// Cornette-Shanks backscatter lobe (Cornette & Shanks 1992); both published forms, both
// analytically energy-conserving, so the mix is too.
//
// Parameters fitted by tools/fit_water_phase.py against the committed behaviour fixture, tuned for
// shaft VISIBILITY rather than oceanographic fidelity; energy conservation is the physical
// constraint kept, side-angle brightness is not Petzold's measured value.
const float PLAGUE_WATER_PHASE_FORWARD_SHARPNESS = 100.0;
const float PLAGUE_WATER_PHASE_BACK_G = -0.27;
const float PLAGUE_WATER_PHASE_FORWARD_WEIGHT = 0.797;
float plagueWaterParticlePhase(float mu) {
    const float gCs2 = PLAGUE_WATER_PHASE_BACK_G * PLAGUE_WATER_PHASE_BACK_G;
    float clampedMu = clamp(mu, -1.0, 1.0);
    float forwardLobe = PLAGUE_WATER_PHASE_FORWARD_SHARPNESS / (6.283185307179586
            * (PLAGUE_WATER_PHASE_FORWARD_SHARPNESS * (1.0 - clampedMu) + 1.0)
            * log(2.0 * PLAGUE_WATER_PHASE_FORWARD_SHARPNESS + 1.0));
    float backLobe = (3.0 * (1.0 - gCs2))
            / (8.0 * 3.141592653589793 * (2.0 + gCs2))
            * ((1.0 + clampedMu * clampedMu)
            / pow(max(1.0 + gCs2 - 2.0 * PLAGUE_WATER_PHASE_BACK_G * clampedMu, 1e-6), 1.5));
    return mix(backLobe, forwardLobe, PLAGUE_WATER_PHASE_FORWARD_WEIGHT);
}

// How fast the light from the sky falls off with depth. Kirk 1984 ("Dependence of relationship
// between inherent and apparent optical properties of water on solar altitude", Limnol. Oceanogr.
// 29, 350-356): Kd = sqrt(a^2 + G a b) / mu0, with G = 0.425 mu0 - 0.19 and mu0 the mean cosine
// of the light entering the water. A sky spread over the whole dome enters at mu0 near 0.86, and
// that figure serves every hour: the sun's share of the light drops as it does.
const float PLAGUE_WATER_DOWNWELLING_MU = 0.86;

// The touch of fantasy, and the one number here that is a choice. Single scatter with the phase
// evaluated side-on is what the sums below give; real water adds light scattered twice or more,
// which the sums leave out, and this pack wants the column a little more luminous than that.
// Picked off tools/render_water_medium.py: at 1.25 the level view through endless water at noon
// reads 0.21 linear in blue against the accepted build's 0.15, a touch brighter, and the hue is
// the water's own. 1.0 lands on the old figure; 1.6 reads as haze.
const float PLAGUE_WATER_SCATTER_GAIN = 1.25;

vec3 plagueWaterSigmaT(float clarity) {
    return (PLAGUE_WATER_SIGMA_S + PLAGUE_WATER_SIGMA_A) / max(clarity, 0.05);
}

// What survives a path of water, per channel. Red goes first.
vec3 plagueWaterVolumeTransmittance(float distance, float clarity) {
    return exp(-plagueWaterSigmaT(clarity) * max(distance, 0.0));
}

// Of the light the water stops, the share it sends back out instead of swallowing. Clarity scales
// both coefficients alike, so it cancels here.
vec3 plagueWaterAlbedo() {
    return PLAGUE_WATER_SIGMA_S / (PLAGUE_WATER_SIGMA_S + PLAGUE_WATER_SIGMA_A);
}

vec3 plagueWaterKd(float clarity) {
    vec3 a = PLAGUE_WATER_SIGMA_A / max(clarity, 0.05);
    vec3 b = PLAGUE_WATER_SIGMA_S / max(clarity, 0.05);
    float g = 0.425 * PLAGUE_WATER_DOWNWELLING_MU - 0.19;
    return sqrt(a * a + g * a * b) / PLAGUE_WATER_DOWNWELLING_MU;
}

// The sky light left at a depth, as a share of what entered at the surface.
vec3 plagueWaterDownwelling(float depthBlocks, float clarity) {
    return exp(-plagueWaterKd(clarity) * max(depthBlocks, 0.0));
}

// The light the water itself gives off along a leg of the view ray, lit from above.
//
// The sky's light is spread over the upper half of directions, so a point in the water sees it
// coming from every angle between straight down and level. The phase is read once, side-on, as
// the stand-in for that spread; the forward peak belongs to the sun, which the shaft march owns.
// Half, because only the upper hemisphere carries light. `lightAtStart` is the sky light where the
// leg begins, in the units a white diffuse surface shows under the same sky; along the leg it
// grows toward the surface and dies away from it as exp(Kd * dirY * s).
//
//   L = albedo * gain * lightAtStart * phaseSide / 2
//       * sigmaT * integral_0^leg exp(-sigmaT * s) * exp(Kd * dirY * s) ds
//     = albedo * gain * lightAtStart * phaseSide / 2 * sigmaT * (1 - exp(-k * leg)) / k
//   with k = sigmaT - Kd * dirY.
//
// k reaches zero and goes negative looking up in red; the integral is sigmaT * leg at zero and
// stays finite past it because an upward leg ends at the surface, so callers bound the leg by the
// distance to the surface along the ray.
vec3 plagueWaterInScatter(vec3 lightAtStart, float dirY, float legBlocks, float clarity) {
    vec3 sigmaT = plagueWaterSigmaT(clarity);
    vec3 k = sigmaT - plagueWaterKd(clarity) * clamp(dirY, -1.0, 1.0);
    float leg = max(legBlocks, 0.0);
    vec3 nearZero = step(abs(k), vec3(1e-4));
    vec3 safeK = mix(k, vec3(1.0), nearZero);
    vec3 integral = mix((vec3(1.0) - exp(-safeK * leg)) / safeK, vec3(leg), nearZero);
    float phaseSide = 12.566370614359172 * plagueWaterParticlePhase(0.0);
    return plagueWaterAlbedo() * PLAGUE_WATER_SCATTER_GAIN * max(lightAtStart, vec3(0.0))
         * (0.5 * phaseSide) * sigmaT * integral;
}

#endif // PLAGUE_WATER_MEDIUM
