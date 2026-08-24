// The sRGB transfer function and its exact inverse — not pow(x, 2.2), which diverges most in the
// darks where most Minecraft pixels live.

#ifndef PLAGUE_COLOR
#define PLAGUE_COLOR

// Decode must switch where the encode's linear segment maps this value (12.92 * knee =
// 0.040449936); the published rounded 0.04045 would leave a ~5e-8 discontinuity at the join.
const float PLAGUE_SRGB_KNEE = 0.0031308;

// mix() with a bvec evaluates both branches, so neither may produce a NaN.
vec3 plagueLinearToSrgb(vec3 colour) {
    return mix(1.055 * pow(colour, vec3(1.0 / 2.4)) - 0.055,
               12.92 * colour,
               lessThan(colour, vec3(PLAGUE_SRGB_KNEE)));
}

vec3 plagueSrgbToLinear(vec3 colour) {
    return mix(pow((colour + 0.055) / 1.055, vec3(2.4)),
               colour / 12.92,
               lessThan(colour, vec3(12.92 * PLAGUE_SRGB_KNEE)));
}

// Converts a display-space authored tint (e.g. underwater hue, water-shaft tint — the source
// number is meant to be read off the screen) into the linear pipeline. Separate from
// plagueSrgbToLinear because authored intensities may exceed 1.0; the power segment continues
// smoothly past the [0,1] range those constants were sized under.
vec3 plagueAuthoredToLinear(vec3 authored) {
    return mix(pow((max(authored, vec3(0.0)) + 0.055) / 1.055, vec3(2.4)),
               authored / 12.92,
               lessThan(authored, vec3(12.92 * PLAGUE_SRGB_KNEE)));
}

#endif // PLAGUE_COLOR
