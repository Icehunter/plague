// Guard name is not PLAGUE_FOG: that is the pack option declared below, and a guard with the same
// name is redefined once the option's own #define is reached, breaking every file that includes
// this one.
#ifndef PLAGUE_FOG_INCLUDE
#define PLAGUE_FOG_INCLUDE

// Fog is always on. Its job is hiding the render distance edge, not mood.
// (a) Fog colour is the sky colour along the view ray (plagueGetSky, doGlare=true, doGround=false).
//     At opacity 1.0 a cutoff pixel becomes the sky beside it, bit for bit, so the edge is gone.
// (b) Density comes from render distance, never from blocks: min(192/renderDistance, 1.0), 192
//     being vanilla's 12-chunk default. Fog tuned at 16 chunks is soup at 8, a hard edge at 32.
// Sky and clouds are not fogged: the sky is the fog colour, and the cloud include already fades
// toward the sky along the same ray. Every curve constant here is fit by tools/derive_fog.py.
//
// No cave fog: the lowest-light table it would be tuned against runs about 2.4x too strong against
// decoded albedo, so any haze tuned against it needs retuning when that table is corrected, and the
// two changes could not be told apart. The enclosure gate below is built, cutting outdoor fog on a near
// fragment with no sky; a far unlit cave sightline still picks up a little haze.
//
// Underwater fog rides this dispatcher as a third, outermost PlagueFogTerms term plus a scene tint
// (underwater.glsl). Both are exact identities above water.
//
// Tried and dropped: a fullscreen fog pass (a whole rgba16f read and write per frame, buying
// nothing the owning passes lack); driving the enclosure gate off the camera sky light uniform
// (unsmoothed, so a cave mouth crossing steps the haze across the whole frame in one frame).

// Fog options and the PLAGUE_FOG_DRIVE macro, shared by this dispatcher, the cloud fade and the
// reflection probe's cloud imposter.
#moj_import <fornax_runtime:fog_options.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:sky.glsl>
// The curves and constants sit in fog_model.glsl so the cloud march can share them without this
// file's runtime options or the underwater arm below.
#moj_import <fornax_runtime:fog_model.glsl>
// Eye-in-water colour, closure and tint. Imported after the two above because it uses
// PlagueLighting. Its caustic section compiles only under PLAGUE_UNDERWATER_CAUSTIC_HOOK
// (gbuffer_resolve.fsh only).
#moj_import <fornax_runtime:underwater.glsl>

// Colour and opacity stay separate per term: a forward site draws into an already tonemapped frame,
// so it must push the fog colour through the display transform while leaving opacity alone, which
// mixing the two makes impossible. plagueApplyFog is a thin wrapper over the same mixes, checked
// bit-identical to this by tools/verify_fog.py.
struct PlagueFogTerms {
    vec3 atmColor;      // haze colour, linear HDR
    vec3 atm;           // its opacity per channel, 0..1; blue dies before red
    vec3 borderColor;   // the sky along this ray, what the world dissolves into at the edge
    float border;       // its opacity, 0..1, outer of the two air terms
    vec3 waterColor;    // eye-in-water fog colour (underwater.glsl); vec3(0) above water
    float water;        // its opacity, 0..1, applied outermost of all
    vec3 uwTint;        // underwater scene tint; exactly vec3(1.0) above water
};

// Eye-in-water terms, shared with the aerial dispatcher (fog_aerial.glsl). Exact identities above
// water.
void plagueFogWaterTerms(inout PlagueFogTerms terms, vec3 worldPos, float rayLength,
                         float renderDistance, PlagueLighting lighting, float uwDepthFloor,
                         float uwFogStartBlocks, float uwDistanceFogBlocks, float uwDepthFogBlocks,
                         vec3 uwTintBase, vec3 uwDarkness) {
#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        // WATER_VEIL and WATER_ABSORPTION_TINT are separate gates under the same u_WaterState
        // branch: one shared gate would let turning off "Water Fog" quietly drop the scene tint
        // too, 30-45% per channel. Named WATER_ABSORPTION_TINT because water_composite.fsh already
        // declares an unrelated local of the name WATER_TINT.
#if WATER_VEIL
        // No dither on the mix factor: its error scales with veil-to-scene contrast, so it peaks
        // along the veil's own gradient as visible lines. Quantisation is handled once, at the end
        // of tonemap.fsh. Lamp glow adds with its own falloff rather than lifting the lit scale,
        // since it is a local source.
        terms.water = plagueGetWaterFogAniso(worldPos, uwFogStartBlocks,
                                             uwDistanceFogBlocks, uwDepthFogBlocks);
        terms.waterColor = plagueWaterFogColor(lighting)
                         * plagueWaterVeilDarkness(worldPos, uwDistanceFogBlocks, uwDarkness.z,
                                                   uwDarkness.x, uwDarkness.y)
                         + plagueWaterLampGlow(lighting, rayLength);
#endif
#if WATER_ABSORPTION_TINT
        // Display-referred ratio, made linear once here. Carries depth: while depth-blind, going
        // down made the frame brighter, near blocks being lit as if at the surface (measured live,
        // Y=33 brighter than Y=58).
        terms.uwTint = plagueAuthoredToLinear(
                plagueUnderwaterMult(rayLength, renderDistance, uwDepthFloor, lighting,
                                     uwTintBase) * 0.85)
                     * plagueWaterDepthDim(worldPos, uwDarkness.z, uwDarkness.y);
#endif
    }
#endif
}

// The dispatcher: every fog quantity for one fragment, computed once.
PlagueFogTerms plagueFogTermsPath(vec3 worldPos, vec3 borderPos, float skyLight, float cameraSkyLight,
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

    // Options and frame signals in one struct, the same macro the cloud fade and reflection probe
    // use, so all three agree.
    PlagueFogDrive drive = PLAGUE_FOG_DRIVE(lighting);

    // Keyed on the fragment's own sky light, never the camera's: a camera-keyed gate breaks sunlit
    // terrain seen through a cave mouth. Handed to the aerial term rather than multiplied in here,
    // since how much light that term stops decides how far the gate can still be right (see the
    // handover note on plagueAtmosphericFog). Guard sliders apply only under Advanced Overrides;
    // each literal matches its option's declared default (harness-pinned).
    float access = smoothstep(mix(0.05, u_FogCaveGuardLo, drive.advanced),
                              mix(0.35, u_FogCaveGuardHi, drive.advanced),
                              clamp(skyLight, 0.0, 1.0));

    // Fog is scattered light, so full strength along a path no sky light reaches would haze a
    // sealed unlit cave (screenshot 217). max() of the path's two ends is all a lightmap can
    // answer, and it lets the camera only add light, never take it away: a cave mouth looking out
    // at sunlit terrain is untouched. The camera term rides squared raw sky light (this pack's
    // lightmap-to-light conversion), which also evens out the uniform's stepped sRGB values.
    float camLight = clamp(cameraSkyLight, 0.0, 1.0);
    float pathLight = max(access, camLight * camLight);

    // Applied to the term, not folded into density, so the gate's handover maths above stays keyed
    // to the real curve. Does not touch the cloud fade: clouds must keep melting into the sky where
    // the terrain veil closes. Per channel, so far terrain loses red before blue instead of greying
    // out evenly; the cloud fade stays on the grey scalar twin.
    terms.atm = plagueAtmosphericFog3(rayLength, fragAltitude, cameraAltitude, renderDistance,
                                      drive, atmDensity, access) * u_FogEnableDistance;
    float heightWeight = plagueFogHeightWeight(fragAltitude, drive.H);

    // Scales the colour, not the opacity: in the dark there is nothing left to scatter in, but the
    // air still blocks light (light off a torch-lit wall still scatters out of a dark path).
    // Dropping opacity instead would wrongly hand that light back.
    terms.atmColor = plagueAtmFogColor(skyColours, VdotS, heightWeight, lighting) * atmColorMult
                    * pathLight;

    // Horizontal radius only. Minecraft culls chunks by XZ distance, never by Y, so render distance
    // is a cylinder, not a cube. max(xz, |y|) would pull the cutoff in toward the camera on any
    // steep look from height, ahead of the true horizontal distance.
    float borderDist = length(borderPos.xz);
    float borderFraction = clamp(borderDist / max(renderDistance, PLAGUE_FOG_MIN_RENDER_DISTANCE),
                                 0.0, 1.0);

    // Gated near, ungated far. Ungated everywhere makes a cutoff pixel bit for bit the sky beside
    // it, a cave mouth at that distance included. Gating near stops the veil glowing inside sealed
    // caves as the reach slider pulls it in (4.9 display codes measured on a 110-block underground
    // sightline without it). The crossover sits below any reach's real opacity, so only caves are
    // affected.
    float borderGate = mix(pathLight, 1.0,
                           smoothstep(mix(0.55, u_FogBorderGateNear, drive.advanced),
                                      mix(0.80, u_FogBorderGateFar, drive.advanced),
                                      borderFraction));
    // Edge Fog multiplies the finished term: off shows the raw render edge, which is the point of
    // the switch.
    float rawBorder = plagueBorderFog(borderDist, renderDistance, borderDensity) * borderGate
                    * u_FogEnableEdge;

    // Border fills only the gap the aerial term's own brightness leaves, not a stack of the two.
    // atmLuma reads terms.atm. Total opacity of the two mixes equals max(atmLuma, rawBorder): below
    // the crossover this term is 0 and atm alone shows; at and past it, the (raw-L)/(1-L) rescale
    // cancels atm and the total is rawBorder. rawBorder hits exactly 1.0 at the cutoff for every
    // reach (fog_model.glsl), so terms.border does too, and the render edge stays hidden.
    float atmLuma = dot(terms.atm, vec3(0.2126, 0.7152, 0.0722));
    terms.border = max(0.0, (rawBorder - atmLuma) / max(1.0 - atmLuma, 1e-4));

    // No air between the eye and a submerged fragment, so air and border fog are wrong there, not
    // just weak. The water term below owns the whole closure.
#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        terms.atm = vec3(0.0);
        terms.border = 0.0;
    }
#endif

    // Sky along this ray, the same function the resolve paints the dome with (rule a).
    // doGround=false: the border colour is what the world dissolves into, and a drawn ground plane
    // would swap one edge for another.
    terms.borderColor = plagueGetSky(skyColours, VdotU, VdotS, dither, true, false)
                       * atmColorMult;

    plagueFogWaterTerms(terms, worldPos, rayLength, renderDistance, lighting, uwDepthFloor,
                        uwFogStartBlocks, uwDistanceFogBlocks, uwDepthFogBlocks, uwTintBase,
                        uwDarkness);
    return terms;
}

// Drawn geometry uses one point for both the segment and the border test. A reflection passes its
// own camera-relative point, so turning the camera cannot move the chunk cutoff.
PlagueFogTerms plagueFogTerms(vec3 worldPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float uwDepthFloor,
                              float uwFogStartBlocks, float uwDistanceFogBlocks,
                              float uwDepthFogBlocks, vec3 uwTintBase, vec3 uwDarkness,
                              vec3 atmColorMult) {
    return plagueFogTermsPath(worldPos, worldPos, skyLight, cameraSkyLight, renderDistance,
            cameraAltitude, dither, skyColours, lighting, sunDirTrue, atmDensity, borderDensity,
            uwDepthFloor, uwFogStartBlocks, uwDistanceFogBlocks, uwDepthFogBlocks,
            uwTintBase, uwDarkness, atmColorMult);
}

// Fallback for callers with no runtime access to the water fog options or colour mults
// (terrain.fsh, particles_translucent.fsh, banner_patterns.fsh); only gbuffer_resolve.fsh and
// water_composite.fsh reach the real 15-arg overload. The 32.0/32.0 pair is a stand-in for those
// callers, a standing gap.
PlagueFogTerms plagueFogTerms(vec3 worldPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float uwDepthFloor) {
    return plagueFogTerms(worldPos, skyLight, cameraSkyLight, renderDistance, cameraAltitude,
                          dither, skyColours, lighting, sunDirTrue, atmDensity, borderDensity,
                          uwDepthFloor, 0.0, 32.0, 32.0, vec3(0.80, 0.87, 0.97),
                          vec3(1.0, 1.0, 999.0), vec3(1.0));
}

// Must replace fully at the edge, or the sky pixel just past the last fragment leaves a hard seam
// at the cutoff instead of a wash. Squared, not cubed: cubing crushes the whole fade into the last
// few pixels before the cutoff, reading as a hard line. Squaring still fades smoothly while keeping
// far objects, a village or hillside a few hundred blocks out, mostly visible.
float plagueBorderColorWeight(float border) {
    float w = clamp(border, 0.0, 1.0);
    return w * w;
}

// plagueApplyFog is exactly affine in `color`: every op is a mix() whose factor comes from geometry
// and sky state alone. These are its two halves, taken from the live terms so a fourth struct term
// flows through with no edit.
vec3 plaguePremultipliedFog(PlagueFogTerms t) {
    float borderW = plagueBorderColorWeight(t.border);
    vec3 p = mix(t.atmColor * clamp(t.atm, 0.0, 1.0), t.borderColor, borderW);
    // Water term outermost, then the underwater tint over all of it, the order plagueApplyFog
    // uses. Above water this is exact identities.
    return mix(p, t.waterColor, clamp(t.water, 0.0, 1.0)) * t.uwTint;
}

// What is left of the incoming colour, per channel since the underwater tint dies per channel, red
// first with depth. A scalar would average that away.
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
