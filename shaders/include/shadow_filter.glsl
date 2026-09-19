#ifndef PLAGUE_SHADOW_FILTER
#define PLAGUE_SHADOW_FILTER
// Consumer defines SUN_SHADOW_MAP, or overrides SUN_SHADOW_LOOKUP to compose raw depths.
// The same projection, sample positions and filter govern both backends.
#ifndef SUN_SHADOW_LOOKUP
#define SUN_SHADOW_LOOKUP(receiver, uv, reference) texture(SUN_SHADOW_MAP, vec3(uv, reference))
#endif
// Sun visibility at a camera-relative world position, 1.0 lit, 0.0 fully shadowed. The shadow map
// is written with a radial distortion (u_ShadowMapParams.x) that must be matched on read, or every
// off-centre sample lands on the wrong texel and shows up as acne.
//
// Trap: moving this into shadow.glsl as a wrapper turned every lit surface black. Suspected cause
// is a sampler2DShadow crossing a function-parameter boundary, a rough edge in some GLSL->SPIR-V
// lowering. Check in a running client, not just check_shaders.sh, before trying again.

// Golden-angle (Vogel) disk PCF, radius ~ (i/N)^p, with p and the per-count radius fitted against a
// committed fixture (tools/verify_shadow_filter.py re-checks it). Vogel 1979. Each sample is a
// +/-offset pair, halving noise for the same taps. Reads SUN_SHADOW_MAP as a global, for the same
// reason this function is kept inline.

// radius_i = diskRadius * (i / SHADOW_SAMPLES)^p. Fitted jointly across all four sample counts.
const float PLAGUE_SHADOW_RADIAL_EXPONENT = 1.266505;

// Disk outer radius per sample count, as a share of whatever width the filter is given.
// Growing with N is expected: more rings reach further out for the same profile width.
#if SHADOW_SAMPLES == 2
const float PLAGUE_SHADOW_DISK_RADIUS = 1.358320;
#elif SHADOW_SAMPLES == 4
const float PLAGUE_SHADOW_DISK_RADIUS = 1.677305;
#elif SHADOW_SAMPLES == 8
const float PLAGUE_SHADOW_DISK_RADIUS = 1.942500;
#else // SHADOW_SAMPLES == 16
const float PLAGUE_SHADOW_DISK_RADIUS = 2.046826;
#endif

// Angular step between consecutive Vogel-disk taps: 2*pi * (1 - 1/phi).
const float PLAGUE_SHADOW_GOLDEN_ANGLE = 2.39996323;

const float PLAGUE_SHADOW_TWO_PI = 6.28318531;

// Wider than the sun-disc penumbra: a caster blocks the sky dome broadly, and the fill-light
// darkening needs a smooth signal or the sharp per-pixel visibility blotches it.
const float PLAGUE_SHADOW_AMBIENT_BROADEN = 4.0;

// Overcast rain is a larger, softer light source, so the penumbra widens with the square of rain
// intensity (matched to the fixture's recorded full-rain d-scale).
const float PLAGUE_SHADOW_RAIN_WIDEN_SCALE = 3.0;

// The Sun's angular diameter seen from Earth, in radians: 0.53 degrees. This is the only number
// the penumbra width needs, and it is a measurement rather than a taste.
const float PLAGUE_SUN_ANGULAR_SIZE = 0.00925;
// How far the blocker search reaches, in shadow-map texels. Wide enough to find the caster for any
// penumbra this can produce at a sane shadow distance, narrow enough that the search stays cheap.
const float PLAGUE_SHADOW_SEARCH_TEXELS = 4.0;
// The light camera's depth half-extent is max(8192, shadowDistance * 2) blocks, so its full depth
// range is twice that. Stored depth runs 0 to 1 across it, which is what turns a depth difference
// back into blocks. See ShadowCamera.depthHalfExtent.
float plagueShadowDepthRangeBlocks() {
    return 2.0 * max(8192.0, u_ShadowDistance * 2.0);
}

/**
 * How wide this receiver's penumbra is, in shadow-map UV.
 *
 * Finds what is casting on this point, measures how far above it that caster sits, and turns the
 * gap into a width using the Sun's own angular size. A caster touching the ground gives almost
 * nothing, so contact stays sharp; the same caster fifty blocks up gives a wide soft band. That is
 * how a shadow behaves, and no setting can be right in both places at once.
 *
 * Zero means nothing was found casting here, so there is nothing to soften and the filter is
 * skipped. The search reads raw stored depths, not the comparison sampler: a comparison answers
 * lit or not, and this needs to know HOW FAR.
 */
float plagueShadowPenumbraUv(vec2 shadowUv, float refDepth, float temporalNoise) {
    ivec2 size = textureSize(SHADOW_RAW_MAP, 0);
    vec2 texel = 1.0 / vec2(size);
    float frameAngle = temporalNoise * PLAGUE_SHADOW_TWO_PI;
    float blockerSum = 0.0;
    float blockerCount = 0.0;
    for (int i = 1; i <= SHADOW_SAMPLES; ++i) {
        float t = float(i) / float(SHADOW_SAMPLES);
        float radius = PLAGUE_SHADOW_SEARCH_TEXELS * pow(t, PLAGUE_SHADOW_RADIAL_EXPONENT);
        float angle = float(i) * PLAGUE_SHADOW_GOLDEN_ANGLE + frameAngle;
        vec2 offset = vec2(cos(angle), sin(angle)) * radius * texel;
        for (int side = 0; side < 2; ++side) {
            vec2 uv = side == 0 ? shadowUv + offset : shadowUv - offset;
            if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0) {
                continue;
            }
            float stored = texelFetch(SHADOW_RAW_MAP, ivec2(uv * vec2(size)), 0).r;
            // Nearer the light than the receiver, which is what casts on it. The handoff compares
            // the same way round: step(reference, stored) is lit.
            if (stored < refDepth) {
                blockerSum += stored;
                blockerCount += 1.0;
            }
        }
    }
    if (blockerCount <= 0.0) {
        return 0.0;
    }
    float gapBlocks = (refDepth - blockerSum / blockerCount) * plagueShadowDepthRangeBlocks();
    // Across the map, which spans twice the shadow distance.
    return (gapBlocks * PLAGUE_SUN_ANGULAR_SIZE) / max(2.0 * u_ShadowDistance, 1.0);
}

// temporalNoise rotates the whole disk each frame (interleaved gradient noise stepped by the
// golden-ratio fraction, Jimenez 2014), so the rotation spreads evenly around the circle over many
// frames (Weyl equidistribution): the condition the radii above were fitted under.
float plagueSunVisibilityFiltered(vec3 receiver, vec2 shadowUv, float refDepth, float texelScale,
                                  float temporalNoise, float rainFactor) {
    float rainScale = 1.0 + (PLAGUE_SHADOW_RAIN_WIDEN_SCALE - 1.0) * rainFactor * rainFactor;
    float diskRadiusTexels = PLAGUE_SHADOW_DISK_RADIUS * rainScale;
    float frameAngle = temporalNoise * PLAGUE_SHADOW_TWO_PI;

    float visSum = 0.0;
    for (int i = 1; i <= SHADOW_SAMPLES; ++i) {
        float t = float(i) / float(SHADOW_SAMPLES);
        float radius = diskRadiusTexels * pow(t, PLAGUE_SHADOW_RADIAL_EXPONENT);
        float angle = float(i) * PLAGUE_SHADOW_GOLDEN_ANGLE + frameAngle;

        vec2 offset = vec2(cos(angle), sin(angle)) * radius * texelScale;

        visSum += SUN_SHADOW_LOOKUP(receiver, shadowUv + offset, refDepth);
        visSum += SUN_SHADOW_LOOKUP(receiver, shadowUv - offset, refDepth);
    }

    return visSum / float(2 * SHADOW_SAMPLES);
}

float sunVisibilityAt(vec3 worldPos, vec3 normal, vec3 sunDir, float rainFactorForShadow,
                      float radiusScale) {
    // Offset along the normal before projecting. Depth bias alone cannot fix acne on surfaces
    // near-parallel to the light: the bias needed there runs to infinity, where a normal offset
    // stays bounded and scales with texel size.
    float slope = 1.0 - abs(dot(normal, sunDir));
    vec3 biased = worldPos + normal * (0.05 + 0.35 * slope);

    // On top of the normal offset, not instead of it: that offset moves the compared depth by
    // dot(normal, sunDir), which goes to zero at grazing angles, exactly where slope above is
    // largest. sunDir is unit length, so this term does not depend on angle and covers the gap.
    biased += sunDir * 0.05;

    vec4 lightClip = u_SunViewProj * vec4(biased, 1.0);
    vec3 lightNdc = lightClip.xyz / lightClip.w;

    float radius = length(lightNdc.xy);
    float distortFactor = radius * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    vec2 shadowUv = (lightNdc.xy / distortFactor) * 0.5 + 0.5;

    float rawDepth = lightNdc.z;
    if (shadowUv.x <= 0.0 || shadowUv.x >= 1.0 || shadowUv.y <= 0.0 || shadowUv.y >= 1.0
            || rawDepth <= 0.0 || rawDepth >= 1.0) {
        return 1.0; // outside the map: unshadowed rather than guessing
    }
    // The write side stores gl_Position.z unscaled, so no conversion sits between the two.
    float refDepth = rawDepth;

    // Interleaved gradient noise (Jimenez 2014), advanced per frame by the golden-ratio fraction so
    // TAA resolves the dither into a smooth penumbra instead of a repeating pattern. Frame counter
    // wrapped at 4096 to stay inside float precision; dense enough to be invisible.
    float gradientNoise = fract(52.9829189 * fract(0.06711056 * gl_FragCoord.x
                                                   + 0.00583715 * gl_FragCoord.y));
    const float goldenRatioFrac = 0.61803398875;
    float temporalNoise = fract(gradientNoise + goldenRatioFrac * mod(u_FrameState.x, 4096.0));

    // The width comes from the geometry, not from a setting: how far the caster sits above this
    // point, times the Sun's angular size. Nothing casting here means nothing to soften.
    // Shadow Softness scales the width the geometry asked for, rather than setting it. At 1 the
    // edge is the width the Sun's angular size gives; lower sharpens it, higher spreads it. One
    // value suits every shadow, because the width it scales moves with the geometry.
    float penumbraUv = plagueShadowPenumbraUv(shadowUv, refDepth, temporalNoise)
            * radiusScale * u_ShadowSoftness;
    // The fitted disk radii describe the filter's SHAPE at whatever width it is given, so the
    // width divides out here and the profile they were fitted under is kept. A width of zero
    // collapses every tap onto the middle texel, which is a hard edge and costs no branch.
    float texelScale = penumbraUv / PLAGUE_SHADOW_DISK_RADIUS;

    return plagueSunVisibilityFiltered(worldPos, shadowUv, refDepth, texelScale, temporalNoise,
                                       rainFactorForShadow);
}

float sunVisibility(vec3 worldPos, vec3 normal, vec3 sunDir, float rainFactorForShadow) {
    return sunVisibilityAt(worldPos, normal, sunDir, rainFactorForShadow, 1.0);
}

#endif
