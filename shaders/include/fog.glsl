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
// Underwater, the same terms carry the water instead of the air: what the eye-to-point leg lets
// through per channel and what it adds (underwater.glsl), with the edge curve closing on the
// water's own far radiance. Exact identities above water.
//
// The opaque fullscreen fog pass adds up and blends fog using the current depth. The cave/open-sky
// gate still checks each pixel on its own; using only the camera's sky exposure would jump the
// whole frame the moment the camera crosses a cave mouth.

// Fog options and the PLAGUE_FOG_DRIVE macro, shared by this dispatcher and the cloud fade.
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
    vec3 waterT;        // what the eye-in-water leg lets through per channel; vec3(1) above water
    vec3 waterIn;       // the light that leg adds, linear HDR; vec3(0) above water
};

// Eye-in-water terms, shared with the aerial dispatcher (fog_aerial.glsl). Exact identities above
// water. Underwater there is no air on the ray, so the air term is dropped and the edge curve
// closes on the water's own far radiance instead of the sky.
void plagueFogWaterTerms(inout PlagueFogTerms terms, vec3 worldPos, float rayLength,
                         PlagueLighting lighting, float waterClarity) {
#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        vec3 viewRay = worldPos / max(rayLength, 1e-4);
        terms.atm = vec3(0.0);
        terms.borderColor = plagueWaterClosedRadiance(viewRay, lighting, waterClarity);
        terms.waterT = plagueWaterViewTransmittance(viewRay, rayLength, waterClarity);
        // The lamp glow adds with its own reach rather than scaling the sky's share: a local
        // source, not a brighter day.
        terms.waterIn = plagueWaterViewInScatter(viewRay, rayLength, lighting, waterClarity)
                      + plagueWaterLampGlow(rayLength, waterClarity);
    }
#endif
}

// The dispatcher: every fog quantity for one fragment, computed once.
PlagueFogTerms plagueFogTermsPath(vec3 worldPos, vec3 borderPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float waterClarity,
                              vec3 atmColorMult) {
    PlagueFogTerms terms = PlagueFogTerms(vec3(0.0), vec3(0.0), vec3(0.0), 0.0,
                                          vec3(1.0), vec3(0.0));

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
    // handover note on plagueAtmosphericFog). Guard sliders apply only under Advanced Fog Settings;
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
    // No air between the eye and a submerged fragment, so the air term is wrong there. Dropped
    // before the border reads it, so the edge curve keeps its full reach under water and closes on
    // the water's own far radiance (plagueFogWaterTerms).
#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        terms.atm = vec3(0.0);
    }
#endif
    float atmLuma = dot(terms.atm, vec3(0.2126, 0.7152, 0.0722));
    terms.border = max(0.0, (rawBorder - atmLuma) / max(1.0 - atmLuma, 1e-4));
    // Sky along this ray, the same function the resolve paints the dome with (rule a).
    // doGround=false: the border colour is what the world dissolves into, and a drawn ground plane
    // would swap one edge for another.
    terms.borderColor = plagueGetSky(skyColours, VdotU, VdotS, dither, true, false)
                       * atmColorMult;
    plagueFogWaterTerms(terms, worldPos, rayLength, lighting, waterClarity);
    return terms;
}

// Drawn geometry uses one point for both the segment and the border test. A reflection passes its
// own camera-relative point, so turning the camera cannot move the chunk cutoff.
PlagueFogTerms plagueFogTerms(vec3 worldPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float waterClarity,
                              vec3 atmColorMult) {
    return plagueFogTermsPath(worldPos, worldPos, skyLight, cameraSkyLight, renderDistance,
            cameraAltitude, dither, skyColours, lighting, sunDirTrue, atmDensity, borderDensity,
            waterClarity, atmColorMult);
}

// For callers with no colour mults (particles_translucent.fsh, banner_patterns.fsh).
PlagueFogTerms plagueFogTerms(vec3 worldPos, float skyLight, float cameraSkyLight,
                              float renderDistance, float cameraAltitude, float dither,
                              PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                              float atmDensity, float borderDensity, float waterClarity) {
    return plagueFogTerms(worldPos, skyLight, cameraSkyLight, renderDistance, cameraAltitude,
                          dither, skyColours, lighting, sunDirTrue, atmDensity, borderDensity,
                          waterClarity, vec3(1.0));
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
    // Air first, then the water over it, then the edge over both: the order plagueApplyFog uses.
    // Above water the water pair is an exact identity.
    vec3 p = t.atmColor * clamp(t.atm, 0.0, 1.0) * t.waterT + t.waterIn;
    return mix(p, t.borderColor, borderW);
}
// What is left of the incoming colour, per channel since water takes red first. A scalar would
// average that away.
vec3 plagueFogOpacity(PlagueFogTerms t) {
    vec3 transmittance = (vec3(1.0) - clamp(t.atm, 0.0, 1.0)) * t.waterT
                       * (1.0 - plagueBorderColorWeight(t.border));
    return clamp(vec3(1.0) - transmittance, 0.0, 1.0);
}

vec3 plagueApplyFog(vec3 color, vec3 worldPos, float skyLight, float cameraSkyLight,
                    float renderDistance, float cameraAltitude, float dither,
                    PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                    float atmDensity, float borderDensity, float waterClarity,
                    vec3 atmColorMult) {
    PlagueFogTerms terms = plagueFogTerms(worldPos, skyLight, cameraSkyLight,
                                          renderDistance, cameraAltitude, dither,
                                          skyColours, lighting, sunDirTrue, atmDensity,
                                          borderDensity, waterClarity, atmColorMult);
    color = mix(color, terms.atmColor, clamp(terms.atm, 0.0, 1.0));
    color = color * terms.waterT + terms.waterIn;
    return mix(color, terms.borderColor, plagueBorderColorWeight(terms.border));
}
vec3 plagueApplyFog(vec3 color, vec3 worldPos, float skyLight, float cameraSkyLight,
                    float renderDistance, float cameraAltitude, float dither,
                    PlagueSkyColors skyColours, PlagueLighting lighting, vec3 sunDirTrue,
                    float atmDensity, float borderDensity, float waterClarity) {
    return plagueApplyFog(color, worldPos, skyLight, cameraSkyLight, renderDistance,
                          cameraAltitude, dither, skyColours, lighting, sunDirTrue,
                          atmDensity, borderDensity, waterClarity, vec3(1.0));
}

#endif // PLAGUE_FOG_INCLUDE
