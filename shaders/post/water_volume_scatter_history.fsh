#version 330

// Reconstructs the noisy half-resolution scatter field against the finite water interval. History
// is attached to the moving water boundary, never to opaque depth or general scene motion.
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_volume.glsl>

uniform sampler2D u_Input0; // waterVolumeScatterRaw
uniform sampler2D u_Input1; // waterVolumeScatter.history
uniform sampler2D u_Input2; // waterVolumeInterval
uniform sampler2D u_Input3; // waterVolumeInterval.history

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="Balanced" 2="High"}
#moj_import <fornax_runtime:water_options.glsl>

// Spatial tolerances are deliberately wider than temporal tolerances: neighboring half-resolution
// rays may cross the same sloped boundary at different distances, while a reprojected history tap
// is expected to describe the same boundary point. All distances are in blocks.
const float PLAGUE_WATER_SPATIAL_ENTRY_TOLERANCE = 1.00;
const float PLAGUE_WATER_SPATIAL_EXIT_TOLERANCE = 2.00;
const float PLAGUE_WATER_SPATIAL_NORMAL_DOT_MIN = 0.85;
const float PLAGUE_WATER_HISTORY_ENTRY_TOLERANCE = 0.75;
const float PLAGUE_WATER_HISTORY_EXIT_TOLERANCE = 1.25;
const float PLAGUE_WATER_HISTORY_NORMAL_DOT_MIN = 0.90;
const float PLAGUE_WATER_REVISION_TOLERANCE = 0.125;
// No global cut bit exists. A translation this large is conservatively a teleport, while ordinary
// projection/UV and interval agreement remain the authoritative per-pixel disocclusion tests.
const float PLAGUE_WATER_CAMERA_CUT_DISTANCE = 64.0;
const float PLAGUE_WATER_RECONSTRUCTION_EPSILON = 1e-5;
const int PLAGUE_DEBUG_WATER_SHAFT_INTERVAL = 64;
const int PLAGUE_DEBUG_WATER_SHAFT_REFRACTIVE_FOCUS = 65;
const int PLAGUE_DEBUG_WATER_SHAFT_SHADOW_VISIBILITY = 66;
const int PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER = 67;

in vec2 texCoord;
out vec4 fragColor;

bool plagueWaterShaftDebugActive(int debugView) {
    return debugView >= PLAGUE_DEBUG_WATER_SHAFT_INTERVAL
            && debugView <= PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER;
}

bool plagueWaterScatterFinite(vec2 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterScatterFinite(vec3 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterScatterFinite(vec4 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterScatterRawValid(
        vec4 raw,
        PlagueWaterVolumeInterval interval) {
    return !any(isnan(raw)) && !any(isinf(raw))
            && raw.a > 0.0
            && abs(raw.a - interval.revision) <= PLAGUE_WATER_REVISION_TOLERANCE;
}

float plagueWaterScatterIntervalAgreement(
        PlagueWaterVolumeInterval center,
        PlagueWaterVolumeInterval candidate,
        float entryTolerance,
        float exitTolerance,
        float normalDotMin) {
    if (!center.valid || !candidate.valid
            || candidate.submerged != center.submerged
            || abs(candidate.revision - center.revision) > PLAGUE_WATER_REVISION_TOLERANCE) {
        return 0.0;
    }

    float entryDelta = abs(candidate.entryDistance - center.entryDistance);
    float exitDelta = abs(
            plagueWaterVolumeEffectiveExit(
                    candidate.exitDistance, u_WaterShaftDistance)
            - plagueWaterVolumeEffectiveExit(
                    center.exitDistance, u_WaterShaftDistance));
    float normalDot = clamp(
            dot(center.boundaryNormal, candidate.boundaryNormal), -1.0, 1.0);
    if (entryDelta > entryTolerance || exitDelta > exitTolerance
            || normalDot < normalDotMin) {
        return 0.0;
    }

    float entryAgreement = 1.0 - smoothstep(0.0, entryTolerance, entryDelta);
    float exitAgreement = 1.0 - smoothstep(0.0, exitTolerance, exitDelta);
    float normalAgreement = smoothstep(normalDotMin, 1.0, normalDot);
    return entryAgreement * exitAgreement * normalAgreement;
}

bool plagueWaterScatterHistoryFootprint(
        vec2 previousUv,
        PlagueWaterVolumeInterval currentInterval,
        out vec3 historyRgb,
        out float historyConfidence) {
    historyRgb = vec3(0.0);
    historyConfidence = 0.0;

    ivec2 previousSize = textureSize(u_Input3, 0);
    if (any(lessThanEqual(previousSize, ivec2(0)))
            || any(notEqual(textureSize(u_Input1, 0), previousSize))) {
        return false;
    }

    vec2 texelPosition = previousUv * vec2(previousSize) - vec2(0.5);
    ivec2 baseTexel = ivec2(floor(texelPosition));
    vec2 bilinearBlend = fract(texelPosition);
    vec3 weightedHistory = vec3(0.0);

    for (int y = 0; y <= 1; y++) {
        float yWeight = y == 0 ? 1.0 - bilinearBlend.y : bilinearBlend.y;
        for (int x = 0; x <= 1; x++) {
            float xWeight = x == 0 ? 1.0 - bilinearBlend.x : bilinearBlend.x;
            float bilinearWeight = xWeight * yWeight;
            if (bilinearWeight <= 0.0) {
                continue;
            }

            ivec2 sampleCoord = clamp(baseTexel + ivec2(x, y), ivec2(0),
                    previousSize - ivec2(1));
            PlagueWaterVolumeInterval sampleInterval = plagueDecodeWaterVolumeInterval(
                    texelFetch(u_Input3, sampleCoord, 0));
            if (!sampleInterval.valid) {
                continue;
            }
            float intervalAgreement = plagueWaterScatterIntervalAgreement(
                    currentInterval, sampleInterval,
                    PLAGUE_WATER_HISTORY_ENTRY_TOLERANCE,
                    PLAGUE_WATER_HISTORY_EXIT_TOLERANCE,
                    PLAGUE_WATER_HISTORY_NORMAL_DOT_MIN);
            vec4 sampleHistory = texelFetch(u_Input1, sampleCoord, 0);
            if (intervalAgreement <= 0.0
                    || !plagueWaterScatterRawValid(sampleHistory, sampleInterval)) {
                continue;
            }

            float compatibleWeight = bilinearWeight * intervalAgreement;
            weightedHistory += sampleHistory.rgb * compatibleWeight;
            historyConfidence += compatibleWeight;
        }
    }

    if (historyConfidence <= PLAGUE_WATER_RECONSTRUCTION_EPSILON
            || isnan(historyConfidence) || isinf(historyConfidence)) {
        return false;
    }
    historyRgb = weightedHistory / historyConfidence;
    return plagueWaterScatterFinite(historyRgb);
}

vec3 plagueWaterScatterViewDirection() {
    vec4 world = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, 0.0001, 1.0);
    if (!plagueWaterScatterFinite(world) || abs(world.w) < 1e-6) {
        return vec3(0.0);
    }
    vec3 ray = world.xyz / world.w;
    float rayLengthSquared = dot(ray, ray);
    return rayLengthSquared > 1e-8 && plagueWaterScatterFinite(ray)
            ? ray * inversesqrt(rayLengthSquared) : vec3(0.0);
}

void main() {
    fragColor = vec4(0.0);

#if PLAGUE_UNDERWATER && WATER_SCATTERING_QUALITY != 0
    ivec2 currentSize = textureSize(u_Input2, 0);
    if (any(lessThanEqual(currentSize, ivec2(0)))
            || any(notEqual(textureSize(u_Input0, 0), currentSize))) {
        return;
    }
    ivec2 currentCoord = clamp(
            ivec2(gl_FragCoord.xy), ivec2(0), currentSize - ivec2(1));
    PlagueWaterVolumeInterval currentInterval = plagueDecodeWaterVolumeInterval(
            texelFetch(u_Input2, currentCoord, 0));
    if (!currentInterval.valid) {
        fragColor = vec4(0.0);
        return;
    }
    // The raw target carries display-ready diagnostics while a shaft view is selected. Never feed
    // those colors into temporal history; keep a valid zero-scatter sample so returning to Off is
    // clean on the next frame instead of fading stale debug colors through the water.
    if (plagueWaterShaftDebugActive(int(u_Param3 + 0.5))) {
        fragColor = vec4(vec3(0.0), currentInterval.revision);
        return;
    }

    vec4 centerRaw = texelFetch(u_Input0, currentCoord, 0);
    bool centerRawValid = plagueWaterScatterRawValid(centerRaw, currentInterval);
    vec3 currentScatter = centerRawValid ? centerRaw.rgb : vec3(0.0);
    vec3 filteredScatter = vec3(0.0);
    float filteredWeight = 0.0;
    vec3 currentMin = vec3(1e30);
    vec3 currentMax = vec3(-1e30);
    bool haveCurrentBounds = false;

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(float(x), float(y));
            ivec2 sampleCoord = clamp(
                    currentCoord + ivec2(x, y), ivec2(0), currentSize - ivec2(1));
            PlagueWaterVolumeInterval sampleInterval = plagueDecodeWaterVolumeInterval(
                    texelFetch(u_Input2, sampleCoord, 0));
            vec4 sampleRaw = texelFetch(u_Input0, sampleCoord, 0);
            float intervalAgreement = plagueWaterScatterIntervalAgreement(
                    currentInterval, sampleInterval,
                    PLAGUE_WATER_SPATIAL_ENTRY_TOLERANCE,
                    PLAGUE_WATER_SPATIAL_EXIT_TOLERANCE,
                    PLAGUE_WATER_SPATIAL_NORMAL_DOT_MIN);
            if (intervalAgreement <= 0.0
                    || !plagueWaterScatterRawValid(sampleRaw, sampleInterval)) {
                continue;
            }

            float pixelWeight = 1.0 / (1.0 + length(offset));
            float weight = pixelWeight * intervalAgreement;
            filteredScatter += sampleRaw.rgb * weight;
            filteredWeight += weight;
            currentMin = min(currentMin, sampleRaw.rgb);
            currentMax = max(currentMax, sampleRaw.rgb);
            haveCurrentBounds = true;
        }
    }
    if (filteredWeight > PLAGUE_WATER_RECONSTRUCTION_EPSILON) {
        currentScatter = filteredScatter / filteredWeight;
    }

    vec3 viewDirection = plagueWaterScatterViewDirection();
    float boundaryDistance = currentInterval.submerged
            ? plagueWaterVolumeEffectiveExit(
                    currentInterval.exitDistance, u_WaterShaftDistance)
            : currentInterval.entryDistance;
    vec3 anchorNow = viewDirection * boundaryDistance;
    bool validHistory = haveCurrentBounds
            && dot(viewDirection, viewDirection) > 1e-8
            && plagueWaterScatterFinite(u_CameraDelta.xyz)
            && length(u_CameraDelta.xyz) <= PLAGUE_WATER_CAMERA_CUT_DISTANCE;

    vec4 prevClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix
            * vec4(anchorNow + u_CameraDelta.xyz, 1.0);
    validHistory = validHistory && plagueWaterScatterFinite(prevClip) && prevClip.w > 1e-6;
    vec2 previousUv = texCoord;
    if (validHistory) {
        vec2 previousNdc = prevClip.xy / prevClip.w;
        vec2 motion = ((texCoord * 2.0 - 1.0 - u_JitterOffset)
                - (previousNdc - u_PrevJitterOffset)) * 0.5;
        previousUv = texCoord - motion;
        validHistory = plagueWaterScatterFinite(previousUv)
                && previousUv.x >= 0.0 && previousUv.x <= 1.0
                && previousUv.y >= 0.0 && previousUv.y <= 1.0;
    }

    vec3 historyRgb = vec3(0.0);
    float historyConfidence = 0.0;
    if (validHistory) {
        validHistory = plagueWaterScatterHistoryFootprint(
                previousUv, currentInterval, historyRgb, historyConfidence);
    }

    vec3 resolvedScatter = currentScatter;
    if (validHistory) {
        vec3 clippedHistory = clamp(historyRgb, currentMin, currentMax);
        float historyLimit = clamp(u_WaterShaftPersistence, 0.0, 0.9);
        float historyWeight = clamp(
                historyLimit * historyConfidence, 0.0, historyLimit);
        resolvedScatter = mix(currentScatter, clippedHistory, historyWeight);
    }
    if (!plagueWaterScatterFinite(resolvedScatter)) {
        resolvedScatter = currentScatter;
    }
    fragColor = vec4(resolvedScatter, currentInterval.revision);
#endif
}
