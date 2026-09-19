#ifndef PLAGUE_GI_BLUR_KERNEL
#define PLAGUE_GI_BLUR_KERNEL

// One step of an edge-aware spreading filter over the bounce grid.
//
// One ray per cell is a very noisy estimate of a very smooth thing: light arriving from the whole
// hemisphere changes slowly across a flat surface. Averaging neighbours trades resolution the
// signal does not have for noise it does.
//
// Run twice with the reach doubled the second time, which is the à-trous arrangement: the same
// small tap count covers a far wider area than one pass could, because the second pass averages
// cells that are themselves already averages. Two passes of 25 taps reach as far as one pass of
// 169 and cost a seventh as much. Dammertz, Sewtz, Hanika and Lensch, "Edge-Avoiding À-Trous
// Wavelet Transform for Fast Global Illumination Filtering", HPG 2009.
//
// Weighted by depth, so the filter stops at an edge. Without that, a bright wall bleeds its light
// through the corner onto a surface no light reaches, which is the failure this whole pass set
// exists to avoid.
//
// The caller declares the images and supplies PLAGUE_GI_BLUR_STEP, the gap between taps in cells.

const int PLAGUE_GI_SIDE = 256;
// Two cells either side of the middle. Wider than this in one pass reaches across a whole small
// room before the second pass has widened anything.
const int PLAGUE_GI_BLUR_RADIUS = 2;
// A neighbour further than this fraction of the depth away is another surface. Same rule the
// history rejection uses, and for the same reason: depth is reversed-Z and nonlinear.
const float PLAGUE_GI_BLUR_DEPTH_REJECT = 0.02;
// Binomial row of five, the discrete Gaussian at this width. Nearer cells count for more, which is
// what stops the two passes together reading as a flat box.
const float PLAGUE_GI_BLUR_TAP[5] = float[5](0.0625, 0.25, 0.375, 0.25, 0.0625);

void plagueGiBlurCell(ivec2 cell, int step) {
    vec2 uv = (vec2(cell) + 0.5) / float(PLAGUE_GI_SIDE);
    float depth = texture(u_Depth, uv).r;

    // Sky, which no surface receives. Passed through rather than filtered so the edge of the world
    // does not pull the horizon's light inward.
    if (depth <= 0.0) {
        imageStore(u_OutBlurred, cell, imageLoad(u_Bounce, cell));
        imageStore(u_OutDir, cell, imageLoad(u_Dir, cell));
        return;
    }

    vec3 total = vec3(0.0);
    // The bearing is averaged the same way and by the same taps. Averaging vectors is what keeps
    // its meaning: neighbours that agree about where the light is keep the length that says so,
    // and neighbours that disagree shorten it, which is the honest answer for that spot.
    vec3 bearing = vec3(0.0);
    float weight = 0.0;
    for (int y = -PLAGUE_GI_BLUR_RADIUS; y <= PLAGUE_GI_BLUR_RADIUS; ++y) {
        for (int x = -PLAGUE_GI_BLUR_RADIUS; x <= PLAGUE_GI_BLUR_RADIUS; ++x) {
            ivec2 tap = clamp(cell + ivec2(x, y) * step, ivec2(0), ivec2(PLAGUE_GI_SIDE - 1));
            vec2 tapUv = (vec2(tap) + 0.5) / float(PLAGUE_GI_SIDE);
            float tapDepth = texture(u_Depth, tapUv).r;
            if (tapDepth <= 0.0
                    || abs(depth - tapDepth) > PLAGUE_GI_BLUR_DEPTH_REJECT * max(depth, 1e-4)) {
                continue;
            }
            float tapWeight = PLAGUE_GI_BLUR_TAP[x + PLAGUE_GI_BLUR_RADIUS]
                    * PLAGUE_GI_BLUR_TAP[y + PLAGUE_GI_BLUR_RADIUS];
            total += imageLoad(u_Bounce, tap).rgb * tapWeight;
            bearing += imageLoad(u_Dir, tap).rgb * tapWeight;
            weight += tapWeight;
        }
    }

    // A cell whose every neighbour was rejected keeps its own sample rather than going black.
    vec3 blurred = weight > 0.0 ? total / weight : imageLoad(u_Bounce, cell).rgb;
    vec3 blurredDir = weight > 0.0 ? bearing / weight : imageLoad(u_Dir, cell).rgb;
    imageStore(u_OutBlurred, cell, vec4(blurred, 1.0));
    imageStore(u_OutDir, cell, vec4(blurredDir, 1.0));
}

#endif
