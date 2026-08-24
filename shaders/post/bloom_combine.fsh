#version 330

// Bloom combine: averages the seven pyramid levels shaders/post/bloom_blur.fsh produces into
// bloomFinal, which tonemap.fsh reads back at full resolution. BLOOM_ENABLED and the strength
// slider live in tonemap.fsh; this pass and the seven blur passes run or don't run together as
// one group, gated at the render-graph level.
//
// Weighted AVERAGE, not a weighted sum: dividing by the summed weights keeps a uniformly-bright
// pyramid combining back to the same brightness, so raising bloom strength never darkens the
// frame as a side effect (the composite blends TOWARD this buffer rather than adding it).

uniform sampler2D u_Input0; // finest level  (least blurred, tightest core)
uniform sampler2D u_Input1;
uniform sampler2D u_Input2;
uniform sampler2D u_Input3;
uniform sampler2D u_Input4;
uniform sampler2D u_Input5;
uniform sampler2D u_Input6; // widest level  (most blurred, softest halo)

in vec2 texCoord;
out vec4 fragColor;

// Clamp ceiling for the sanitize below; matches bloom_blur.fsh's own MAX_BLOOM_RADIANCE tap clamp,
// and confirmed against tools/fit_emission_parity.py.
const float PLAGUE_BLOOM_SANITIZE_CEILING = 4096.0;

// Per-level falloff past the three full-weight core levels (indices 0-2); see plagueBloomWeight
// below. Default is 1/e (0.37): chosen on principle rather than fit, since an earlier round-number
// default could not be shown independent of the measurement fixture it was tuned against. At the
// default the widest level contributes ~1/55th of a core level's weight. Must not be parity-fit or
// reverse-derived at all — see tools/verify_emission.py's structural checks on this ratio.
#define u_BloomFalloff 0.37 //[0.05..1.00 step 0.01] runtime "Bloom Falloff"

float plagueBloomWeight(int level) {
    return level <= 2 ? 1.0 : pow(u_BloomFalloff, float(level - 2));
}

// NaN/Inf -> 0, else clamped. Applied per level before weighting (so one bad texel can't poison
// the sum) and once more to the finished average, since the division could otherwise reintroduce
// a non-finite value.
vec3 plagueBloomSanitize(vec3 value) {
    if (any(isnan(value)) || any(isinf(value))) {
        return vec3(0.0);
    }
    return clamp(value, vec3(0.0), vec3(PLAGUE_BLOOM_SANITIZE_CEILING));
}

void main() {
    float w3 = plagueBloomWeight(3);
    float w4 = plagueBloomWeight(4);
    float w5 = plagueBloomWeight(5);
    float w6 = plagueBloomWeight(6);
    vec3 weightedSum = plagueBloomSanitize(texture(u_Input0, texCoord).rgb)
                      + plagueBloomSanitize(texture(u_Input1, texCoord).rgb)
                      + plagueBloomSanitize(texture(u_Input2, texCoord).rgb)
                      + plagueBloomSanitize(texture(u_Input3, texCoord).rgb) * w3
                      + plagueBloomSanitize(texture(u_Input4, texCoord).rgb) * w4
                      + plagueBloomSanitize(texture(u_Input5, texCoord).rgb) * w5
                      + plagueBloomSanitize(texture(u_Input6, texCoord).rgb) * w6;
    float weightSum = 3.0 + w3 + w4 + w5 + w6;

    vec3 combined = plagueBloomSanitize(weightedSum / weightSum);
    fragColor = vec4(combined, 1.0);
}
