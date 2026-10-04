#ifndef PLAGUE_REFLECTION_CONFIDENCE
#define PLAGUE_REFLECTION_CONFIDENCE
// RGB describes a supported hit; alpha is confidence, not surface opacity. Filter
// associated RGB, then divide once. A black hit still owns its full confidence.
vec4 plagueReflectionAssociate(vec4 value) {
    return vec4(value.rgb * value.a, value.a);
}
vec4 plagueReflectionUnassociate(vec4 value) {
    return vec4(value.a > 0.0 ? value.rgb / value.a : vec3(0.0), value.a);
}
vec4 plagueReflectionSample(sampler2D source, vec2 uv) {
    ivec2 size = textureSize(source, 0);
    vec2 position = uv * vec2(size) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 fraction = fract(position);
    vec4 sum = vec4(0.0);
    // Four bilinear neighbours; 0.5 is the raster texel-centre convention.
    for (int y = 0; y < 2; ++y) {
        for (int x = 0; x < 2; ++x) {
            vec2 weight = mix(vec2(1.0) - fraction, fraction, vec2(x, y));
            vec4 value = texelFetch(source, clamp(base + ivec2(x, y), ivec2(0), size - 1), 0);
            sum += plagueReflectionAssociate(value) * weight.x * weight.y;
        }
    }
    return plagueReflectionUnassociate(sum);
}
#endif
