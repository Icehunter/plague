#ifndef PLAGUE_VOXEL_LOCAL_SOURCE_SAMPLING
#define PLAGUE_VOXEL_LOCAL_SOURCE_SAMPLING

#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:emission.glsl>
#moj_import <fornax_runtime:voxel_atlas_pages.glsl>

// Uses the compute pass's faceTextureWords, u_BlockAtlas and u_MaterialAtlas bindings.
// Whole-face/whole-sprite eligibility comes from source evidence; UV bounds alone cannot prove it.
struct PlagueLocalSourceFace {
    int page;
    vec2 uv0;
    vec2 ds;
    vec2 dt;
    ivec2 blockOrigin;
    ivec2 blockEnd;
    ivec2 materialOrigin;
    ivec2 materialEnd;
    vec3 linearTint;
    float intrinsic;
    bool cutout;
    bool missingMap;
};

bool plagueLocalSourceFace(int entry, int face, uint facts, out PlagueLocalSourceFace mapping) {
    // VoxelFaceTexture ABI: six faces in direction-ID order, seven words per face.
    int base = entry * 42 + face * 7;
    uint header = faceTextureWords[base];
    uint flags = header >> 24;
    if ((flags & 1u) == 0u) return false;
    mapping.uv0 = uintBitsToFloat(uvec2(faceTextureWords[base+1], faceTextureWords[base+2]));
    mapping.ds = uintBitsToFloat(uvec2(faceTextureWords[base+3], faceTextureWords[base+4]));
    mapping.dt = uintBitsToFloat(uvec2(faceTextureWords[base+5], faceTextureWords[base+6]));
    if (any(isnan(mapping.uv0)) || any(isinf(mapping.uv0))
            || any(isnan(mapping.ds)) || any(isinf(mapping.ds))
            || any(isnan(mapping.dt)) || any(isinf(mapping.dt))) return false;
    mapping.missingMap = (facts & (1u << (16+face))) != 0u;
    if (!plagueSourceAtlasPage(flags, mapping.missingMap,
            mapping.uv0, mapping.ds, mapping.dt, mapping.page)) return false;
    vec2 lo = min(min(mapping.uv0, mapping.uv0+mapping.ds),
            min(mapping.uv0+mapping.dt, mapping.uv0+mapping.ds+mapping.dt));
    vec2 hi = max(max(mapping.uv0, mapping.uv0+mapping.ds),
            max(mapping.uv0+mapping.dt, mapping.uv0+mapping.ds+mapping.dt));
    float determinant = mapping.ds.x*mapping.dt.y - mapping.dt.x*mapping.ds.y;
    if (any(isnan(lo)) || any(isnan(hi)) || any(isinf(lo)) || any(isinf(hi))
            || any(lessThan(lo, vec2(0.0))) || any(greaterThan(hi, vec2(1.0)))
            || any(lessThanEqual(hi, lo)) || determinant == 0.0) return false;
    ivec2 blockSize = plagueSourceBlockSize(mapping.page);
    mapping.blockOrigin = ivec2(floor(lo*vec2(blockSize)+0.5));
    ivec2 extent = ivec2(floor((hi-lo)*vec2(blockSize)+0.5));
    mapping.blockEnd = mapping.blockOrigin + extent;
    if (any(lessThan(extent, ivec2(1))) || any(greaterThan(mapping.blockEnd, blockSize))) return false;
    mapping.materialOrigin = ivec2(0);
    mapping.materialEnd = ivec2(0);
    if (!mapping.missingMap) {
        ivec2 materialSize = plagueSourceMaterialSize(mapping.page);
        vec2 scale = vec2(materialSize)/vec2(blockSize);
        // Sidecar atlas layout rounds in block space before flooring its scaled rectangle.
        mapping.materialOrigin = ivec2(floor(vec2(mapping.blockOrigin)*scale));
        ivec2 materialExtent = max(ivec2(1), ivec2(floor(vec2(extent)*scale)));
        mapping.materialEnd = mapping.materialOrigin + materialExtent;
        if (any(greaterThan(mapping.materialEnd, materialSize))) return false;
    }
    vec3 tint = vec3((header>>16)&255u, (header>>8)&255u, header&255u)/255.0;
    mapping.linearTint = plagueSrgbToLinear(tint);
    mapping.intrinsic = float((facts>>8)&15u)/15.0; // Raw Minecraft emission range, never incident light.
    mapping.cutout = (flags & 2u) != 0u;
    return true;
}

vec3 plagueLocalSourceSample(PlagueLocalSourceFace mapping, vec2 st) {
    vec2 uv = mapping.uv0 + st.x*mapping.ds + st.y*mapping.dt;
    ivec2 texel = clamp(ivec2(uv*vec2(plagueSourceBlockSize(mapping.page))),
            mapping.blockOrigin, mapping.blockEnd-1);
    vec4 albedo = plagueSourceBlockTexel(mapping.page, texel);
    // Rejected cutout texels are valid zero emission, retaining their share of the quarter area.
    if (mapping.cutout && albedo.a < 0.5) return vec3(0.0);
    float materialAlpha = 1.0; // labPBR byte 255: known missing authored map.
    if (!mapping.missingMap) {
        ivec2 materialTexel = clamp(ivec2(uv*vec2(plagueSourceMaterialSize(mapping.page))),
                mapping.materialOrigin, mapping.materialEnd-1);
        // Exact bytes keep the unauthored 255 sentinel separate from authored emission.
        materialAlpha = plagueSourceMaterialTexel(mapping.page, materialTexel).a;
    }
    vec3 linearAlbedo = plagueSrgbToLinear(albedo.rgb)*mapping.linearTint;
    float luminance = plagueSourceLuminance(linearAlbedo, mapping.intrinsic,
            materialAlpha, u_AuthoredEmission);
    return plagueEmittedRadiance(linearAlbedo, luminance);
}

#endif
