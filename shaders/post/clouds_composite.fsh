#version 330

// Blends the marched clouds over the scene, in HDR, before bloom and the tonemap. A separate pass
// from the march because the march writes at half resolution (two of three quality tiers) while
// the scene is full resolution, so this reconstructs at scene resolution instead.
//
// The march writes PREMULTIPLIED (rgb*a, a) because bilinear-filtering straight colour against
// zero-alpha (rgb=0) texels darkens cloud edges toward black at magnification. This pass divides
// back out to straight colour for Fornax's translucent blend, since the engine has no
// premultiplied blend mode.
//
// builtin.depth is unused: listed only so a depth-aware bilateral upsample (if half-res silhouettes
// shimmer against terrain edges in motion) is a shader edit, not a graph edit.

#moj_import <fornax:globals.glsl>
// underwater.glsl needs the lighting include first: its colour helpers take PlagueLighting.
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:underwater.glsl>

uniform sampler2D u_Input0; // clouds (premultiplied rgba16f, half or full resolution)
uniform sampler2D u_Input1; // builtin.depth; unused, see note above
uniform sampler2D u_Input2; // builtin.waterDepth (reversed-Z, 0.0 = no surface), for the eye-in-water veil

#moj_import <fornax_runtime:water_options.glsl>
in vec2 texCoord;
out vec4 fragColor; // straight rgb+alpha; the pipeline's translucent blend composites it

void main() {
    // Four taps at a rotated cross of one FULL half-res texel: the spatial half of the march's own
    // interleaved-gradient-noise dither resolve (the march undersamples and offsets each pixel's
    // first sample by IGN; this pass was previously leaning on TAA's temporal half alone, which
    // left a halftone on backlit cloud where reprojection clamps history at high-contrast edges).
    //
    // MEASURED across five AA modes: the pattern survived under pure-supersampling SSAA at a
    // half-texel offset (footprints overlapped too much to sample distinct phases), so the offset
    // was widened to a full texel; four diagonal taps then cover the 2x2 block IGN interleaves
    // across. Cost is bounded (~2 screen pixels of edge softening); a wider kernel would start
    // blurring the silhouette itself.
    //
    // Averaging premultiplied (rgb*a, a) is linear and reproduces the march's own accumulation;
    // averaging straight colour would drag transparent texels' rgb into the result.
    vec2 tap = 1.0 / vec2(textureSize(u_Input0, 0));
    vec4 c = 0.25 * (texture(u_Input0, texCoord + vec2( tap.x,  tap.y))
                   + texture(u_Input0, texCoord + vec2(-tap.x,  tap.y))
                   + texture(u_Input0, texCoord + vec2( tap.x, -tap.y))
                   + texture(u_Input0, texCoord + vec2(-tap.x, -tap.y)));

    // Early-out keeps the divide below away from zero on the overwhelming majority of pixels.
    if (c.a <= 0.0) { fragColor = vec4(0.0); return; }

#if PLAGUE_UNDERWATER
    // No clouds underwater at all, matching the resolve's sky arm: the underwater sky is a total
    // override, so any cloud composited over it would be sky content escaping that override.
    if (u_WaterState.x > 0.5) { fragColor = vec4(0.0); return; }
#endif

    fragColor = vec4(c.rgb / c.a, c.a);
}
