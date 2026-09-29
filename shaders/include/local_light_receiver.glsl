#moj_import <fornax_runtime:voxel_palette_layout.glsl>
#ifndef PLAGUE_LOCAL_LIGHT_RECEIVER
#define PLAGUE_LOCAL_LIGHT_RECEIVER
#moj_import <fornax_runtime:voxel_local_layout.glsl>

// Raster and compute must classify the same rendered sheet. Missing geometry never certifies it.
bool plagueLocalReceiverBuffersValid();
bool plagueLocalReceiverFacesValid();
int plagueLocalReceiverCapacity();
uint plagueLocalReceiverOccupancy(int word);
uint plagueLocalReceiverPayload(int word);
uint plagueLocalReceiverPalette(int word);
uint plagueLocalReceiverSummary(int word);
uint plagueLocalReceiverFace(int word);

vec3 plagueLocalSurfacePoint(vec3 point,vec3 geometricNormal) {
    vec3 start=point;
    // Depth roundoff can cross a model plane. Recover nearby 1/16-block planes before the
    // outward bias; crossed foliage must keep its own plane.
    vec3 p=fract(u_CameraAbs)+point;
    for(int axis=0;axis<3;axis++) if(abs(geometricNormal[axis])==1.0) {
        float plane=round(p[axis]*16.0)/16.0;
        if(abs(plane-p[axis])<=PLAGUE_LOCAL_PLANE_TOLERANCE) start[axis]+=plane-p[axis];
    }
    return start;
}
// A subsurface material alone cannot certify a thin sheet. CROSS supplies two rendered planes;
// a cube face needs a cutout mapping with no opaque backing.
bool plagueLocalThinReceiver(vec3 point,vec3 geometricNormal) {
    int d=u_VoxelWindow.w;
    if(d<1 || d>33 || !plagueLocalReceiverBuffersValid()) return false;
    ivec3 cameraCell=ivec3(floor(u_CameraAbs));
    vec3 relative=fract(u_CameraAbs)+point;
    for(int axis=0;axis<3;axis++) if(abs(geometricNormal[axis])==1.0) {
        float plane=round(relative[axis]*16.0)/16.0;
        if(abs(plane-relative[axis])<=PLAGUE_LOCAL_PLANE_TOLERANCE) relative[axis]=plane;
    }
    ivec3 cell=cameraCell+ivec3(floor(relative-geometricNormal*PLAGUE_LOCAL_NUDGE));
    ivec3 section=cell>>4;
    ivec3 first=u_VoxelWindow.xyz-ivec3((d-1)/2);
    if(any(lessThan(section,first)) || any(greaterThanEqual(section,first+ivec3(d)))) return false;
    int slot=(plagueLocalSectionMod(section.y,d)*d+plagueLocalSectionMod(section.z,d))*d+plagueLocalSectionMod(section.x,d);
    uint summary=plagueLocalReceiverSummary(slot);
    if((summary&0x80000001u)!=1u) return false;
    ivec3 local=cell&15;
    int idx=(local.y<<8)|(local.z<<4)|local.x;
    if((plagueLocalReceiverOccupancy(slot*128+(idx>>5))&(1u<<uint(idx&31)))==0u) return false;
    int entry=int((plagueLocalReceiverPayload(slot*1024+(idx>>2))>>uint((idx&3)*8))&255u);
    if(entry>=plagueLocalReceiverCapacity()) return false;
    entry+=slot*plagueLocalReceiverCapacity();
    uint flags=plagueLocalReceiverPalette(entry*16);
    if((flags&0x80000000u)!=0u) return true;
    if((flags&0x40000000u)==0u
            || max(abs(geometricNormal.x),max(abs(geometricNormal.y),abs(geometricNormal.z)))!=1.0) return false;
    int face=geometricNormal.y!=0.0 ? (geometricNormal.y>0.0?1:0)
            : geometricNormal.z!=0.0 ? (geometricNormal.z>0.0?3:2) : (geometricNormal.x>0.0?5:4);
    if(!plagueLocalReceiverFacesValid()) return false;
    uint header=plagueLocalReceiverFace(entry*42+face*7);
    return (header&0x07000000u)==0x03000000u;
}
#endif
