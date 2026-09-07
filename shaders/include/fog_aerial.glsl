#ifndef PLAGUE_FOG_AERIAL
#define PLAGUE_FOG_AERIAL

// Fog dispatcher for the scattering sky. Same PlagueFogTerms, border curve, enclosure gate and
// eye-in-water terms as fog.glsl, with the haze read from the atmoAerial table (light scattered in
// and light let through along the marched ray) and the border colour taken as the sky along the
// ray. A pixel at the render cutoff then equals the sky beside it: both are the same table read.
//
// The program owns the samplers and hands in every table read: the aerial sample at the fragment,
// the brightness let through at PLAGUE_FOG_SKY_LIGHT_REACH short of it (the gate's handover), the
// sky along the ray, and the frame's colour for that light. This file tests no compile option; the
// program picks this dispatcher under PLAGUE_SKY_MODEL == 1.

#moj_import <fornax_runtime:fog.glsl>

PlagueFogTerms plagueFogTermsAerialPath(vec3 worldPos, vec3 borderPos,
                                    float skyLight, float cameraSkyLight,
                                    float renderDistance, vec4 aerial, float transmittanceNear,
                                    vec3 skyAlongRay, vec3 transmittance, PlagueFogDrive drive,
                                    float borderDensity, float uwDepthFloor,
                                    float uwFogStartBlocks, float uwDistanceFogBlocks,
                                    float uwDepthFogBlocks, vec3 uwTintBase, vec3 uwDarkness,
                                    PlagueLighting lighting, vec3 atmColorMult) {
    PlagueFogTerms terms = PlagueFogTerms(vec3(0.0), vec3(0.0), vec3(0.0), 0.0,
                                          vec3(0.0), 0.0, vec3(1.0));

    float rayLength = length(worldPos);
    if (rayLength < 1e-4) {
        return terms;
    }

    // The enclosure gate, as in fog.glsl: keyed on the fragment's own sky light, and the camera can
    // only add light to the path, never take it away.
    float access = smoothstep(mix(0.05, u_FogCaveGuardLo, drive.advanced),
                              mix(0.35, u_FogCaveGuardHi, drive.advanced),
                              clamp(skyLight, 0.0, 1.0));
    float camLight = clamp(cameraSkyLight, 0.0, 1.0);
    float pathLight = max(access, camLight * camLight);

    // How much air sits between the fragment and the last fifteen blocks, as far as a lightmap can
    // speak for. The more air, the less the fragment's own sky light says about the path, so the
    // cave gate hands over to full fog. Whichever of the two says there is more air wins: clear air
    // lets so much light through that the table alone gives a far cave almost no fog (0.03 at the
    // render edge, against the curve's 1.00), leaving the cave mouth clear while the ground around
    // it hazes. The table still counts where the air is thick enough to beat the curve.
    float pathAir = max(plagueFogAirOpacity(rayLength - PLAGUE_FOG_SKY_LIGHT_REACH, drive,
                                            renderDistance),
                        1.0 - clamp(transmittanceNear, 0.0, 1.0));
    float accessHandover = mix(access, 1.0, pathAir);

    // atm = 1 - T and atmColor = L / (1 - T), so the site's mix(lit, atmColor, atm) lands on
    // lit * T + L: what the air lets through plus what it scatters in. The gate scales the opacity,
    // the path light scales the colour.
    vec3 opacity = vec3(1.0) - transmittance;
    terms.atm = opacity * accessHandover * u_FogEnableDistance;
    terms.atmColor = aerial.rgb / max(opacity, vec3(1e-4)) * atmColorMult * pathLight;

    // Fog may never be brighter than the sky it fades into: rule (a) at the top of fog.glsl. The
    // table gathers its light along the ray with the dust lobe aimed at the sun, so with the sun up
    // it comes back brighter than the sky that ray ends at, lifting every pixel carrying fog.
    // Capped by brightness, not per colour, so the fog keeps its hue. Fog already darker than the
    // sky is left alone.
    vec3 fogCeiling = skyAlongRay * atmColorMult * pathLight;
    float fogLuma = dot(terms.atmColor, vec3(0.2126, 0.7152, 0.0722));
    float skyLuma = dot(fogCeiling, vec3(0.2126, 0.7152, 0.0722));
    terms.atmColor *= min(1.0, skyLuma / max(fogLuma, 1e-5));

    // Horizontal radius alone, matching fog.glsl's border metric and the reason there: Minecraft's
    // render distance is a cylinder (XZ-only chunk culling), not a cube. Nether sliders scale this
    // same curve rather than branching it, so it still reaches exactly 1.0 at the cutoff.
    float netherFog = u_WorldBounds.w == 2.0 ? 1.0 : 0.0;
    float borderRenderDistance = renderDistance * mix(1.0, u_NetherFogDistance, netherFog);
    float borderDensityScaled = borderDensity * mix(1.0, u_NetherFogDensity, netherFog);
    float borderDist = length(borderPos.xz);
    float borderFraction = clamp(borderDist / max(borderRenderDistance, PLAGUE_FOG_MIN_RENDER_DISTANCE),
                                 0.0, 1.0);
    float borderGate = mix(pathLight, 1.0,
                           smoothstep(mix(0.55, u_FogBorderGateNear, drive.advanced),
                                      mix(0.80, u_FogBorderGateFar, drive.advanced),
                                      borderFraction));
    float rawBorder = plagueBorderFog(borderDist, borderRenderDistance, borderDensityScaled) * borderGate
                    * u_FogEnableEdge;
    float atmLuma = dot(terms.atm, vec3(0.2126, 0.7152, 0.0722));
    terms.border = max(0.0, (rawBorder - atmLuma) / max(1.0 - atmLuma, 1e-4));

#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        terms.atm = vec3(0.0);
        terms.border = 0.0;
    }
#endif

    terms.borderColor = skyAlongRay * atmColorMult;

    plagueFogWaterTerms(terms, worldPos, rayLength, renderDistance, lighting, uwDepthFloor,
                        uwFogStartBlocks, uwDistanceFogBlocks, uwDepthFogBlocks, uwTintBase,
                        uwDarkness);
    return terms;
}

// Drawn geometry: the air segment and the cull radius both start at the camera. A reflection
// passes its own segment and camera-relative hit to the Path form above.
PlagueFogTerms plagueFogTermsAerial(vec3 worldPos, float skyLight, float cameraSkyLight,
                                    float renderDistance, vec4 aerial, float transmittanceNear,
                                    vec3 skyAlongRay, vec3 chroma, PlagueFogDrive drive,
                                    float borderDensity, float uwDepthFloor,
                                    float uwFogStartBlocks, float uwDistanceFogBlocks,
                                    float uwDepthFogBlocks, vec3 uwTintBase, vec3 uwDarkness,
                                    PlagueLighting lighting, vec3 atmColorMult) {
    vec3 transmittance = pow(vec3(clamp(aerial.a, 0.0, 1.0)), chroma);
    return plagueFogTermsAerialPath(worldPos, worldPos, skyLight, cameraSkyLight,
            renderDistance, aerial, transmittanceNear, skyAlongRay, transmittance, drive,
            borderDensity, uwDepthFloor, uwFogStartBlocks, uwDistanceFogBlocks, uwDepthFogBlocks,
            uwTintBase, uwDarkness, lighting, atmColorMult);
}

#endif // PLAGUE_FOG_AERIAL
