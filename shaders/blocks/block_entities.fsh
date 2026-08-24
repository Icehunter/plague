#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:entity_labpbr.glsl>

uniform sampler2D Sampler0;
uniform sampler2D u_NormalTex;
uniform sampler2D u_MaterialTex;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec2 texCoord0;

in vec3 v_PlagueWorldPos;
in vec2 v_PlagueMotion;
in float v_PlagueBlockLight;
in float v_PlagueSkyLight;

// Same G-buffer layout terrain and entities write, so one resolve lights all three.
layout(location = 0) out vec4 gNormalOut;
layout(location = 1) out vec4 gAlbedoOut;
layout(location = 2) out vec4 gMaterialOut;
layout(location = 3) out vec4 gAoOut;
layout(location = 4) out vec2 gMotionOut;

void main() {
    // vertexColor/ColorModulator carry an authored picked colour (banner/bed/shulker/sign dye),
    // never baked shade/AO — see entities.fsh for the full trace. Must decode before multiplying,
    // same as the texture sample; alpha is untouched (coverage, not colour).
    vec4 texSample = texture(Sampler0, texCoord0);
    vec4 color = vec4(
            plagueLinearToSrgb(plagueSrgbToLinear(texSample.rgb)
                    * plagueSrgbToLinear(vertexColor.rgb)
                    * plagueSrgbToLinear(ColorModulator.rgb)),
            texSample.a * vertexColor.a * ColorModulator.a);
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif

    // No normal in the vertex format, so recover a flat per-face normal from screen-space
    // derivatives — correct here since block entities are flat-shaded boxes. Flipped toward the
    // viewer since the cross product's sign depends on winding; v_PlagueWorldPos is camera-relative
    // so the eye direction is simply -v_PlagueWorldPos.
    vec3 normalCross = cross(dFdx(v_PlagueWorldPos), dFdy(v_PlagueWorldPos));
    float normalCrossLength = length(normalCross);
    // A triangle collapsed at the silhouette has no recoverable normal; avoid normalizing zero
    // (NaN) with a finite view-facing fallback instead.
    vec3 viewFallback = length(v_PlagueWorldPos) > 1e-8
            ? normalize(-v_PlagueWorldPos) : vec3(0.0, 0.0, 1.0);
    vec3 normal = normalCrossLength > 1e-12
            ? normalCross / normalCrossLength : viewFallback;
    if (dot(normal, -v_PlagueWorldPos) < 0.0) {
        normal = -normal;
    }

    PlagueEntityLabPbr labPbr = plagueSampleEntityLabPbr(
            u_NormalTex, u_MaterialTex, texCoord0, v_PlagueWorldPos, normal);

    // Fog applied once by the resolve, from depth; albedo stays unlit here, matching terrain/entities.
    gNormalOut   = vec4(labPbr.worldNormal, 1.0);
    gAlbedoOut   = vec4(color.rgb, v_PlagueSkyLight);
    gMaterialOut = vec4(labPbr.smoothness, labPbr.f0, labPbr.materialBlue,
                        v_PlagueBlockLight);
    gAoOut       = vec4(labPbr.ao, labPbr.emission, labPbr.pomShadow, 0.0);
    gMotionOut   = v_PlagueMotion;
}
