#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Fornax's per-frame uniforms. Every geometry-slot program must import this: the slot's pipeline
// declares the matching bind group, so omitting it is a bind-group mismatch, not a missing feature.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>
#moj_import <minecraft:sample_lightmap.glsl>

// Narrowest vertex format in the pack: no normal, no overlay, no tangent (a particle is a
// camera-facing quad and vanilla gives nothing else).
in vec3 Position;
in vec2 UV0;
in vec4 Color;
in ivec2 UV2;

uniform sampler2D Sampler2;

out vec2 texCoord0;
out vec4 vertexColor;
out vec2 v_PlagueMotion;

void main() {
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    gl_Position = ProjMat * viewPos;

    texCoord0 = UV0;

    // Lightmap folded into the tint, matching entities.vsh/block_entities.vsh (terrain instead
    // writes true light levels to the G-buffer and is lit by the resolve) so a particle shades like
    // the mob it drifts past.
    vertexColor = Color * sample_lightmap(Sampler2, UV2);

    // Camera-relative world position, the convention terrain.vsh sets and the resolve reads.
    vec3 worldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;

    // Motion vectors cover only the CAMERA's motion, not the particle's own (vanilla bakes each
    // quad's transform at submit time with no previous-frame position to diff against). Still
    // strictly better than a cleared gMotion, which would make TAA fetch 90%-stale history at
    // taaBlendFactor 0.9 while the camera turns.
    //
    // u_CameraDelta is added here (unlike entities.vsh/block_entities.vsh) because both model-view
    // matrices in u_Globals are rotation-only, so reprojecting a camera that TRAVELLED (not just
    // turned) needs `P + u_CameraDelta.xyz`, matching what terrain.vsh builds from
    //
    // Fixes the sky-ghosting regression from Fornax a878f59. entities.vsh and block_entities.vsh
    // still have the same particle-motion reprojection gap this file just closed for particles.
    // u_PrevRegionOffset.
    vec4 previousClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix
            * vec4(worldPos + u_CameraDelta.xyz, 1.0);

    // Each frame's jitter cancels by subtracting it; skipping this makes the jitter itself read as
    // motion, the wobble TAA exists to remove.
    vec2 currentNdc  = (gl_Position.xy / gl_Position.w) - u_JitterOffset;
    vec2 previousNdc = (previousClip.xy / previousClip.w) - u_PrevJitterOffset;
    v_PlagueMotion = (currentNdc * 0.5 + 0.5) - (previousNdc * 0.5 + 0.5);
}
