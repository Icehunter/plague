#version 330

// Blends the marched clouds over the scene, in HDR, before bloom and the tonemap. A separate pass
// from the march because the march writes at half resolution (two of three quality tiers) while
// the scene is full resolution, so this reconstructs at scene resolution instead.
//
// The march writes PREMULTIPLIED (rgb*a, a) so the fixed-tap reconstruction can average cloud
// energy and opacity without transparent texels' colour leaking into the result. This pass divides
// back out to straight colour for Fornax's translucent blend, since the engine has no
// premultiplied blend mode.
//
// The march also carries its first density-bearing distance. Comparing that distance with the
// destination pixel's terrain prevents source-pixel terrain from erasing or lending clouds at a
// silhouette while retaining clouds that are genuinely in front of geometry.

#moj_import <fornax:globals.glsl>
// underwater.glsl needs the lighting include first: its colour helpers take PlagueLighting.
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:underwater.glsl>

uniform sampler2D u_Input0; // clouds (premultiplied rgba16f, half or full resolution)
uniform sampler2D u_Input1; // builtin.depth (reversed-Z: 0.0 sky, >0.0 geometry)
uniform sampler2D u_Input2; // builtin.waterDepth (reversed-Z, 0.0 = no surface), for the eye-in-water veil
uniform sampler2D u_Input3; // first density-bearing cloud distance (r32f; 0.0 means empty ray)

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
    ivec2 sourceSize = textureSize(u_Input0, 0);
    vec2 tap = 1.0 / vec2(sourceSize);
    vec2 offsets[4] = vec2[4](
        vec2( tap.x,  tap.y),
        vec2(-tap.x,  tap.y),
        vec2( tap.x, -tap.y),
        vec2(-tap.x, -tap.y));

    float destinationDepth = texture(u_Input1, texCoord).r;
    bool destinationGeometry = destinationDepth > 0.0;
    float destinationTerrainDistance = 0.0;
    if (destinationGeometry) {
        vec4 destinationH = u_InvProjModelView
                * vec4(texCoord * 2.0 - 1.0, destinationDepth, 1.0);
        destinationTerrainDistance = length(destinationH.xyz / destinationH.w);
    }

    // The water SURFACE occludes a cloud behind it, and opaque depth cannot say so: at a water
    // pixel that depth belongs to the lake bed, which is further than the surface and often further
    // than the cloud. water_composite draws after this pass and blends unconditionally, so a cloud
    // left visible here is painted over. Without this test, looking down from above the deck, every
    // lake and sea reads as sitting on top of the cloud.
    //
    // Reconstructed exactly as the terrain distance above is, from the same reversed-Z convention;
    // 0.0 is this target's "no surface" sentinel, not a near plane.
    float waterSurfaceDepth = texture(u_Input2, texCoord).r;
    float destinationWaterDistance = 0.0;
    if (waterSurfaceDepth > 0.0) {
        vec4 waterH = u_InvProjModelView
                * vec4(texCoord * 2.0 - 1.0, waterSurfaceDepth, 1.0);
        destinationWaterDistance = length(waterH.xyz / waterH.w);
    }

    vec4 c = vec4(0.0);
    for (int i = 0; i < 4; ++i) {
        vec2 sampleUv = texCoord + offsets[i];
        // First-hit distance is discontinuous and zero is its empty sentinel. Fetching both values
        // from one exact texel preserves their ordering before destination-depth visibility.
        ivec2 sampleTexel = clamp(ivec2(floor(sampleUv * vec2(sourceSize))),
                                  ivec2(0), sourceSize - ivec2(1));
        vec4 sampleCloud = texelFetch(u_Input0, sampleTexel, 0);
        float cloudFrontDistance = texelFetch(u_Input3, sampleTexel, 0).r;
        bool cloudVisible = cloudFrontDistance > 0.0
                && (!destinationGeometry || cloudFrontDistance < destinationTerrainDistance)
                && (destinationWaterDistance <= 0.0
                    || cloudFrontDistance < destinationWaterDistance);
        if (cloudVisible) {
            c += sampleCloud;
        }
    }
    c /= 4.0;

    // Early-out keeps the divide below away from zero on the overwhelming majority of pixels.
    if (c.a <= 0.0) { fragColor = vec4(0.0); return; }

#if PLAGUE_UNDERWATER
    // No clouds underwater at all, matching the resolve's sky arm: the underwater sky is a total
    // override, so any cloud composited over it would be sky content escaping that override.
    if (u_WaterState.x > 0.5) { fragColor = vec4(0.0); return; }
#endif

    fragColor = vec4(c.rgb / c.a, c.a);
}
