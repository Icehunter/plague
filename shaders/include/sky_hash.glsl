#ifndef PLAGUE_SKY_HASH
#define PLAGUE_SKY_HASH

// Shared hash/noise primitives for the night-sky layers (stars, meteors, nebula, aurora), kept as
// one copy so two layers can't silently diverge onto different hashes.

/**
 * "Hash without Sine" hash12, (c) 2014 David Hoskins, MIT licence.
 * https://www.shadertoy.com/view/4djSRW; see THIRD-PARTY-NOTICES.md for the full text.
 * Reproduced with its notice, which is all the MIT licence asks; do not strip this comment.
 *
 * Preferred over the sin-fract idiom because sin() at large arguments is precision-dependent: the
 * same coordinate can hash differently on two GPUs, which for a star field means the sky is not the
 * same sky on two machines.
 */
float plagueHash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/** Two independent hashes of the same cell, for uncorrelated per-cell properties. */
vec2 plagueHash22(vec2 p) {
    return vec2(plagueHash12(p), plagueHash12(p + 71.13));
}

/** Value noise: hash the lattice, smoothstep between. */
float plagueSkyValueNoise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = plagueHash12(cell);
    float b = plagueHash12(cell + vec2(1.0, 0.0));
    float c = plagueHash12(cell + vec2(0.0, 1.0));
    float d = plagueHash12(cell + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Textbook lacunarity 2.0 / gain 0.5 for scale invariance; rotating between octaves stops the
// lattice axes printing through as a visible cross-hatch.
float plagueSkyFbm(vec2 p, int octaves) {
    const mat2 turn = mat2(0.80, 0.60, -0.60, 0.80);   // a plain rotation, det = 1
    float sum = 0.0;
    float amp = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * plagueSkyValueNoise(p);
        norm += amp;
        p = turn * p * 2.0;
        amp *= 0.5;
    }
    return sum / max(norm, 1e-5);
}

#endif
