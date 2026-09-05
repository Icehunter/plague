#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Fornax's per-frame uniforms. Every geometry-slot program must import this, or the bind group the
// pipeline declares has nothing to match.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>

// Position only. Vanilla gives this draw no colour, no texture coordinate and no lightmap.
in vec3 Position;

out vec4 texProj0;
out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec2 v_PlagueMotion;

void main() {
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    gl_Position = ProjMat * viewPos;

    // Where this pixel sits on screen, in clip space.
    texProj0 = projection_from_position(gl_Position);
    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);

    // Position is already the camera-relative world position the resolve wants: ModelViewMat turns
    // but does not travel here, so there is no inverse to undo.
    vec3 worldPos = Position;

    // A portal never moves, so camera-only motion is exact here. u_CameraDelta is added because
    // both model-view matrices turn but do not travel.
    vec4 previousClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix
            * vec4(worldPos + u_CameraDelta.xyz, 1.0);

    // Subtracting each frame's jitter, or the jitter reads as movement.
    vec2 currentNdc  = (gl_Position.xy / gl_Position.w) - u_JitterOffset;
    vec2 previousNdc = (previousClip.xy / previousClip.w) - u_PrevJitterOffset;
    v_PlagueMotion = (currentNdc * 0.5 + 0.5) - (previousNdc * 0.5 + 0.5);
}
