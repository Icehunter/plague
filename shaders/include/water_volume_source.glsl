#ifndef PLAGUE_WATER_VOLUME_SOURCE
#define PLAGUE_WATER_VOLUME_SOURCE

#moj_import <fornax_runtime:water_volume.glsl>

bool plagueWaterSourceFinite(float value) {
    return !isnan(value) && !isinf(value);
}

bool plagueWaterSourceFinite(vec2 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterSourceFinite(vec3 value) {
    return !any(isnan(value)) && !any(isinf(value));
}

bool plagueWaterReservoirBaseHeight(
        sampler2D noiseTexture,
        PlagueWaterVolumeInterval interval,
        vec3 viewDirection,
        float waveSpeed,
        out float reservoirBaseHeight) {
    reservoirBaseHeight = u_WaterState.z;
    if (interval.submerged) {
        return plagueWaterSourceFinite(reservoirBaseHeight);
    }

    vec3 entryAbs = u_CameraAbs + viewDirection * interval.entryDistance;
    if (!plagueWaterSourceFinite(entryAbs)) {
        return false;
    }
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    float waveTime = plagueWaveAnimatedTime(
            u_SkyState.w / 20.0, u_WaveStrength, waveSpeed);
    vec3 entryWaveDisplacement = plagueWaveSurfaceDisplacement(
            noiseTexture, entryAbs, waveTime, 0.0, u_WaveStrength);
    if (!plagueWaterSourceFinite(entryWaveDisplacement)) {
        return false;
    }
    reservoirBaseHeight = entryAbs.y - entryWaveDisplacement.y;
#else
    reservoirBaseHeight = entryAbs.y;
#endif
    return plagueWaterSourceFinite(reservoirBaseHeight);
}

// Exact unpolarised dielectric Fresnel for the air-to-water boundary. This is deliberately shared
// with the light-path solve instead of using Schlick: low-elevation light is precisely the case where
// the approximation is least useful and where the previous unrefracted path extinguished everything.
float plagueWaterDielectricFresnel(
        float cosIncident,
        float etaIncident,
        float etaTransmitted) {
    float cI = clamp(abs(cosIncident), 0.0, 1.0);
    float eta = etaIncident / etaTransmitted;
    float sin2Transmitted = eta * eta * max(1.0 - cI * cI, 0.0);
    if (sin2Transmitted >= 1.0) {
        return 1.0;
    }

    float cT = sqrt(max(1.0 - sin2Transmitted, 0.0));
    float rs = (etaIncident * cI - etaTransmitted * cT)
            / max(etaIncident * cI + etaTransmitted * cT, 1e-6);
    float rp = (etaTransmitted * cI - etaIncident * cT)
            / max(etaTransmitted * cI + etaIncident * cT, 1e-6);
    return clamp(0.5 * (rs * rs + rp * rp), 0.0, 1.0);
}

// u_SunDirection points from the surface toward the active celestial source in AIR. Light travels
// down the opposite direction. Refract that incident ray into water, then reverse it again so the
// returned vector points from an underwater sample back toward the interface/source. At the horizon
// this bends the water-side ray to about y=.661 instead of leaving y near zero and inventing an
// effectively infinite Beer path.
bool plagueWaterRefractAirLight(
        vec3 airLightDirection,
        vec3 interfaceNormal,
        out vec3 waterLightDirection,
        out float interfaceTransmission) {
    waterLightDirection = vec3(0.0);
    interfaceTransmission = 0.0;
    if (!plagueWaterSourceFinite(airLightDirection)
            || !plagueWaterSourceFinite(interfaceNormal)) {
        return false;
    }

    vec3 airLight = plagueWaterVolumeSafeNormal(airLightDirection);
    vec3 normal = plagueWaterVolumeSafeNormal(interfaceNormal);
    if (normal.y < 0.0) {
        normal = -normal;
    }
    float cosAir = dot(normal, airLight);
    if (!plagueWaterSourceFinite(cosAir) || cosAir <= 1e-5) {
        return false;
    }

    vec3 waterPhotonDirection = refract(-airLight, normal, 1.0 / 1.333);
    float waterLengthSquared = dot(waterPhotonDirection, waterPhotonDirection);
    if (!plagueWaterSourceFinite(waterPhotonDirection) || waterLengthSquared <= 1e-8) {
        return false;
    }
    waterLightDirection = -waterPhotonDirection * inversesqrt(waterLengthSquared);
    interfaceTransmission = 1.0 - plagueWaterDielectricFresnel(cosAir, 1.0, 1.333);
    return plagueWaterSourceFinite(waterLightDirection)
            && plagueWaterSourceFinite(interfaceTransmission)
            && dot(waterLightDirection, normal) > 1e-5;
}

// The displaced-surface solve below is deliberately iterative: a wave changes both the interface
// height and the Snell-refracted direction used to reach it.  At steep crests or low sun angles that
// fixed-point map can leave its convergence basin, and a local wave normal can briefly face away
// from the source.  Neither event means the entire view ray contains no celestial radiance.  A
// finite sun disc illuminates it through neighbouring surface area, and the two shadow-map queries
// in plagueWaterDirectSource still decide whether real geometry blocks that light.
//
// Keep one conservative, flat-reservoir solution for those failure paths.  This is not an
// unshadowed ambient term: it returns a real interface position, direction, distance and Fresnel
// transmission, which then go through the exact same air-side and submerged-geometry shadow tests
// as a converged displaced ray.  Its purpose is solely to stop numerical/non-local surface failures
// becoming black production holes and magenta zero-sample diagnostics.
bool plagueWaterFlatLightExit(
        vec3 sampleAbs,
        vec3 airLightDirection,
        float reservoirBaseHeight,
        out vec3 waterLightDirection,
        out float lightDistance,
        out vec3 interfacePosition,
        out float interfaceTransmission) {
    waterLightDirection = vec3(0.0);
    lightDistance = 0.0;
    interfacePosition = vec3(0.0);
    interfaceTransmission = 0.0;
    if (!plagueWaterSourceFinite(sampleAbs)
            || !plagueWaterSourceFinite(airLightDirection)
            || !plagueWaterSourceFinite(reservoirBaseHeight)
            || !plagueWaterRefractAirLight(
                    airLightDirection, vec3(0.0, 1.0, 0.0),
                    waterLightDirection, interfaceTransmission)) {
        return false;
    }

    lightDistance = (reservoirBaseHeight - sampleAbs.y) / waterLightDirection.y;
    if (!plagueWaterSourceFinite(lightDistance) || lightDistance <= 0.0) {
        return false;
    }
    vec3 interfaceAbs = sampleAbs + waterLightDirection * lightDistance;
    interfacePosition = interfaceAbs - u_CameraAbs;
    return plagueWaterSourceFinite(interfaceAbs)
            && plagueWaterSourceFinite(interfacePosition)
            && plagueWaterSourceFinite(interfaceTransmission);
}

// Finds the actual displaced surface exit for one celestial path. Both the point and Snell-refracted
// water direction are refined together. The shadow query later starts at this exit and travels along
// the original air direction; Beer extinction and phase use the returned water-side path.
bool plagueWaterDominantLightExit(
        sampler2D noiseTexture,
        vec3 sampleAbs,
        vec3 airLightDirection,
        vec3 boundaryNormal,
        float distanceToViewBoundary,
        float reservoirBaseHeight,
        float waveSpeed,
        out vec3 waterLightDirection,
        out float lightDistance,
        out vec3 interfacePosition,
        out float interfaceTransmission,
        out bool displacedSurfaceExit) {
    waterLightDirection = vec3(0.0);
    lightDistance = 0.0;
    interfacePosition = vec3(0.0);
    interfaceTransmission = 0.0;
    displacedSurfaceExit = false;
    if (!plagueWaterSourceFinite(sampleAbs) || !plagueWaterSourceFinite(airLightDirection)
            || !plagueWaterSourceFinite(reservoirBaseHeight)) {
        return false;
    }

    vec3 initialNormal = plagueWaterVolumeSafeNormal(boundaryNormal);
    if (initialNormal.y < 0.0) {
        initialNormal = -initialNormal;
    }
    if (!plagueWaterRefractAirLight(
            airLightDirection, initialNormal, waterLightDirection, interfaceTransmission)) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }
    if (distanceToViewBoundary <= 0.25 && dot(initialNormal, waterLightDirection) <= 0.0) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }

    float distance = (reservoirBaseHeight - sampleAbs.y) / waterLightDirection.y;
    if (!plagueWaterSourceFinite(distance) || distance <= 0.0) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }

#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    float waveTime = plagueWaveAnimatedTime(
            u_SkyState.w / 20.0, u_WaveStrength, waveSpeed);
#endif
    for (int refinement = 0; refinement < 3; refinement++) {
        vec3 interfaceAbs = sampleAbs + waterLightDirection * distance;
        if (!plagueWaterSourceFinite(interfaceAbs)) {
            return plagueWaterFlatLightExit(
                    sampleAbs, airLightDirection, reservoirBaseHeight,
                    waterLightDirection, lightDistance,
                    interfacePosition, interfaceTransmission);
        }
        float displacedHeight = reservoirBaseHeight;
        vec3 refinedNormal = vec3(0.0, 1.0, 0.0);
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
        vec3 waveDisplacement;
        plagueWaveNormalAndDisplacement(
                noiseTexture,
                vec3(interfaceAbs.x, reservoirBaseHeight, interfaceAbs.z),
                waveTime, u_WaveStrength,
                waveDisplacement, refinedNormal);
        if (!plagueWaterSourceFinite(waveDisplacement)
                || !plagueWaterSourceFinite(refinedNormal)) {
            return plagueWaterFlatLightExit(
                    sampleAbs, airLightDirection, reservoirBaseHeight,
                    waterLightDirection, lightDistance,
                    interfacePosition, interfaceTransmission);
        }
        displacedHeight += waveDisplacement.y;
#endif
        vec3 refinedWaterLightDirection;
        float refinedInterfaceTransmission;
        if (!plagueWaterRefractAirLight(
                airLightDirection, refinedNormal,
                refinedWaterLightDirection, refinedInterfaceTransmission)) {
            return plagueWaterFlatLightExit(
                    sampleAbs, airLightDirection, reservoirBaseHeight,
                    waterLightDirection, lightDistance,
                    interfacePosition, interfaceTransmission);
        }
        float refinedDistance = (displacedHeight - sampleAbs.y)
                / refinedWaterLightDirection.y;
        if (!plagueWaterSourceFinite(refinedDistance) || refinedDistance <= 0.0) {
            return plagueWaterFlatLightExit(
                    sampleAbs, airLightDirection, reservoirBaseHeight,
                    waterLightDirection, lightDistance,
                    interfacePosition, interfaceTransmission);
        }
        waterLightDirection = refinedWaterLightDirection;
        interfaceTransmission = refinedInterfaceTransmission;
        distance = refinedDistance;
    }

    vec3 finalInterfaceAbs = sampleAbs + waterLightDirection * distance;
    if (!plagueWaterSourceFinite(finalInterfaceAbs)) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }
    float finalHeight = reservoirBaseHeight;
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    vec3 finalWaveDisplacement = plagueWaveSurfaceDisplacement(
            noiseTexture,
            vec3(finalInterfaceAbs.x, reservoirBaseHeight, finalInterfaceAbs.z),
            waveTime, 0.0, u_WaveStrength);
    if (!plagueWaterSourceFinite(finalWaveDisplacement)) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }
    finalHeight += finalWaveDisplacement.y;
#endif
    float agreement = abs(finalInterfaceAbs.y - finalHeight);
    if (!plagueWaterSourceFinite(agreement) || agreement > 0.25) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }

    lightDistance = distance;
    interfacePosition = finalInterfaceAbs - u_CameraAbs;
    if (!plagueWaterSourceFinite(interfacePosition)
            || !plagueWaterSourceFinite(interfaceTransmission)) {
        return plagueWaterFlatLightExit(
                sampleAbs, airLightDirection, reservoirBaseHeight,
                waterLightDirection, lightDistance,
                interfacePosition, interfaceTransmission);
    }
    displacedSurfaceExit = true;
    return true;
}

// Irradiance is not conserved by carrying only the refracted direction. A curved interface maps one
// square metre of incident sunlight onto a different area at an underwater sample plane. The ratio
// is the reciprocal determinant of that ray map's 2-D Jacobian: converging rays make a bright tube,
// diverging rays make the dark gap beside it. The shortcut would be injecting an authored caustic
// texture at every volume step; this evaluates the real source structure from Plague's actual
// displaced wave surface and Snell's law instead.
bool plagueWaterProjectedSurfacePoint(
        sampler2D noiseTexture,
        vec2 surfaceXZ,
        float reservoirBaseHeight,
        float sampleHeight,
        float waveTime,
        vec3 airLightDirection,
        out vec2 projectedXZ) {
    projectedXZ = vec2(0.0);
    vec3 surfaceQuery = vec3(surfaceXZ.x, reservoirBaseHeight, surfaceXZ.y);
    vec3 waveDisplacement = vec3(0.0);
    vec3 waveNormal = vec3(0.0, 1.0, 0.0);
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    plagueWaveNormalAndDisplacement(
            noiseTexture, surfaceQuery, waveTime, u_WaveStrength,
            waveDisplacement, waveNormal);
    if (!plagueWaterSourceFinite(waveDisplacement)
            || !plagueWaterSourceFinite(waveNormal)) {
        return false;
    }
#endif

    vec3 waterLightDirection;
    float unusedTransmission;
    if (!plagueWaterRefractAirLight(
            airLightDirection, waveNormal,
            waterLightDirection, unusedTransmission)) {
        return false;
    }

    vec3 photonDirection = -waterLightDirection;
    vec3 surfaceAbs = surfaceQuery + waveDisplacement;
    if (photonDirection.y >= -1e-5) {
        return false;
    }
    float travel = (sampleHeight - surfaceAbs.y) / photonDirection.y;
    if (!plagueWaterSourceFinite(travel) || travel < 0.0) {
        return false;
    }
    projectedXZ = surfaceXZ + photonDirection.xz * travel;
    return plagueWaterSourceFinite(projectedXZ);
}

float plagueWaterRefractiveFocus(
        sampler2D noiseTexture,
        vec3 interfacePosition,
        vec3 sampleAbs,
        vec3 airLightDirection,
        float reservoirBaseHeight,
        float differential,
        float waveSpeed,
        float shaftFocus) {
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    if (!plagueWaterSourceFinite(interfacePosition)
            || !plagueWaterSourceFinite(sampleAbs)
            || !plagueWaterSourceFinite(differential)) {
        return 1.0;
    }

    differential = clamp(differential, 0.20, 1.50);
    float waveTime = plagueWaveAnimatedTime(
            u_SkyState.w / 20.0, u_WaveStrength, waveSpeed);
    vec2 surfaceXZ = (u_CameraAbs + interfacePosition).xz;
    vec2 mappedCenter;
    vec2 mappedX;
    vec2 mappedZ;
    if (!plagueWaterProjectedSurfacePoint(
                noiseTexture, surfaceXZ,
                reservoirBaseHeight, sampleAbs.y, waveTime,
                airLightDirection, mappedCenter)
            || !plagueWaterProjectedSurfacePoint(
                noiseTexture, surfaceXZ + vec2(differential, 0.0),
                reservoirBaseHeight, sampleAbs.y, waveTime,
                airLightDirection, mappedX)
            || !plagueWaterProjectedSurfacePoint(
                noiseTexture, surfaceXZ + vec2(0.0, differential),
                reservoirBaseHeight, sampleAbs.y, waveTime,
                airLightDirection, mappedZ)) {
        return 1.0;
    }

    // Anchor both forward differences at the evaluated centre of the same ray map. The displaced
    // surface solve deliberately accepts a finite residual, so sampleAbs.xz is not an exact map
    // value and subtracting it here turns that residual into a false derivative.
    vec2 columnX = (mappedX - mappedCenter) / differential;
    vec2 columnZ = (mappedZ - mappedCenter) / differential;
    float determinant = abs(columnX.x * columnZ.y - columnZ.x * columnX.y);
    if (!plagueWaterSourceFinite(determinant)) {
        return 1.0;
    }

    // The finite sun disc and unresolved capillary waves keep a geometric caustic finite. The
    // reciprocal bounds below are an energy-preserving safety envelope, not an arbitrary shaft
    // mask: flat water has determinant 1 and returns exactly 1; convergence rises above one while
    // divergence falls below it.
    float physicalFocus = clamp(1.0 / max(determinant, 0.125), 0.125, 8.0);
    // Zero flattens the tube to neutral one, one preserves the physical Jacobian, and two
    // exaggerates its contrast without escaping the same finite safety envelope.
    return clamp(pow(max(physicalFocus, 1e-6), max(shaftFocus, 0.0)), 0.125, 8.0);
#else
    return 1.0;
#endif
}

float plagueWaterShadowVisibility(
        vec3 interfacePosition,
        vec3 airLightDirection) {
#ifdef SHADOWS
    vec3 biased = interfacePosition + airLightDirection * 0.08;
    vec4 lightClip = u_SunViewProj * vec4(biased, 1.0);
    if (any(isnan(lightClip)) || any(isinf(lightClip)) || abs(lightClip.w) < 1e-6) {
        return 0.0;
    }

    vec3 lightNdc = lightClip.xyz / lightClip.w;
    float radius = length(lightNdc.xy);
    float distortFactor = radius * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    if (!plagueWaterSourceFinite(lightNdc) || !plagueWaterSourceFinite(distortFactor)
            || distortFactor <= 1e-6) {
        return 0.0;
    }

    vec2 shadowUv = (lightNdc.xy / distortFactor) * 0.5 + 0.5;
    float uvEdge = min(min(shadowUv.x, 1.0 - shadowUv.x),
                       min(shadowUv.y, 1.0 - shadowUv.y));
    float depthEdge = min(lightNdc.z, 1.0 - lightNdc.z);
    float coverage = clamp(min(uvEdge, depthEdge) * 64.0, 0.0, 1.0);
    if (coverage <= 0.0) {
        return 0.0;
    }
    // Compared against the writer's plain [0,1] light-clip depth. Outside its covered volume
    // there is no evidence of direct illumination, so the edge fades to dark—not lit.
    float sampledVisibility = texture(u_Input1, vec3(shadowUv, lightNdc.z));
    return sampledVisibility * coverage;
#else
    return 1.0;
#endif
}

vec3 plagueWaterDirectSource(
        vec3 samplePosition,
        vec3 interfacePosition,
        vec3 viewDirection,
        vec3 waterLightDirection,
        vec3 airLightDirection,
        vec3 lightRadiance,
        vec3 lightTransmittance,
        float interfaceTransmission,
        float refractiveFocus,
        float shaftSpread,
        out float shadowVisibility) {
    float phase = plagueWaterEffectiveDirectPhase(
            dot(viewDirection, waterLightDirection), shaftSpread);
    // The light path is piecewise. The surface query owns the air-side segment (roofs, boats and
    // terrain above water); querying only there cannot see opaque terrain between this cell and the
    // surface, which is why the first live build let shafts pass through submerged land. The cell
    // query makes that underwater geometry participate in the same real shadow map. Taking the
    // conservative intersection preserves every existing air-side blocker while adding the missing
    // submerged blocker—neither term can manufacture light.
    float interfaceVisibility = plagueWaterShadowVisibility(
            interfacePosition, airLightDirection);
    float submergedGeometryVisibility = plagueWaterShadowVisibility(
            samplePosition, airLightDirection);
    shadowVisibility = min(interfaceVisibility, submergedGeometryVisibility);
    return phase * max(lightRadiance, vec3(0.0))
            * max(lightTransmittance, vec3(0.0))
            * max(interfaceTransmission, 0.0)
            * max(refractiveFocus, 0.0) * shadowVisibility;
}

vec3 plagueWaterHeldSource(vec3 samplePosition, vec3 viewDirection, vec3 blockLightColour) {
    vec3 lightToSample = samplePosition;
    lightToSample.y += 0.7;
    float directionLengthSquared = dot(lightToSample, lightToSample);
    if (directionLengthSquared <= 1e-8 || max(u_HeldLight.x, u_HeldLight.y) <= 0.0) {
        return vec3(0.0);
    }
    vec3 sampleToLight = -lightToSample * inversesqrt(directionLengthSquared);
    float phase = plagueWaterParticlePhase(
            dot(viewDirection, sampleToLight));
    // plagueHeldLighting owns the existing +0.7 position offset, +6 distance bound, inverse-square
    // falloff and held-level scaling; block-light colour is threaded in from whichever model the
    // caller resolved, same as every other plagueHeldLighting call site.
    return phase * plagueHeldLighting(samplePosition, u_HeldLight.x, u_HeldLight.y, blockLightColour);
}

#endif
