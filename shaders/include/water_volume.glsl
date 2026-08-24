#ifndef PLAGUE_WATER_VOLUME
#define PLAGUE_WATER_VOLUME

#moj_import <fornax_runtime:color.glsl>

// Shared finite-water transport ABI: the interval target carries geometry only, radiance is
// evaluated by the later transport pass. Absorption/scattering kept SPLIT so Beer's term can use
// real total extinction while the source integral adds back only scattered radiance.
//
// Absorption: Pope & Fry 1997 (pure water, 630/532.5/465 nm). Scattering: Petzold 1972 (suspended
// particulates, spectrally near-flat), magnitude in the clear-lake band.
const vec3 PLAGUE_WATER_SIGMA_S = vec3(0.015);
const vec3 PLAGUE_WATER_SIGMA_A = vec3(0.2916, 0.0447, 0.01011);
const float PLAGUE_WATER_INTERVAL_EPSILON = 1e-3;
const float PLAGUE_WATER_MEDIUM_REVISION = 2.0;
const float PLAGUE_WATER_RECONSTRUCTION_ENTRY_TOLERANCE = 1.00;
const float PLAGUE_WATER_RECONSTRUCTION_EXIT_TOLERANCE = 2.00;
const float PLAGUE_WATER_RECONSTRUCTION_NORMAL_DOT_MIN = 0.85;
const float PLAGUE_WATER_RECONSTRUCTION_REVISION_TOLERANCE = 0.125;
const float PLAGUE_WATER_RECONSTRUCTION_WEIGHT_EPSILON = 1e-5;

// Fractional alpha lets the debug view identify which branch rejected a pixel; the integer
// revision lane stays zero so plagueDecodeWaterVolumeInterval still rejects these as invalid.
const float PLAGUE_WATER_INTERVAL_FAILURE_INPUT = 0.125;
const float PLAGUE_WATER_INTERVAL_FAILURE_OPTICAL = 0.250;
const float PLAGUE_WATER_INTERVAL_FAILURE_SURFACE_DISTANCE = 0.375;
const float PLAGUE_WATER_INTERVAL_FAILURE_OPAQUE_DISTANCE = 0.500;
const float PLAGUE_WATER_INTERVAL_FAILURE_ENTRY_DISTANCE = 0.625;
const float PLAGUE_WATER_INTERVAL_FAILURE_EMPTY = 0.750;

struct PlagueWaterVolumeInterval {
    float entryDistance;
    float exitDistance;
    vec3 boundaryNormal;
    float revision;
    bool submerged;
    bool valid;
};

bool plagueWaterVolumeFinite(float value) {
    return !isnan(value) && !isinf(value);
}

bool plagueWaterVolumeFinite(vec2 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterVolumeFinite(vec3 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterVolumeFinite(vec4 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

vec3 plagueWaterVolumeSafeNormal(vec3 normal) {
    float normalLengthSquared = dot(normal, normal);
    return normalLengthSquared > 1e-8
            ? normal * inversesqrt(normalLengthSquared)
            : vec3(0.0, 1.0, 0.0);
}

vec2 plagueWaterVolumeSignNotZero(vec2 value) {
    return vec2(value.x < 0.0 ? -1.0 : 1.0, value.y < 0.0 ? -1.0 : 1.0);
}

vec2 plagueWaterVolumeOctEncode(vec3 normal) {
    vec3 unitNormal = plagueWaterVolumeSafeNormal(normal);
    unitNormal /= max(abs(unitNormal.x) + abs(unitNormal.y) + abs(unitNormal.z), 1e-6);
    vec2 encoded = unitNormal.xy;
    if (unitNormal.z < 0.0) {
        encoded = (vec2(1.0) - abs(encoded.yx)) * plagueWaterVolumeSignNotZero(encoded.xy);
    }
    return encoded * 0.5 + 0.5;
}

vec3 plagueWaterVolumeOctDecode(vec2 encoded) {
    vec2 folded = encoded * 2.0 - 1.0;
    vec3 normal = vec3(folded, 1.0 - abs(folded.x) - abs(folded.y));
    if (normal.z < 0.0) {
        normal.xy = (vec2(1.0) - abs(normal.yx)) * plagueWaterVolumeSignNotZero(normal.xy);
    }
    return plagueWaterVolumeSafeNormal(normal);
}

vec4 plagueEncodeWaterVolumeInterval(PlagueWaterVolumeInterval interval) {
    if (!interval.valid) {
        return vec4(0.0);
    }

    vec2 octNormal = plagueWaterVolumeOctEncode(interval.boundaryNormal);
    // Kept clear of both integer boundaries so half-float filtering can't push it across one.
    float packedNormalY = 0.001 + clamp(octNormal.y, 0.0, 1.0) * 0.998;
    float signedEntry = (interval.submerged ? 1.0 : -1.0)
            * (max(interval.entryDistance, 0.0) + PLAGUE_WATER_INTERVAL_EPSILON);
    return vec4(signedEntry, interval.exitDistance, octNormal.x,
            floor(interval.revision + 0.5) + packedNormalY);
}

vec4 plagueEncodeWaterVolumeIntervalFailure(float reason) {
    return vec4(0.0, 0.0, 0.0, clamp(reason, 0.0, 0.999));
}

PlagueWaterVolumeInterval plagueDecodeWaterVolumeInterval(vec4 encoded) {
    PlagueWaterVolumeInterval interval;
    interval.entryDistance = 0.0;
    interval.exitDistance = 0.0;
    interval.boundaryNormal = vec3(0.0, 1.0, 0.0);
    interval.revision = 0.0;
    interval.submerged = false;
    interval.valid = false;

    if (any(isnan(encoded)) || any(isinf(encoded))) {
        return interval;
    }

    interval.submerged = encoded.r > 0.0;
    // Submerged entry is forced to exactly 0.0 rather than recovered as abs(r)-epsilon: RGBA16F
    // filtering can shrink the stored sentinel below epsilon, which turned the camera entry
    // negative and rejected every wet ray.
    interval.entryDistance = interval.submerged ? 0.0
            : -encoded.r - PLAGUE_WATER_INTERVAL_EPSILON;
    interval.exitDistance = encoded.g;
    interval.revision = floor(encoded.a);
    float packedNormalY = fract(encoded.a);
    if (packedNormalY <= 0.0 || packedNormalY >= 1.0
            || interval.revision != PLAGUE_WATER_MEDIUM_REVISION
            || (!interval.submerged && interval.entryDistance < 0.0)
            || interval.exitDistance <= interval.entryDistance) {
        return interval;
    }

    float normalY = clamp((packedNormalY - 0.001) / 0.998, 0.0, 1.0);
    interval.boundaryNormal = plagueWaterVolumeOctDecode(vec2(encoded.b, normalY));
    interval.valid = true;
    return interval;
}

vec3 plagueWaterSigmaT(float clarity) {
    return (PLAGUE_WATER_SIGMA_S + PLAGUE_WATER_SIGMA_A) / max(clarity, 0.05);
}

vec3 plagueWaterVolumeTransmittance(float distance, float clarity) {
    return exp(-plagueWaterSigmaT(clarity) * max(distance, 0.0));
}

vec3 plagueWaterCellWeight(vec3 sigmaT, float distance) {
    vec3 opticalDepth = sigmaT * max(distance, 0.0);
    vec3 safeSigmaT = max(sigmaT, vec3(1e-8));
    return mix(vec3(max(distance, 0.0)), (vec3(1.0) - exp(-opticalDepth)) / safeSigmaT,
            step(vec3(1e-8), abs(sigmaT)));
}

// Normalized water-particle phase: a Kopelevich-style small-angle forward lobe mixed with a
// Cornette-Shanks backscatter lobe (Cornette & Shanks 1992); both published forms, both
// analytically energy-conserving, so the mix is too.
//
// Parameters fitted by tools/fit_water_phase.py against the committed behaviour fixture, tuned for
// shaft VISIBILITY rather than oceanographic fidelity — energy conservation is the physical
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

// The direct (celestial shaft) curve: two exponential lobes in sqrt(1 - mu) — a NEAR lobe for the
// look-into-the-light peak, a WIDE lobe for everything else — already in volume units. Constants
// fitted by tools/fit_water_phase.py against the committed behaviour fixture.
const float PLAGUE_WATER_DIRECT_PHASE_NEAR_AMP = 2.210774;
const float PLAGUE_WATER_DIRECT_PHASE_NEAR_RATE = 12.34596;
const float PLAGUE_WATER_DIRECT_PHASE_WIDE_AMP = 4.964092;
const float PLAGUE_WATER_DIRECT_PHASE_WIDE_RATE = 4.404965;
// Closed-form spherical mean of the curve above (u = sqrt(1 - mu) reduces the integral to
// elementary terms in u * 2^(-rate * u)); mixing toward it broadens the lobe without changing its
// solid-angle integral.
const float PLAGUE_WATER_DIRECT_PHASE_MEAN = 0.524930251718;
// Shipped-default numerical reference; the march supplies the live spread control.
const float PLAGUE_WATER_DIRECT_ISOTROPIC_WEIGHT = 0.75;

// Broadens the forward lobe toward its energy-equivalent isotropic value so side-on camera angles
// still show shaft contrast; occlusion still comes only from the shadow map, this changes angular
// distribution only.
float plagueWaterEffectiveDirectPhase(float mu, float shaftSpread) {
    float s = sqrt(clamp(1.0 - clamp(mu, -1.0, 1.0), 0.0, 2.0));
    float directPhase =
            PLAGUE_WATER_DIRECT_PHASE_NEAR_AMP * exp2(-PLAGUE_WATER_DIRECT_PHASE_NEAR_RATE * s)
            + PLAGUE_WATER_DIRECT_PHASE_WIDE_AMP * exp2(-PLAGUE_WATER_DIRECT_PHASE_WIDE_RATE * s);
    return mix(directPhase, PLAGUE_WATER_DIRECT_PHASE_MEAN, clamp(shaftSpread, 0.0, 1.0));
}

vec3 plagueWaterOpticalDistance(vec3 sigmaT, float epsilon) {
    return vec3(-log(clamp(epsilon, 1e-6, 0.999999))) / max(sigmaT, vec3(1e-6));
}

float plagueWaterVolumeEffectiveExit(
        float intervalExit,
        float maximumDistanceChunks) {
    // Clamped to the same reach the march integrated, so terrain beyond it can't affect agreement.
    float maximumDistance = max(maximumDistanceChunks, 1.0) * 16.0;
    return min(intervalExit, maximumDistance);
}

float plagueWaterVolumeReconstructionAgreement(
        PlagueWaterVolumeInterval fullInterval,
        PlagueWaterVolumeInterval candidate,
        float maximumDistanceChunks) {
    if (!fullInterval.valid || !candidate.valid
            || candidate.submerged != fullInterval.submerged
            || abs(candidate.revision - fullInterval.revision)
                    > PLAGUE_WATER_RECONSTRUCTION_REVISION_TOLERANCE) {
        return 0.0;
    }

    float entryDelta = abs(candidate.entryDistance - fullInterval.entryDistance);
    float exitDelta = abs(
            plagueWaterVolumeEffectiveExit(
                    candidate.exitDistance, maximumDistanceChunks)
            - plagueWaterVolumeEffectiveExit(
                    fullInterval.exitDistance, maximumDistanceChunks));
    float normalDot = clamp(dot(fullInterval.boundaryNormal, candidate.boundaryNormal),
            -1.0, 1.0);
    if (entryDelta > PLAGUE_WATER_RECONSTRUCTION_ENTRY_TOLERANCE
            || exitDelta > PLAGUE_WATER_RECONSTRUCTION_EXIT_TOLERANCE
            || normalDot < PLAGUE_WATER_RECONSTRUCTION_NORMAL_DOT_MIN) {
        return 0.0;
    }

    float entryAgreement = 1.0 - smoothstep(
            0.0, PLAGUE_WATER_RECONSTRUCTION_ENTRY_TOLERANCE, entryDelta);
    float exitAgreement = 1.0 - smoothstep(
            0.0, PLAGUE_WATER_RECONSTRUCTION_EXIT_TOLERANCE, exitDelta);
    float normalAgreement = smoothstep(
            PLAGUE_WATER_RECONSTRUCTION_NORMAL_DOT_MIN, 1.0, normalDot);
    return entryAgreement * exitAgreement * normalAgreement;
}

bool plagueWaterVolumeScatterValid(
        vec4 scatter,
        PlagueWaterVolumeInterval interval) {
    return plagueWaterVolumeFinite(scatter)
            && scatter.a > 0.0
            && abs(scatter.a - interval.revision)
                    <= PLAGUE_WATER_RECONSTRUCTION_REVISION_TOLERANCE;
}

// The interval root imports this file with no lighting dependencies; the march root pulls in the
// source evaluator separately, after globals/light tables/water waves exist.

#endif
