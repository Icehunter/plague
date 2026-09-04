#ifndef PLAGUE_FOG_AERIAL
#define PLAGUE_FOG_AERIAL

// The fog dispatcher for the scattering sky: the same PlagueFogTerms, the same border curve, the
// same enclosure gate and eye-in-water terms as fog.glsl, with the aerial haze replaced by a read
// of the atmoAerial table (in-scatter and transmittance along the ray, marched) and the border
// colour by the sky along the ray. A pixel at the render cutoff then equals the sky beside it by
// construction: both are the same table read.
//
// The program supplies every table read (it owns the samplers): the aerial sample at the
// fragment, the luminance transmittance at PLAGUE_FOG_SKY_LIGHT_REACH short of it (the gate's
// handover), the sky along the ray and the frame's transmittance chroma. This file tests no
// compile option; the program picks this dispatcher under PLAGUE_SKY_MODEL == 1.

#moj_import <fornax_runtime:fog.glsl>

PlagueFogTerms plagueFogTermsAerial(vec3 worldPos, float skyLight, float cameraSkyLight,
                                    float renderDistance, vec4 aerial, float transmittanceNear,
                                    vec3 skyAlongRay, vec3 chroma, PlagueFogDrive drive,
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

    // The enclosure gate, unchanged from fog.glsl: keyed on the fragment's own sky light, and the
    // camera can only add light to the path, never remove it.
    float access = smoothstep(mix(0.05, u_FogCaveGuardLo, drive.advanced),
                              mix(0.35, u_FogCaveGuardHi, drive.advanced),
                              clamp(skyLight, 0.0, 1.0));
    float camLight = clamp(cameraSkyLight, 0.0, 1.0);
    float pathLight = max(access, camLight * camLight);

    // Per-channel transmittance from the table's luminance one. The gate hands over to the ray's
    // own extinction past what a lightmap can vouch for: the more air is between the fragment and
    // the last fifteen blocks, the less the fragment's sky light says about the path.
    vec3 transmittance = pow(vec3(clamp(aerial.a, 0.0, 1.0)), chroma);
    float pathAir = 1.0 - clamp(transmittanceNear, 0.0, 1.0);
    float accessHandover = mix(access, 1.0, pathAir);

    // atm = 1 - T and atmColor = L / (1 - T), so the site's mix(lit, atmColor, atm) lands on
    // lit * T + L: what the air lets through plus what it scatters in. The gate scales the opacity,
    // the path light scales the colour, as before.
    vec3 opacity = vec3(1.0) - transmittance;
    terms.atm = opacity * accessHandover * u_FogEnableDistance;
    terms.atmColor = aerial.rgb / max(opacity, vec3(1e-4)) * atmColorMult * pathLight;

    // Horizontal radius alone, matching fog.glsl's own border metric and the reasoning there:
    // Minecraft's render distance is a cylinder (XZ-only chunk culling), not a cube. Nether
    // sliders scale this same curve rather than branching it, so the terminal-1.0-at-cutoff
    // property survives.
    float netherFog = u_WorldBounds.w == 2.0 ? 1.0 : 0.0;
    float borderRenderDistance = renderDistance * mix(1.0, u_NetherFogDistance, netherFog);
    float borderDensityScaled = borderDensity * mix(1.0, u_NetherFogDensity, netherFog);
    float borderDist = length(worldPos.xz);
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

#endif // PLAGUE_FOG_AERIAL
