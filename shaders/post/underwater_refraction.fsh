#version 330

// Sub-pixel underwater refraction: sceneHdrComposited -> sceneHdrRefracted, between
// water_composite and bloom/tonemap. Dry camera is a passthrough copy. Opaque and water depth are
// both used so distortion can't pull colour across a geometry silhouette.
//
// Audited and confirmed clean against the pack's actual fog shape (plagueGetWaterFogAniso); a
// stray duplicate fog top-up that used to live here is removed (see the note near the end of main).

#moj_import <fornax:globals.glsl>

uniform sampler2D u_Input0; // sceneHdrComposited
uniform sampler2D u_Input1; // builtin.depth: opaque reversed-Z
uniform sampler2D u_Input2; // builtin.noise: existing tileable engine noise
uniform sampler2D u_Input3; // builtin.waterDepth: water-surface reversed-Z

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4  u_SunDirection;
};

// Byte-identical to underwater.glsl so the option scanner merges the shared feature switch.
#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}

#moj_import <fornax_runtime:water_options.glsl>
// Local copy of underwater.glsl's plagueChunksToBlocks: this pass is deliberately self-contained
// and avoids pulling in light_and_ambient_colors.glsl for a one-line multiply. Keep in sync by hand.
float plagueChunksToBlocks(float chunks) {
    return chunks * 16.0;
}

in vec2 texCoord;
out vec4 fragColor;

vec3 plagueAddonWorldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    // Guards the divide while keeping the sign of w (an abs()*sign() guard zeroes out at w==0).
    float w = abs(world.w) < 1e-6 ? 1e-6 : world.w;
    return world.xyz / w;
}

vec2 plagueAddonDepthPair(vec2 uv) {
    // Reversed-Z: larger is nearer. Water depth is included so the warp can't cross its silhouette.
    return vec2(texture(u_Input1, uv).r, texture(u_Input3, uv).r);
}

// Callers test depth > 0.0 before calling, so there's no depth <= 0.0 sentinel case to handle here.
float plagueAddonDistance(vec2 uv, float depth) {
    return length(plagueAddonWorldPosAt(uv, depth));
}

void main() {
    vec4 original = texture(u_Input0, texCoord);

#if PLAGUE_UNDERWATER
    if (u_WaterState.x > 0.5) {
        float time = u_SkyState.w / 20.0;
        float cameraWaterDepth = max(u_WaterState.z - u_CameraAbs.y, 0.0);
        // Fades in over the first half block of submersion so an eye bobbing at the waterline
        // doesn't pop the effect on and off every frame.
        float submergedFade = smoothstep(0.08, 0.55, cameraWaterDepth);

        vec2 centreDepths = plagueAddonDepthPair(texCoord);
        float centreDepth = max(centreDepths.x, centreDepths.y);

        // Projected 4 blocks out and converted to world space, so the noise is anchored in the
        // world instead of swimming with the screen.
        float rayDepth = centreDepth > 0.0 ? centreDepth : 1e-5;
        vec3 rayPosition = plagueAddonWorldPosAt(texCoord, rayDepth);
        vec3 rayDirection = normalize(rayPosition);
        vec3 probe = u_CameraAbs.xyz + rayDirection * 4.0;

        // Two decorrelated taps of one noise tile: 0.80/0.60 is an exact unit vector (3-4-5
        // triangle) rotating the second tap ~36.87 deg without rescaling it; 1.37 is a non-integer
        // frequency ratio so the taps share no repeat period; 0.31/0.17 offsets them off the same
        // lattice cell; the two time drifts are slow and non-parallel so the pair evolves rather
        // than translating rigidly. None of these values is otherwise tuned — only the property
        // each satisfies matters.
        vec2 noiseUvA = probe.xz * u_UnderwaterFlowScale
                      + vec2(0.011, 0.007) * time;
        vec2 noiseUvB = vec2(0.80 * probe.x - 0.60 * probe.z,
                             0.60 * probe.x + 0.80 * probe.z)
                      * (u_UnderwaterFlowScale * 1.37)
                      + vec2(-0.008, 0.013) * time + vec2(0.31, 0.17);
        vec2 flowA = texture(u_Input2, noiseUvA).rg * 2.0 - 1.0;
        vec2 flowB = texture(u_Input2, noiseUvB).rg * 2.0 - 1.0;
        vec2 flow = (flowA + flowB) * 0.5;

        float sceneDistance = centreDepth > 0.0
                ? plagueAddonDistance(texCoord, centreDepth)
                : plagueChunksToBlocks(u_WaterDistanceFog) * 3.0;
        // Off at arm's length, full by six blocks: within half a block the warp lands on the same
        // surface and is invisible work; too close and it reads as a wobbling texture.
        float distanceFade = smoothstep(0.5, 6.0, sceneDistance);

        vec2 candidateUv = clamp(texCoord + flow * u_PassTexelSize
                               * u_UnderwaterFlowPixels
                               * submergedFade * distanceFade,
                                 u_PassTexelSize * 1.5,
                                 vec2(1.0) - u_PassTexelSize * 1.5);

        // Reject a displaced tap that changes sky/surface classification or crosses a large depth
        // discontinuity, so bright water/sky can't bleed through a block silhouette.
        vec2 candidateDepths = plagueAddonDepthPair(candidateUv);
        float candidateDepth = max(candidateDepths.x, candidateDepths.y);
        bool centreMiss = centreDepth <= 0.0;
        bool candidateMiss = candidateDepth <= 0.0;
        // Opaque and water classes tracked independently: comparing only the combined max depth
        // can't tell an opaque silhouette from a water-surface one at similar radial distance.
        bool sameOpaqueClass = (centreDepths.x > 0.0) == (candidateDepths.x > 0.0);
        bool sameWaterClass = (centreDepths.y > 0.0) == (candidateDepths.y > 0.0);
        bool centreOpaqueFront = centreDepths.x > 0.0
                && (centreDepths.y <= 0.0 || centreDepths.x >= centreDepths.y);
        bool candidateOpaqueFront = candidateDepths.x > 0.0
                && (candidateDepths.y <= 0.0 || candidateDepths.x >= candidateDepths.y);
        bool sameFrontLayer = centreOpaqueFront == candidateOpaqueFront;
        float edgeGuard = centreMiss == candidateMiss && sameOpaqueClass && sameWaterClass
                && sameFrontLayer ? 1.0 : 0.0;
        if (!centreMiss && !candidateMiss) {
            float candidateDistance = plagueAddonDistance(candidateUv, candidateDepth);
            edgeGuard *= 1.0 - smoothstep(0.75, 3.0,
                                         abs(candidateDistance - sceneDistance));
        }

        vec2 warpedUv = mix(texCoord, candidateUv, edgeGuard);
        vec3 colour = texture(u_Input0, warpedUv).rgb;

        // A second, independently-curved and wrongly-coloured lateral water fog used to live here,
        // duplicating the veil fog.glsl already applies; removed rather than left at a zero default.
        // This pass warps and samples, and that is all it should do.
        fragColor = vec4(colour, original.a);
        return;
    }
#endif

    fragColor = original;
}
