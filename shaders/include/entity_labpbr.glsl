#ifndef PLAGUE_ENTITY_LABPBR
#define PLAGUE_ENTITY_LABPBR

// Shared LabPBR decode for the deferred ENTITIES and BLOCK_ENTITIES consumers.
// Fornax binds each missing sidecar independently to its semantic-neutral texture, so this code
// never guesses material data from the albedo and never needs an owner- or block-specific branch.
struct PlagueEntityLabPbr {
    vec3 worldNormal;
    float ao;
    float height;
    float smoothness;
    float f0;
    float materialBlue;
    float emission;
    float pomShadow;
    bool basisStable;
};

// `_s` contains categorical/split byte lanes. Select one whole mip level instead of blending two
// material definitions together. This is the same selection rule used by terrain.fsh.
float plagueEntityMaterialLod(sampler2D materialTexture, vec2 ddx, vec2 ddy) {
    vec2 texels = vec2(textureSize(materialTexture, 0));
    vec2 dx = ddx * texels;
    vec2 dy = ddy * texels;
    float rhoSq = max(dot(dx, dx), dot(dy, dy));
    return floor(0.5 * log2(max(rhoSq, 1.0)) + 0.5);
}

PlagueEntityLabPbr plagueSampleEntityLabPbr(
        sampler2D u_NormalTex, sampler2D u_MaterialTex,
        vec2 uv, vec3 worldPos, vec3 geometricNormal) {
    PlagueEntityLabPbr result;
    geometricNormal = normalize(geometricNormal);

    vec3 dPosX = dFdx(worldPos);
    vec3 dPosY = dFdy(worldPos);
    vec2 dUvX = dFdx(uv);
    vec2 dUvY = dFdy(uv);
    float det = dUvX.x * dUvY.y - dUvY.x * dUvX.y;

    vec3 tangent = vec3(0.0);
    vec3 bitangent = vec3(0.0);
    result.basisStable = abs(det) > 1e-12
            && length(dPosX) > 1e-8 && length(dPosY) > 1e-8;
    if (result.basisStable) {
        tangent = (dPosX * dUvY.y - dPosY * dUvX.y) * sign(det);
        bitangent = (dPosY * dUvX.x - dPosX * dUvY.x) * sign(det);
        tangent -= geometricNormal * dot(geometricNormal, tangent);
        bitangent -= geometricNormal * dot(geometricNormal, bitangent);
        result.basisStable = length(tangent) > 1e-8 && length(bitangent) > 1e-8;
    }

    vec2 ddx = dUvX;
    vec2 ddy = dUvY;
    vec4 normalSample = textureGrad(u_NormalTex, uv, ddx, ddy);
    vec4 materialSample = textureLod(
            u_MaterialTex, uv, plagueEntityMaterialLod(u_MaterialTex, ddx, ddy));

    // labPBR `_n`: rg tangent normal, b AO, a height. The all-black normal sentinel is flat.
    bool flatNormal = all(lessThan(normalSample.rgb, vec3(0.003)))
            || all(lessThan(abs(normalSample.rgb
                    - vec3(128.0 / 255.0, 128.0 / 255.0, 1.0)), vec3(0.5 / 255.0)));
    vec2 tangentXY = flatNormal
            ? vec2(0.0)
            : normalSample.rg * 2.0 - (254.0 / 255.0);
    float tangentZ = sqrt(clamp(1.0 - dot(tangentXY, tangentXY), 0.0, 1.0));
    vec3 worldNormal = geometricNormal;
    if (result.basisStable) {
        tangent = normalize(tangent);
        bitangent = normalize(bitangent);
        worldNormal = normalize(tangent * tangentXY.x
                + bitangent * tangentXY.y + geometricNormal * tangentZ);
    }

    result.worldNormal = worldNormal;
    result.ao = normalSample.b;
    result.height = normalSample.a;
    result.smoothness = materialSample.r;
    result.f0 = materialSample.g;
    result.materialBlue = materialSample.b;

    // LabPBR alpha 255 means emission was not authored. Values 0..254 are authored magnitudes.
    bool unauthoredEmission = materialSample.a >= (254.5 / 255.0);
    result.emission = unauthoredEmission ? 0.0 : materialSample.a;

    // Height is transported above, but these consumers have no per-sprite bounds. Marching an
    // atlas coordinate without those bounds can sample a neighbouring sprite, so POM remains the
    // exact identity until that geometric contract exists. Normal mapping still uses the stable
    // derivative basis; degenerate triangles preserve the supplied geometric normal.
    result.pomShadow = 1.0;
    return result;
}

#endif
