#version 330

// Puts the local light back together: the smooth light this pixel would receive, times how much of
// it actually got through.
//
// The visibility arrives already averaged over frames by voxel_local_accum, and is filtered across
// neighbours here as well: one sample per quarter face needs both axes. It is the only thing
// filtered either way. The light beside it is deterministic and carries the block's texture and
// relief, so touching it would soften the block while cleaning the shadow.
//
// Weighted by depth and by facing, so the filter stops at an edge. Depth alone passes a wall and
// the floor it meets wherever they sit at a similar distance, and light then crawls around the
// corner.

// Which half of the local light to show on its own, so the grain can be pinned to one of them
// instead of guessed at. The light and the visibility are multiplied together by the time anything
// downstream sees them, and a product tells you nothing about which factor is noisy.
#define PLAGUE_LOCAL_DEBUG 0 //[0 1 2] compile "Test View: Coloured Lighting" {0="Off" 1="Visibility only" 2="Light only"}

uniform sampler2D u_VoxelLocalUnshadowed; // voxelLocalUnshadowed, rgb the light, a how much got through
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GNormal; // builtin.gNormal
uniform sampler2D u_CloudShadowMask; // cloudShadowMask, carried into alpha for the resolve
uniform sampler2D u_VoxelLocalVisAccum; // voxelLocalVisAccum, r = visibility already averaged over frames

in vec2 texCoord;
out vec4 fragColor;

// How far either side of the pixel's own place the taps reach, counted in the visibility's texels.
// Four across on each axis, which both smooths the sampling and carries the answer up to the
// screen's size in one go.
const int PLAGUE_LOCAL_VIS_RADIUS = 2;
// A tap's share by how far it sits from the pixel's true place, which is somewhere between texels
// rather than on one. Falls to nothing at the edge of the reach, so a tap entering or leaving
// arrives at no weight and nothing steps.
float plagueLocalVisTap(float distance) {
    return max(0.0, 1.0 - abs(distance) / float(PLAGUE_LOCAL_VIS_RADIUS));
}
// As a FRACTION of the depth: depth is reversed-Z and nonlinear, so a fixed gap means different
// things near and far.
const float PLAGUE_LOCAL_VIS_DEPTH_REJECT = 0.02;
// Cosine of about 25 degrees. Past this the tap is another face.
const float PLAGUE_LOCAL_VIS_NORMAL_REJECT = 0.9;

void main() {
    vec4 light = texture(u_VoxelLocalUnshadowed, texCoord);
    float cloudShadow = texture(u_CloudShadowMask, texCoord).r;
    float depth = texture(u_Depth, texCoord).r;
    vec3 n = texture(u_GNormal, texCoord).xyz;
    if (depth <= 0.0 || dot(n, n) <= 1e-6) {
#if PLAGUE_LOCAL_DEBUG == 1
        fragColor = vec4(vec3(texture(u_VoxelLocalVisAccum, texCoord).r), cloudShadow);
#elif PLAGUE_LOCAL_DEBUG == 2
        fragColor = vec4(light.rgb, cloudShadow);
#else
        fragColor = vec4(light.rgb * texture(u_VoxelLocalVisAccum, texCoord).r, cloudShadow);
#endif
        return;
    }

    vec3 normal = normalize(n);
    // Taps named by WHICH texel, not by how far along the picture.
    //
    // The visibility may be held smaller than the screen. Asking for it at this pixel's place lands
    // between its texels, and the two it blends alternate with the column, which stands on the wall
    // as a bar. Naming the texel and weighting it here leaves nothing to alternate: the answer
    // moves smoothly with the pixel's true place inside a texel, whatever the two sizes are.
    vec2 accumSize = vec2(textureSize(u_VoxelLocalVisAccum, 0));
    vec2 place = texCoord * accumSize - 0.5;
    ivec2 nearest = ivec2(floor(place));
    vec2 offset = place - vec2(nearest);
    float total = 0.0;
    float weight = 0.0;
    for (int y = 1 - PLAGUE_LOCAL_VIS_RADIUS; y <= PLAGUE_LOCAL_VIS_RADIUS; ++y) {
        for (int x = 1 - PLAGUE_LOCAL_VIS_RADIUS; x <= PLAGUE_LOCAL_VIS_RADIUS; ++x) {
            ivec2 tap = nearest + ivec2(x, y);
            if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, ivec2(accumSize)))) {
                continue;
            }
            // Where that texel sits on the screen, so the surface under it can be compared.
            vec2 tapUv = (vec2(tap) + 0.5) / accumSize;
            float tapDepth = texture(u_Depth, tapUv).r;
            if (tapDepth <= 0.0
                    || abs(depth - tapDepth) > PLAGUE_LOCAL_VIS_DEPTH_REJECT * max(depth, 1e-4)) {
                continue;
            }
            vec3 tapN = texture(u_GNormal, tapUv).xyz;
            if (dot(tapN, tapN) <= 1e-6
                    || dot(normal, normalize(tapN)) < PLAGUE_LOCAL_VIS_NORMAL_REJECT) {
                continue;
            }
            float tapWeight = plagueLocalVisTap(float(x) - offset.x)
                    * plagueLocalVisTap(float(y) - offset.y);
            if (tapWeight <= 0.0) {
                continue;
            }
            total += texelFetch(u_VoxelLocalVisAccum, tap, 0).r * tapWeight;
            weight += tapWeight;
        }
    }

    // A pixel whose every neighbour was rejected keeps its own sample rather than going dark.
    float visibility = weight > 0.0 ? total / weight : texture(u_VoxelLocalVisAccum, texCoord).r;
#if PLAGUE_LOCAL_DEBUG == 1
    // Grey: white is every emitter sample reaching this pixel, black is none of them.
    fragColor = vec4(vec3(visibility), cloudShadow);
#elif PLAGUE_LOCAL_DEBUG == 2
    // The light with nothing in the way. Deterministic, so any grain here is not the sampling.
    fragColor = vec4(light.rgb, cloudShadow);
#else
    fragColor = vec4(light.rgb * visibility, cloudShadow);
#endif
}
