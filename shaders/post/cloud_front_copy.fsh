#version 330

// The marching tier's cloud front distance, copied into one UNGATED target so a pass that is not
// gated on CLOUD_RESOLUTION can read it.
//
// water_composite is the consumer, and it needs this because compositing order cannot give it what
// it needs on its own: clouds composite into sceneHdr, ssr_trace_water reads sceneHdr (which is what
// puts clouds IN the water), and water composites after the trace. Clouds therefore always land
// before water, and water blends over them. Reordering trades the reflection for the occlusion; a
// distance the water pass can test keeps both.
//
// Three tier-specific copies exist and exactly one compiles, since cloudsVolumeDistance,
// cloudsVolumeDistanceQuarter and cloudsVolumeDistanceFull are each gated to their own
// CLOUD_RESOLUTION arm. A gated pass writing an ungated target is the direction gate-consistency
// allows; the reverse is what it refuses.
//
// Half scale on purpose. The source is at most three-quarter scale, the signal is a smooth
// first-hit distance with no chunk-level detail, and the consumer only compares it against the water
// surface distance. Sampled with `filter = "linear"`, so the comparison reads between texels rather
// than stepping.
//
// 0.0 is the empty-ray sentinel the march writes, not a near plane: a pixel whose ray met no cloud
// carries zero, and the consumer must test for it rather than treating it as "cloud at the eye".

uniform sampler2D u_Input0; // cloudsVolumeDistance for the live tier (r32f; 0.0 means empty ray)

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    fragColor = vec4(texture(u_Input0, texCoord).r, 0.0, 0.0, 1.0);
}
