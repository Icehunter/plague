#version 330

// Produces a finite camera-ray interval through water.  Every pixel writes an ABI value, including
// the invalid identity, because this half-resolution target owns history.
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_volume.glsl>

uniform sampler2D u_Input0; // builtin.depth      : opaque reversed-Z
uniform sampler2D u_Input1; // builtin.waterDepth : water-surface reversed-Z
uniform sampler2D u_Input2; // builtin.waterNormal: xyz normal, a signed water flags

// This root does not import underwater.glsl, so it declares the compile options it evaluates.
#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="Balanced" 2="High"}
#moj_import <fornax_runtime:water_options.glsl>

in vec2 texCoord;
out vec4 fragColor;

bool plagueWaterIntervalFinite(float value) {
    return !isnan(value) && !isinf(value);
}

bool plagueWaterIntervalFinite(vec2 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterIntervalFinite(vec3 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

ivec2 plagueWaterIntervalSourceCoord(sampler2D sourceTexture) {
    ivec2 sourceSize = textureSize(sourceTexture, 0);
    return clamp(ivec2(texCoord * vec2(sourceSize)), ivec2(0), sourceSize - ivec2(1));
}

bool plagueWaterIntervalWorldPosAt(vec2 uv, float depth, out vec3 worldPos) {
    worldPos = vec3(0.0);
    if (!plagueWaterIntervalFinite(uv) || !plagueWaterIntervalFinite(depth) || depth <= 0.0
            || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return false;
    }
    vec4 world = u_InvProjModelView * vec4(uv * 2.0 - 1.0, depth, 1.0);
    if (any(isnan(world)) || any(isinf(world)) || abs(world.w) < 1e-6) {
        return false;
    }
    worldPos = world.xyz / world.w;
    return plagueWaterIntervalFinite(worldPos);
}

bool plagueWaterIntervalDistanceAt(vec2 uv, float depth, out float distanceToPoint) {
    distanceToPoint = 0.0;
    vec3 worldPos;
    if (!plagueWaterIntervalWorldPosAt(uv, depth, worldPos)) {
        return false;
    }
    distanceToPoint = length(worldPos);
    return plagueWaterIntervalFinite(distanceToPoint) && distanceToPoint >= 0.0;
}

void main() {
    PlagueWaterVolumeInterval interval;
    interval.entryDistance = 0.0;
    interval.exitDistance = 0.0;
    interval.boundaryNormal = vec3(0.0, 1.0, 0.0);
    interval.revision = PLAGUE_WATER_MEDIUM_REVISION;
    interval.submerged = false;
    interval.valid = false;

#if PLAGUE_UNDERWATER && WATER_SCATTERING_QUALITY != 0
    if (!plagueWaterIntervalFinite(texCoord)) {
        fragColor = plagueEncodeWaterVolumeIntervalFailure(
                PLAGUE_WATER_INTERVAL_FAILURE_INPUT);
        return;
    }

    // texelFetch, not a filtered sample: at half resolution a filtered read between four
    // full-resolution texels can synthesize a nonexistent water/opaque state.
    float opaqueDepth = texelFetch(
            u_Input0, plagueWaterIntervalSourceCoord(u_Input0), 0).r;
    float waterDepth = texelFetch(
            u_Input1, plagueWaterIntervalSourceCoord(u_Input1), 0).r;
    vec4 waterNormalSample = texelFetch(
            u_Input2, plagueWaterIntervalSourceCoord(u_Input2), 0);
    if (!plagueWaterIntervalFinite(opaqueDepth) || !plagueWaterIntervalFinite(waterDepth)
            || any(isnan(waterNormalSample)) || any(isinf(waterNormalSample))
            || !plagueWaterIntervalFinite(u_WaterState.x)
            || !plagueWaterIntervalFinite(u_WaterClarity)) {
        fragColor = plagueEncodeWaterVolumeIntervalFailure(
                PLAGUE_WATER_INTERVAL_FAILURE_INPUT);
        return;
    }

    bool opaquePresent = opaqueDepth > 0.0;
    bool waterSurface = waterDepth > 0.0 && abs(waterNormalSample.a) >= 0.5;
    // Reversed-Z: opaque wins a tie, matching the surface composite's occlusion rule.
    bool visibleWaterSurface = waterSurface && (!opaquePresent || opaqueDepth < waterDepth);
    vec3 boundaryNormal = plagueWaterVolumeSafeNormal(waterNormalSample.xyz);
    vec3 sigmaT = plagueWaterSigmaT(u_WaterClarity);
    vec3 opticalDistance = plagueWaterOpticalDistance(sigmaT, PLAGUE_WATER_INTERVAL_EPSILON);
    float opticalEnd = max(max(opticalDistance.x, opticalDistance.y), opticalDistance.z);
    if (!plagueWaterIntervalFinite(opticalDistance) || !plagueWaterIntervalFinite(opticalEnd)
            || opticalEnd <= PLAGUE_WATER_INTERVAL_EPSILON) {
        fragColor = plagueEncodeWaterVolumeIntervalFailure(
                PLAGUE_WATER_INTERVAL_FAILURE_OPTICAL);
        return;
    }

    if (u_WaterState.x > 0.5) {
        interval.submerged = true;
        interval.entryDistance = 0.0;
        float surfaceExit = 1e20;
        float opaqueExit = 1e20;
        bool surfaceDistanceValid = visibleWaterSurface
                && plagueWaterIntervalDistanceAt(texCoord, waterDepth, surfaceExit);
        bool opaqueDistanceValid = opaquePresent
                && plagueWaterIntervalDistanceAt(texCoord, opaqueDepth, opaqueExit);
        if (!surfaceDistanceValid && visibleWaterSurface) {
            fragColor = plagueEncodeWaterVolumeIntervalFailure(
                    PLAGUE_WATER_INTERVAL_FAILURE_SURFACE_DISTANCE);
            return;
        }
        if (!opaqueDistanceValid && opaquePresent) {
            fragColor = plagueEncodeWaterVolumeIntervalFailure(
                    PLAGUE_WATER_INTERVAL_FAILURE_OPAQUE_DISTANCE);
            return;
        }
        interval.exitDistance = min(opticalEnd, min(surfaceExit, opaqueExit));
        interval.boundaryNormal = boundaryNormal;
        interval.valid = interval.exitDistance > interval.entryDistance + PLAGUE_WATER_INTERVAL_EPSILON;
    } else if (visibleWaterSurface) {
        if (!plagueWaterIntervalDistanceAt(texCoord, waterDepth, interval.entryDistance)) {
            fragColor = plagueEncodeWaterVolumeIntervalFailure(
                    PLAGUE_WATER_INTERVAL_FAILURE_ENTRY_DISTANCE);
            return;
        }
        float opaqueExit = 1e20;
        if (opaquePresent && !plagueWaterIntervalDistanceAt(texCoord, opaqueDepth, opaqueExit)) {
            fragColor = plagueEncodeWaterVolumeIntervalFailure(
                    PLAGUE_WATER_INTERVAL_FAILURE_OPAQUE_DISTANCE);
            return;
        }
        interval.exitDistance = min(interval.entryDistance + opticalEnd, opaqueExit);
        interval.boundaryNormal = boundaryNormal;
        interval.valid = interval.exitDistance > interval.entryDistance + PLAGUE_WATER_INTERVAL_EPSILON;
    }
#endif

    fragColor = interval.valid
            ? plagueEncodeWaterVolumeInterval(interval)
            : plagueEncodeWaterVolumeIntervalFailure(PLAGUE_WATER_INTERVAL_FAILURE_EMPTY);
}
