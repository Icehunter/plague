#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:dof.glsl>

// One output texel per 16x16 full-resolution depth region: records the largest blur disc in the
// region so the gather pass can size its spiral. Tile classification per Jimenez 2014, "Next
// Generation Post Processing in Call of Duty: Advanced Warfare" (SIGGRAPH course). 16 px pairs
// with the dilate's 4-tile reach: 16 full-res px is 8 half-res px, and 4 tiles of reach covers
// the 32 half-res px slider cap on u_DofMaxBlur.

uniform sampler2D u_Depth; // builtin.depth: reversed-Z, 0.0 is the far plane
uniform sampler2D u_DofFocus; // 1x1 smoothed focus distance in blocks
uniform sampler2D u_WaterDepth; // builtin.waterDepth: reversed-Z, 0.0 = no water surface

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    float focus = texture(u_DofFocus, vec2(0.5)).r;
    // Defensive: dof_focus runs earlier in this same frame and always writes >= 0.5, so 0
    // appears only if the graph reorders; 16 blocks is a neutral focus for that frame.
    if (focus <= 0.0) focus = 16.0;
    // Half-res width in pixels: this pass runs at 1/16 scale, so half res is 8 of its
    // texels. Target sizes round per scale, so this can sit under one percent off the
    // true half width at odd resolutions; the dilate absorbs the difference.
    float pxPerMm = (8.0 / u_PassTexelSize.x) / PLAGUE_DOF_SENSOR_MM;
    float maxAbs = 0.0;
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            // 8x8 taps over 256 pixels: a sub-2-pixel feature can slip between taps, accepted
            // because the dilate pass widens every maximum before use.
            vec2 uv = texCoord + ((vec2(x, y) + 0.5) / 8.0 - 0.5) * u_PassTexelSize;
            // Nearest surface, water included, matching dof_focus and dof_downsample.
            float depth = max(texture(u_Depth, uv).r, texture(u_WaterDepth, uv).r);
            // Sky focuses at optical infinity; 512 blocks matches the autofocus sky distance.
            float dist = 512.0;
            if (depth > 0.0) {
                vec4 h = u_InvProjModelView * vec4(uv * 2.0 - 1.0, depth, 1.0);
                dist = length(h.xyz / h.w);
            }
            maxAbs = max(maxAbs, abs(plagueDofCoc(dist, focus, pxPerMm)));
        }
    }
    fragColor = vec4(maxAbs, 0.0, 0.0, 1.0);
}
