#ifndef PLAGUE_VOXEL_LOCAL_APERTURE
#define PLAGUE_VOXEL_LOCAL_APERTURE
// Full-cube neighbours bound the emitter's visible area. Partial/cutout/missing shapes cannot
// certify these strips, so they retain ordinary finite-segment quadrature.
bool plagueApertureFullCube(ivec3 cell) {
    int d=u_VoxelWindow.w;
    ivec3 section=cell>>4,first=u_VoxelWindow.xyz-ivec3((d-1)/2);
    if(any(lessThan(section,first)) || any(greaterThanEqual(section,first+ivec3(d))))return false;
    int slot=(plagueCoverageMod(section.y,d)*d+plagueCoverageMod(section.z,d))*d+plagueCoverageMod(section.x,d);
    if((texelFetch(u_Input6,slot).r&0x80000001u)!=1u)return false;
    ivec3 local=cell&15;int idx=(local.y<<8)|(local.z<<4)|local.x;
    if((texelFetch(u_Input3,slot*128+(idx>>5)).r&(1u<<uint(idx&31)))==0u)return false;
    int entry=int((texelFetch(u_Input4,slot*1024+(idx>>2)).r>>uint((idx&3)*8))&255u);
    if(entry>=96)return false;
    int base=slot*1536+entry*16;
    uint flags=texelFetch(u_Input5,base).r;
    // Only one ordinary full box certifies the strip; cutouts and multi-box shapes fall back.
    if((flags&0xc000000fu)!=1u)return false;
    // Coverage boxes use 1/16 coordinates; this one must cover the entire unit cube.
    return (texelFetch(u_Input5,base+7).r&0x3fffffffu)==((16u<<15)|(16u<<20)|(16u<<25));
}
vec4 plagueApertureRect(ivec3 cell,vec3 sourceOrigin,int face,vec3 point,vec3 geometricNormal) {
    vec4 rect=vec4(0.,0.,1.,1.);
    int d=u_VoxelWindow.w,slots=d*d*d;
    if(textureSize(u_Input3)!=slots*128 || textureSize(u_Input4)!=slots*1024
            || textureSize(u_Input5)!=slots*1536 || textureSize(u_Input6)!=slots)return rect;
    int nAxis=face<2?1:face<4?2:0;
    int sAxis=face<4?0:1, tAxis=face<2?2:face<4?1:2;
    vec3 n=plagueLocalNormal(face);
    vec3 receiver=plagueLocalSegmentStart(point,geometricNormal);
    vec3 r=receiver-(sourceOrigin+n*PLAGUE_LOCAL_NUDGE);
    float distance=(r[nAxis]-float(face&1))*n[nAxis];
    // Project the forward cell from the same biased endpoints as the visibility segment.
    // Its slab depth is one unit cell minus the emitter normal nudge.
    float slabDepth=1.-PLAGUE_LOCAL_NUDGE;
    if(distance<=slabDepth)return rect;
    // Ordered comparisons above admit NaN; retain its existing query/arithmetic path.
    bool keepFullCubeQuery=isnan(distance)||isinf(distance);
    ivec3 forward=cell+ivec3(n);
    for(int tangent=0;tangent<2;tangent++) {
        int axis=tangent==0?sAxis:tAxis,other=tangent==0?tAxis:sAxis;
        // Entire source-to-receiver segment lies within the occluder's other-axis slab.
        // Other receiver orientations can cross the slab on one flat face; restricting its normal
        // avoids a seam when unsupported polygonal silhouettes fall back to coarse quadrature.
        if(abs(geometricNormal[other])!=1. || r[other]<0. || r[other]>1.)continue;
        // At the slab exit q=(1-h/d)*s+(h/d)*r. Solve q>=0 or q<=1 for source s;
        // h is the biased slab depth and d is the biased source-to-receiver normal distance.
        ivec3 step=ivec3(0);step[axis]=1;
        // With distance>slabDepth, a side strip reaches the source square only when the
        // receiver lies beyond that source edge. Otherwise its max/min leaves rect unchanged.
        if((keepFullCubeQuery || !(r[axis]>=0.0)) && plagueApertureFullCube(forward-step))
            rect[tangent]=max(rect[tangent],-slabDepth*r[axis]/(distance-slabDepth));
        if((keepFullCubeQuery || !(r[axis]<=1.0)) && plagueApertureFullCube(forward+step))
            rect[tangent+2]=min(rect[tangent+2],(distance-slabDepth*r[axis])/(distance-slabDepth));
    }
    return clamp(rect,0.,1.);
}

#endif
