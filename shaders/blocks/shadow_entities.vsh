#version 330

#if defined(PER_FACE_LIGHTING) || !defined(NO_CARDINAL_LIGHTING)
#moj_import <minecraft:light.glsl>
#endif
#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
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

out vec2 v_ShadowTexCoord;

void main() {
#ifdef FORNAX_WORLD_SPACE_INPUT
    // View/projection were swapped to the LIGHT before this draw, so the vanilla transform already
    // lands in light clip space; reprojecting here would apply the light twice.
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);
#else
    // Replayed from draws prepared under the PLAYER's camera; that view must come back out first.
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    vec3 worldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;
    gl_Position = u_SunViewProj * vec4(worldPos, 1.0);
#endif

    // Radial distortion applied in CLIP space, matching the engine's terrain shadow program — the
    // two forms are equivalent only while the light projection stays orthographic (w == 1).
    //
    // gl_Position.z is written unscaled and stays that way: a matching depth-scale constant used to
    // exist on both the write side here and every read site, and removing it from all of them at
    // once provably changed no comparison outcome on this float depth target.
    float lVertexPos = length(gl_Position.xy);
    float distortFactor = lVertexPos * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    gl_Position.xy /= distortFactor;
    v_ShadowTexCoord = UV0;
}
