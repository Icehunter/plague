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

uniform sampler2D u_Input0; // ssrRaw: this frame's traced reflection
uniform sampler2D u_Input1; // ssr.history: last frame's accumulated reflection
uniform sampler2D u_Input2; // builtin.gMotion
uniform sampler2D u_Input3; // builtin.depth
uniform sampler2D u_Input4; // builtin.gMaterial: r = smoothness, g = F0, b = porosity/SSS
uniform sampler2D u_Input5; // builtin.gNormal

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec3  u_SunDirection;
};

#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="Fancy" 2="Fast"}

// High because a single mirror ray is a sparse lobe estimate; the disocclusion test below is what
// keeps this from ghosting.
const float SSR_TEMPORAL_BLEND = 0.85;
const float SSR_DISOCCLUSION_DEPTH_THRESHOLD = 0.05;
const float SSR_SHARPEN = 0.4;
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
    float cosine = clamp(dot(centerNormal, sampleNormal), 0.0, 1.0);
    float sg = exp(beta * harmonic * (cosine - 1.0));
    // Falls back to a gentle normal falloff below denormal range, where sg collapses to exactly zero
    // for mirror surfaces and would otherwise leave a pixel with no valid neighbours.
    float gaussian = sg > 1e-8 ? sg : exp(-(1.0 - cosine) * 16.0);
    return amplitude * gaussian;
}

void main() {
    float centerDepth = texture(u_Input3, texCoord).r;

    // gMaterial already carries wetness (baked in by terrain.fsh), so centre and taps read the same
    // number the trace keyed off, with no chance of drift.
    float smoothness = texture(u_Input4, texCoord).r;

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

    vec4 blurred;
    if (radius == 0) {
        // Exact shortcut, not an approximation: at radius 0 the loop below degenerates to comparing
        // the centre tap with itself, which always yields weight 1. Covers smoothness > 5/6 — every
        // wet and puddled surface — skipping 5 of 9 fetches. Verified against the full loop
        // (tools/verify_ssr.py, 0 mismatches).
        blurred = compressRange(texture(u_Input0, texCoord));
    } else {
        vec2 sourceSize = vec2(textureSize(u_Input0, 0));
        vec2 fullSize = vec2(textureSize(u_Input3, 0));
        vec2 texelSize = 1.0 / sourceSize;
        float sourceToFullScale = min(sourceSize.x / max(fullSize.x, 1.0),
                                      sourceSize.y / max(fullSize.y, 1.0));
        float tapSpacingSourceTexels = SSR_BLUR_TAP_SPACING_FULL_RES * sourceToFullScale;
        vec3 cn = texture(u_Input5, texCoord).xyz;
        vec3 centerNormal = dot(cn, cn) > 1e-6 ? normalize(cn) : vec3(0.0, 1.0, 0.0);
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
                float tapDepth = texture(u_Input3, uv).r;
                // Hard depth gate first: the lobe weight alone doesn't always reject a
                // far-side-of-silhouette tap.
                if (abs(tapDepth - centerDepth) > SSR_DISOCCLUSION_DEPTH_THRESHOLD) {
                    continue;
                }
                vec4 tapSample = texture(u_Input0, uv);
                alphaSum += clamp(tapSample.a, 0.0, 1.0);
                alphaTaps += 1.0;
                vec3 sn = texture(u_Input5, uv).xyz;
                if (dot(sn, sn) < 1e-6) {
                    continue;
                }
                vec3 tapNormal = normalize(sn);
                float tapSmoothness = texture(u_Input4, uv).r;
                float tapRoughness = (1.0 - tapSmoothness) * (1.0 - tapSmoothness);
                float w = specularLobeWeight(centerNormal, tapNormal, centerRoughness, tapRoughness, 1.5);
                if (w <= 0.0) {
                    continue;
                }
                sum += compressRange(tapSample) * w;
                weightSum += w;
            }
        }

        // weightSum can legitimately be zero only if every tap was rejected.
        blurred = weightSum > 0.0 ? sum / weightSum : compressRange(texture(u_Input0, texCoord));
        if (alphaTaps > 0.0) {
            blurred.a = alphaSum / alphaTaps;
        }
    }

    vec2 previousUv = texCoord - texture(u_Input2, texCoord).rg;
    bool validHistory = previousUv.x >= 0.0 && previousUv.x <= 1.0
            && previousUv.y >= 0.0 && previousUv.y <= 1.0;
    if (validHistory) {
        float depthAtReprojected = texture(u_Input3, previousUv).r;
        if (abs(centerDepth - depthAtReprojected) > SSR_DISOCCLUSION_DEPTH_THRESHOLD) {
            validHistory = false;
        }
    }

    vec4 accumulated = validHistory
            ? mix(blurred, compressRange(texture(u_Input1, previousUv)), SSR_TEMPORAL_BLEND)
            : blurred;

    fragColor = expandRange(accumulated);
}
