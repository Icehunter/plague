#ifndef PLAGUE_GI_HISTORY_TEST
#define PLAGUE_GI_HISTORY_TEST

// Whether a grid cell's history from last frame still describes the same surface.
//
// Reprojection follows the surface by the motion vector, landing between four texels of last
// frame's grid. Each of those four is kept only when the surface gi_surface recorded THERE, last
// frame, faces the same way as this cell and passes this cell's own point through its plane. That
// plane is carried into last frame's camera frame by u_CameraDelta before the test, since the
// recorded plane is relative to last frame's camera and this cell's point is relative to this
// frame's. Comparing against last frame's own recorded surface, rather than re-sampling this
// frame's depth and normal at the reprojected spot, is what keeps a turned view from testing
// against whatever new wall now happens to sit at the old screen position.
//
// The caller names its own images before importing: PLAGUE_GI_HISTORY_MOTION (rg, this frame's uv
// minus last frame's) and, for the weighted test below, PLAGUE_GI_HISTORY_SURFACE (a readonly
// rgba16f image2D holding last frame's own gi_surface output: rgb its normal, a its plane offset).
// A caller that wants only the position helper and the tolerances, such as the spreading passes,
// leaves PLAGUE_GI_HISTORY_SURFACE undefined and the weighted test is not compiled.
//
// Blind spot: an entity has no surface written into this grid's G-buffer or motion, since motion
// vectors here are terrain only, so a moving entity reprojects as if it were still standing where
// it was.

// Tolerance as a fraction of the distance from the camera: depth precision falls off with
// distance, and a whole block face at range is a few cells wide. Two percent at ten blocks is a
// fifth of a block, well under any voxel step.
const float PLAGUE_GI_HISTORY_PLANE = 0.02;
// Blocks. A surface right at the camera still needs room for the depth's own rounding.
const float PLAGUE_GI_HISTORY_PLANE_FLOOR = 0.05;
// Cosine of about 25 degrees. Two surfaces further apart than this in facing are not the same
// surface.
const float PLAGUE_GI_HISTORY_NORMAL_REJECT = 0.9;

vec3 plagueGiHistoryPosition(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    return world.xyz / world.w;
}

bool plagueGiHistorySurfaceMatches(vec4 then, vec3 normal, vec3 position, float tolerance) {
    if (dot(then.xyz, then.xyz) <= 1e-6) return false;
    vec3 nThen = normalize(then.xyz);
    return dot(normal, nThen) >= PLAGUE_GI_HISTORY_NORMAL_REJECT
            && abs(dot(nThen, position) - then.w) <= tolerance;
}

#ifdef PLAGUE_GI_HISTORY_SURFACE
// Bilinear weights over the four history texels around last frame's spot, each zeroed when that
// texel's surface is not this cell's surface. Returns their sum; zero means no history.
float plagueGiHistoryWeights(vec2 uv, float depth, vec3 normal, ivec2 size, out ivec2 corner, out vec4 weights, out bool recovered, bool allowNeighbours) {
    corner = ivec2(0); weights = vec4(0.0);
    recovered = false;
    // uv is the jittered sample location; last frame's grid was written at unjittered cell
    // centres, so the jitter is backed out before the motion vector is applied.
    vec2 previousUv = uv - u_JitterOffset * 0.5 - texture(PLAGUE_GI_HISTORY_MOTION, uv).rg;
    if (any(lessThan(previousUv, vec2(0.0))) || any(greaterThan(previousUv, vec2(1.0)))) return 0.0;
    vec3 nHere = normalize(normal);
    vec3 here = plagueGiHistoryPosition(uv, depth);
    vec3 thenRelative = here + u_CameraDelta.xyz;
    float tolerance = max(PLAGUE_GI_HISTORY_PLANE * length(here), PLAGUE_GI_HISTORY_PLANE_FLOOR);
    vec2 place = previousUv * vec2(size) - 0.5;
    corner = ivec2(floor(place));
    vec2 f = place - vec2(corner);
    vec4 bilinear = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
    ivec2 offsets[4] = ivec2[4](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));
    for (int i = 0; i < 4; ++i) {
        ivec2 texel = clamp(corner + offsets[i], ivec2(0), size - 1);
        vec4 then = imageLoad(PLAGUE_GI_HISTORY_SURFACE, texel);
        if (!plagueGiHistorySurfaceMatches(then, nHere, thenRelative, tolerance)) continue;
        weights[i] = bilinear[i];
    }
    float kept = weights.x + weights.y + weights.z + weights.w;
#ifdef PLAGUE_GI_HISTORY_NEIGHBOURS
    if (kept <= 0.0 && allowNeighbours) {
        // The nearest eight neighbours are the smallest symmetric recovery footprint around
        // a missing centre. TAA cutout coverage can erase that centre even in a stationary view.
        ivec2 centre = ivec2(floor(place + 0.5));
        float nearestDistance = dot(vec2(size), vec2(size));
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                ivec2 tap = centre + ivec2(x, y);
                if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, size))) continue;
                vec4 then = imageLoad(PLAGUE_GI_HISTORY_SURFACE, tap);
                if (!plagueGiHistorySurfaceMatches(then, nHere, thenRelative, tolerance)) continue;
                vec2 offset = vec2(tap) - place;
                float distance = dot(offset, offset);
                if (distance >= nearestDistance) continue;
                nearestDistance = distance;
                corner = tap;
                recovered = true;
            }
        }
        // Callers must treat spatial recovery as one prior sample, not inherit a neighbour's
        // full temporal age: coplanar neighbours can still have different lighting.
        if (recovered) {
            weights = vec4(1.0, 0.0, 0.0, 0.0);
            kept = 1.0;
        }
    }
#endif
    return kept;
}

float plagueGiHistoryWeights(vec2 uv, float depth, vec3 normal, ivec2 size, out ivec2 corner, out vec4 weights, out bool recovered) {
    return plagueGiHistoryWeights(uv, depth, normal, size, corner, weights, recovered, true);
}

float plagueGiHistoryWeights(vec2 uv, float depth, vec3 normal, ivec2 size, out ivec2 corner, out vec4 weights) {
    bool recovered;
    return plagueGiHistoryWeights(uv, depth, normal, size, corner, weights, recovered);
}
// Last frame's value from any history image, over the texels the test kept. Callers check the
// weight sum is above zero first. A macro because a storage image's format cannot be a parameter.
#define plagueGiHistoryGather(past, corner, weights, size) \
    ((imageLoad(past, clamp((corner), ivec2(0), (size) - 1)) * (weights).x \
    + imageLoad(past, clamp((corner) + ivec2(1, 0), ivec2(0), (size) - 1)) * (weights).y \
    + imageLoad(past, clamp((corner) + ivec2(0, 1), ivec2(0), (size) - 1)) * (weights).z \
    + imageLoad(past, clamp((corner) + ivec2(1, 1), ivec2(0), (size) - 1)) * (weights).w) \
    / ((weights).x + (weights).y + (weights).z + (weights).w))
#endif

#endif
