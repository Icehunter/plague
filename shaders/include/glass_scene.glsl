#moj_import <fornax_runtime:voxel_palette_layout.glsl>
#ifndef PLAGUE_GLASS_SCENE
#define PLAGUE_GLASS_SCENE
#moj_import <fornax_runtime:glass_optics.glsl>
#moj_import <fornax_runtime:color.glsl>

// Accessors let raster texture buffers and compute storage buffers share one optical traversal.
uint plagueGlassOccupancyWord(int word);
uint plagueGlassPayloadWord(int word);
uint plagueGlassPaletteWord(int word);
uint plagueGlassSummaryWord(int word);
uint plagueGlassFaceWord(int word);
vec4 plagueGlassAlbedo(vec2 uv);
vec4 plagueGlassMaterial(vec2 uv);
bool plagueGlassBuffersValid();
int plagueGlassPaletteCapacity();

struct PlagueGlassMedium { bool glass; float ior; vec3 absorption; float roughness; };
struct PlagueGlassHit {
    vec3 position;
    vec3 normal;
    vec3 local;
    int entry;
    float distance;
    bool glass;
};
#ifdef PLAGUE_GLASS_RECORD_PATH
int plagueGlassFace(vec3 n);
void plagueGlassBox(int entry,int box,out vec3 lo,out vec3 hi);
// Trace-only endpoint metadata lets reconstruction reject blockers at neighbouring receivers.
vec4 plagueGlassLastPlane;
vec3 plagueGlassLastLo,plagueGlassLastHi;
float plagueGlassPathDistance;
bool plagueGlassLastIsSource;
void plagueGlassRecordBoundary(PlagueGlassHit hit,vec3 direction) {
    vec3 normal=dot(hit.normal,direction)>0.0 ? hit.normal : -hit.normal;
    plagueGlassLastPlane=vec4(normal,dot(normal,hit.position));
    vec3 cellOrigin=hit.position-hit.local;
    plagueGlassLastLo=vec3(1e30); plagueGlassLastHi=vec3(-1e30);
    int count=int(plagueGlassPaletteWord(hit.entry*16)&15u);
    for(int box=0;box<max(count,1);++box) {
        vec3 lo,hi; plagueGlassBox(hit.entry,box,lo,hi);
        plagueGlassLastLo=min(plagueGlassLastLo,cellOrigin+lo);
        plagueGlassLastHi=max(plagueGlassLastHi,cellOrigin+hi);
    }
    plagueGlassLastIsSource=false;
}
#endif
int plagueGlassMod(int a, int b) { return a >= 0 ? a % b : b - 1 - ((-1 - a) % b); }
int plagueGlassFace(vec3 n) {
    return n.y != 0.0 ? (n.y > 0.0 ? 1 : 0) : n.z != 0.0 ? (n.z > 0.0 ? 3 : 2) : (n.x > 0.0 ? 5 : 4);
}
vec3 plagueGlassFaceNormal(int face) {
    vec3 n = vec3(0.0);
    n[face < 2 ? 1 : face < 4 ? 2 : 0] = (face & 1) == 0 ? -1.0 : 1.0;
    return n;
}
#ifndef PLAGUE_GLASS_SCENE_ORIGIN
#define PLAGUE_GLASS_SCENE_ORIGIN u_CameraAbs
#endif
vec3 plagueGlassGridOrigin() { return PLAGUE_GLASS_SCENE_ORIGIN - vec3((u_VoxelWindow.xyz - ivec3((u_VoxelWindow.w-1)/2))*16); }

// Returns -1 for empty and -2 for unknown. Unknown cells never certify an unoccluded ray.
int plagueGlassCell(ivec3 cell) {
    int d = u_VoxelWindow.w;
    if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(d*16)))) return -2;
    ivec3 section = (cell >> 4) + u_VoxelWindow.xyz - ivec3((d-1)/2);
    int slot = (plagueGlassMod(section.y,d)*d + plagueGlassMod(section.z,d))*d + plagueGlassMod(section.x,d);
    uint summary = plagueGlassSummaryWord(slot);
    if ((summary & 0x80000000u) != 0u) return -2;
    if ((summary & 1u) == 0u) return -1;
    ivec3 local = cell & 15;
    int index = (local.y << 8) | (local.z << 4) | local.x;
    if ((plagueGlassOccupancyWord(slot*128+(index>>5)) & (1u << uint(index&31))) == 0u) return -1;
    int entry = int((plagueGlassPayloadWord(slot*1024+(index>>2)) >> uint((index&3)*8)) & 255u);
    return entry < plagueGlassPaletteCapacity() ? slot*plagueGlassPaletteCapacity() + entry : -2;
}
void plagueGlassBox(int entry, int box, out vec3 lo, out vec3 hi) {
    int count = int(plagueGlassPaletteWord(entry*16) & 15u);
    uint packed = count == 0 ? 0u : plagueGlassPaletteWord(entry*16+7+box);
    lo = count == 0 ? vec3(0.0) : vec3(packed&31u,(packed>>5)&31u,(packed>>10)&31u)/16.0;
    hi = count == 0 ? vec3(1.0) : vec3((packed>>15)&31u,(packed>>20)&31u,(packed>>25)&31u)/16.0;
}
bool plagueGlassContains(int entry, vec3 local) {
    int count = int(plagueGlassPaletteWord(entry*16) & 15u);
    if (count > 8) return false;
    for (int box=0; box<max(count,1); ++box) {
        vec3 lo,hi; plagueGlassBox(entry,box,lo,hi);
        if (all(greaterThanEqual(local,lo)) && all(lessThan(local,hi))) return true;
    }
    return false;
}
bool plagueGlassUv(int entry, vec3 local, vec3 normal, out vec2 uv, out vec3 tint) {
    int base = entry*42+plagueGlassFace(normal)*7;
    uint header = plagueGlassFaceWord(base);
    uv=vec2(0.0); tint=vec3(1.0);
    // bit24 is the existing solid/cutout mapping, bit29 the independent translucent mapping.
    if ((header & 0x21000000u)==0u) return false;
    vec2 origin=uintBitsToFloat(uvec2(plagueGlassFaceWord(base+1),plagueGlassFaceWord(base+2)));
    vec2 ds=uintBitsToFloat(uvec2(plagueGlassFaceWord(base+3),plagueGlassFaceWord(base+4)));
    vec2 dt=uintBitsToFloat(uvec2(plagueGlassFaceWord(base+5),plagueGlassFaceWord(base+6)));
    vec2 st=normal.x!=0.0 ? local.yz : normal.y!=0.0 ? local.xz : local.xy;
    uv=origin+ds*st.x+dt*st.y;
    tint=plagueSrgbToLinear(vec3((header>>16)&255u,(header>>8)&255u,header&255u)/255.0);
    return !any(isnan(uv)) && !any(isinf(uv)) && all(greaterThanEqual(uv,vec2(0.0))) && all(lessThanEqual(uv,vec2(1.0)));
}
bool plagueGlassMaterialSample(int entry,int face,out vec2 uv,out float area) {
    int base=entry*42+face*7;
    uint header=plagueGlassFaceWord(base);
    uv=vec2(0.0); area=0.0;
    // Fornax sample-only ABI: bit25 without either affine-valid bit. It carries one actual
    // rectangle's material centre and area, never a spatial map or closed-boundary proof.
    if((header&0x23000000u)!=0x02000000u) return false;
    uv=uintBitsToFloat(uvec2(plagueGlassFaceWord(base+1),plagueGlassFaceWord(base+2)));
    area=uintBitsToFloat(plagueGlassFaceWord(base+3));
    if(plagueGlassFaceWord(base+4)!=0u || plagueGlassFaceWord(base+5)!=0u || plagueGlassFaceWord(base+6)!=0u) return false;
    return !any(isnan(uv)) && !any(isinf(uv)) && all(greaterThanEqual(uv,vec2(0.0)))
        && all(lessThanEqual(uv,vec2(1.0))) && !isnan(area) && !isinf(area) && area>0.0 && area<=1.0;
}
PlagueGlassMedium plagueGlassMedium(int entry) {
    PlagueGlassMedium medium;
    medium.glass=false; medium.ior=1.0; medium.absorption=vec3(0.0); medium.roughness=0.0;
    if (entry<0) return medium;
    uint flags=plagueGlassPaletteWord(entry*16);
    uint header=plagueGlassFaceWord(entry*42);
    // Engine bit30 certifies a closed union of the actual model boxes. Open foliage is not a volume.
    if ((header&0x40000000u)==0u || (flags&0x80000000u)!=0u) return medium;
    int blendedFaces=0;
    bool mappedPartial=false;
    vec3 colour=vec3(0.0); float weight=0.0;
    float faceArea[6], faceCoverage[6];
    float dominantArea=0.0, materialArea=0.0;
    vec4 spec=vec4(0.0,0.0,0.0,1.0);
    int count=int(flags&15u);
    if(count>8) return medium;
    for (int face=0;face<6;++face) {
        uint faceHeader=plagueGlassFaceWord(entry*42+face*7);
        // A model with an opaque backing is not a homogeneous transmitting volume.
        if((faceHeader&0x04000000u)!=0u) return medium;
        if((faceHeader&0x80000000u)!=0u) ++blendedFaces;
        mappedPartial=mappedPartial || (count!=0 && (faceHeader&0x20000000u)!=0u);
        vec2 materialUv; float sampleArea;
        if(plagueGlassMaterialSample(entry,face,materialUv,sampleArea)) {
            mappedPartial=mappedPartial || count!=0;
            // Connected panes can use edge and broad sprites in the same direction. Their
            // largest emitted rectangle supplies material evidence without inventing UV coverage.
            if(sampleArea>materialArea) { materialArea=sampleArea; spec=plagueGlassMaterial(materialUv); }
        }
        uint packed=plagueGlassPaletteWord(entry*16+1+face);
        float a=float(packed>>24)/255.0;
        colour+=plagueSrgbToLinear(vec3((packed>>16)&255u,(packed>>8)&255u,packed&255u)/255.0)*a;
        weight+=a;
        faceCoverage[face]=a; faceArea[face]=0.0;
        vec3 normal=plagueGlassFaceNormal(face);
        int axis=face<2 ? 1 : face<4 ? 2 : 0;
        for(int box=0;box<max(count,1);++box) {
            vec3 lo,hi; plagueGlassBox(entry,box,lo,hi);
            vec3 extent=hi-lo;
            float area=axis==0 ? extent.y*extent.z : axis==1 ? extent.x*extent.z : extent.x*extent.y;
            vec3 samplePoint=(lo+hi)*0.5;
            samplePoint[axis]=(face&1)==0 ? lo[axis] : hi[axis];
            // Midpoint exposure approximates partially overlapped box faces. This only chooses
            // material evidence; it never certifies or changes the traced boundary geometry.
            if(plagueGlassContains(entry,samplePoint+normal*PLAGUE_GLASS_EPSILON)) continue;
            faceArea[face]+=area;
            vec2 uv; vec3 tint;
            // Repeated edge maps may fail while a broad face still has a valid mapping.
            // Sample the largest mapped box face at its own centre, not the empty cell centre.
            if(area>materialArea && plagueGlassUv(entry,samplePoint,normal,uv,tint)) {
                materialArea=area; spec=plagueGlassMaterial(uv);
            }
        }
        dominantArea=max(dominantArea,faceArea[face]);
    }
    // A closed translucent boundary alone says nothing about its dielectric material. Missing
    // mappings and representative samples must not turn the unauthored default into evidence for
    // replacing raster geometry. One representative sample cannot model mixed optical volumes.
    if(materialArea<=0.0) return medium;
    float coverage=0.0, coverageArea=0.0;
    // Greatest projected area selects a pane's broad faces without a thickness cutoff. Tiny
    // opaque caps cannot outweigh its transparent surface. Areas lie on the exact 1/256-square-
    // block model grid, so equal-area directions compare exactly.
    for(int face=0;face<6;++face) if(faceArea[face]==dominantArea) {
        coverage+=faceCoverage[face]*faceArea[face]; coverageArea+=faceArea[face];
    }
    coverage=coverageArea>0.0 ? coverage/coverageArea : 1.0;
    // A cutout closed shell requires material evidence, or a sparse border in an unauthored map.
    // One-quarter coverage is the area of a one-texel frame in an 16x16 sprite, rounded upward.
    // This fallback cannot disambiguate arbitrary texture art; labPBR smoothness takes precedence.
    // Vanilla's light-transmission fact only covers full cubes. Certified partial model boxes
    // may opt in through their sampled material, without inventing a block-identity exception.
    bool clearShell=((flags&0x1000u)!=0u || mappedPartial) && (flags&0x40000000u)!=0u
        && spec.b<=64.0/255.0 && ((spec.r>=0.75 && spec.g>0.0) || (spec.r==0.0 && spec.g==0.0 && coverage<=0.25));
    // labPBR's conductor range has no bulk dielectric transmission.
    bool blended=blendedFaces==6;
    if ((blendedFaces>0 && !blended) || (!blended && !clearShell) || spec.g>=230.0/255.0) return medium;
    medium.glass=true;
    medium.ior=plagueGlassIor(spec.g);
    medium.roughness=(1.0-spec.r)*(1.0-spec.r);
    if (spec.r==0.0 && spec.g==0.0) medium.roughness=0.0; // Unauthored closed glass uses a smooth interface.
    // Clear cutout texels describe a frame, not an absorbing interior. Blended material carries tint.
    medium.absorption=plagueGlassAbsorption(blended && weight>0.0 ? colour/weight : vec3(1.0));
    return medium;
}
PlagueGlassMedium plagueGlassAt(vec3 point) {
    vec3 p=plagueGlassGridOrigin()+point;
    int entry=plagueGlassCell(ivec3(floor(p)));
    PlagueGlassMedium medium=plagueGlassMedium(entry);
    if (entry>=0 && !plagueGlassContains(entry,fract(p))) medium.glass=false;
    if (!medium.glass) { medium.ior=1.0; medium.absorption=vec3(0.0); medium.roughness=0.0; }
    return medium;
}

bool plagueGlassInterval(vec3 origin,vec3 direction,vec3 lo,vec3 hi,
        out float enter,out float leave,out vec3 enterNormal,out vec3 leaveNormal) {
    enter=-1e30; leave=1e30; // Unbounded ray-axis sentinels, as in voxel_coverage.glsl.
    enterNormal=vec3(0.0); leaveNormal=vec3(0.0);
    for(int axis=0;axis<3;++axis) {
        if(direction[axis]==0.0) { if(origin[axis]<lo[axis] || origin[axis]>=hi[axis]) return false; }
        else {
            float a=(lo[axis]-origin[axis])/direction[axis], b=(hi[axis]-origin[axis])/direction[axis];
            // The limiting ray slab supplies its normal. Nearest spatial faces can choose a
            // parallel face at an edge, which changes the optical interface entirely.
            if(min(a,b)>enter) {
                enter=min(a,b); enterNormal=vec3(0.0); enterNormal[axis]=-sign(direction[axis]);
            }
            if(max(a,b)<leave) {
                leave=max(a,b); leaveNormal=vec3(0.0); leaveNormal[axis]=sign(direction[axis]);
            }
        }
    }
    return leave>enter;
}
vec3 plagueGlassBoundaryOffset(vec3 position,vec3 direction,vec3 normal) {
    // Twice the shared intersection tolerance separates consecutive interfaces. Enforce that
    // distance along the normal: a direction-only offset rounds onto the same face at grazing.
    float distance=PLAGUE_GLASS_EPSILON*2.0;
    vec3 offset=direction*distance;
    float side=dot(direction,normal)>0.0 ? 1.0 : -1.0;
    return position+offset+normal*(side*distance-dot(offset,normal));
}

bool plagueGlassEmptySection(ivec3 cell) {
    int d=u_VoxelWindow.w;
    ivec3 section=(cell>>4)+u_VoxelWindow.xyz-ivec3((d-1)/2);
    int slot=(plagueGlassMod(section.y,d)*d+plagueGlassMod(section.z,d))*d+plagueGlassMod(section.x,d);
    return (plagueGlassSummaryWord(slot)&0x80000001u)==0u;
}
float plagueGlassSkipSection(inout ivec3 cell,ivec3 step,vec3 delta,inout vec3 next) {
    ivec3 steps=ivec3(0); vec3 boundary=vec3(1e30);
    for(int axis=0;axis<3;++axis) if(step[axis]!=0) {
        steps[axis]=step[axis]>0 ? 16-(cell[axis]&15) : (cell[axis]&15)+1;
        boundary[axis]=next[axis];
        // Match voxel_coverage's incremental DDA arithmetic; multiplying can change a boundary tie.
        for(int crossing=1;crossing<steps[axis];++crossing) boundary[axis]+=delta[axis];
    }
    float distance=min(boundary.x,min(boundary.y,boundary.z));
    for(int axis=0;axis<3;++axis) if(step[axis]!=0) {
        if(boundary[axis]<=distance) {
            cell[axis]+=step[axis]*steps[axis]; next[axis]=boundary[axis]+delta[axis];
        } else {
            for(int crossing=0;crossing<steps[axis] && next[axis]<=distance;++crossing) {
                cell[axis]+=step[axis]; next[axis]+=delta[axis];
            }
        }
    }
    return distance;
}

int plagueGlassCross(vec3 localOrigin,vec3 direction,int entry,float start,float reach,
        out float nearest,out vec3 normal) {
    nearest=reach; normal=vec3(0.0);
    // CROSS stores its bounds in box word zero and sprite rectangle in words 13/14.
    uint packed=plagueGlassPaletteWord(entry*16+7);
    vec3 lo=vec3(packed&31u,(packed>>5)&31u,(packed>>10)&31u)/16.0;
    vec3 hi=vec3((packed>>15)&31u,(packed>>20)&31u,(packed>>25)&31u)/16.0;
    vec3 size=hi-lo;
    uint a=plagueGlassPaletteWord(entry*16+13),b=plagueGlassPaletteWord(entry*16+14);
    vec2 uvLo=vec2(a>>16,a&65535u)/65535.0,uvHi=vec2(b>>16,b&65535u)/65535.0;
    if(any(lessThanEqual(size,vec3(0.0))) || any(lessThanEqual(uvHi,uvLo))) return -1;
    vec3 q=(localOrigin-lo)/size,v=direction/size;
    for(int plane=0;plane<2;++plane) {
        vec3 gradient=plane==0 ? vec3(1.0,0.0,-1.0) : vec3(1.0,0.0,1.0);
        float denominator=dot(gradient,v);
        if(denominator==0.0) continue;
        float candidate=(float(plane)-dot(gradient,q))/denominator;
        if(candidate<PLAGUE_GLASS_EPSILON || candidate+PLAGUE_GLASS_EPSILON<start || candidate>=nearest) continue;
        vec3 point=q+candidate*v;
        if(any(lessThan(point,vec3(0.0))) || any(greaterThan(point,vec3(1.0)))) continue;
        vec2 uv=mix(uvLo,uvHi,vec2(point.x,1.0-point.y));
        if(plagueGlassAlbedo(uv).a<0.5) continue;
        nearest=candidate; normal=normalize(gradient/size);
        if(dot(normal,direction)>0.0) normal=-normal;
    }
    return nearest<reach ? 1 : 0;
}

// 1 boundary, 0 clear to requested endpoint, -1 unknown/budget exhausted. Never promotes unknown to sky.
int plagueGlassTrace(vec3 origin,vec3 direction,float reach,bool glassOnly,out PlagueGlassHit hit) {
    hit.position=origin; hit.normal=vec3(0.0); hit.entry=-1; hit.distance=0.0; hit.local=vec3(0.0); hit.glass=false;
    if (!plagueGlassBuffersValid()) return -1;
    vec3 gridOrigin=plagueGlassGridOrigin()+origin;
    float t=PLAGUE_GLASS_EPSILON;
    ivec3 cell=ivec3(floor(gridOrigin+direction*t)), step=ivec3(sign(direction));
    vec3 delta=vec3(1e30),next=vec3(1e30);
    for(int axis=0;axis<3;++axis) if(step[axis]!=0) {
        delta[axis]=abs(1.0/direction[axis]);
        next[axis]=(float(cell[axis]+max(step[axis],0))-gridOrigin[axis])/direction[axis];
    }
    for(int walk=0;walk<PLAGUE_GLASS_STEPS && t<reach;++walk) {
        int entry=plagueGlassCell(cell);
        if(entry==-2) return -1;
        if(entry==-1 && plagueGlassEmptySection(cell)) {
            t=plagueGlassSkipSection(cell,step,delta,next);
            continue;
        }
        float crossing=min(next.x,min(next.y,next.z));
        if(entry>=0) {
            PlagueGlassMedium medium=plagueGlassMedium(entry);
            uint flags=plagueGlassPaletteWord(entry*16);
            int count=int(flags&15u);
            if(count>8) return -1;
            if((flags&0x80000000u)!=0u) {
                if(!glassOnly) {
                    float nearest; vec3 normal;
                    int crossHit=plagueGlassCross(gridOrigin-vec3(cell),direction,entry,t,reach,nearest,normal);
                    if(crossHit<0) return -1;
                    if(crossHit==1 && nearest<=crossing+PLAGUE_GLASS_EPSILON) {
                        hit.position=origin+direction*nearest; hit.normal=normal; hit.distance=nearest;
                        hit.entry=entry; hit.local=gridOrigin+direction*nearest-vec3(cell); hit.glass=false;
                        return 1;
                    }
                }
            } else if(!glassOnly || medium.glass) {
                float nearest=reach; vec3 normal=vec3(0.0);
                // Exact ray-interval sidedness survives grazing rays whose spatial epsilon
                // probes round to the same point. Shared box endpoints suppress internal faces.
                float enters[8],leaves[8];
                vec3 enterNormals[8],leaveNormals[8];
                bool intersects[8];
                for(int box=0;box<max(count,1);++box) {
                    vec3 lo,hi; plagueGlassBox(entry,box,lo,hi);
                    intersects[box]=plagueGlassInterval(gridOrigin-vec3(cell),direction,lo,hi,
                        enters[box],leaves[box],enterNormals[box],leaveNormals[box]);
                }
                for(int box=0;box<max(count,1);++box) {
                    if(!intersects[box]) continue;
                    for(int side=0;side<2;++side) {
                        float candidate=side==0?enters[box]:leaves[box];
                        if(candidate<PLAGUE_GLASS_EPSILON || candidate+PLAGUE_GLASS_EPSILON<t || candidate>=nearest) continue;
                        bool before=false,after=false;
                        for(int other=0;other<max(count,1);++other) if(intersects[other]) {
                            before=before || (enters[other]<candidate && leaves[other]>=candidate);
                            after=after || (enters[other]<=candidate && leaves[other]>candidate);
                        }
                        if(before==after) continue; // Overlapping box faces are not medium boundaries.
                        vec3 local=gridOrigin+direction*candidate-vec3(cell);
                        vec3 n=side==0?enterNormals[box]:leaveNormals[box];
                        if(!medium.glass && (flags&0xc0000000u)!=0u) {
                            vec2 uv; vec3 tint;
                            if(plagueGlassUv(entry,local,n,uv,tint) && plagueGlassAlbedo(uv).a<0.5) continue;
                        }
                        nearest=candidate; normal=n;
                    }
                }
                if(nearest<reach && nearest<=crossing+PLAGUE_GLASS_EPSILON) {
                    hit.position=origin+direction*nearest; hit.normal=normal; hit.distance=nearest;
                    hit.entry=entry; hit.local=gridOrigin+direction*nearest-vec3(cell); hit.glass=medium.glass;
                    return 1;
                }
            }
        }
        for(int axis=0;axis<3;++axis) if(next[axis]<=crossing) { cell[axis]+=step[axis]; next[axis]+=delta[axis]; }
        t=crossing;
    }
    return t>=reach ? 0 : -1;
}
bool plagueGlassSegmentIntersects(vec3 origin,vec3 direction,float reach) {
    PlagueGlassHit hit;
    return plagueGlassTrace(origin,direction,reach,true,hit)==1;
}

// Branch -1 retains stochastic Fresnel transport; 0/1 force the first reflection/transmission.
// The first branch weight is returned separately: multiplying it again along the path loses energy.
// Both forced calls must start from the same state to share the first GGX normal and original draw.
// Status 2 is a valid zero-energy sample. Unknown geometry or exhausted work remains -1.
int plagueGlassTransportFirstBranch(inout vec3 origin,inout vec3 direction,inout vec3 throughput,float reach,
        bool photon,inout uint randomState,out PlagueGlassHit receiver,out bool crossed,out float firstDistance,
        int firstBranch,out float firstWeight,out bool firstSelected,out bool splitApplied) {
#ifdef PLAGUE_GLASS_RECORD_PATH
    plagueGlassLastPlane=plagueGlassEmissionPlane;
    plagueGlassPathDistance=0.0;
    plagueGlassLastLo=plagueGlassEmissionLo; plagueGlassLastHi=plagueGlassEmissionHi;
    plagueGlassLastIsSource=dot(plagueGlassEmissionPlane.xyz,plagueGlassEmissionPlane.xyz)>0.0;
#endif
    crossed=false; firstDistance=-1.0;
    firstWeight=1.0; firstSelected=true; splitApplied=false;
    float remaining=reach;
    PlagueGlassMedium current=plagueGlassAt(origin);
    for(int event=0;event<PLAGUE_GLASS_INTERFACES;++event) {
        int status=plagueGlassTrace(origin,direction,remaining,false,receiver);
        if(status!=1) return status;
        throughput*=plagueGlassAttenuation(current.absorption,receiver.distance);
        remaining-=receiver.distance;
#ifdef PLAGUE_GLASS_RECORD_PATH
        plagueGlassPathDistance=reach-remaining;
#endif
        if(max(throughput.x,max(throughput.y,throughput.z))<=0.0) return 2;
        if(!receiver.glass) return 1;
        if(!crossed) firstDistance=reach-remaining;
        crossed=true;
        vec3 afterPoint=plagueGlassBoundaryOffset(receiver.position,direction,receiver.normal);
        // Unknown space cannot establish the other medium, even when Fresnel would reflect
        // the sample back into known space before another traversal could expose that absence.
        if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+afterPoint)))==-2) return -1;
        PlagueGlassMedium nextMedium=plagueGlassAt(afterPoint);
        // A touching receiver shares the glass exit plane. Offsetting into it would skip its
        // near face and deposit the photon on its far face, leaking through a whole solid block.
        if(current.glass && !nextMedium.glass) {
            vec3 contactGrid=plagueGlassGridOrigin()+receiver.position;
            vec3 afterGrid=plagueGlassGridOrigin()+afterPoint;
            ivec3 contactCell=ivec3(floor(afterGrid));
            int contactEntry=plagueGlassCell(contactCell);
            vec3 contactLocal=contactGrid-vec3(contactCell);
            if(contactEntry>=0 && plagueGlassContains(contactEntry,fract(afterGrid))) {
                vec3 contactNormal=dot(direction,receiver.normal)<0.0 ? receiver.normal : -receiver.normal;
                uint contactFlags=plagueGlassPaletteWord(contactEntry*16);
                vec2 contactUv; vec3 contactTint;
                bool contactOpaque=(contactFlags&0x80000000u)==0u && ((contactFlags&0xc0000000u)==0u
                    || !plagueGlassUv(contactEntry,contactLocal,contactNormal,contactUv,contactTint)
                    || plagueGlassAlbedo(contactUv).a>=0.5); // Same rendered cutout coverage threshold.
                if(contactOpaque) {
                    receiver.entry=contactEntry; receiver.local=contactLocal;
                    receiver.normal=contactNormal; receiver.glass=false;
                    return 1;
                }
            }
        }
        // Connected equal-index media have no Fresnel surface, even if their absorption differs.
        if(current.ior==nextMedium.ior) {
#ifdef PLAGUE_GLASS_RECORD_PATH
            // A model seam inside an identical medium is not an optical interface. Retaining
            // it would split the same path family according to which block seam a ray crossed.
            if(current.glass!=nextMedium.glass || current.roughness!=nextMedium.roughness
                    || any(notEqual(current.absorption,nextMedium.absorption)))
                plagueGlassRecordBoundary(receiver,direction);
#endif
            origin=afterPoint;
            current=nextMedium;
            continue;
        }
        vec3 n=dot(direction,receiver.normal)<0.0 ? receiver.normal : -receiver.normal;
        // The rougher material defines a shared dielectric boundary; air contributes no roughness.
        float alpha=max(current.glass ? current.roughness : 0.0,nextMedium.glass ? nextMedium.roughness : 0.0);
        vec3 microfacet=plagueGlassVisibleNormal(direction,n,alpha,randomState);
        vec3 incident=direction;
        vec3 transmitted; float fresnel;
        bool canTransmit=plagueGlassInterface(incident,microfacet,current.ior,nextMedium.ior,transmitted,fresnel);
        bool reflectPath=!canTransmit || (photon && plagueGlassRandom(randomState)<fresnel);
        if(photon && firstBranch>=0 && !splitApplied) {
            splitApplied=true;
            firstSelected=(firstBranch==0)==reflectPath;
            firstWeight=firstBranch==0 ? fresnel : 1.0-fresnel;
            reflectPath=firstBranch==0;
            // A zero-probability branch, including TIR transmission, has known zero energy.
            if(firstWeight<=0.0) { throughput=vec3(0.0); return 2; }
        }
        if(reflectPath) direction=reflect(incident,microfacet);
        else {
            direction=transmitted;
            if(!photon) throughput*=1.0-fresnel;
            current=nextMedium;
        }
        // Walter et al. (2007), Microfacet Models for Refraction through Rough Surfaces:
        // reject samples that cross the wrong geometric hemisphere. Resampling would add energy.
        float outgoingSide=dot(direction,n);
        if((reflectPath && outgoingSide<=0.0) || (!reflectPath && outgoingSide>=0.0)) {
            throughput=vec3(0.0);
            return 2;
        }
        throughput*=plagueGlassMaskWeight(incident,direction,n,alpha);
        if(max(throughput.x,max(throughput.y,throughput.z))<=0.0) return 2;
#ifdef PLAGUE_GLASS_RECORD_PATH
        plagueGlassRecordBoundary(receiver,direction);
#endif
        origin=plagueGlassBoundaryOffset(receiver.position,direction,receiver.normal);
        if(remaining<=PLAGUE_GLASS_EPSILON) return -1;
    }
    return -1;
}

// Photon transport keeps one Fresnel-selected branch at every boundary.
int plagueGlassTransport(inout vec3 origin,inout vec3 direction,inout vec3 throughput,float reach,
        bool photon,inout uint randomState,out PlagueGlassHit receiver,out bool crossed,out float firstDistance) {
    float firstWeight; bool firstSelected,splitApplied;
    return plagueGlassTransportFirstBranch(origin,direction,throughput,reach,photon,randomState,
            receiver,crossed,firstDistance,-1,firstWeight,firstSelected,splitApplied);
}
#endif
