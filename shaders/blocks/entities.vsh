#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Fornax's per-frame uniforms. Every geometry-slot program must import this: the slot's pipeline
// declares the matching bind group, so omitting it is a bind-group mismatch, not a missing feature.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>

in vec3 Position;
in vec4 Color;
in vec2 UV0;
in ivec2 UV1;
in ivec2 UV2;
in vec3 Normal;

#ifndef NO_OVERLAY
uniform sampler2D Sampler1;
#endif

out float sphericalVertexDistance;
out float cylindricalVertexDistance;

#ifdef PER_FACE_LIGHTING
out vec4 vertexPerFaceColorBack;
out vec4 vertexPerFaceColorFront;
#else
out vec4 vertexColor;
#endif

#ifndef NO_OVERLAY
out vec4 overlayColor;
#endif

out vec2 texCoord0;
// Vanilla consumes Normal for its own lighting and never forwards it; a deferred
// fragment stage needs it to write gNormal at all.
out vec3 v_PlagueNormal;
out vec3 v_PlagueWorldPos;
out vec2 v_PlagueMotion;
out float v_PlagueBlockLight;
out float v_PlagueSkyLight;

void main() {
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);

    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);

#ifdef PER_FACE_LIGHTING
    // Authored tint only — baking vanilla face lighting in here would double it with the resolve's
    // deferred-normal lighting.
    vertexPerFaceColorBack = Color;
    vertexPerFaceColorFront = Color;
#else
    vertexColor = Color;
#endif

#ifndef NO_OVERLAY
    overlayColor = texelFetch(Sampler1, UV1, 0);
#endif

    texCoord0 = UV0;

#ifdef APPLY_TEXTURE_MATRIX
    texCoord0 = (TextureMat * vec4(UV0, 0.0, 1.0)).xy;
#endif
    v_PlagueBlockLight = clamp(float(UV2.x) / 240.0, 0.0, 1.0);
    v_PlagueSkyLight = clamp(float(UV2.y) / 240.0, 0.0, 1.0);
    // Screen-space motion for TAA reprojection. Only CAMERA motion is captured — ModelViewMat folds
    // camera view together with the entity's own pose with no previous-frame pose to separate them,
    // so an entity moving through a still world reads zero motion here.
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    vec3 worldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;
    v_PlagueWorldPos = worldPos;
    // Transform the supplied entity normal through the same local->view->world chain as position.
    vec3 viewNormal = mat3(transpose(inverse(ModelViewMat))) * Normal;
    v_PlagueNormal = normalize(mat3(inverse(u_ModelViewMatrix)) * viewNormal);

    vec4 currentClip = ProjMat * viewPos;
    vec4 previousClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix * vec4(worldPos, 1.0);

    // Each frame's jitter is baked into its own projection, so subtracting cancels it exactly —
    // otherwise the jitter itself reads as motion, the wobble TAA exists to remove.
    vec2 currentNdc = (currentClip.xy / currentClip.w) - u_JitterOffset;
    vec2 previousNdc = (previousClip.xy / previousClip.w) - u_PrevJitterOffset;
    v_PlagueMotion = (currentNdc * 0.5 + 0.5) - (previousNdc * 0.5 + 0.5);
}
