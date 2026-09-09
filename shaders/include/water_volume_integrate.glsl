#ifndef PLAGUE_WATER_VOLUME_INTEGRATE
#define PLAGUE_WATER_VOLUME_INTEGRATE

// One quadrature implementation for the half-resolution field and unresolved full-resolution rays.
// Callers supply the footprint and jitter coordinates so moving this code does not change sampling.
#if WATER_SCATTERING_QUALITY == 1
const int PLAGUE_WATER_VOLUME_CELLS = 8;
#else
const int PLAGUE_WATER_VOLUME_CELLS = 12;
#endif

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

float plagueWaterCellJitter(vec2 sampleCoord) {
    // Interleaved-gradient noise is fixed in screen space and distributes a 3x3 neighborhood across
    // nine distinct sub-cell depths. That gives the interval-aware reconstruction real stratified
    // coverage instead of nine copies of one hard midpoint contour, without reintroducing the
    // frame/time terms that made the field alternate between incompatible solutions.
    return fract(52.9829189 * fract(dot(
            sampleCoord, vec2(0.06711056, 0.00583715))));
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
        vec2 uv,
        vec2 integrationTexelSize,
        vec3 viewDirection,
        float sampleDistance) {
    // Measure the actual half-resolution ray footprint instead of differentiating through the
    // interval texture. Two output pixels match the support of the existing interval-aware 3x3
    // reconstruction and turn sub-pixel wave convergence into a stable average at distance.
    vec2 xUv = clamp(uv + vec2(integrationTexelSize.x, 0.0), vec2(0.0), vec2(1.0));
    vec2 yUv = clamp(uv + vec2(0.0, integrationTexelSize.y), vec2(0.0), vec2(1.0));
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

bool plagueWaterIntegrate(
        PlagueWaterVolumeInterval interval,
        vec2 uv,
        vec2 sampleCoord,
        vec2 integrationTexelSize,
        sampler2D noiseTexture,
        sampler2DShadow shadowTexture,
        out vec3 scatter,
        out vec3 diagnostics) {
    scatter = vec3(0.0);
    diagnostics = vec3(0.0);
    if (!interval.valid || !interval.submerged) {
        return false;
    }
    vec3 viewDirection = plagueWaterMarchViewDirectionAt(uv);
    if (dot(viewDirection, viewDirection) <= 1e-8) {
        return false;
    }

    float marchExit = plagueWaterShaftMarchExit(interval.exitDistance);
    float segmentLength = marchExit - interval.entryDistance;
    float ds = segmentLength / float(PLAGUE_WATER_VOLUME_CELLS);
    if (!plagueWaterSourceFinite(segmentLength) || !plagueWaterSourceFinite(ds)
            || ds <= 0.0) {
        return false;
    }
    float clarity = max(u_WaterClarity, 0.05);
    scatter = vec3(0.0);
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
    float jitter = plagueWaterCellJitter(sampleCoord);
    float reservoirBaseHeight;
    bool reservoirBaseHeightValid = plagueWaterReservoirBaseHeight(
            noiseTexture, interval, viewDirection, u_WaveSpeed, reservoirBaseHeight);

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
                uv, integrationTexelSize, viewDirection, sampleDistance);

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
                noiseTexture, sampleAbs, activeLight, interval.boundaryNormal,
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
                            noiseTexture, interfacePosition, sampleAbs,
                            activeLight, reservoirBaseHeight, focusDifferential,
                            u_WaveSpeed, u_WaterShaftFocus)
                    : 1.0;
            float shadowVisibility = 1.0;
            directSource = plagueWaterDirectSource(
                    shadowTexture, samplePosition, interfacePosition, viewDirection,
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
        return false;
    }
    diagnostics = vec3(refractiveFocusSum, shadowVisibilitySum, directSampleCount);
    scatter = max(scatter, vec3(0.0));
    return true;
}

#endif
