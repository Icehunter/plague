#version 330

// RGB visibility has a separate estimator per source colour. Alpha stores history age;
// averaging channels through luminance would let a blocked red lamp shadow an unblocked blue one.
uniform sampler2D u_VoxelLocalVisibility;
uniform sampler2D u_VoxelLocalVisVoxel_history;
uniform sampler2D u_GMotion;
uniform sampler2D u_Depth;
uniform sampler2D u_GNormal;

in vec2 texCoord;
out vec4 fragColor;

// Retains the existing twelve-frame response window. Importance samples can exceed one, so
// a single-frame magnitude test cannot distinguish a changed blocker from a rare coloured lamp.
const float PLAGUE_LOCAL_ACCUM_FRAMES = 12.0;
const float PLAGUE_LOCAL_ACCUM_DEPTH_REJECT = 0.02; // Existing relative reversed-Z history tolerance.
const float PLAGUE_LOCAL_ACCUM_NORMAL_REJECT = 0.9; // Existing cosine of roughly 25 degrees.

void main() {
    vec4 sampleNow = texture(u_VoxelLocalVisibility, texCoord);
    fragColor = sampleNow;
    // A pixel owned by current RT has no voxel observation to add to this history.
    if (sampleNow.a <= 0.0) return;
    vec3 current = sampleNow.rgb;
    float depth = texture(u_Depth, texCoord).r;
    vec3 normal = texture(u_GNormal, texCoord).xyz;
    if (depth <= 0.0 || dot(normal, normal) <= 1e-6) return;
    vec2 previousUv = texCoord - texture(u_GMotion, texCoord).rg;
    if (any(lessThan(previousUv, vec2(0.0))) || any(greaterThan(previousUv, vec2(1.0)))) return;
    float previousDepth = texture(u_Depth, previousUv).r;
    if (previousDepth <= 0.0
            || abs(depth - previousDepth) > PLAGUE_LOCAL_ACCUM_DEPTH_REJECT * max(depth, 1e-4)) return;
    vec3 previousNormal = texture(u_GNormal, previousUv).xyz;
    if (dot(previousNormal, previousNormal) <= 1e-6
            || dot(normalize(normal), normalize(previousNormal)) < PLAGUE_LOCAL_ACCUM_NORMAL_REJECT) return;
    vec4 previous = texture(u_VoxelLocalVisVoxel_history, previousUv);
    float gathered = min(max(previous.a, 0.0) + 1.0, PLAGUE_LOCAL_ACCUM_FRAMES);
    fragColor = vec4(mix(previous.rgb, current, 1.0 / gathered), gathered);
}
