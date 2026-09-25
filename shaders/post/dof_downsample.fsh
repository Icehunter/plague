#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:dof.glsl>

// Half-res colour + CoC for the bokeh gather. Plain average with a radiance cap rather than a
// luma-weighted one: weighting by 1/(1+luma) dims a defocused lantern's disc several times
// over, and a bokeh disc IS that bright energy spread wide. The cap alone handles stray
// spikes. CoC taken from the nearest of the four parents so a thin near silhouette keeps
// its blur.

uniform sampler2D u_SceneHdrGlare; // full-res linear HDR scene with the glare already baked in
uniform sampler2D u_Depth; // builtin.depth: reversed-Z, 0.0 is the far plane
uniform sampler2D u_DofFocus; // 1x1 focus distance in blocks
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
    // Defensive fallback, matching dof_tile.fsh; dof_focus has already run this frame.
    if (focus <= 0.0) focus = 16.0;
    vec2 fullTexel = 1.0 / vec2(textureSize(u_SceneHdrGlare, 0));

    vec2 offs[4] = vec2[4](vec2(-0.5, -0.5), vec2(0.5, -0.5), vec2(-0.5, 0.5), vec2(0.5, 0.5));
    vec3 colourSum = vec3(0.0);
    float wSum = 0.0;
    float nearestDist = 1e9;
    float nearestCoc = 0.0;

    for (int i = 0; i < 4; ++i) {
        vec2 uv = texCoord + offs[i] * fullTexel;
        vec3 c = texture(u_SceneHdrGlare, uv).rgb;
        if (any(isnan(c)) || any(isinf(c))) c = vec3(0.0);
        // 256 comfortably clears the pack's emissive range at the tonemap stage while a stray
        // near-infinite spike cannot flood a whole disc; same job as bloom's own radiance cap.
        c = clamp(c, 0.0, 256.0);

        // Nearest surface, water included, matching dof_focus and dof_tile.
        float depth = max(texture(u_Depth, uv).r, texture(u_WaterDepth, uv).r);
        // Sky focuses at optical infinity; 512 blocks matches the autofocus sky distance.
        float dist = 512.0;
        if (depth > 0.0) {
            vec4 h = u_InvProjModelView * vec4(uv * 2.0 - 1.0, depth, 1.0);
            dist = length(h.xyz / h.w);
        }

        // This pass renders at half res, so its own texel count is the pixel scale.
        float tapCoc = plagueDofCoc(dist, focus, (1.0 / u_PassTexelSize.x) / PLAGUE_DOF_SENSOR_MM);
        if (dist < nearestDist) {
            nearestDist = dist;
            nearestCoc = tapCoc;
        }

        colourSum += c;
        wSum += 1.0;
    }

    fragColor = vec4(colourSum / max(wSum, 1e-4), nearestCoc);
}
