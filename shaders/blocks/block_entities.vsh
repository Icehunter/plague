#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Fornax's per-frame uniforms. Every geometry-slot program must import this: the slot's pipeline
// declares the matching bind group, so omitting it is a bind-group mismatch, not a missing feature.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>

// Chests, signs, banners, beds, shulkers. No NORMAL in this vertex format (vanilla shades from the
// baked lightmap); the fragment stage reconstructs one from screen-space derivatives instead.
in vec3 Position;
in vec4 Color;
in vec2 UV0;
in ivec2 UV2;

out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec4 vertexColor;
out vec2 texCoord0;

// Camera-relative, matching terrain.vsh's convention so the resolve agrees with both.
out vec3 v_PlagueWorldPos;
out vec2 v_PlagueMotion;
out float v_PlagueBlockLight;
out float v_PlagueSkyLight;

void main() {
    vec3 pos = Position + ModelOffset;
    vec4 viewPos = ModelViewMat * vec4(pos, 1.0);
    gl_Position = ProjMat * viewPos;

    sphericalVertexDistance = fog_spherical_distance(pos);
    cylindricalVertexDistance = fog_cylindrical_distance(pos);
    vertexColor = Color;
    texCoord0 = UV0;
    v_PlagueBlockLight = clamp(float(UV2.x) / 240.0, 0.0, 1.0);
    v_PlagueSkyLight = clamp(float(UV2.y) / 240.0, 0.0, 1.0);

    vec3 worldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;
    v_PlagueWorldPos = worldPos;

    // Screen-space motion for TAA reprojection. Camera motion only (see entities.vsh) — a chest lid
    // swinging in a still world reads as stationary, a smaller error than screen-wide smear.
    vec4 currentClip = gl_Position;
    vec4 previousClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix * vec4(worldPos, 1.0);

    // Each frame's jitter is baked into its own projection, so subtracting cancels it exactly —
    // otherwise the jitter itself reads as motion, the wobble TAA exists to remove.
    vec2 currentNdc = (currentClip.xy / currentClip.w) - u_JitterOffset;
    vec2 previousNdc = (previousClip.xy / previousClip.w) - u_PrevJitterOffset;
    v_PlagueMotion = (currentNdc * 0.5 + 0.5) - (previousNdc * 0.5 + 0.5);
}
