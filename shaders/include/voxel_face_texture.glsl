#moj_import <fornax_runtime:voxel_palette_layout.glsl>
#ifndef PLAGUE_VOXEL_FACE_TEXTURE
#define PLAGUE_VOXEL_FACE_TEXTURE

#ifndef PLAGUE_VOXEL_EXTERNAL_BUFFERS
uniform usamplerBuffer u_Input10; // optional voxelFaceTexture buffer; the palette's own stride stays 16
#endif

// Rendered opaque backing is independent of atlas UV mapping (a grass overlay has multiple quads).
bool plagueVoxelOpaqueFace(int entry,vec3 normal) {
    int d=u_VoxelWindow.w;
    if(d<1 || d>33 || plagueVoxelFaceCapacity(textureSize(u_Input10),d)==0 || entry<0 || entry>=textureSize(u_Input10)/42) return false;
    int face=normal.y!=0.0 ? (normal.y>0.0?1:0) : normal.z!=0.0 ? (normal.z>0.0?3:2) : (normal.x>0.0?5:4);
    return (texelFetch(u_Input10,entry*42+face*7).r & 0x04000000u)!=0u;
}

// Mapping flags are the engine ABI: bit 24 is legacy face data; bit 29 is explicit
// boundary data. Visibility callers must keep the legacy mask; shading may read both.
bool plagueVoxelQuadMapping(int entry, int face, vec2 st, vec2 stLo, vec2 stHi,
        vec3 axisS, vec3 axisT, uint mappingMask, out vec2 atlasUV,
        out vec3 tintColour, out vec3 tangent, out vec3 bitangent) {
    atlasUV = vec2(0.0); tintColour = vec3(1.0);
    tangent = vec3(0.0); bitangent = vec3(0.0);
    int d = u_VoxelWindow.w;
    // VoxelFaceTexture ABI: six seven-word records per entry, capacity derived from the buffer extent.
    if (d <= 0 || d > 33 || plagueVoxelFaceCapacity(textureSize(u_Input10),d) == 0
            || entry < 0 || entry >= textureSize(u_Input10)/42 || face < 0 || face >= 6) return false;
    if (any(isnan(st)) || any(isinf(st)) || any(isnan(stLo)) || any(isinf(stLo))
            || any(isnan(stHi)) || any(isinf(stHi)) || any(lessThanEqual(stHi,stLo))) return false;
    int base = entry*42 + face*7;
    uint tint = texelFetch(u_Input10,base).r;
    if (((tint >> 24) & mappingMask) == 0u) return false;
    vec2 origin = uintBitsToFloat(uvec2(texelFetch(u_Input10,base+1).r,texelFetch(u_Input10,base+2).r));
    vec2 ds = uintBitsToFloat(uvec2(texelFetch(u_Input10,base+3).r,texelFetch(u_Input10,base+4).r));
    vec2 dt = uintBitsToFloat(uvec2(texelFetch(u_Input10,base+5).r,texelFetch(u_Input10,base+6).r));
    if (any(isnan(origin)) || any(isinf(origin)) || any(isnan(ds)) || any(isinf(ds))
            || any(isnan(dt)) || any(isinf(dt))) return false;
    // Partial boundaries and crosses occupy their actual box, not an extrapolated unit square.
    vec2 a = origin + ds*stLo.x + dt*stLo.y;
    vec2 b = origin + ds*stHi.x + dt*stLo.y;
    vec2 c = origin + ds*stLo.x + dt*stHi.y;
    vec2 e = origin + ds*stHi.x + dt*stHi.y;
    vec2 lo = min(min(a,b),min(c,e));
    vec2 hi = max(max(a,b),max(c,e));
    // Four rounded float32 operations reconstruct each corner. Bound their accumulated
    // roundoff by four machine epsilons times operand magnitudes, capped at half a texel.
    // Without this, a valid atlas-edge corner one ulp above 1 silently loses its texture.
    vec2 halfTexel = 0.5/vec2(textureSize(u_Input9,0));
    vec2 roundoff = min(halfTexel,4.0*exp2(-23.0)*(abs(origin)
            + abs(ds)*max(abs(stLo.x),abs(stHi.x)) + abs(dt)*max(abs(stLo.y),abs(stHi.y))));
    if (any(isnan(lo)) || any(isinf(lo)) || any(isnan(hi)) || any(isinf(hi))
            || any(lessThan(lo,-roundoff)) || any(greaterThan(hi,vec2(1.0)+roundoff))) return false;
    lo=clamp(lo,vec2(0.0),vec2(1.0)); hi=clamp(hi,vec2(0.0),vec2(1.0));
    if (any(lessThanEqual(hi,lo))) return false;
    vec2 inset = min(halfTexel,(hi-lo)*0.5);
    atlasUV = clamp(origin + ds*st.x + dt*st.y,lo+inset,hi-inset);
    float determinant = ds.x*dt.y - dt.x*ds.y;
    if (determinant == 0.0) return false;
    tangent = normalize((dt.y*axisS - ds.y*axisT)/determinant);
    bitangent = normalize((-dt.x*axisS + ds.x*axisT)/determinant);
    tintColour = vec3((tint>>16)&255u,(tint>>8)&255u,tint&255u)/255.0;
    return true;
}

bool plagueVoxelBoundaryMapping(int entry, vec3 local, vec3 normal, vec3 boxLo, vec3 boxHi,
        uint mappingMask, out vec2 atlasUV, out vec3 tintColour, out vec3 tangent, out vec3 bitangent) {
    atlasUV=vec2(0); tintColour=vec3(1); tangent=vec3(0); bitangent=vec3(0);
    if (any(isnan(local)) || any(isinf(local)) || any(isnan(normal)) || any(isinf(normal))) return false;
    vec3 axes=abs(normal);
    if (dot(axes,vec3(1)) != 1.0 || max(axes.x,max(axes.y,axes.z)) != 1.0) return false;
    int face=normal.y!=0.0 ? (normal.y>0.0?1:0) : normal.z!=0.0 ? (normal.z>0.0?3:2) : (normal.x>0.0?5:4);
    vec2 st=normal.x!=0.0 ? local.yz : normal.y!=0.0 ? local.xz : local.xy;
    vec2 lo=normal.x!=0.0 ? boxLo.yz : normal.y!=0.0 ? boxLo.xz : boxLo.xy;
    vec2 hi=normal.x!=0.0 ? boxHi.yz : normal.y!=0.0 ? boxHi.xz : boxHi.xy;
    vec3 axisS=normal.x!=0.0 ? vec3(0,1,0) : vec3(1,0,0);
    vec3 axisT=normal.z!=0.0 ? vec3(0,1,0) : vec3(0,0,1);
    return plagueVoxelQuadMapping(entry,face,st,lo,hi,axisS,axisT,mappingMask,
            atlasUV,tintColour,tangent,bitangent);
}

bool plagueVoxelFaceMapping(int entry, vec3 local, vec3 normal, out vec2 atlasUV,
        out vec3 tintColour, out vec3 tangent, out vec3 bitangent) {
    return plagueVoxelBoundaryMapping(entry,local,normal,vec3(0),vec3(1),1u,
            atlasUV,tintColour,tangent,bitangent);
}

bool plagueVoxelCrossMapping(int entry, vec3 local, vec3 normal, vec3 boxLo, vec3 boxHi,
        out vec2 atlasUV, out vec3 tintColour, out vec3 tangent, out vec3 bitangent) {
    atlasUV=vec2(0); tintColour=vec3(1); tangent=vec3(0); bitangent=vec3(0);
    if (any(isnan(local)) || any(isinf(local)) || any(isnan(normal)) || any(isinf(normal)) || normal.y!=0.0
            || normal.x==0.0 || normal.z==0.0) return false;
    // CROSS records use physical normal quadrants and affine (local.x,local.y) coordinates.
    int face=(normal.x>0.0?1:0)+(normal.z>0.0?2:0);
    return plagueVoxelQuadMapping(entry,face,local.xy,boxLo.xy,boxHi.xy,
            vec3(1,0,-normal.x/normal.z),vec3(0,1,0),1u,
            atlasUV,tintColour,tangent,bitangent);
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
