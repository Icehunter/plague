#ifndef PLAGUE_WATER_REFLECTION
#define PLAGUE_WATER_REFLECTION

// Surface-response values carried through builtin.waterNormal. The target remains RGBA16_SNORM:
// RGB direction stores normal direction and reflection width together, while alpha keeps the
// existing signed rain/skylight flags unchanged.
const float PLAGUE_WATER_MIN_ROUGHNESS = 0.018;
const float PLAGUE_WATER_MAX_ROUGHNESS = 0.32;
const float PLAGUE_WATER_ENV_MAX_LOD = 7.0;

vec3 plagueSafeWaterNormal(vec3 normal) {
    float lengthSquared = dot(normal, normal);
    return lengthSquared > 1e-8
            ? normal * inversesqrt(lengthSquared)
            : vec3(0.0, 1.0, 0.0);
}

vec4 plagueEncodeWaterReflectionSurface(vec3 normal, float roughness, float signedFlags) {
    vec3 unitNormal = plagueSafeWaterNormal(normal);
    float encodedRoughness = clamp(roughness,
            PLAGUE_WATER_MIN_ROUGHNESS, PLAGUE_WATER_MAX_ROUGHNESS);
    return vec4(unitNormal * (1.0 - encodedRoughness), signedFlags);
}

void plagueDecodeWaterReflectionSurface(vec4 encoded, out vec3 normal,
                                         out float roughness, out float signedFlags) {
    float encodedLength = length(encoded.rgb);
    normal = encodedLength > 1e-8
            ? encoded.rgb / encodedLength
            : vec3(0.0, 1.0, 0.0);
    roughness = clamp(1.0 - encodedLength,
            PLAGUE_WATER_MIN_ROUGHNESS, PLAGUE_WATER_MAX_ROUGHNESS);
    signedFlags = encoded.a;
}

float plagueWaterRoughnessFromSlopeVariance(float slopeVariance) {
    return clamp(sqrt(max(slopeVariance, 0.0)),
            PLAGUE_WATER_MIN_ROUGHNESS, PLAGUE_WATER_MAX_ROUGHNESS);
}

vec2 plagueWaterEnvironmentUv(vec3 direction, vec3 sunDirection, vec3 upDirection) {
    vec3 unitDirection = plagueSafeWaterNormal(direction);
    vec3 unitSun = plagueSafeWaterNormal(sunDirection);
    vec3 unitUp = plagueSafeWaterNormal(upDirection);
    float sunDot = dot(unitDirection, unitSun);
    float upDot = dot(unitDirection, unitUp);
    return clamp(vec2(sunDot, upDot) * 0.5 + 0.5, 0.0, 1.0);
}

float plagueWaterEnvironmentLod(float roughness) {
    float range = PLAGUE_WATER_MAX_ROUGHNESS - PLAGUE_WATER_MIN_ROUGHNESS;
    float normalizedRoughness = clamp(
            (roughness - PLAGUE_WATER_MIN_ROUGHNESS) / max(range, 1e-6), 0.0, 1.0);
    return normalizedRoughness * PLAGUE_WATER_ENV_MAX_LOD;
}

#endif
