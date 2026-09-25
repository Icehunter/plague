#version 330

// Reconstructs the glossy lobe from ssr_trace's single mirror ray (see ssr_trace.fsh for why a
// per-pixel GGX cone speckles instead); blur radius scales with roughness.
//
// Bilateral, not a box blur: weight represents the specular lobe as a spherical Gaussian, using the
// closed-form overlap of two such Gaussians (Wang et al. 2009, "All-Frequency Rendering of Dynamic,
// Spatially-Varying Reflectance") so a mirror rejects nearly every neighbour with no hand-tuned
// normal exponent.
//
// Averaging happens in compressed L^0.4 space (hue preserved via normalize(rgb) staying untouched)
// so one bright hit doesn't dominate its neighbourhood and re-emerge as a temporally-smeared comet.
//
// One file compiles both the full-res (`ssr_blur`, Fancy) and half-res (`ssr_blur_fast`) passes;
// every size-dependent quantity comes from textureSize() so neither needs to know which it is.
//
// Not separated into two 1D passes: the lobe-overlap weight doesn't factor across x/y, so a
// separable form would change Fancy's output, not just reorganise it.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>

uniform sampler2D u_Input0; // ssrRaw: this frame's traced reflection
uniform sampler2D u_Input1; // ssr.history: last frame's accumulated reflection
uniform sampler2D u_GMotion; // builtin.gMotion
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GMaterial; // builtin.gMaterial: r = smoothness, g = F0, b = porosity/SSS
uniform sampler2D u_GNormal; // builtin.gNormal
#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "World Reflections" {0="Off" 1="On"}
#if PLAGUE_VOXEL_REFLECTIONS != 0
uniform sampler2D u_Input6; // appended input: same-resolution world recovery
#endif

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec3  u_SunDirection;
};

#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="High" 2="Epic"}

// High because one mirror ray per pixel is a thin guess. The depth check below is a guess too:
// it cannot tell the pixel, or the thing it reflected, is the same one as last frame.
const float SSR_TEMPORAL_BLEND = 0.85;
const float SSR_SHARPEN = 0.4;
// Existing GI reconstruction's 0.05-block precision floor and face-agreement threshold.
// Keep the plane bound in world units: a distance-scaled bound admits entire terrain steps
// at long range. tools/verify_terrain_reflection_blur_native.py covers one-block steps and
// coplanar camera slopes at 4..256 blocks; arbitrary curved surfaces are not the same plane.
const float SSR_SURFACE_PLANE_TOLERANCE = 0.05;
const float SSR_SURFACE_NORMAL_REJECT = 0.9;
// Tap spacing in full-res pixels, converted through the actual texture-size ratio so Fast (half-res
// source) and Fancy sample the same authored roughness footprint.
const float SSR_BLUR_TAP_SPACING_FULL_RES = 2.0;
// Must stay in step with the resolve's smoothstep(0.1, 0.35) floor and ssr_trace's own ray cutoff.
const float SSR_MIN_SMOOTHNESS = 0.1;

in vec2 texCoord;
out vec4 fragColor;

vec3 normalizeSafe(vec3 v) {
    float len = length(v);
    return len > 1e-8 ? v / len : vec3(0.0);
}

vec4 compressRange(vec4 c) {
    return vec4(pow(length(c.rgb), SSR_SHARPEN) * normalizeSafe(c.rgb), c.a);
}

vec4 expandRange(vec4 c) {
    return vec4(pow(length(c.rgb), 1.0 / SSR_SHARPEN) * normalizeSafe(c.rgb), clamp(c.a, 0.0, 1.0));
}

vec4 plagueOpaqueRaw(vec2 uv) {
    vec4 screen = texture(u_Input0, uv);
#if PLAGUE_VOXEL_REFLECTIONS != 0
    // Preserve every screen hit byte-for-byte. Only the trace's zero-confidence miss may use
    // world geometry, before roughness filtering so recovery never paints a sharp rough metal.
    if (screen.a <= 0.0) return texture(u_Input6, uv);
#endif
    return screen;
}

vec3 reflectionPosition(vec2 uv, float depth) {
    // Depth is nearest sampled. Reconstruct its texel centre, not the continuous reprojection
    // coordinate: mixing the two moves a sloped surface off its plane during fractional motion
    // and at half-resolution SSR centres. Clamp matches the depth sampler at screen borders.
    ivec2 size = textureSize(u_Depth, 0);
    ivec2 pixel = clamp(ivec2(floor(uv * vec2(size))), ivec2(0), size - 1);
    vec2 depthUv = (vec2(pixel) + 0.5) / vec2(size);
    vec4 position = u_InvProjModelView * vec4(depthUv * 2.0 - 1.0, depth, 1.0);
    return position.xyz / position.w;
}

bool reflectionSameSurface(vec2 uv, float depth, vec4 packedNormal,
        vec3 centerPosition, vec3 centerFace) {
    if (depth <= 0.0 || dot(packedNormal.xyz, packedNormal.xyz) < 1e-6) return false;
    vec3 face = plagueDecodeGeometricNormal(packedNormal.a, normalize(packedNormal.xyz));
    vec3 separation = reflectionPosition(uv, depth) - centerPosition;
    return dot(centerFace, face) >= SSR_SURFACE_NORMAL_REJECT
            && abs(dot(centerFace, separation)) <= SSR_SURFACE_PLANE_TOLERANCE
            && abs(dot(face, separation)) <= SSR_SURFACE_PLANE_TOLERANCE;
}

/** Sharpness of the specular lobe as a spherical Gaussian. Mirrors are enormous, rough are broad. */
float lobeSharpness(float roughness) {
    float r = max(roughness, 1e-5);
    return 2.0 / (r * r);
}

/**
 * Overlap of two specular lobes: an amplitude term penalising roughness mismatch, times a
 * spherical Gaussian on the normals whose width is set by how sharp those lobes actually are.
 */
float specularLobeWeight(vec3 centerNormal, vec3 sampleNormal, float centerRoughness, float sampleRoughness, float beta) {
    float lc = lobeSharpness(centerRoughness);
    float ls = lobeSharpness(sampleRoughness);
    float harmonic = lc * ls / max(lc + ls, 1e-5);
    float amplitude = pow(2.0 * sqrt(lc * ls) / max(lc + ls, 1e-5), beta);
    // For unit normals, dot(n,m)-1 = -0.5*|n-m|^2. The difference form stays exactly zero
    // for identical normals, including oblique mirrors. An underflowed lobe is rejection;
    // replacing it with a broad fallback admits the very bump directions the lobe excluded.
    vec3 delta = centerNormal - sampleNormal;
    return amplitude * exp(-0.5 * beta * harmonic * dot(delta, delta));
}

void main() {
    float centerDepth = texture(u_Depth, texCoord).r;

    // gMaterial already carries wetness (baked in by terrain.fsh), so centre and taps read the same
    // number the trace keyed off, with no chance of drift.
    float smoothness = texture(u_GMaterial, texCoord).r;

    // Early-out for sky and below-smoothness-floor pixels: gbuffer_resolve.fsh never reads ssr for
    // either case, so blurring them was previously pure waste (this pass was the single most
    // expensive in the pack before these were added). Writes zero rather than discarding, since this
    // target ping-pongs and a discard would keep the value from two frames ago, not one.
    if (centerDepth <= 0.0 || smoothness < SSR_MIN_SMOOTHNESS) {
        fragColor = vec4(0.0);
        return;
    }

    // Radius 0 (pass-through) at mirror smoothness, radius 3 at the trace's 0.1 floor.
    int radius = int(round((1.0 - smoothness) * 3.0));

    vec4 centerPacked = texture(u_GNormal, texCoord);
    if (dot(centerPacked.xyz, centerPacked.xyz) < 1e-6) {
        fragColor = vec4(0.0);
        return;
    }
    vec3 centerNormal = normalize(centerPacked.xyz);
    vec3 centerFace = plagueDecodeGeometricNormal(centerPacked.a, centerNormal);
    vec3 centerPosition = reflectionPosition(texCoord, centerDepth);
    vec4 centerCurrent = compressRange(plagueOpaqueRaw(texCoord));
    // Bounds describe only this frame's supported reflection. Zero misses and black hits
    // must remain in the box: either can replace a formerly bright, now-hidden surface.
    vec4 currentLo = centerCurrent;
    vec4 currentHi = centerCurrent;

    vec4 blurred;
    if (radius == 0) {
        // Exact shortcut, not an approximation: at radius 0 the loop below degenerates to comparing
        // the centre tap with itself, which always yields weight 1. Covers smoothness > 5/6.
        // Its current bounds are that single deterministic mirror sample; TAA still accumulates
        // the final image, while this reflection history cannot trail a vanished mirror hit.
        blurred = centerCurrent;
    } else {
        vec2 sourceSize = vec2(textureSize(u_Input0, 0));
        vec2 fullSize = vec2(textureSize(u_Depth, 0));
        vec2 texelSize = 1.0 / sourceSize;
        float sourceToFullScale = min(sourceSize.x / max(fullSize.x, 1.0),
                                      sourceSize.y / max(fullSize.y, 1.0));
        float tapSpacingSourceTexels = SSR_BLUR_TAP_SPACING_FULL_RES * sourceToFullScale;
        float centerRoughness = (1.0 - smoothness) * (1.0 - smoothness);

        vec4 sum = vec4(0.0);
        float weightSum = 0.0;
        // Confidence gets its own uniform-weighted accumulator rather than riding the lobe-rejected
        // colour weights: letting a roughness-varying wear map pick confidence per texel made the
        // wear map itself decide which world (traced vs. resolve fallback) each texel showed.
        float alphaSum = 0.0;
        float alphaTaps = 0.0;
        for (int y = -radius; y <= radius; y++) {
            for (int x = -radius; x <= radius; x++) {
                vec2 uv = texCoord + vec2(float(x), float(y)) * texelSize
                                     * tapSpacingSourceTexels;
                float tapDepth = texture(u_Depth, uv).r;
                vec4 tapPacked = texture(u_GNormal, uv);
                // Check the receiver's geometry before either colour OR confidence. A bump
                // normal can agree across a block corner while the actual faces disagree.
                if (!reflectionSameSurface(uv, tapDepth, tapPacked, centerPosition, centerFace)) {
                    continue;
                }
                vec4 tapSample = plagueOpaqueRaw(uv);
                alphaSum += clamp(tapSample.a, 0.0, 1.0);
                alphaTaps += 1.0;
                vec3 tapNormal = normalize(tapPacked.xyz);
                float tapSmoothness = texture(u_GMaterial, uv).r;
                float tapRoughness = (1.0 - tapSmoothness) * (1.0 - tapSmoothness);
                float w = specularLobeWeight(centerNormal, tapNormal, centerRoughness, tapRoughness, 1.5);
                if (w <= 0.0) {
                    continue;
                }
                vec4 current = compressRange(tapSample);
                sum += current * w;
                weightSum += w;
                currentLo = min(currentLo, current);
                currentHi = max(currentHi, current);
            }
        }

        // weightSum can legitimately be zero only if every tap was rejected.
        blurred = weightSum > 0.0 ? sum / weightSum : centerCurrent;
        if (alphaTaps > 0.0) {
            blurred.a = alphaSum / alphaTaps;
        }
    }
    currentLo = min(currentLo, blurred);
    currentHi = max(currentHi, blurred);

    // Motion leaves out both wobble offsets; history holds last frame's wobbled picture.
    vec2 previousUv = texCoord - texture(u_GMotion, texCoord).rg
            + 0.5 * (u_PrevJitterOffset - u_JitterOffset);
    bool validHistory = u_LocalActorFluid.w < 0.5 && previousUv.x >= 0.0 && previousUv.x <= 1.0
            && previousUv.y >= 0.0 && previousUv.y <= 1.0;
    if (validHistory) {
        // Current geometry is only a coverage heuristic, not the previous frame's surface.
        // The current supported-colour bounds below reject stale energy without another
        // full-resolution history allocation. They cannot identify old geometry exactly.
        float depthAtReprojected = texture(u_Depth, previousUv).r;
        validHistory = reflectionSameSurface(previousUv, depthAtReprojected,
                texture(u_GNormal, previousUv), centerPosition, centerFace);
    }

    vec4 accumulated = blurred;
    if (validHistory) {
        vec4 history = clamp(compressRange(texture(u_Input1, previousUv)), currentLo, currentHi);
        accumulated = mix(blurred, history, SSR_TEMPORAL_BLEND);
    }

    fragColor = expandRange(accumulated);
}
