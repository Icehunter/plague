#version 330

// Half-res reflections back to full res. Fast tier only (SSR_QUALITY == 2); Fancy never runs this.
//
// Joint bilateral upsample: the four half-res texels covering this pixel are weighted by bilinear
// footprint AND gated on agreeing with this pixel's depth, so a wall's reflection can't bleed onto
// the floor behind it the way a plain bilinear upsample would (the exact defect ssr_blur's bilateral
// filter exists to avoid). If none agree, the single closest in depth is taken whole (degrades to
// point sampling, not a halo).
//
// Depth test is relative (fraction of centreDepth), not a fixed NDC epsilon: reversed-Z depth is
// ~near/distance, so a relative threshold holds the same tolerance at 5 blocks and at 200.
//
// No <fornax:globals.glsl> import: this pass only needs texel size and depth, both already carried
// in u_PassParams/u_Input1, so it stays free of ssr_trace.fsh's thickness-window machinery.

uniform sampler2D u_Input0; // ssrHalf: rgb = reflected colour, a = hit confidence, at half scale
uniform sampler2D u_Input1; // builtin.depth (full res)
uniform sampler2D u_Input2; // builtin.gMaterial: r = smoothness

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

// A tap is the same surface within this fraction of the centre's depth: 0.2 blocks at 10, 2 at 100.
const float SSR_UPSAMPLE_DEPTH_TOLERANCE = 0.02;
// Matches ssr_trace's early-out and the lower bound of the resolve's smoothstep(0.1, 0.35) fade.
const float SSR_MIN_SMOOTHNESS = 0.1;

in vec2 texCoord;
out vec4 fragColor;

void main() {
    float centerDepth = texture(u_Input1, texCoord).r;

    // Sky, and below the smoothness floor the resolve's weight zeroes out anyway: both provably
    // invisible downstream. Writes zero rather than discarding, since `ssr` ping-pongs between two
    // physical textures and a discarded pixel would retain the value from TWO frames ago.
    if (centerDepth <= 0.0 || texture(u_Input2, texCoord).r < SSR_MIN_SMOOTHNESS) {
        fragColor = vec4(0.0);
        return;
    }

    // -0.5 puts the sample point in texel-centre coordinates, so floor()/fract() give the covering
    // 2x2's lower-left and the bilinear fractions directly.
    vec2 halfSize = vec2(textureSize(u_Input0, 0));
    vec2 h = texCoord * halfSize - 0.5;
    ivec2 base = ivec2(floor(h));
    vec2 f = h - floor(h);

    vec4 sum = vec4(0.0);
    float weightSum = 0.0;
    vec4 closest = vec4(0.0);
    float closestError = 1e30;

    for (int i = 0; i < 4; i++) {
        ivec2 offset = ivec2(i & 1, i >> 1);
        ivec2 tap = clamp(base + offset, ivec2(0), ivec2(halfSize) - 1);
        vec4 c = texelFetch(u_Input0, tap, 0);

        // Sampled at the half-res texel's own centre UV (where ssr_trace_fast ran); lands on the
        // boundary between the two full-res texels it covers, a sub-texel ambiguity bounded by the
        // quantisation this pass exists to undo.
        float tapDepth = texture(u_Input1, (vec2(tap) + 0.5) / halfSize).r;
        float error = abs(tapDepth - centerDepth);

        vec2 bilinear = mix(1.0 - f, f, vec2(offset));
        float w = bilinear.x * bilinear.y;
        if (error <= SSR_UPSAMPLE_DEPTH_TOLERANCE * centerDepth) {
            sum += c * w;
            weightSum += w;
        }
        if (error < closestError) {
            closestError = error;
            closest = c;
        }
    }

    // weightSum is zero only when all four taps sit on a different surface (a thin silhouette);
    // taking the nearest-in-depth tap whole is blockier than bilinear but at least the right colour.
    fragColor = weightSum > 0.0 ? sum / weightSum : closest;
}
