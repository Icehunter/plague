#version 330

// Builds the prefiltered reflection hierarchy: one mip chain over the finished `ssr` target, so a
// rough surface can read a genuinely convolved environment rather than a mirror sample.
//
// Fills the gap past ssr_blur's 7x7 kernel cap, where roughness stopped reaching the reflection:
// the pack's four copper door tiers (perceptual roughness 0.249-0.778) rendered identically. Each
// level here doubles the footprint, reaching the range a hemisphere integral needs.
//
// Mipchain passes get a reduced bind group and u_PassTexelSize is zero; every dimension comes from
// textureSize() instead. u_Param2 is 1.0 on the seed level, 0.0 on every reduce level.
//
// Alpha reduces with colour deliberately: it's the trace's hit confidence, and the wide lobe this
// feeds should see the neighbourhood's average confidence, not one lucky texel's hit.

uniform sampler2D u_Input0;

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize; // zero for mipchain passes, do not use
    float u_Param2;        // 1.0 on the seed level, 0.0 on every reduce level
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    ivec2 destination = ivec2(gl_FragCoord.xy);
    ivec2 sourceSize = textureSize(u_Input0, 0);

    // Seed level must equal `ssr` texel for texel: gbuffer_resolve reads LOD 0 as its sharp mirror
    // lobe, so any filtering here would change every mirror surface in the pack.
    if (u_Param2 > 0.5) {
        fragColor = texelFetch(u_Input0, min(destination, sourceSize - 1), 0);
        return;
    }

    // Bounds test matters on odd sizes, where the last row/column has no partner to pair with.
    ivec2 base = destination * 2;
    vec4 sum = vec4(0.0);
    float count = 0.0;
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            ivec2 source = base + ivec2(x, y);
            if (all(lessThan(source, sourceSize))) {
                sum += texelFetch(u_Input0, source, 0);
                count += 1.0;
            }
        }
    }
    fragColor = sum / max(count, 1.0);
}
