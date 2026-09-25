#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Fornax's per-frame uniforms. Every geometry-slot program must import this: the slot's pipeline
// declares the matching bind group, so omitting it is a bind-group mismatch, not a missing feature.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>
#moj_import <minecraft:sample_lightmap.glsl>
#moj_import <fornax_runtime:local_light_mode.glsl>

// Narrowest vertex format in the pack: no normal, no overlay, no tangent (a particle is a
// camera-facing quad and vanilla gives nothing else).
in vec3 Position;
in vec2 UV0;
in vec4 Color;
in ivec2 UV2;

uniform sampler2D Sampler2;

out vec2 texCoord0;
out vec4 vertexColor;
out vec3 v_MotionCurrentClip;
out vec3 v_MotionPreviousClip;

void main() {
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    gl_Position = ProjMat * viewPos;

    texCoord0 = UV0;

    // Lightmap folded into the tint, matching entities.vsh/block_entities.vsh (terrain instead
    // writes true light levels to the G-buffer and is lit by the resolve) so a particle shades like
    // the mob it drifts past.
    vertexColor = Color * sample_lightmap(Sampler2, plagueLightingPackedCoord(UV2));

    // Camera-relative world position, the convention terrain.vsh sets and the resolve reads.
    vec3 worldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;

    // Motion vectors cover only the CAMERA's motion, not the particle's own (vanilla bakes each
    // quad's transform at submit time with no previous-frame position to diff against). Still
    // strictly better than a cleared gMotion, which would make TAA fetch 90%-stale history at
    // taaBlendFactor 0.9 while the camera turns.
    //
    // u_CameraDelta is added here because both model-view
    // matrices in u_Globals are rotation-only, so reprojecting a camera that TRAVELLED (not just
    // turned) needs `P + u_CameraDelta.xyz`, matching terrain.vsh's u_PrevRegionOffset.
    vec4 previousClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix
            * vec4(worldPos + u_CameraDelta.xyz, 1.0);

    // Preserve homogeneous coordinates through interpolation: divided vertex motion picks the
    // wrong history pixel on slanted faces. Removing jitter times w is linear in clip space.
    v_MotionCurrentClip = vec3(gl_Position.xy - u_JitterOffset * gl_Position.w, gl_Position.w);
    v_MotionPreviousClip = vec3(previousClip.xy - u_PrevJitterOffset * previousClip.w, previousClip.w);
}
