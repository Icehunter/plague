#version 330

// Adds direct celestial single-scatter to the accepted submerged scene after refraction and before
// the existing underwater blur/bloom. Unsupported pixels preserve the refracted scene exactly.
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_volume.glsl>

uniform sampler2D u_Input0; // sceneHdrRefractedTransport
uniform sampler2D u_Input1; // waterVolumeScatter
uniform sampler2D u_Input2; // waterVolumeInterval
uniform sampler2D u_Input3; // builtin.depth
uniform sampler2D u_Input4; // builtin.waterDepth
uniform sampler2D u_Input5; // builtin.waterNormal

#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="Balanced" 2="High"}
#moj_import <fornax_runtime:water_options.glsl>

in vec2 texCoord;
out vec4 fragColor;

bool plagueWaterSubmergedWorldPositionAt(
        vec2 uv,
        float depth,
        out vec3 worldPosition) {
    worldPosition = vec3(0.0);
    if (!plagueWaterVolumeFinite(uv) || !plagueWaterVolumeFinite(depth) || depth <= 0.0
            || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return false;
    }
    vec4 world = u_InvProjModelView * vec4(uv * 2.0 - 1.0, depth, 1.0);
    if (!plagueWaterVolumeFinite(world) || abs(world.w) < 1e-6) {
        return false;
    }
    worldPosition = world.xyz / world.w;
    return plagueWaterVolumeFinite(worldPosition);
}

bool plagueWaterSubmergedDistanceAt(
        vec2 uv,
        float depth,
        out float distanceToPoint) {
    distanceToPoint = 0.0;
    vec3 worldPosition;
    if (!plagueWaterSubmergedWorldPositionAt(uv, depth, worldPosition)) {
        return false;
    }
    distanceToPoint = length(worldPosition);
    return plagueWaterVolumeFinite(distanceToPoint) && distanceToPoint >= 0.0;
}

bool plagueWaterSubmergedFullInterval(
        out PlagueWaterVolumeInterval fullInterval) {
    fullInterval.entryDistance = 0.0;
    fullInterval.exitDistance = 0.0;
    fullInterval.boundaryNormal = vec3(0.0, 1.0, 0.0);
    fullInterval.revision = PLAGUE_WATER_MEDIUM_REVISION;
    fullInterval.submerged = true;
    fullInterval.valid = false;

    if (!plagueWaterVolumeFinite(texCoord) || !plagueWaterVolumeFinite(u_WaterState.x)
            || !plagueWaterVolumeFinite(u_WaterClarity) || u_WaterState.x <= 0.5) {
        return false;
    }

    ivec2 opaqueSize = textureSize(u_Input3, 0);
    ivec2 waterSize = textureSize(u_Input4, 0);
    ivec2 normalSize = textureSize(u_Input5, 0);
    ivec2 opaqueCoord = clamp(
            ivec2(gl_FragCoord.xy), ivec2(0), opaqueSize - ivec2(1));
    ivec2 waterCoord = clamp(
            ivec2(gl_FragCoord.xy), ivec2(0), waterSize - ivec2(1));
    ivec2 normalCoord = clamp(
            ivec2(gl_FragCoord.xy), ivec2(0), normalSize - ivec2(1));
    float opaqueDepth = texelFetch(u_Input3, opaqueCoord, 0).r;
    float waterDepth = texelFetch(u_Input4, waterCoord, 0).r;
    vec4 waterNormalSample = texelFetch(u_Input5, normalCoord, 0);
    if (!plagueWaterVolumeFinite(opaqueDepth) || !plagueWaterVolumeFinite(waterDepth)
            || !plagueWaterVolumeFinite(waterNormalSample)) {
        return false;
    }

    bool opaquePresent = opaqueDepth > 0.0;
    bool waterSurface = waterDepth > 0.0 && abs(waterNormalSample.a) >= 0.5;
    // Reversed-Z: an opaque sample wins equal depth, matching interval generation and the interface.
    bool visibleWaterSurface = waterSurface && (!opaquePresent || opaqueDepth < waterDepth);

    vec3 sigmaT = plagueWaterSigmaT(u_WaterClarity);
    vec3 opticalDistance = plagueWaterOpticalDistance(
            sigmaT, PLAGUE_WATER_INTERVAL_EPSILON);
    float opticalEnd = max(max(opticalDistance.x, opticalDistance.y), opticalDistance.z);
    if (!plagueWaterVolumeFinite(opticalDistance) || !plagueWaterVolumeFinite(opticalEnd)
            || opticalEnd <= PLAGUE_WATER_INTERVAL_EPSILON) {
        return false;
    }

    float surfaceExit = 1e20;
    if (visibleWaterSurface
            && !plagueWaterSubmergedDistanceAt(texCoord, waterDepth, surfaceExit)) {
        return false;
    }
    float opaqueExit = 1e20;
    if (opaquePresent
            && !plagueWaterSubmergedDistanceAt(texCoord, opaqueDepth, opaqueExit)) {
        return false;
    }
    if (!plagueWaterVolumeFinite(surfaceExit) || !plagueWaterVolumeFinite(opaqueExit)) {
        return false;
    }

    fullInterval.exitDistance = min(opticalEnd, min(surfaceExit, opaqueExit));
    fullInterval.boundaryNormal = plagueWaterVolumeSafeNormal(waterNormalSample.xyz);
    fullInterval.valid = plagueWaterVolumeFinite(fullInterval.exitDistance)
            && fullInterval.exitDistance
                    > fullInterval.entryDistance + PLAGUE_WATER_INTERVAL_EPSILON;
    return fullInterval.valid;
}

bool plagueWaterSubmergedUpsample(
        PlagueWaterVolumeInterval fullInterval,
        out vec3 scatter) {
    // The shared agreement/validity helpers own all five ABI thresholds:
    // PLAGUE_WATER_RECONSTRUCTION_ENTRY_TOLERANCE,
    // PLAGUE_WATER_RECONSTRUCTION_EXIT_TOLERANCE,
    // PLAGUE_WATER_RECONSTRUCTION_NORMAL_DOT_MIN,
    // PLAGUE_WATER_RECONSTRUCTION_REVISION_TOLERANCE, and
    // PLAGUE_WATER_RECONSTRUCTION_WEIGHT_EPSILON.
    scatter = vec3(0.0);
    ivec2 halfSize = textureSize(u_Input2, 0);
    if (any(lessThanEqual(halfSize, ivec2(0)))
            || any(notEqual(textureSize(u_Input1, 0), halfSize))) {
        return false;
    }

    vec2 texelPosition = texCoord * vec2(halfSize) - vec2(0.5);
    ivec2 baseTexel = ivec2(floor(texelPosition));
    vec2 bilinearBlend = fract(texelPosition);
    vec3 weightedScatter = vec3(0.0);
    float compatibleWeightSum = 0.0;

    for (int y = 0; y <= 1; y++) {
        float yWeight = y == 0 ? 1.0 - bilinearBlend.y : bilinearBlend.y;
        for (int x = 0; x <= 1; x++) {
            float xWeight = x == 0 ? 1.0 - bilinearBlend.x : bilinearBlend.x;
            float bilinearWeight = xWeight * yWeight;
            if (bilinearWeight <= 0.0) {
                continue;
            }

            ivec2 sampleCoord = clamp(baseTexel + ivec2(x, y), ivec2(0),
                    halfSize - ivec2(1));
            PlagueWaterVolumeInterval sampleInterval = plagueDecodeWaterVolumeInterval(
                    texelFetch(u_Input2, sampleCoord, 0));
            vec4 sampleScatter = texelFetch(u_Input1, sampleCoord, 0);
            float intervalAgreement = plagueWaterVolumeReconstructionAgreement(
                    fullInterval, sampleInterval, u_WaterShaftDistance);
            if (intervalAgreement <= 0.0
                    || !plagueWaterVolumeScatterValid(sampleScatter, sampleInterval)) {
                continue;
            }

            float compatibleWeight = bilinearWeight * intervalAgreement;
            weightedScatter += sampleScatter.rgb * compatibleWeight;
            compatibleWeightSum += compatibleWeight;
        }
    }

    if (!plagueWaterVolumeFinite(compatibleWeightSum)
            || compatibleWeightSum <= PLAGUE_WATER_RECONSTRUCTION_WEIGHT_EPSILON) {
        return false;
    }
    scatter = weightedScatter / compatibleWeightSum;
    return plagueWaterVolumeFinite(scatter);
}

void main() {
    vec4 refractedScene = texture(u_Input0, texCoord);
    fragColor = refractedScene;

#if PLAGUE_UNDERWATER && WATER_SCATTERING_QUALITY != 0
    if (!plagueWaterVolumeFinite(refractedScene) || !plagueWaterVolumeFinite(texCoord)
            || !plagueWaterVolumeFinite(u_WaterState.x) || u_WaterState.x <= 0.5) {
        return;
    }

    PlagueWaterVolumeInterval fullInterval;
    if (!plagueWaterSubmergedFullInterval(fullInterval)) {
        return;
    }

    vec3 scatter;
    if (!plagueWaterSubmergedUpsample(fullInterval, scatter)) {
        return;
    }

    vec3 additiveShafts = refractedScene.rgb + scatter;
    if (!plagueWaterVolumeFinite(additiveShafts)) {
        return;
    }
    fragColor = vec4(refractedScene.rgb + scatter, refractedScene.a);
#endif
}
