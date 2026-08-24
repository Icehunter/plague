#version 330

// Bloom blur, one pyramid level.
//
// No threshold: the whole image blooms, since the composite lerps toward an averaged blur rather
// than adding highlights, so no pixel needs to be singled out as "bright enough".
//
// Kernel is the binomial recurrence, not a tabulated Gaussian: weights are exact integers, so a
// normalised kernel cannot drift energy across the seven summed levels.
//
// Each level blurs the level above rather than full-res, avoiding the aliasing from striding taps
// by 2^lod pixels at the coarser levels. Targets are rgba16f (linear, no encode/decode curve).

uniform sampler2D u_Input0; // the level above: sceneHdr for the first pass, bloomN-1 after that

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4  u_SunDirection;
};

in vec2 texCoord;
out vec4 fragColor;

// Caps a stray NaN/Inf so it can't survive the adds below and bloom into a bright square.
const float MAX_BLOOM_RADIANCE = 4096.0;

vec3 sanitize(vec3 value) {
    if (any(isnan(value)) || any(isinf(value))) {
        return vec3(0.0);
    }
    return clamp(value, vec3(0.0), vec3(MAX_BLOOM_RADIANCE));
}

void main() {
    // Radius in taps either side of centre. 3 gives Pascal's row 6 at 7 taps.
    const int RADIUS = 3;

    // C(n, k+1) = C(n, k) * (n - k) / (k + 1), normalised by its own sum.
    float kernel[2 * RADIUS + 1];
    float total = 0.0;
    float c = 1.0;
    for (int k = 0; k <= 2 * RADIUS; k++) {
        kernel[k] = c;
        total += c;
        c = c * float(2 * RADIUS - k) / float(k + 1);
    }

    // Sampled at the SOURCE's texel size, not u_PassTexelSize (this pass's smaller output).
    vec2 srcTexel = 1.0 / vec2(textureSize(u_Input0, 0));

    // 2D kernel is the outer product of the row with itself, so its sum is total*total.
    vec3 blur = vec3(0.0);
    for (int i = -RADIUS; i <= RADIUS; i++) {
        for (int j = -RADIUS; j <= RADIUS; j++) {
            vec2 offset = vec2(float(i), float(j)) * srcTexel;
            blur += sanitize(texture(u_Input0, texCoord + offset).rgb)
                  * kernel[i + RADIUS] * kernel[j + RADIUS];
        }
    }
    blur /= total * total;

    fragColor = vec4(sanitize(blur), 1.0);
}
