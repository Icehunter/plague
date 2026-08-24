#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:entity_labpbr.glsl>

uniform sampler2D Sampler0;
uniform sampler2D u_NormalTex;
uniform sampler2D u_MaterialTex;

#ifdef DISSOLVE
uniform sampler2D DissolveMaskSampler;
#endif

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
#ifdef PER_FACE_LIGHTING
in vec4 vertexPerFaceColorBack;
in vec4 vertexPerFaceColorFront;
#else
in vec4 vertexColor;
#endif

#ifndef NO_OVERLAY
in vec4 overlayColor;
#endif

in vec2 texCoord0;

in vec3 v_PlagueNormal;
in vec3 v_PlagueWorldPos;
in vec2 v_PlagueMotion;
in float v_PlagueBlockLight;
in float v_PlagueSkyLight;

// Same G-buffer layout terrain writes, so one resolve lights both.
layout(location = 0) out vec4 gNormalOut;
layout(location = 1) out vec4 gAlbedoOut;
layout(location = 2) out vec4 gMaterialOut;
layout(location = 3) out vec4 gAoOut;
layout(location = 4) out vec2 gMotionOut;

void main() {
    vec4 color = texture(Sampler0, texCoord0);
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif

#ifdef PER_FACE_LIGHTING
    vec4 faceVertexColor = gl_FrontFacing ? vertexPerFaceColorFront : vertexPerFaceColorBack;
#else
    vec4 faceVertexColor = vertexColor;
#endif

#ifdef DISSOLVE
    if (faceVertexColor.a < texture(DissolveMaskSampler, texCoord0).a) {
        discard;
    }
    // The dissolve effect entirely replaces translucency
    faceVertexColor.a = 1.0;
#endif

    // The per-vertex Color attribute carries an authored picked colour (banner/sign dye, etc.),
    // never baked shade/AO — confirmed via vanilla bytecode trace (BannerRenderer ->
    // DyeColor.getTextureDiffuseColor() -> ... -> VertexConsumer.addVertex). Unlike terrain's
    // shade/AO scalar, it's display-space and must be decoded before multiplying, same as the
    // texture. A prior linear-multiply treatment here read a brown-dyed banner as pale cream instead
    // of dark brown, measured as linear RGB ~(0.45, 0.30, 0.18) misread as ~(0.17, 0.073, 0.027) —
    // same failure entities.vsh:52-53 guards against. Alpha is untouched (coverage, never gamma-encoded).
    color.rgb = plagueLinearToSrgb(
            plagueSrgbToLinear(color.rgb)
                    * plagueSrgbToLinear(faceVertexColor.rgb)
                    * plagueSrgbToLinear(ColorModulator.rgb));
    color.a *= faceVertexColor.a * ColorModulator.a;
#ifndef NO_OVERLAY
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayColor.a);
#endif
    PlagueEntityLabPbr labPbr = plagueSampleEntityLabPbr(
            u_NormalTex, u_MaterialTex, texCoord0, v_PlagueWorldPos,
            normalize(v_PlagueNormal));

    // Fog and lighting applied once by the resolve.
    gNormalOut   = vec4(labPbr.worldNormal, 1.0);
    gAlbedoOut   = vec4(color.rgb, v_PlagueSkyLight);
    gMaterialOut = vec4(labPbr.smoothness, labPbr.f0, labPbr.materialBlue,
                        v_PlagueBlockLight);
    // .a = 0.75 marks this as the animated ENTITIES draw for responsive temporal treatment.
    gAoOut       = vec4(labPbr.ao, labPbr.emission, labPbr.pomShadow, 0.75);
    gMotionOut   = v_PlagueMotion;
}
