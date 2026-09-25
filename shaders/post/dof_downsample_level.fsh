#version 330

// One level of a small pyramid for the depth-of-field gather: halves resolution with an
// energy-preserving box average so a large disc radius samples a footprint comparable
// to its tap spacing; without this, sparse taps turn a bokeh disc into speckle.
// Colour in rgb (HDR), signed circle of confusion in alpha, both box-averaged.

uniform sampler2D u_Input0; // the level above: rgb HDR colour, a = signed CoC in half-res px

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec2 srcTexel = 1.0 / vec2(textureSize(u_Input0, 0));
    vec4 t0 = texture(u_Input0, texCoord + vec2(-0.5, -0.5) * srcTexel);
    vec4 t1 = texture(u_Input0, texCoord + vec2( 0.5, -0.5) * srcTexel);
    vec4 t2 = texture(u_Input0, texCoord + vec2(-0.5,  0.5) * srcTexel);
    vec4 t3 = texture(u_Input0, texCoord + vec2( 0.5,  0.5) * srcTexel);
    if (any(isnan(t0.rgb))) t0 = vec4(0.0);
    if (any(isnan(t1.rgb))) t1 = vec4(0.0);
    if (any(isnan(t2.rgb))) t2 = vec4(0.0);
    if (any(isnan(t3.rgb))) t3 = vec4(0.0);
    // Average rgba so the CoC channel averages too; a mixed near/far tile drifts toward
    // zero CoC here, accepted because classification at coarse levels is inherently soft.
    fragColor = (t0 + t1 + t2 + t3) * 0.25;
}
