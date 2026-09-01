#version 330

// Raw, half-resolution single-scattering integration over the finite raster water interval.
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:atmosphere.glsl>
#moj_import <fornax_runtime:main_lighting.glsl>
#moj_import <fornax_runtime:water_waves.glsl>
#moj_import <fornax_runtime:water_options.glsl>
#define PLAGUE_WATER_MESH_DISPLACEMENT 1 //[0 1] compile "Water Mesh Displacement" {0="Off" 1="Standard"}

uniform sampler2D u_Input0;       // waterVolumeInterval
uniform sampler2DShadow u_Input1; // sunShadowMap
uniform sampler2D u_Input2;       // builtin.noise

#moj_import <fornax_runtime:water_volume_source.glsl>

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4  u_SunDirection; // xyz active sun/moon direction; w true-sun elevation
};

#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="Balanced" 2="High"}
#define WATER_ABSORPTION_TINT 1 //[0 1] compile "Underwater Tint" {0="Off" 1="On"}

#if WATER_SCATTERING_QUALITY == 1
const int PLAGUE_WATER_VOLUME_CELLS = 8;
#else
const int PLAGUE_WATER_VOLUME_CELLS = 12;
#endif

in vec2 texCoord;
out vec4 fragColor;

// Stable Fornax debug ids. They deliberately do not equal these views' enum ordinals.
const int PLAGUE_DEBUG_WATER_SHAFT_INTERVAL = 64;
const int PLAGUE_DEBUG_WATER_SHAFT_REFRACTIVE_FOCUS = 65;
const int PLAGUE_DEBUG_WATER_SHAFT_SHADOW_VISIBILITY = 66;
const int PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER = 67;

bool plagueWaterShaftDebugActive(int debugView) {
    return debugView >= PLAGUE_DEBUG_WATER_SHAFT_INTERVAL
            && debugView <= PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER;
}

vec3 plagueWaterShaftTint() {
#if WATER_ABSORPTION_TINT
    // These are absolute authored display-space values, just like the standard underwater tint.
    // Convert them before multiplying linear HDR radiance, but never normalize against defaults:
    // changing any channel must change the corresponding single-scatter channel.
    return plagueAuthoredToLinear(
            vec3(u_WaterTintR, u_WaterTintG, u_WaterTintB) * 0.85);
#else
    return vec3(1.0);
#endif
}

bool plagueWaterShaftReasonIs(float encodedReason, float expectedReason) {
    // RGBA16F stores these eighth-step values exactly. The tolerance also makes the view readable
    // along half-resolution boundaries where the target's required linear filter mixes pixels.
    return abs(encodedReason - expectedReason) < 0.055;
}

vec3 plagueWaterShaftIntervalDebug(
        vec4 encodedInterval,
        PlagueWaterVolumeInterval interval,
        float waterState) {
    // Valid: green dry interval, cyan submerged interval.
    if (interval.valid) {
        return vec3(0.0, 1.0, interval.submerged ? 1.0 : 0.0);
    }

    if (any(isnan(encodedInterval)) || any(isinf(encodedInterval))) {
        return vec3(1.0); // non-finite value reached the stored ABI
    }

    float encodedRevision = floor(encodedInterval.a);
    float reason = fract(encodedInterval.a);
    // Producer failures live only in revision zero. A valid record also uses fractional alpha for
    // its octahedral normal, so interpreting the fraction without this integer guard produces false
    // reason colours—the first live diagnostic screenshot exposed exactly that ambiguity.
    if (encodedRevision < 1.0) {
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_INPUT)) {
            return vec3(1.0, 0.35, 0.0); // non-finite producer input
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_OPTICAL)) {
            return vec3(0.0, 0.25, 1.0); // invalid optical cap / clarity
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_SURFACE_DISTANCE)) {
            return vec3(0.0, 1.0, 0.35); // surface depth reconstruction failed
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_OPAQUE_DISTANCE)) {
            return vec3(0.55, 0.0, 1.0); // opaque depth reconstruction failed
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_ENTRY_DISTANCE)) {
            return vec3(1.0); // dry-camera water entry reconstruction failed
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_EMPTY)) {
            return vec3(1.0, 0.0, 0.0); // no non-empty water segment was produced
        }
        if (reason <= 0.001) {
            // Yellow means this pass sees a dry camera. Red means the camera is submerged but the
            // producer target remained at its unwritten/cleared identity.
            return waterState <= 0.5 ? vec3(1.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        }
        return vec3(1.0, 0.0, 1.0); // unknown producer failure tag
    }

    // The producer marked this as valid, so show the exact ABI predicate that rejected the stored
    // record. Yellow = revision, blue = packed-normal lane, orange = entry, red = exit.
    if (encodedRevision != PLAGUE_WATER_MEDIUM_REVISION) {
        return vec3(1.0, 1.0, 0.0);
    }
    if (!plagueWaterVolumePackedNormalYValid(reason)) {
        return vec3(0.0, 0.25, 1.0);
    }
    float encodedEntry = encodedInterval.r > 0.0 ? 0.0
            : -encodedInterval.r - PLAGUE_WATER_INTERVAL_EPSILON;
    if (encodedInterval.r <= 0.0 && encodedEntry < 0.0) {
        return vec3(1.0, 0.35, 0.0);
    }
    if (encodedInterval.g <= encodedEntry) {
        return vec3(1.0, 0.0, 0.0);
    }
    return vec3(1.0, 0.0, 1.0); // decoder and diagnostic predicates disagree
}

vec3 plagueWaterShaftFocusDebug(float focusSum, float sampleCount) {
    if (sampleCount <= 0.0 || !plagueWaterSourceFinite(focusSum)) {
        return vec3(1.0, 0.0, 1.0);
    }
    float focus = max(focusSum / sampleCount, 0.125);
    float signedFocus = clamp(log2(focus) / 3.0, -1.0, 1.0);
    // Blue = spreading, green = neutral, red = converging/bright caustic ray tube.
    return vec3(max(signedFocus, 0.0), 1.0 - abs(signedFocus),
            max(-signedFocus, 0.0));
}

vec3 plagueWaterShaftShadowDebug(float visibilitySum, float sampleCount) {
    if (sampleCount <= 0.0 || !plagueWaterSourceFinite(visibilitySum)) {
        return vec3(1.0, 0.0, 1.0);
    }
    return vec3(clamp(visibilitySum / sampleCount, 0.0, 1.0));
}

vec3 plagueWaterShaftRawScatterDebug(vec3 scatter) {
    // Display mapping only. Production scatter remains linear HDR when this view is not selected.
    return vec3(1.0) - exp(-max(scatter, vec3(0.0)) * 32.0);
}

float plagueWaterCellJitter() {
    // Interleaved-gradient noise is fixed in screen space and distributes a 3x3 neighborhood across
    // nine distinct sub-cell depths. That gives the interval-aware reconstruction real stratified
    // coverage instead of nine copies of one hard midpoint contour, without reintroducing the
    // frame/time terms that made the field alternate between incompatible solutions.
    return fract(52.9829189 * fract(dot(
            gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
}

vec3 plagueWaterMarchViewDirectionAt(vec2 uv) {
    vec4 world = u_InvProjModelView * vec4(uv * 2.0 - 1.0, 0.0001, 1.0);
    if (any(isnan(world)) || any(isinf(world)) || abs(world.w) < 1e-6) {
        return vec3(0.0);
    }
    vec3 ray = world.xyz / world.w;
    float rayLengthSquared = dot(ray, ray);
    return rayLengthSquared > 1e-8 && plagueWaterSourceFinite(ray)
            ? ray * inversesqrt(rayLengthSquared) : vec3(0.0);
}

vec3 plagueWaterMarchViewDirection() {
    return plagueWaterMarchViewDirectionAt(texCoord);
}

float plagueWaterShaftDistanceFade(float sampleDistance) {
    if (!plagueWaterSourceFinite(sampleDistance)
            || !plagueWaterSourceFinite(u_WaterShaftDistance)) {
        return 0.0;
    }
    // The default is deliberately phrased in Minecraft scale: retain the authored shaft field
    // through two chunks, then remove it continuously over the third. Only direct volume radiance
    // takes this envelope; the accepted underwater fog, tint, refraction and scene remain intact.
    float fadeEnd = max(u_WaterShaftDistance, 1.0) * 16.0;
    float fadeStart = fadeEnd * (2.0 / 3.0);
    return 1.0 - smoothstep(fadeStart, fadeEnd, max(sampleDistance, 0.0));
}

float plagueWaterShaftFocusDifferential(
        vec3 viewDirection,
        float sampleDistance) {
    // Measure the actual half-resolution ray footprint instead of differentiating through the
    // interval texture. Two output pixels match the support of the existing interval-aware 3x3
    // reconstruction and turn sub-pixel wave convergence into a stable average at distance.
    vec2 xUv = clamp(texCoord + vec2(u_PassTexelSize.x, 0.0), vec2(0.0), vec2(1.0));
    vec2 yUv = clamp(texCoord + vec2(0.0, u_PassTexelSize.y), vec2(0.0), vec2(1.0));
    vec3 xDirection = plagueWaterMarchViewDirectionAt(xUv);
    vec3 yDirection = plagueWaterMarchViewDirectionAt(yUv);
    if (!plagueWaterSourceFinite(viewDirection)
            || !plagueWaterSourceFinite(xDirection)
            || !plagueWaterSourceFinite(yDirection)
            || !plagueWaterSourceFinite(sampleDistance)) {
        return 0.20;
    }
    float angularFootprint = max(
            length(xDirection - viewDirection),
            length(yDirection - viewDirection));
    float projectedFootprint = max(sampleDistance, 0.0) * angularFootprint * 2.0;
    return clamp(max(0.20, projectedFootprint), 0.20, 1.50);
}

float plagueWaterShaftMarchExit(float intervalExit) {
    // Distance limits the water volume being integrated, not the background that happens to be
    // visible through it. A mountain 100 blocks away must not erase illuminated water in the first
    // three chunks; clip the quadrature domain itself so all 8/12 cells resolve that nearby volume.
    return plagueWaterVolumeEffectiveExit(intervalExit, u_WaterShaftDistance);
}

vec3 plagueWaterActiveDirectRadiance(PlagueLighting lighting, vec3 activeLight) {
    vec3 directRadiance;
#if CUSTOM_LIGHT_COLORS
    directRadiance = lighting.light;
#else
    vec3 airEyePos = plagueAirEyePos(u_CameraAbs.y);
    if (u_SunDirection.w > 0.0) {
        directRadiance = plagueSunColor(airEyePos, activeLight);
    } else {
        directRadiance = plagueMoonColor(airEyePos, activeLight);
    }
    directRadiance *= 1.0 - lighting.rainFactor * 0.95;
#endif
    if (u_SunDirection.w <= 0.0) {
        directRadiance *= plagueMoonPhaseInfluence(
                u_SkyCelestial.w, lighting.sunVisibility2);
    }
    return directRadiance;
}

void main() {
    int debugView = int(u_Param3 + 0.5);
    bool debugActive = plagueWaterShaftDebugActive(debugView);
    // Magenta means the selected diagnostic reached this shader but a prerequisite failed before
    // that signal could be measured. It is intentionally distinct from genuine zero scatter.
    fragColor = debugActive ? vec4(1.0, 0.0, 1.0, 1.0) : vec4(0.0);

#if PLAGUE_UNDERWATER && WATER_SCATTERING_QUALITY != 0
    ivec2 intervalSize = textureSize(u_Input0, 0);
    ivec2 intervalCoord = clamp(
            ivec2(gl_FragCoord.xy), ivec2(0), intervalSize - ivec2(1));
    vec4 encodedInterval = texelFetch(u_Input0, intervalCoord, 0);
    PlagueWaterVolumeInterval interval = plagueDecodeWaterVolumeInterval(encodedInterval);
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_INTERVAL) {
        fragColor = vec4(plagueWaterShaftIntervalDebug(
                encodedInterval, interval, u_WaterState.x), 1.0);
        return;
    }

    // The additive shaft field is a submerged-camera effect. Dry cameras keep the established water
    // interface and scene pipeline byte-for-byte; in particular this pass must never tint the scene
    // behind an above-water surface again.
    if (u_WaterState.x <= 0.5) {
        return;
    }

    if (!interval.valid) {
        return;
    }

    vec3 viewDirection = plagueWaterMarchViewDirection();
    if (dot(viewDirection, viewDirection) <= 1e-8) {
        return;
    }

    float marchExit = plagueWaterShaftMarchExit(interval.exitDistance);
    float segmentLength = marchExit - interval.entryDistance;
    float ds = segmentLength / float(PLAGUE_WATER_VOLUME_CELLS);
    if (!plagueWaterSourceFinite(segmentLength) || !plagueWaterSourceFinite(ds)
            || ds <= 0.0) {
        return;
    }
    float clarity = max(u_WaterClarity, 0.05);
    vec3 scatter = vec3(0.0);
    vec3 viewT = vec3(1.0);
    float refractiveFocusSum = 0.0;
    float shadowVisibilitySum = 0.0;
    float directSampleCount = 0.0;

    float activeLightLengthSquared = dot(u_SunDirection.xyz, u_SunDirection.xyz);
    vec3 activeLight = activeLightLengthSquared > 1e-8
            ? u_SunDirection.xyz * inversesqrt(activeLightLengthSquared) : vec3(0.0);
    PlagueCustomPalette palette = PlagueCustomPalette(
            u_AtmPaletteNoonExponent, u_AtmPaletteNoonBrightness,
            vec3(u_AtmPaletteSunsetTintR, u_AtmPaletteSunsetTintG, u_AtmPaletteSunsetTintB),
            vec3(u_AtmPaletteNightR, u_AtmPaletteNightG, u_AtmPaletteNightB),
            vec3(u_AtmPaletteRainDayR, u_AtmPaletteRainDayG, u_AtmPaletteRainDayB),
            vec3(u_AtmPaletteRainNightR, u_AtmPaletteRainNightG, u_AtmPaletteRainNightB),
            vec3(u_LightPaletteNoonR, u_LightPaletteNoonG, u_LightPaletteNoonB),
            vec3(u_LightPaletteSunsetR, u_LightPaletteSunsetG, u_LightPaletteSunsetB),
            u_LightPaletteSunsetWarmth,
            vec3(u_LightPaletteNightR, u_LightPaletteNightG, u_LightPaletteNightB),
            vec3(u_LightPaletteRainDayR, u_LightPaletteRainDayG, u_LightPaletteRainDayB),
            vec3(u_LightPaletteRainNightR, u_LightPaletteRainNightG, u_LightPaletteRainNightB),
            u_LightPaletteRainMagnitude);
    PlagueLighting lighting = plagueOverworldLighting(
            max(u_SkyColor.rgb, vec3(0.0)), u_SunDirection.w, u_SkyState.y,
            clamp(u_SkyState.x, 0.0, 1.0), u_ScreenBrightness, palette);
    vec3 directRadiance = plagueWaterActiveDirectRadiance(lighting, activeLight);
    float jitter = plagueWaterCellJitter();
    float reservoirBaseHeight;
    bool reservoirBaseHeightValid = plagueWaterReservoirBaseHeight(
            u_Input2, interval, viewDirection, u_WaveSpeed, reservoirBaseHeight);

    for (int cell = 0; cell < PLAGUE_WATER_VOLUME_CELLS; cell++) {
        float sampleDistance = interval.entryDistance + (float(cell) + jitter) * ds;
        vec3 samplePosition = viewDirection * sampleDistance;
        vec3 sampleAbs = u_CameraAbs + samplePosition;
        // Constant across the cell: plagueWaterCellWeight integrates constant sigma. No valid
        // surface height means no depth to stratify against, so the medium stays flat.
        float cellLoad = reservoirBaseHeightValid
                ? plagueWaterTurbidityLoad(
                        reservoirBaseHeight - sampleAbs.y, u_WaterTurbidityDepth)
                : 1.0;
        vec3 cellSigmaS = plagueWaterSigmaSLoaded(clarity, cellLoad);
        vec3 cellSigmaT = plagueWaterSigmaTLoaded(clarity, cellLoad);
        float shaftDistanceFade = plagueWaterShaftDistanceFade(sampleDistance);
        float focusDifferential = plagueWaterShaftFocusDifferential(
                viewDirection, sampleDistance);

        vec3 directSource = vec3(0.0);
        vec3 waterLightDirection;
        float lightDistance;
        vec3 interfacePosition;
        float interfaceTransmission;
        bool displacedSurfaceExit;
        float distanceToViewBoundary = interval.submerged
                ? interval.exitDistance - sampleDistance
                : sampleDistance - interval.entryDistance;
        if (reservoirBaseHeightValid && plagueWaterDominantLightExit(
                u_Input2, sampleAbs, activeLight, interval.boundaryNormal,
                distanceToViewBoundary, reservoirBaseHeight, u_WaveSpeed,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission,
                displacedSurfaceExit)) {
            // Midpoint of the light segment, not the cell: that path climbs to the interface, so
            // charging it the cell's own murk puts out every shaft reaching deep water.
            // interfacePosition is camera-relative, reservoirBaseHeight and sampleAbs absolute.
            // Lift it before averaging.
            float lightLoad = plagueWaterTurbidityLoad(
                    reservoirBaseHeight
                            - 0.5 * (sampleAbs.y + interfacePosition.y + u_CameraAbs.y),
                    u_WaterTurbidityDepth);
            vec3 lightTransmittance = exp(
                    -plagueWaterSigmaTLoaded(clarity, lightLoad) * max(lightDistance, 0.0));
            float refractiveFocus = displacedSurfaceExit
                    ? plagueWaterRefractiveFocus(
                            u_Input2, interfacePosition, sampleAbs,
                            activeLight, reservoirBaseHeight, focusDifferential,
                            u_WaveSpeed, u_WaterShaftFocus)
                    : 1.0;
            float shadowVisibility = 1.0;
            directSource = plagueWaterDirectSource(
                    samplePosition, interfacePosition, viewDirection,
                    waterLightDirection, activeLight,
                    directRadiance, lightTransmittance,
                    interfaceTransmission, refractiveFocus,
                    u_WaterShaftSpread,
                    shadowVisibility);
            if (plagueWaterSourceFinite(refractiveFocus)
                    && plagueWaterSourceFinite(shadowVisibility)) {
                refractiveFocusSum += refractiveFocus;
                shadowVisibilitySum += shadowVisibility;
                directSampleCount += 1.0;
            }
        }

        // Fog/tint/ambient/held lighting remain owned by the accepted underwater pipeline. This
        // field carries only direct celestial single-scatter contrast, so adding it later cannot
        // remove or double-attenuate any of those effects.
        vec3 source = directSource * plagueWaterShaftTint() * shaftDistanceFade
                * max(u_WaterShaftStrength, 0.0);
        vec3 Tcell = exp(-cellSigmaT * ds);
        vec3 cellWeight = plagueWaterCellWeight(cellSigmaT, ds);
        scatter += viewT * cellSigmaS * cellWeight * source;
        viewT *= Tcell;

        if (all(lessThan(viewT, vec3(PLAGUE_WATER_INTERVAL_EPSILON)))) {
            break;
        }
    }

    if (!plagueWaterSourceFinite(scatter)) {
        return;
    }
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_REFRACTIVE_FOCUS) {
        fragColor = vec4(plagueWaterShaftFocusDebug(
                refractiveFocusSum, directSampleCount), 1.0);
        return;
    }
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_SHADOW_VISIBILITY) {
        fragColor = vec4(plagueWaterShaftShadowDebug(
                shadowVisibilitySum, directSampleCount), 1.0);
        return;
    }
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER) {
        fragColor = vec4(plagueWaterShaftRawScatterDebug(scatter), 1.0);
        return;
    }
    fragColor = vec4(max(scatter, vec3(0.0)), interval.revision);
#endif
}
