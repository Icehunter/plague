#ifndef PLAGUE_VOXEL_VISIBILITY
#define PLAGUE_VOXEL_VISIBILITY

// Uses voxel_coverage's buffer bindings, interval and DDA helpers. Visibility needs opacity,
// not reflected colour: crossed plants have no cardinal face colours but still block light.
bool plagueVisibilitySprite(int base, out vec2 lo, out vec2 hi) {
    uint a=texelFetch(u_Input5,base+13).r, b=texelFetch(u_Input5,base+14).r;
    lo=vec2(a>>16,a&65535u)/65535.0;
    hi=vec2(b>>16,b&65535u)/65535.0;
    return all(greaterThan(hi,lo));
}

bool plagueVisibilityAlpha(vec2 uv,vec2 lo,vec2 hi) {
    vec2 inset=min(0.5/vec2(textureSize(u_Input9,0)),(hi-lo)*0.5);
    // Same half-alpha cutoff and texel-centre clamp as the rendered cutout traversal.
    return textureLod(u_Input9,clamp(uv,lo+inset,hi-inset),0.0).a>=0.5;
}

// 0 = transparent, 1 = opaque, 2 = missing evidence. Mapping and rendered backing are
// independent flags; a multi-quad grass cube may have opaque backing without a usable UV map.
int plagueVisibilityCubeFace(int base,vec3 point,vec3 normal) {
    int face=normal.y!=0.0 ? (normal.y>0.0?1:0)
            : normal.z!=0.0 ? (normal.z>0.0?3:2) : (normal.x>0.0?5:4);
    int mapping=(base/16)*42+face*7;
    uint header=texelFetch(u_Input10,mapping).r;
    if((header&0x04000000u)!=0u) return 1;
    if((header&0x01000000u)!=0u) {
        vec2 origin=uintBitsToFloat(uvec2(texelFetch(u_Input10,mapping+1).r,texelFetch(u_Input10,mapping+2).r));
        vec2 ds=uintBitsToFloat(uvec2(texelFetch(u_Input10,mapping+3).r,texelFetch(u_Input10,mapping+4).r));
        vec2 dt=uintBitsToFloat(uvec2(texelFetch(u_Input10,mapping+5).r,texelFetch(u_Input10,mapping+6).r));
        vec2 lo=min(min(origin,origin+ds),min(origin+dt,origin+ds+dt));
        vec2 hi=max(max(origin,origin+ds),max(origin+dt,origin+ds+dt));
        if(!any(isnan(origin)) && !any(isinf(origin))
                && !any(isnan(ds)) && !any(isinf(ds)) && !any(isnan(dt)) && !any(isinf(dt))
                && all(greaterThanEqual(lo,vec2(0.0))) && all(lessThanEqual(hi,vec2(1.0)))
                && all(greaterThan(hi,lo)) && ds.x*dt.y-ds.y*dt.x!=0.0) {
            vec2 st=normal.x!=0.0 ? point.yz : normal.y!=0.0 ? point.xz : point.xy;
            return plagueVisibilityAlpha(origin+ds*st.x+dt*st.y,lo,hi) ? 1 : 0;
        }
    }
    vec2 lo,hi;
    if(!plagueVisibilitySprite(base,lo,hi)) return 2;
    return plagueVisibilityAlpha(mix(lo,hi,plagueVoxelCubeUV(point,normal)),lo,hi) ? 1 : 0;
}

int plagueVisibilityCutout(vec3 origin,vec3 dir,ivec3 cell,int base,uint flags,
        float current,float end) {
    vec3 localOrigin=origin-vec3(cell);
    if((flags&0x80000000u)!=0u) {
        vec2 loUV,hiUV;
        if(!plagueVisibilitySprite(base,loUV,hiUV)) return 2;
        uint packed=texelFetch(u_Input5,base+7).r;
        vec3 lo=vec3(packed&31u,(packed>>5)&31u,(packed>>10)&31u)/16.0;
        vec3 hi=vec3((packed>>15)&31u,(packed>>20)&31u,(packed>>25)&31u)/16.0;
        vec3 size=hi-lo;
        if(any(lessThanEqual(size,vec3(0.0)))) return 2;
        vec3 q=(localOrigin-lo)/size, v=dir/size;
        for(int plane=0;plane<2;plane++) {
            // The harvested CROSS ABI stores two diagonal planes in its 1/16-block box.
            vec3 gradient=plane==0 ? vec3(1.0,0.0,-1.0) : vec3(1.0,0.0,1.0);
            float denominator=dot(gradient,v);
            if(denominator==0.0) continue;
            float candidate=(float(plane)-dot(gradient,q))/denominator;
            if(candidate<current || candidate>=end) continue;
            vec3 point=q+candidate*v;
            if(any(lessThan(point,vec3(0.0))) || any(greaterThan(point,vec3(1.0)))) continue;
            if(plagueVisibilityAlpha(mix(loUV,hiUV,vec2(point.x,1.0-point.y)),loUV,hiUV)) return 1;
        }
        return 0;
    }
    float a,b;
    if(!plagueCoverageInterval(localOrigin,dir,vec3(0.0),vec3(1.0),a,b)) return 0;
    for(int side=0;side<2;side++) {
        float candidate=side==0 ? a : b;
        if(candidate+PLAGUE_COVERAGE_EPSILON<current || candidate>=end) continue;
        vec3 point=localOrigin+dir*candidate;
        vec3 normal=plagueVoxelHitNormal(point,vec3(0.0),vec3(1.0),side==0 ? dir : -dir);
        float coordinate=dot(point,abs(normal));
        if(abs(coordinate-max(dot(normal,vec3(1.0)),0.0))>PLAGUE_COVERAGE_EPSILON) continue;
        int opacity=plagueVisibilityCubeFace(base,point,normal);
        if(opacity!=0) return opacity;
    }
    return 0;
}

bool plagueVoxelSegmentVisible(vec3 originRel,vec3 dir,float maxDistance,int maxSteps) {
    int d=u_VoxelWindow.w;
    if(d<1 || d>33 || maxSteps<=0 || maxDistance<=0.0 || isnan(maxDistance) || isinf(maxDistance)
            || any(isnan(originRel)) || any(isinf(originRel)) || any(isnan(dir)) || any(isinf(dir))) return false;
    int slots=d*d*d;
    if(textureSize(u_Input3)!=slots*128 || textureSize(u_Input4)!=slots*1024
            || textureSize(u_Input5)!=slots*1536 || textureSize(u_Input6)!=slots
            || textureSize(u_Input10)!=slots*96*42) return false;
    ivec3 first=u_VoxelWindow.xyz-ivec3((d-1)/2);
    vec3 origin=(u_CameraAbs-vec3(first*16))+originRel;
    vec3 end=origin+dir*maxDistance;
    // Both endpoints inside a convex grid prove the whole segment stays inside it. Reaching a
    // grid boundary or exhausting the work budget cannot certify an unobserved part of the ray.
    if(any(lessThan(origin,vec3(0.0))) || any(greaterThanEqual(origin,vec3(d*16)))
            || any(lessThan(end,vec3(0.0))) || any(greaterThanEqual(end,vec3(d*16)))) return false;
    float t=PLAGUE_COVERAGE_EPSILON;
    ivec3 cell=ivec3(floor(origin+dir*t)), stepDir=ivec3(sign(dir));
    vec3 delta=vec3(1e30), next=vec3(1e30); // Same unbounded-axis sentinel as the shared DDA.
    for(int axis=0;axis<3;axis++) if(stepDir[axis]!=0) {
        delta[axis]=abs(1.0/dir[axis]);
        next[axis]=(float(cell[axis]+max(stepDir[axis],0))-origin[axis])/dir[axis];
    }
    ivec3 cachedSection=ivec3(-1);
    int slot=0, occupancyAddress=-1;
    uint summary=0u, occupancyWord=0u;
    for(int step=0;step<maxSteps && t<maxDistance;step++) {
        if(any(lessThan(cell,ivec3(0))) || any(greaterThanEqual(cell,ivec3(d*16)))) return false;
        ivec3 localSection=cell>>4;
        if(any(notEqual(localSection,cachedSection))) {
            cachedSection=localSection;
            ivec3 section=localSection+first;
            slot=(plagueCoverageMod(section.y,d)*d+plagueCoverageMod(section.z,d))*d
                    +plagueCoverageMod(section.x,d);
            summary=texelFetch(u_Input6,slot).r;
        }
        if((summary&0x80000000u)!=0u) return false;
        if((summary&1u)==0u) {
            t=plagueVoxelSkipEmptySection(cell,stepDir,delta,next);
            continue;
        }
        ivec3 local=cell&15;
        int index=(local.y<<8)|(local.z<<4)|local.x;
        int address=slot*128+(index>>5);
        if(address!=occupancyAddress) {
            occupancyAddress=address;
            occupancyWord=texelFetch(u_Input3,address).r;
        }
        if((occupancyWord&(1u<<uint(index&31)))!=0u) {
            uint payload=texelFetch(u_Input4,slot*1024+(index>>2)).r;
            int entry=int((payload>>uint((index&3)*8))&255u);
            if(entry>=96) return false;
            int base=slot*1536+entry*16;
            uint flags=texelFetch(u_Input5,base).r;
            if((flags&0xc0000000u)!=0u) {
                if(plagueVisibilityCutout(origin,dir,cell,base,flags,t,maxDistance)!=0) return false;
            } else {
                int boxes=int(flags&15u);
                if(boxes==0 || boxes>8) return false;
                for(int box=0;box<boxes;box++) {
                    uint packed=texelFetch(u_Input5,base+7+box).r;
                    vec3 lo=vec3(packed&31u,(packed>>5)&31u,(packed>>10)&31u)/16.0;
                    vec3 hi=vec3((packed>>15)&31u,(packed>>20)&31u,(packed>>25)&31u)/16.0;
                    float a,b;
                    if(plagueCoverageInterval(origin,dir,vec3(cell)+lo,vec3(cell)+hi,a,b)
                            && b>max(a,t) && a<maxDistance) return false;
                }
            }
        }
        float crossing=min(next.x,min(next.y,next.z));
        for(int axis=0;axis<3;axis++) if(next[axis]<=crossing) {
            cell[axis]+=stepDir[axis]; next[axis]+=delta[axis];
        }
        t=crossing;
    }
    return t>=maxDistance;
}

#endif
