#ifndef PLAGUE_VOXEL_FACE_TEXTURE
#define PLAGUE_VOXEL_FACE_TEXTURE

uniform usamplerBuffer u_Input10; // optional voxelFaceTexture buffer; the palette's own stride stays 16

bool plagueVoxelFaceMapping(int entry, vec3 local, vec3 normal, out vec2 atlasUV,
        out vec3 tintColour, out vec3 tangent, out vec3 bitangent) {
    atlasUV = vec2(0.0); tintColour = vec3(1.0);
    tangent = vec3(0.0); bitangent = vec3(0.0);
    int d = u_VoxelWindow.w;
    // Six faces, eight words each, 96 palette entries per section. Reject a missing or stale buffer.
    if (d <= 0 || d > 33 || textureSize(u_Input10) != d * d * d * 96 * 48
            || entry < 0 || entry >= d * d * d * 96) return false;
    if (any(isnan(local)) || any(isinf(local)) || any(isnan(normal)) || any(isinf(normal))) return false;
    vec3 axes = abs(normal);
    if (dot(axes, vec3(1.0)) != 1.0 || max(axes.x, max(axes.y, axes.z)) != 1.0) return false;
    int face = normal.y != 0.0 ? (normal.y > 0.0 ? 1 : 0)
             : normal.z != 0.0 ? (normal.z > 0.0 ? 3 : 2) : (normal.x > 0.0 ? 5 : 4);
    int base = entry * 48 + face * 8;
    uint flags = texelFetch(u_Input10, base).r;
    if ((flags & 1u) == 0u) return false;
    uint tint = texelFetch(u_Input10, base + 1).r;
    vec2 origin = uintBitsToFloat(uvec2(texelFetch(u_Input10, base + 2).r, texelFetch(u_Input10, base + 3).r));
    vec2 ds = uintBitsToFloat(uvec2(texelFetch(u_Input10, base + 4).r, texelFetch(u_Input10, base + 5).r));
    vec2 dt = uintBitsToFloat(uvec2(texelFetch(u_Input10, base + 6).r, texelFetch(u_Input10, base + 7).r));
    if (any(isnan(origin)) || any(isinf(origin)) || any(isnan(ds)) || any(isinf(ds))
            || any(isnan(dt)) || any(isinf(dt))) return false;
    // The four corners bound the atlas region, turned sprites included.
    vec2 lo = min(min(origin, origin + ds), min(origin + dt, origin + ds + dt));
    vec2 hi = max(max(origin, origin + ds), max(origin + dt, origin + ds + dt));
    if (any(isnan(lo)) || any(isnan(hi)) || any(isinf(lo)) || any(isinf(hi))
            || any(lessThan(lo, vec2(0.0))) || any(greaterThan(hi, vec2(1.0)))
            || any(lessThanEqual(hi, lo))) return false;
    vec2 st = normal.x != 0.0 ? local.yz : normal.y != 0.0 ? local.xz : local.xy;
    vec2 inset = min(0.5 / vec2(textureSize(u_Input9, 0)), (hi - lo) * 0.5);
    atlasUV = clamp(origin + ds * st.x + dt * st.y, lo + inset, hi - inset);
    // Turn the UV map around for the world directions U and V grow in, mirrored and turned
    // sprites included. A flat map has no usable tangent; do not invent one.
    float determinant = ds.x * dt.y - dt.x * ds.y;
    if (determinant == 0.0) return false;
    vec3 axisS = normal.x != 0.0 ? vec3(0,1,0) : vec3(1,0,0);
    vec3 axisT = normal.z != 0.0 ? vec3(0,1,0) : vec3(0,0,1);
    tangent = normalize((dt.y * axisS - ds.y * axisT) / determinant);
    bitangent = normalize((-dt.x * axisS + ds.x * axisT) / determinant);
    tintColour = vec3((tint >> 16) & 255u, (tint >> 8) & 255u, tint & 255u) / 255.0;
    return true;
}
bool plagueVoxelFaceSample(int entry, vec3 local, vec3 normal, out vec4 sampleColour) {
    sampleColour = vec4(0.0);
    vec2 atlasUV; vec3 tintColour, tangent, bitangent;
    if (!plagueVoxelFaceMapping(entry, local, normal, atlasUV, tintColour, tangent, bitangent)) return false;
    sampleColour = textureLod(u_Input9, atlasUV, 0.0);
    // For callers that want one packed colour. Material shading reads texture and tint apart.
    sampleColour.rgb *= tintColour;
    return true;
}
#endif
