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

uniform sampler2D u_Input0; // voxelLocalUnshadowed, rgb the light, a how much got through
uniform sampler2D u_Input1; // builtin.depth
uniform sampler2D u_Input2; // builtin.gNormal
uniform sampler2D u_Input3; // cloudShadowMask, carried into alpha for the resolve
uniform sampler2D u_Input4; // voxelLocalVisAccum, r = visibility already averaged over frames

in vec2 texCoord;
out vec4 fragColor;

// Binomial row of five, the discrete Gaussian at this width. Nearer taps count for more.
const float PLAGUE_LOCAL_VIS_TAP[5] = float[5](0.0625, 0.25, 0.375, 0.25, 0.0625);
// As a FRACTION of the depth: depth is reversed-Z and nonlinear, so a fixed gap means different
// things near and far.
const float PLAGUE_LOCAL_VIS_DEPTH_REJECT = 0.02;
// Cosine of about 25 degrees. Past this the tap is another face.
const float PLAGUE_LOCAL_VIS_NORMAL_REJECT = 0.9;

void main() {
    vec4 light = texture(u_Input0, texCoord);
    float cloudShadow = texture(u_Input3, texCoord).r;
    float depth = texture(u_Input1, texCoord).r;
    vec3 n = texture(u_Input2, texCoord).xyz;
    if (depth <= 0.0 || dot(n, n) <= 1e-6) {
#if PLAGUE_LOCAL_DEBUG == 1
        fragColor = vec4(vec3(texture(u_Input4, texCoord).r), cloudShadow);
#elif PLAGUE_LOCAL_DEBUG == 2
        fragColor = vec4(light.rgb, cloudShadow);
#else
        fragColor = vec4(light.rgb * texture(u_Input4, texCoord).r, cloudShadow);
#endif
        return;
    }

    vec3 normal = normalize(n);
    vec2 texel = 1.0 / vec2(textureSize(u_Input0, 0));
    float total = 0.0;
    float weight = 0.0;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            vec2 tapUv = texCoord + vec2(x, y) * texel;
            if (any(lessThan(tapUv, vec2(0.0))) || any(greaterThan(tapUv, vec2(1.0)))) {
                continue;
            }
            float tapDepth = texture(u_Input1, tapUv).r;
            if (tapDepth <= 0.0
                    || abs(depth - tapDepth) > PLAGUE_LOCAL_VIS_DEPTH_REJECT * max(depth, 1e-4)) {
                continue;
            }
            vec3 tapN = texture(u_Input2, tapUv).xyz;
            if (dot(tapN, tapN) <= 1e-6
                    || dot(normal, normalize(tapN)) < PLAGUE_LOCAL_VIS_NORMAL_REJECT) {
                continue;
            }
            float tapWeight = PLAGUE_LOCAL_VIS_TAP[x + 2] * PLAGUE_LOCAL_VIS_TAP[y + 2];
            total += texture(u_Input4, tapUv).r * tapWeight;
            weight += tapWeight;
        }
    }

    // A pixel whose every neighbour was rejected keeps its own sample rather than going dark.
    float visibility = weight > 0.0 ? total / weight : texture(u_Input4, texCoord).r;
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
