#version 330

// Hi-Z depth pyramid: a max-reduced mip chain over builtin.depth, marched by ssr_trace.
//
// Max-reduce, not min: reversed-Z means the CLOSEST surface has the MAXIMUM depth value, so a
// min-reduce would build a pyramid of the farthest surfaces and defeat the trace's "in front of
// everything in this tile" test.
//
// No <fornax:globals.glsl> import: mipchain passes get a reduced bind group (u_PassParams only).
// u_PassTexelSize is zero here too; every dimension comes from textureSize() instead.

uniform sampler2D u_Input0; // seed: builtin.depth | reduce: the parent mip level

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize; // zero for mipchain passes, do not use
    float u_Param2;        // 1.0 on the seed level, 0.0 on every reduce level
    float u_Param3;
};

in vec2 texCoord;
out float fragColor;

void main() {
    ivec2 dst = ivec2(gl_FragCoord.xy);
    ivec2 srcSize = textureSize(u_Input0, 0);

    if (u_Param2 > 0.5) {
        // texelFetch, not texture(), so filtering can't invent a depth no surface actually has.
        fragColor = texelFetch(u_Input0, min(dst, srcSize - 1), 0).r;
        return;
    }

    // Mip N is floor(srcDim/2), so an odd source dimension leaves one texel with no destination;
    // the last texel along an odd axis widens its footprint to three source texels instead of two,
    // so a Hi-Z level can't under-report "closest" and let a ray skip through real geometry.
    ivec2 dstSize = max(srcSize / 2, ivec2(1));
    ivec2 base = dst * 2;
    bool wideX = (srcSize.x & 1) == 1 && dst.x == dstSize.x - 1;
    bool wideY = (srcSize.y & 1) == 1 && dst.y == dstSize.y - 1;

    float closest = 0.0; // reversed-Z: 0.0 is the far plane, so this is the correct identity for max
    for (int y = 0; y <= (wideY ? 2 : 1); y++) {
        for (int x = 0; x <= (wideX ? 2 : 1); x++) {
            closest = max(closest, texelFetch(u_Input0, min(base + ivec2(x, y), srcSize - 1), 0).r);
        }
    }
    fragColor = closest;
}
