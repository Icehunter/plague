// Guard name deliberately NOT PLAGUE_FOG: that is the pack OPTION declared below, and a guard
// sharing its name is redefined the moment the option's own #define is reached, breaking every
// file that includes this one.
#ifndef PLAGUE_FOG_INCLUDE
#define PLAGUE_FOG_INCLUDE

// FOG IS ALWAYS ON: its job is dissolving the render-distance edge, not mood.
// (a) FOG COLOUR IS THE SKY COLOUR along the view ray (plagueGetSky, doGlare=true,
//     doGround=false): at opacity exactly 1.0 a cutoff pixel becomes bit-for-bit the sky beside
//     it, so the edge stops existing.
// (b) DENSITY DERIVES FROM RENDER DISTANCE, never absolute blocks (min(192/renderDistance, 1.0),
//     192 = vanilla's 12-chunk default): fog tuned at 16 chunks is soup at 8 and a hard edge at 32.
//
// The sky and clouds are deliberately NOT fogged: the sky IS the fog colour (mixing toward itself
// is the identity), and the cloud include already fades toward the sky along the same ray.
//
// Every curve constant here is a fit output (tools/derive_fog.py); re-run the script to reproduce
// or dispute any number, its anchors re-check the fits on every run.
//
// CAVE FOG IS NOT BUILT: the minimum-lighting table it would be tuned against is known ~2.4x too
// strong relative to decoded albedo, so a cave haze tuned now would need retuning the moment
// that's fixed, with the two changes impossible to tell apart. What IS built is the enclosure GATE
// below (outdoor fog suppressed on a near fragment with no sky access); a distant unlit cave
// sightline still picks up a little haze (see the handover note on plagueAtmosphericFog).
//
// UNDERWATER FOG RIDES THIS DISPATCHER as a third, outermost PlagueFogTerms term plus a scene tint
// (underwater.glsl); both are exact identities above water, giving every forward site the same
// veil with no per-site plumbing.
//
// REJECTED, recorded so it isn't retried: a dedicated fullscreen fog pass (a full rgba16f
// read+write per frame, buys nothing the owning passes don't already have); driving the enclosure
// gate off the camera's own sky light uniform (unsmoothed — a cave-mouth crossing would step the
// haze across the whole frame in a single frame).

// Fog options declared once for the three consumers that share them (this dispatcher, the cloud
// fade, the reflection probe's cloud imposter), plus the PLAGUE_FOG_DRIVE macro.
#moj_import <fornax_runtime:fog_options.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:sky.glsl>
// The curves and constants themselves, split into fog_model.glsl so the cloud march can share
// them without inheriting this file's runtime options or the underwater arm below.
#moj_import <fornax_runtime:fog_model.glsl>
// Eye-in-water colour/closure/tint, imported after the two above since it consumes PlagueLighting,
// so every fog consumer carries the same underwater veil with no per-site plumbing. Its caustic
// section compiles only under PLAGUE_UNDERWATER_CAUSTIC_HOOK (gbuffer_resolve.fsh only).
#moj_import <fornax_runtime:underwater.glsl>

// Colour and opacity kept separate per term: a forward site composites into an already-tonemapped,
// display-referred frame, so it must push the fog colour through the display transform while
// leaving opacity alone — impossible once the two are mixed. plagueApplyFog is a thin wrapper over
// the same mixes, verified bit-identical to this by tools/verify_fog.py.
struct PlagueFogTerms {
    vec3 atmColor;      // aerial-perspective haze colour, linear HDR
    vec3 atm;           // its opacity per channel, 0..1; blue extinguishes before red
    vec3 borderColor;   // the sky along this ray, what the world dissolves INTO at the boundary
    float border;       // its opacity, 0..1, outermost of the two AIR terms
    vec3 waterColor;    // eye-in-water fog colour (underwater.glsl); vec3(0) above water
    float water;        // its opacity, 0..1, applied OUTERMOST of all
    vec3 uwTint;        // underwater scene tint; EXACTLY vec3(1.0) above water
};

// The eye-in-water terms, shared by this dispatcher and the aerial-table one (fog_aerial.glsl):
// exact identities above water.
void plagueFogWaterTerms(inout PlagueFogTerms terms, vec3 worldPos, float rayLength,
                         float renderDistance, PlagueLighting lighting, float uwDepthFloor,
                         float uwFogStartBlocks, float uwDistanceFogBlocks, float uwDepthFogBlocks,
                         vec3 uwTintBase, vec3 uwDarkness) {
#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        // WATER_VEIL and WATER_ABSORPTION_TINT are separate gates sharing the outer u_WaterState
        // branch: a single shared gate would let turning off "Water Fog" silently remove the
        // whole scene tint too, ~30-45% per channel. Named WATER_ABSORPTION_TINT rather than
        // WATER_TINT since water_composite.fsh already declares an unrelated local constant of
        // that name.
#if WATER_VEIL
        // No dither on the mix factor: a factor dither's error scales with veil-to-scene
        // contrast, so it peaks along the veil's own gradient as visible structured lines
        // (quantisation is handled once, at the end of tonemap.fsh). Lamp glow ADDS with its own
        // falloff rather than lifting the lit scale, since it's a local source.
        terms.water = plagueGetWaterFogAniso(worldPos, uwFogStartBlocks,
                                             uwDistanceFogBlocks, uwDepthFogBlocks);
        terms.waterColor = plagueWaterFogColor(lighting)
                         * plagueWaterVeilDarkness(worldPos, uwDistanceFogBlocks, uwDarkness.z,
                                                   uwDarkness.x, uwDarkness.y)
                         + plagueWaterLampGlow(lighting, rayLength);
#endif
#if WATER_ABSORPTION_TINT
        // Display-referred ratio, converted to linear once here. CARRIES DEPTH: while depth-blind,
        // descending made the frame BRIGHTER since near blocks were lit as if at the surface
        // (measured live, Y=33 brighter than Y=58).
        terms.uwTint = plagueAuthoredToLinear(
                plagueUnderwaterMult(rayLength, renderDistance, uwDepthFloor, lighting,
                                     uwTintBase) * 0.85)
                     * plagueWaterDepthDim(worldPos, uwDarkness.z, uwDarkness.y);
#endif
    }
#endif
}

// The dispatcher: every fog quantity for one fragment, computed once, handed out as terms.
PlagueFogTerms plagueFogTerms(vec3 worldPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float uwDepthFloor,
                              float uwFogStartBlocks, float uwDistanceFogBlocks,
                              float uwDepthFogBlocks, vec3 uwTintBase, vec3 uwDarkness,
                              vec3 atmColorMult) {
    PlagueFogTerms terms = PlagueFogTerms(vec3(0.0), vec3(0.0), vec3(0.0), 0.0,
                                          vec3(0.0), 0.0, vec3(1.0));

    float rayLength = length(worldPos);
    if (rayLength < 1e-4) {
        return terms;
    }
    vec3 viewRay = worldPos / rayLength;

    float VdotU = viewRay.y;
    float VdotS = dot(viewRay, sunDirTrue);
    float fragAltitude = cameraAltitude + worldPos.y;

    // The option values and frame signals folded into one steering struct; the same macro
    // expansion the cloud fade and reflection probe use, so all three consumers agree.
    PlagueFogDrive drive = PLAGUE_FOG_DRIVE(lighting);

    // Keyed on the FRAGMENT's own sky light, never the camera's: a camera-keyed gate breaks
    // sunlit terrain seen through a cave mouth. Handed to the aerial term rather than multiplied
    // in here, since that term's own extinction decides how far the gate can still be right (see
    // the handover note on plagueAtmosphericFog). Guard sliders apply only under Advanced
    // Overrides; each literal matches its option's declared default (harness-pinned).
    float access = smoothstep(mix(0.05, u_FogCaveGuardLo, drive.advanced),
                              mix(0.35, u_FogCaveGuardHi, drive.advanced),
                              clamp(skyLight, 0.0, 1.0));

    // Fog is scattered light: full strength along a path no sky light reaches would haze a
    // sealed unlit cave (screenshot 217). max() of the path's two endpoints (the only thing a
    // lightmap can answer), so the camera can only ADD light, never remove it — a cave mouth
    // looking out at sunlit terrain is unchanged. Camera term rides squared raw sky light (this
    // pack's lightmap-to-light conversion), which also evens the uniform's quantised sRGB steps.
    float camLight = clamp(cameraSkyLight, 0.0, 1.0);
    float pathLight = max(access, camLight * camLight);

    // Applied to the term, not folded into density, so the gate's handover maths above stays
    // keyed to the real curve. Deliberately doesn't touch the cloud fade: clouds must keep
    // melting into the sky where the terrain veil closes. Per channel, so distant terrain loses
    // red before blue instead of greying out uniformly; the cloud fade stays on the grey scalar
    // twin.
    terms.atm = plagueAtmosphericFog3(rayLength, fragAltitude, cameraAltitude, renderDistance,
                                      drive, atmDensity, access) * u_FogEnableDistance;
    float heightWeight = plagueFogHeightWeight(fragAltitude, drive.H);

    // Scales the COLOUR, not the opacity: in the dark the in-scatter vanishes but extinction
    // survives (light off a torch-lit wall still scatters out of a dark path); dropping opacity
    // instead would wrongly restore that light.
    terms.atmColor = plagueAtmFogColor(skyColours, VdotS, heightWeight, lighting) * atmColorMult
                    * pathLight;

    // Horizontal radius only. Minecraft culls chunks by XZ distance, never by Y, so render
    // distance is a cylinder, not a cube. max(xz, |y|) would pull the cutoff up toward the camera
    // on any steep look from altitude, ahead of the true horizontal distance.
    float borderDist = length(worldPos.xz);
    float borderFraction = clamp(borderDist / max(renderDistance, PLAGUE_FOG_MIN_RENDER_DISTANCE),
                                 0.0, 1.0);

    // Gated near, ungated far: ungated everywhere makes a cutoff pixel bit-for-bit the sky beside
    // it, including a cave mouth at that distance. Gated near stops the veil glowing inside sealed
    // caves as the reach slider brings it inward (4.9 display codes measured on a 110-block
    // underground sightline without it); the crossover sits below any reach's meaningful opacity,
    // so it only affects caves.
    float borderGate = mix(pathLight, 1.0,
                           smoothstep(mix(0.55, u_FogBorderGateNear, drive.advanced),
                                      mix(0.80, u_FogBorderGateFar, drive.advanced),
                                      borderFraction));
    // Edge Fog multiplies the finished term: off shows the raw render edge, the point of the
    // switch.
    float rawBorder = plagueBorderFog(borderDist, renderDistance, borderDensity) * borderGate
                    * u_FogEnableEdge;

    // Border fills only the gap the aerial term's own luminance leaves, not a stack of the two.
    // atmLuma reads terms.atm. The sequential mix's total opacity equals max(atmLuma, rawBorder):
    // below the crossover this term is 0 and atm alone shows; at and past it, the (raw-L)/(1-L)
    // rescale cancels atm's contribution and the total equals rawBorder. rawBorder reaches exactly
    // 1.0 at the cutoff for every reach (fog_model.glsl), so terms.border does too: the render edge
    // stays fully hidden.
    float atmLuma = dot(terms.atm, vec3(0.2126, 0.7152, 0.0722));
    terms.border = max(0.0, (rawBorder - atmLuma) / max(1.0 - atmLuma, 1e-4));

    // No air between the eye and a submerged fragment, so aerial/border fog are wrong there, not
    // just weak. The water term below owns the whole closure.
#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        terms.atm = vec3(0.0);
        terms.border = 0.0;
    }
#endif

    // Sky along this ray, same function the resolve paints the dome with (rule a). doGround=false:
    // the border colour is what the world dissolves INTO, and a drawn ground plane would just
    // replace one edge with another.
    terms.borderColor = plagueGetSky(skyColours, VdotU, VdotS, dither, true, false)
                       * atmColorMult;

    plagueFogWaterTerms(terms, worldPos, rayLength, renderDistance, lighting, uwDepthFloor,
                        uwFogStartBlocks, uwDistanceFogBlocks, uwDepthFogBlocks, uwTintBase,
                        uwDarkness);
    return terms;
}

// Fallback for callers with no runtime access to the water-fog options or colour mults
// (terrain.fsh, particles_translucent.fsh, banner_patterns.fsh); only gbuffer_resolve.fsh and
// water_composite.fsh reach the real 15-arg overload. 32.0/32.0 keeps these callers exactly as
// before — a pre-existing gap, not a regression.
PlagueFogTerms plagueFogTerms(vec3 worldPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float uwDepthFloor) {
    return plagueFogTerms(worldPos, skyLight, cameraSkyLight, renderDistance, cameraAltitude,
                          dither, skyColours, lighting, sunDirTrue, atmDensity, borderDensity,
                          uwDepthFloor, 0.0, 32.0, 32.0, vec3(0.80, 0.87, 0.97),
                          vec3(1.0, 1.0, 999.0), vec3(1.0));
}

// Must fully replace at the edge, or the sky pixel just past the last fragment leaves a hard
// seam at the cutoff instead of a wash.
//
// Squared, not cubed: cubing crushes the whole transition into the last few pixels before the
// cutoff, reading as a hard line. Squaring still fades smoothly while keeping distant objects
// (a village or hillside a few hundred blocks out) mostly visible.
float plagueBorderColorWeight(float border) {
    float w = clamp(border, 0.0, 1.0);
    return w * w;
}

// plagueApplyFog is exactly affine in `color` (every op is a mix() whose factor comes from
// geometry/sky state alone); these are its two halves, derived from the live terms so a fourth
// struct term flows through with no edit.
vec3 plaguePremultipliedFog(PlagueFogTerms t) {
    float borderW = plagueBorderColorWeight(t.border);
    vec3 p = mix(t.atmColor * clamp(t.atm, 0.0, 1.0), t.borderColor, borderW);
    // Water term outermost, then the underwater tint over the lot, the order plagueApplyFog
    // composes. Above water this is exact identities.
    return mix(p, t.waterColor, clamp(t.water, 0.0, 1.0)) * t.uwTint;
}

// What survives of the incoming colour, PER-CHANNEL since the underwater tint dies per channel
// (red first with depth) — a scalar would average that away.
vec3 plagueFogOpacity(PlagueFogTerms t) {
    vec3 transmittance = vec3((1.0 - clamp(t.atm, 0.0, 1.0)) * (1.0 - plagueBorderColorWeight(t.border))
                              * (1.0 - clamp(t.water, 0.0, 1.0))) * t.uwTint;
    return clamp(vec3(1.0) - transmittance, 0.0, 1.0);
}

vec3 plagueApplyFog(vec3 color, vec3 worldPos, float skyLight, float cameraSkyLight,
                    float renderDistance, float cameraAltitude, float dither,
                    PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                    float atmDensity, float borderDensity, float uwDepthFloor,
                    float uwFogStartBlocks, float uwDistanceFogBlocks,
                    float uwDepthFogBlocks, vec3 uwTintBase, vec3 uwDarkness,
                    vec3 atmColorMult) {
    PlagueFogTerms terms = plagueFogTerms(worldPos, skyLight, cameraSkyLight,
                                          renderDistance, cameraAltitude, dither,
                                          skyColours, lighting, sunDirTrue, atmDensity,
                                          borderDensity, uwDepthFloor, uwFogStartBlocks,
                                          uwDistanceFogBlocks, uwDepthFogBlocks, uwTintBase,
                                          uwDarkness, atmColorMult);
    color = mix(color, terms.atmColor, clamp(terms.atm, 0.0, 1.0));
    color = mix(color, terms.borderColor, plagueBorderColorWeight(terms.border));
    color = mix(color, terms.waterColor, clamp(terms.water, 0.0, 1.0));
    return color * terms.uwTint;
}

vec3 plagueApplyFog(vec3 color, vec3 worldPos, float skyLight, float cameraSkyLight,
                    float renderDistance, float cameraAltitude, float dither,
                    PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                    float atmDensity, float borderDensity, float uwDepthFloor) {
    return plagueApplyFog(color, worldPos, skyLight, cameraSkyLight, renderDistance,
                          cameraAltitude, dither, skyColours, lighting, sunDirTrue,
                          atmDensity, borderDensity, uwDepthFloor, 0.0, 32.0, 32.0, vec3(0.80, 0.87, 0.97),
                          vec3(1.0, 1.0, 999.0), vec3(1.0));
}

#endif // PLAGUE_FOG_INCLUDE
