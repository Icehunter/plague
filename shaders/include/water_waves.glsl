#ifndef PLAGUE_WATER_WAVES
#define PLAGUE_WATER_WAVES

// Iterative domain-warped sea: octave directions sweep the full circle by the golden angle (no
// wind-axis corrugation), each octave samples in a domain the earlier ones already dragged along
// their own slope (so nothing lines up into a lattice), the profile is exp(sin(x)-1) for sharp
// crests and broad troughs, and the wavelength ratio (1.18) is near unity for a dense spectrum.
// An earlier fixed-cone, constant-ratio field measured a 1.07-degree mean tilt and read as a flat
// plane with a diagonal grain rather than an isotropic sea.
//
// Phase speed is the deep-water dispersion relation sqrt(g*k) per octave, not a geometric ramp.

// How the swell's low-frequency bend samples the noise. The default is the plain filtered REPEAT
// fetch every graphics stage gets. A COMPUTE consumer must override it: Fornax binds an engine
// builtin to a compute pass with a NEAREST_CLAMP sampler, and this field is low enough frequency
// (one texel per ~2.5 blocks) that point sampling terraces the swell axis into visible steps.
#ifndef PLAGUE_WAVE_NOISE
#define PLAGUE_WAVE_NOISE(tex, uv) texture(tex, uv)
#endif

const float PLAGUE_WAVE_TAU = 6.28318530718;
const float PLAGUE_WAVE_INV_PI = 0.31830988618;
const float PLAGUE_WAVE_GRAVITY = 9.81;
const float PLAGUE_WAVE_GOLDEN = 0.61803398875;
// The golden ANGLE in radians. Successive octaves turn by this, which is the least-rational turn
// there is and therefore the one that clusters least over any octave count.
const float PLAGUE_WAVE_PHASE = 2.39996;
const float PLAGUE_WAVE_TURN_COS = -0.73736670;
const float PLAGUE_WAVE_TURN_SIN = 0.67549268;

// Dominant swell length in blocks at the two ends of the sea state. Growth stays modest since the
// slider's job is mostly roughness — stretching wavelength as fast as height cancels the extra slope.
const float PLAGUE_WAVE_MESH_MIN_LENGTH = 20.0;
const float PLAGUE_WAVE_MESH_MAX_LENGTH = 27.0;

// Octave schedule. Wavelength divides and weight multiplies by these every step.
const float PLAGUE_WAVE_FREQUENCY_GAIN = 1.18;
const float PLAGUE_WAVE_WEIGHT_GAIN = 0.88;

// How far one octave's slope pushes the sampling position for every later octave, as a fraction of
// the dominant wavelength. This is the single constant that separates an ocean from a plaid.
const float PLAGUE_WAVE_STEEPENING = 0.046;

// Mean of exp(sin(x) - 1) over a period, == I0(1)/e. Subtracted so a still lake sits at the mesh's
// own Y rather than above it.
const float PLAGUE_WAVE_PROFILE_MEAN = 0.46575961;
// Mean square of that profile's derivative, for the unresolved-slope estimate below.
const float PLAGUE_WAVE_PROFILE_SLOPE_VARIANCE = 0.10763464;

// Octaves the MESH may carry. Water quads are one block across and there is no tessellation stage,
// so the shortest displaced wavelength must stay well above the two-block Nyquist limit: nine
// octaves bottom out at 20/1.18^8 = 5.3 blocks at the calmest state and 8.0 at the roughest.
const int PLAGUE_WAVE_MESH_OCTAVES = 9;
// Shading octave counts near/far. The tail the distance fade drops isn't discarded:
// plagueWaveUnresolvedSlopeVariance turns it into reflection roughness instead.
const int PLAGUE_WAVE_SHADING_OCTAVES = 22;
const int PLAGUE_WAVE_DISTANT_OCTAVES = 10;

// Summed weight of the full shading series. Normalising by the weight actually evaluated instead
// would make distant water grow taller as it lost octaves.
const float PLAGUE_WAVE_WEIGHT_NORM = 7.8327948;

// Nominal spectrum height in blocks, before the sea-state scalar. Not the on-screen wave height —
// the normalised sum only reaches a fraction of this, recorded in the RMS constant below.
const float PLAGUE_WAVE_HEIGHT_CALM = 1.30;
const float PLAGUE_WAVE_HEIGHT_ROUGH = 1.52;

// RMS of the normalised sum per unit of amplitude, and how far a fully developed trough is pulled
// back toward the mean. Measured against the shipped octave schedule by tools/verify_water_waves.py.
const float PLAGUE_WAVE_HEIGHT_RMS = 0.075;
const float PLAGUE_WAVE_TROUGH_FLATTEN = 0.72;

const float PLAGUE_WAVE_DISPLACEMENT_LIMIT = 0.78;

float plagueWaveSeaState(float strength) {
    return clamp(strength, 0.0, 2.0);
}

float plagueWaveSeaMix(float strength) {
    float x = plagueWaveSeaState(strength) * 0.5;
    return x * x * (3.0 - 2.0 * x);
}

float plagueWaveDominantLength(float strength) {
    return mix(PLAGUE_WAVE_MESH_MIN_LENGTH, PLAGUE_WAVE_MESH_MAX_LENGTH,
            plagueWaveSeaMix(strength));
}

// Height of the whole spectrum in blocks at the given sea state, before the soft ceiling.
float plagueWaveMeshScale(float strength) {
    float sea = plagueWaveSeaState(strength);
    return sea * mix(PLAGUE_WAVE_HEIGHT_CALM, PLAGUE_WAVE_HEIGHT_ROUGH,
            plagueWaveSeaMix(strength));
}

// Travel direction of one octave. Turning by the golden angle every step is what removes the wind
// axis: bands 0..11 land within 15 degrees of a uniform fan around the full circle.
vec2 plagueWaveDirection(int octave) {
    float angle = float(octave) * PLAGUE_WAVE_PHASE;
    return vec2(sin(angle), cos(angle));
}

// Fixed rotation by the golden angle, applied iteratively instead of recomputing sin/cos per octave
// (this is the hottest shader in the pack).
vec2 plagueWaveTurn(vec2 direction) {
    return vec2(direction.x * PLAGUE_WAVE_TURN_COS + direction.y * PLAGUE_WAVE_TURN_SIN,
                direction.y * PLAGUE_WAVE_TURN_COS - direction.x * PLAGUE_WAVE_TURN_SIN);
}

// World Y is folded in so a waterfall face still animates. A very-low-frequency bend lets the swell
// axis wander over a few hundred blocks rather than holding one heading to the horizon; the
// per-octave drag in plagueWaveSpectrum does the rest of the decorrelation work.
vec2 plagueWavePosition(sampler2D noiseTex, vec3 worldAbs, float time,
                        float dominantLength) {
    vec2 pos = worldAbs.xz + worldAbs.y * PLAGUE_WAVE_INV_PI;
    float bendScale = 1.0 / max(dominantLength * 64.0, 1.0);
    vec2 uv = (pos - vec2(0.34, 0.72) * time * 0.35) * bendScale;
    vec2 bend = PLAGUE_WAVE_NOISE(noiseTex, uv).rg * 2.0 - 1.0;
    return pos + bend * dominantLength * 0.05;
}

// One octave: its height contribution (x), the first derivative of its profile with respect to phase
// (y) which the slope accumulator and the drag both need, and the second derivative (z), which is
// what lets the drag warp be differentiated rather than assumed away.
//
//   f(p)   = exp(sin p - 1)
//   f'(p)  = f cos p
//   f''(p) = f (cos^2 p - sin p)
vec3 plagueWaveBand(vec2 pos, float time, vec2 dir, float wavelength) {
    float k = PLAGUE_WAVE_TAU / max(wavelength, 1e-4);
    // Deep-water dispersion. A 25-block swell takes four seconds to pass; a 1-block ripple takes
    // four fifths of one. Nothing here is tuned to make that true, it falls out of sqrt(g*k).
    float phase = k * dot(dir, pos) - sqrt(PLAGUE_WAVE_GRAVITY * k) * time;
    float profile = exp(sin(phase) - 1.0);
    float cosine = cos(phase);
    return vec3(profile, profile * cosine, profile * (cosine * cosine - sin(phase)));
}

// Flattens troughs without touching crests: summing a dozen octaves drifts back toward Gaussian,
// so the asymmetry is reasserted on the total. `slope` is corrected through the product rule so the
// shading normal stays registered to the reshaped height instead of drifting off it.
float plagueWaveCrestShape(float height, float amplitude, inout vec2 slope) {
    float edge = max(amplitude * PLAGUE_WAVE_HEIGHT_RMS * 1.2, 1e-4);
    float t = clamp(-height / edge, 0.0, 1.0);
    float trough = t * t * (3.0 - 2.0 * t);
    float scale = mix(1.0, PLAGUE_WAVE_TROUGH_FLATTEN, trough);
    // d(trough)/d(height) = -6t(1-t)/edge, and only while the smoothstep is inside its ramp.
    float dTrough = (t > 0.0 && t < 1.0) ? -6.0 * t * (1.0 - t) / edge : 0.0;
    slope *= scale + height * (PLAGUE_WAVE_TROUGH_FLATTEN - 1.0) * dTrough;
    return height * scale;
}

// The sea itself. `octaves` is fractional so the distance LOD slides instead of popping. `slope`
// receives d(height)/d(pos) analytically from the same loop, cheaper than finite-differencing a
// normal and exactly registered to the surface it describes.
float plagueWaveSpectrum(vec2 pos, float time, float dominantLength, float amplitude,
                         float octaves, out vec2 slope) {
    slope = vec2(0.0);
    if (amplitude <= 0.0 || octaves <= 0.0) {
        return 0.0;
    }

    float wavelength = dominantLength;
    float weight = 1.0;
    float drag = PLAGUE_WAVE_STEEPENING * dominantLength;
    float height = 0.0;
    float weightSum = 0.0;
    vec2 dir = plagueWaveDirection(0);
    int count = int(ceil(octaves));

    // Accumulated warp Jacobian d(pos_i)/d(pos_0), by columns. Octave i is evaluated wherever
    // octaves 0..i-1 pushed the domain to, so its gradient needs this chain-rule factor — treating
    // it as identity measured a median 3.4-degree shading-normal error on the steepest tenth of the
    // surface, concentrated on crests, where the specular highlight lands.
    vec2 warpColumn0 = vec2(1.0, 0.0);
    vec2 warpColumn1 = vec2(0.0, 1.0);

    for (int i = 0; i < count; i++) {
        float fade = min(octaves - float(i), 1.0);
        vec3 band = plagueWaveBand(pos, time, dir, wavelength);
        float w = weight * fade;
        float k = PLAGUE_WAVE_TAU / max(wavelength, 1e-4);

        // J^T * dir, which is both the direction this octave's gradient actually points in the
        // caller's frame and the row vector the Jacobian update needs. One dot product each way.
        vec2 warpedDir = vec2(dot(dir, warpColumn0), dot(dir, warpColumn1));

        height += band.x * w;
        slope += warpedDir * (band.y * w * k);
        weightSum += w;

        // J <- (I - c * dir * dir^T) * J, where c is d(drag displacement)/d(phase) * k.
        float c = w * drag * k * band.z;
        warpColumn0 -= dir * (c * warpedDir.x);
        warpColumn1 -= dir * (c * warpedDir.y);

        // Push the domain for later octaves; sign matches wave travel so they pile onto the
        // leading face of this crest, the same asymmetry a real swell steepens into.
        pos -= dir * (band.y * w * drag);

        weight *= PLAGUE_WAVE_WEIGHT_GAIN;
        wavelength /= PLAGUE_WAVE_FREQUENCY_GAIN;
        dir = plagueWaveTurn(dir);
    }

    float norm = amplitude / PLAGUE_WAVE_WEIGHT_NORM;
    slope *= norm;
    return plagueWaveCrestShape((height - PLAGUE_WAVE_PROFILE_MEAN * weightSum) * norm,
            amplitude, slope);
}

// How many octaves the shading may resolve at this distance. Squared so detail survives across the
// near field and only collapses once a wavelength is genuinely sub-pixel.
float plagueWaveShadingOctaves(float distFalloff) {
    float far = clamp(distFalloff, 0.0, 1.0);
    return mix(float(PLAGUE_WAVE_SHADING_OCTAVES), float(PLAGUE_WAVE_DISTANT_OCTAVES), far * far);
}

float plagueWaveMeshHeightAt(vec2 pos, float time, float strength) {
    vec2 slope;
    return plagueWaveSpectrum(pos, time, plagueWaveDominantLength(strength),
            plagueWaveMeshScale(strength), float(PLAGUE_WAVE_MESH_OCTAVES), slope);
}

float plagueWaveSurfaceHeight(sampler2D noiseTex, vec3 worldAbs, float time,
                              float distFalloff, float strength) {
    float dominantLength = plagueWaveDominantLength(strength);
    vec2 pos = plagueWavePosition(noiseTex, worldAbs, time, dominantLength);
    vec2 slope;
    return plagueWaveSpectrum(pos, time, dominantLength, plagueWaveMeshScale(strength),
            plagueWaveShadingOctaves(distFalloff), slope);
}

float plagueWaveHeight(sampler2D noiseTex, vec3 worldAbs, float time, float distFalloff) {
    return plagueWaveSurfaceHeight(noiseTex, worldAbs, time, distFalloff, 1.0);
}

float plagueWaveSoftDisplacement(float rawHeight) {
    float normalizedHeight = rawHeight / PLAGUE_WAVE_DISPLACEMENT_LIMIT;
    return rawHeight * inversesqrt(1.0 + normalizedHeight * normalizedHeight);
}

vec3 plagueWaveSurfaceDisplacement(sampler2D noiseTex, vec3 worldAbs, float time,
                                   float distFalloff, float strength) {
    float dominantLength = plagueWaveDominantLength(strength);
    vec2 pos = plagueWavePosition(noiseTex, worldAbs, time, dominantLength);
    float height = plagueWaveSoftDisplacement(plagueWaveMeshHeightAt(pos, time, strength));
    return vec3(0.0, height, 0.0);
}

// Returns the displaced height and its normal from one spectrum evaluation, so a caller needing
// both (the directional-light boundary solve) can't pair them from mismatched evaluations. The
// slope response is the exact derivative of plagueWaveSoftDisplacement, so the normal stays
// registered after the crest limiter.
void plagueWaveNormalAndDisplacement(
        sampler2D noiseTex,
        vec3 worldAbs,
        float time,
        float strength,
        out vec3 displacement,
        out vec3 normal) {
    if (strength <= 0.0) {
        displacement = vec3(0.0);
        normal = vec3(0.0, 1.0, 0.0);
        return;
    }

    float dominantLength = plagueWaveDominantLength(strength);
    vec2 pos = plagueWavePosition(noiseTex, worldAbs, time, dominantLength);
    vec2 rawSlope;
    float rawHeight = plagueWaveSpectrum(pos, time, dominantLength,
            plagueWaveMeshScale(strength), float(PLAGUE_WAVE_MESH_OCTAVES), rawSlope);
    float normalizedHeight = rawHeight / PLAGUE_WAVE_DISPLACEMENT_LIMIT;
    float limiterBase = 1.0 + normalizedHeight * normalizedHeight;
    float slopeResponse = inversesqrt(limiterBase * limiterBase * limiterBase);
    vec2 displacedSlope = rawSlope * slopeResponse;

    displacement = vec3(0.0, plagueWaveSoftDisplacement(rawHeight), 0.0);
    normal = normalize(vec3(-displacedSlope.x, 1.0, -displacedSlope.y));
}

float plagueWaveDisplacedHeight(float baseHeight, float strength, vec3 worldAbs) {
    return plagueWaveSoftDisplacement(baseHeight * plagueWaveSeaState(strength));
}

// No plagueWaveWhitecap: an open-water breaking-foam pass was tried and rejected — a per-fragment
// threshold on crest height/slope paints whole crest FACES as flat white slabs, because foam is a
// boundary phenomenon with its own advection, not a region a smooth field can threshold into.
// Shoreline foam works here because depth-to-bed genuinely is a region.

float plagueWaveLocalCalmness(vec3 worldAbs) {
    // Reserved for the shared water-body/depth field. Geometry and shading will consume the same
    // value when that field becomes available.
    return 1.0;
}

float plagueWaveEffectiveStrength(float strength, vec3 worldAbs) {
    return plagueWaveSeaState(strength) * plagueWaveLocalCalmness(worldAbs);
}

float plagueWavePlaybackRate(float strength) {
    float sea = plagueWaveSeaState(strength);
    float baseline = min(sea, 1.0);
    float storm = max(sea - 1.0, 0.0) / 9.0;
    return 0.5 * (baseline + storm * (1.225 - 0.225 * storm));
}

float plagueWaveAnimatedTime(float time, float strength, float speed) {
    return time * plagueWavePlaybackRate(strength) * max(speed, 0.0);
}

float plagueWaveNormalStrength(float strength, float distFalloff, vec3 worldAbs) {
    float far = clamp(distFalloff, 0.0, 1.0);
    return mix(1.0, 0.62, far * far);
}

// Slope variance of one octave that the pixel cannot resolve, whether because the distance LOD
// dropped it or because its wavelength has fallen inside the pixel footprint.
float plagueWaveBandUnresolvedVariance(float slope, float wavelength, float footprint,
                                       float dropped) {
    float aliased = smoothstep(0.20 * wavelength, 0.75 * wavelength, footprint);
    return PLAGUE_WAVE_PROFILE_SLOPE_VARIANCE * slope * slope * max(aliased, dropped);
}

// Widens the reflection lobe by exactly what the surface stopped carrying, or distant water turns
// into a mirror and then crawling shimmer. Sums the octaves the shading pass is not resolving.
float plagueWaveUnresolvedSlopeVariance(float strength, float footprint,
                                         float distFalloff, vec2 worldAbs) {
    float sea = plagueWaveSeaState(strength);
    if (sea <= 0.0) {
        return 0.0;
    }
    float far = clamp(distFalloff, 0.0, 1.0);
    float resolved = plagueWaveShadingOctaves(far);
    float wavelength = plagueWaveDominantLength(sea);
    float amplitude = plagueWaveMeshScale(sea) / PLAGUE_WAVE_WEIGHT_NORM;
    float weight = 1.0;
    float variance = 0.0;
    for (int i = 0; i < PLAGUE_WAVE_SHADING_OCTAVES; i++) {
        float slope = amplitude * weight * (PLAGUE_WAVE_TAU / wavelength);
        float dropped = 1.0 - clamp(resolved - float(i), 0.0, 1.0);
        variance += plagueWaveBandUnresolvedVariance(slope, wavelength, footprint, dropped);
        weight *= PLAGUE_WAVE_WEIGHT_GAIN;
        wavelength /= PLAGUE_WAVE_FREQUENCY_GAIN;
    }
    float response = plagueWaveNormalStrength(strength, far,
            vec3(worldAbs.x, 0.0, worldAbs.y));
    return max(variance * response * response, 0.0);
}

vec3 plagueWaveNormal(sampler2D noiseTex, vec3 worldAbs, float time, float distFalloff,
                      vec3 faceNormal, vec3 tangent, vec3 bitangent, float strength) {
    if (strength <= 0.0) {
        return faceNormal;
    }

    float far = clamp(distFalloff, 0.0, 1.0);
    float dominantLength = plagueWaveDominantLength(strength);
    vec2 pos = plagueWavePosition(noiseTex, worldAbs, time, dominantLength);
    vec2 slope;
    plagueWaveSpectrum(pos, time, dominantLength, plagueWaveMeshScale(strength),
            plagueWaveShadingOctaves(far), slope);

    // plagueWavePosition folds world Y into its sampling plane, so the plane-space gradient has to
    // be projected through that same fold to reach each face axis. On a flat +Y face this reduces
    // to tangent.xz and bitangent.xz; on a waterfall it is what keeps the flow reading downward.
    vec2 planeTangent = tangent.xz + tangent.y * PLAGUE_WAVE_INV_PI;
    vec2 planeBitangent = bitangent.xz + bitangent.y * PLAGUE_WAVE_INV_PI;
    // Displacement is along world +Y, not the face's own normal, so a downward-facing quad needs
    // both tangential terms negated or the bump on water spilling over a ledge comes out mirrored.
    float facing = faceNormal.y < 0.0 ? -1.0 : 1.0;
    vec3 displacedNormal = normalize(faceNormal
            - facing * tangent * dot(slope, planeTangent)
            - facing * bitangent * dot(slope, planeBitangent));
    float response = plagueWaveNormalStrength(strength, far, worldAbs);
    return normalize(mix(faceNormal, displacedNormal, response));
}

#endif
