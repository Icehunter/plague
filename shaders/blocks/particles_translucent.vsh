#version 330

// Translucent particles: the FORWARD slot's vertex stage (campfire smoke, torch flame/smoke, souls,
// spells, sculk). A faithful port of vanilla's core/particle.vsh, plus forwarding the camera-relative
// world position the fragment stage needs to compute fog by view ray and altitude (vanilla's own
// stage forwards only two scalar fog distances, not enough for that).
//
// Not a copy of particles.vsh: that's the deferred solid arm and writes gMotion; this forward draw
// has no G-buffer attachment to write one to. No depth texture either — depth is bound as this
// draw's own attachment, and sampling it too would be a feedback-loop hazard.

// Declared but never called: kept only so this program's bind-group layout matches vanilla's.
// The fog actually applied is Plague's own, in the fragment stage.
#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Fornax's per-frame uniforms. Every geometry-slot program must import this: the slot's pipeline
// declares the matching bind group, so omitting it is a bind-group mismatch, not a missing feature.
#moj_import <fornax:globals.glsl>
#moj_import <minecraft:projection.glsl>
#moj_import <minecraft:sample_lightmap.glsl>

// DefaultVertexFormat.PARTICLE, the narrowest format in the pack: no normal, no overlay, no tangent.
in vec3 Position;
in vec2 UV0;
in vec4 Color;
in ivec2 UV2;

uniform sampler2D Sampler2;

out vec2 texCoord0;
out vec4 vertexColor;

// Camera-relative world position, terrain.vsh's convention, so a smoke puff's fog anchors exactly
// like the terrain behind it.
out vec3 v_PlagueWorldPos;

void main() {
    vec4 viewPos = ModelViewMat * vec4(Position, 1.0);
    gl_Position = ProjMat * viewPos;

    texCoord0 = UV0;
    // Vanilla's own line: forward draw compositing into an already-lit frame, so this is the
    // lighting, unchanged.
    vertexColor = Color * sample_lightmap(Sampler2, UV2);

    // Same construction particles.vsh/entities.vsh/banner_patterns.vsh use, rather than a private
    // shortcut, so any convention bug shows consistently instead of only here.
    v_PlagueWorldPos = (inverse(u_ModelViewMatrix) * viewPos).xyz;
}
