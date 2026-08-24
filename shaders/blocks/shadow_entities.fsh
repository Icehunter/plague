#version 330

// Depth-only shadow caster. Dummy colour attachment only because a zero-colour-target pipeline
// can't be built; nothing reads it. The alpha test is the point: without it, cutout textures
// (leashes, capes, wings) would cast a solid rectangular shadow.

uniform sampler2D Sampler0;

in vec2 v_ShadowTexCoord;

void main() {
    if (texture(Sampler0, v_ShadowTexCoord).a < 0.1) {
        discard;
    }
}
