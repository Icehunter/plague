#ifndef PLAGUE_OPAQUE_REFLECTION_GRID
#define PLAGUE_OPAQUE_REFLECTION_GRID
// A coarse centre falls between SSR texels at even scale ratios. Both producer and
// reconstruction must use the same single texel's geometry, including at odd image sizes.
vec2 plagueOpaqueReceiverUv(ivec2 coarseCell, ivec2 coarseSize, ivec2 screenSize) {
    // Integer centre mapping avoids opposite sides of a source-texel boundary when the
    // raster UV and a reconstructed UV differ by one float ULP at an even scale ratio.
    ivec2 pixel = ((2 * coarseCell + 1) * screenSize) / (2 * coarseSize);
    pixel = clamp(pixel, ivec2(0), screenSize - 1);
    return (vec2(pixel) + 0.5) / vec2(screenSize);
}
#endif
