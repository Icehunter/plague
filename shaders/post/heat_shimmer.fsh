#version 330

// Heat shimmer: sceneHdrTemporal -> sceneHdrShimmer, between temporal accumulation and underwater
// refraction. Post-TAA: a warp before accumulation displaces pixels TAA then reprojects against
// unwarped motion vectors (see underwater_refraction.fsh).
//
// Two drives, independently toggled (heat_options.glsl): a Nether-wide ambient baseline
// (u_WorldBounds.w == 2), and a ground-facing boost near anything G-buffer-emissive (lava, fire,
// campfires write gAo.g for gbuffer_resolve.fsh's own glow). A climate-driven drive (deserts, hot
// biomes) waits on the aerial pass carrying per-column heat, which nothing produces yet.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:heat_options.glsl>

uniform sampler2D u_Input0; // sceneHdrTemporal
uniform sampler2D u_Input1; // builtin.depth
uniform sampler2D u_Input2; // builtin.gNormal
uniform sampler2D u_Input3; // builtin.gAo (g = emission, same lane gbuffer_resolve.fsh reads)
uniform sampler2D u_Input4; // builtin.noise

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4  u_SunDirection;
};

in vec2 texCoord;
out vec4 fragColor;

// Local copy of underwater_refraction.fsh's own helper; kept self-contained rather than importing
// a lighting file for one reconstruction.
vec3 plagueHeatWorldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    float w = abs(world.w) < 1e-6 ? 1e-6 : world.w;
    return world.xyz / w;
}

void main() {
    vec4 original = texture(u_Input0, texCoord);

    float depth = texture(u_Input1, texCoord).r;
    if (depth <= 0.0 || u_HeatShimmer <= 0.0) {
        fragColor = original;
        return;
    }

    // Not gated on facing: a wall or ceiling sits in the same hot air as the floor. Ramps in over
    // the 8 blocks past the start distance.
    float ambientHeat = 0.0;
    if (u_WorldBounds.w == 2.0 && u_HeatShimmerNether > 0.5) {
        float sceneDistance = length(plagueHeatWorldPosAt(texCoord, depth));
        float rampStart = u_NetherHeatDistance * 16.0;
        float distanceRamp = smoothstep(rampStart, rampStart + 8.0, sceneDistance);
        ambientHeat = u_NetherHeatAmbient * distanceRamp;
    }

    // Ground-facing only: heat rises from a floor, not sideways off a wall or down from a ceiling.
    vec3 normal = texture(u_Input2, texCoord).xyz * 2.0 - 1.0;
    float emissiveHeat = 0.0;
    if (u_HeatShimmerEmissive > 0.5 && normal.y >= 0.7) {
        float emission = texture(u_Input3, texCoord).g;
        emissiveHeat = smoothstep(0.05, 0.6, emission);
    }

    float heat = max(ambientHeat, emissiveHeat);
    if (heat <= 0.001) {
        fragColor = original;
        return;
    }

    // Scrolled upward on the wind clock: heat rises.
    float time = u_SkyState.w * 0.05;
    vec2 driftUv = texCoord * 40.0 + vec2(0.0, -time * 1.6);
    float drift = texture(u_Input4, driftUv).r * 2.0 - 1.0;

    // The travelling ripple people mean by "heat distortion": two sine terms at different
    // frequency and speed so it reads as organic air movement, not one mechanical wave.
    float wave = sin(texCoord.y * 120.0 - time * 5.0) * 0.6
               + sin(texCoord.y * 45.0 - time * 2.3) * 0.4;

    // Vertical drift dominates; the wave adds a horizontal-only bend on top.
    vec2 pixelOffset = (vec2(drift * 0.35, drift) * 3.0 + vec2(wave * 2.5, 0.0))
                     * heat * u_HeatShimmer;
    vec2 warpedUv = clamp(texCoord + pixelOffset * u_PassTexelSize,
                          u_PassTexelSize * 1.5, vec2(1.0) - u_PassTexelSize * 1.5);

    fragColor = vec4(texture(u_Input0, warpedUv).rgb, original.a);
}
