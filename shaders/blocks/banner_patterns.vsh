#version 330

// Banner pattern layers: the forward slot's vertex stage. A faithful port of vanilla's
// core/entity.vsh with one addition: camera-relative world position is forwarded to the fragment
// stage, since plagueApplyFog needs the view ray and altitude, not vanilla's two scalar fog
// distances. shaders/blocks/particles.vsh forwards the same thing for the same reason.
//
// Reconstructing position from depth (how every fullscreen pass here does it) is not an option:
// the depth buffer is bound as this draw's own depth ATTACHMENT, and sampling a texture that is
// simultaneously an attachment is a feedback-loop hazard.

#if defined(PER_FACE_LIGHTING) || !defined(NO_CARDINAL_LIGHTING)
#moj_import <minecraft:light.glsl>
#endif
// Declared, never called: keeps vanilla's Fog bind group layout, but the fog applied is Plague's
// own, in the fragment stage. entities.fsh imports it on the same terms.
#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Every geometry-slot program must import this: the slot's pipeline declares the matching bind
// group, so omitting it is a bind-group mismatch, not a missing feature.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>
#moj_import <minecraft:sample_lightmap.glsl>

in vec3 Position;
in vec4 Color;
in vec2 UV0;
in ivec2 UV1;
in ivec2 UV2;
in vec3 Normal;

#ifndef NO_OVERLAY
uniform sampler2D Sampler1;
#endif

#ifndef EMISSIVE
uniform sampler2D Sampler2;
#endif

out float sphericalVertexDistance;
out float cylindricalVertexDistance;

#ifdef PER_FACE_LIGHTING
out vec4 vertexPerFaceColorBack;
out vec4 vertexPerFaceColorFront;
#else
out vec4 vertexColor;
#endif

#ifndef EMISSIVE
out vec4 lightMapColor;
#endif

#ifndef NO_OVERLAY
out vec4 overlayColor;
#endif

out vec2 texCoord0;

// The convention terrain.vsh sets and every fog call site reads, so this banner's fog is anchored
// exactly the way the terrain behind it is.
out vec3 v_PlagueWorldPos;

// BANNER_PATTERN only ever carries NO_OVERLAY today (javap -c on RenderPipelines, 26.2), so the
// other guards below are dead here. Kept anyway: the defines are the engine's to supply, not this
// pack's to assume away, and a variant arriving later should render rather than fail to compile.
void main() {
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);

    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);

#ifdef PER_FACE_LIGHTING
    vec2 light = minecraft_compute_light(Light0_Direction, Light1_Direction, Normal);
    vertexPerFaceColorBack = minecraft_mix_light_separate(-light, Color);
    vertexPerFaceColorFront = minecraft_mix_light_separate(light, Color);
#elif defined(NO_CARDINAL_LIGHTING)
    vertexColor = Color;
#else
    vertexColor = minecraft_mix_light(Light0_Direction, Light1_Direction, Normal, Color);
#endif

#ifndef EMISSIVE
    lightMapColor = sample_lightmap(Sampler2, UV2);
#endif

#ifndef NO_OVERLAY
    overlayColor = texelFetch(Sampler1, UV1, 0);
#endif

    texCoord0 = UV0;

#ifdef APPLY_TEXTURE_MATRIX
    texCoord0 = (TextureMat * vec4(UV0, 0.0, 1.0)).xy;
#endif

    // Built through view space and back out through Sodium's rotation-only camera matrix, rather
    // than forwarding `Position` raw, so this derives its fog anchor from the same two matrices as
    // entities.vsh and particles.vsh. A private shortcut here would disagree with the frame by a
    // pose transform whenever a banner isn't axis-aligned with the world.
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    v_PlagueWorldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;
}
