#ifndef PLAGUE_VOXEL_LOCAL_LIGHT
#define PLAGUE_VOXEL_LOCAL_LIGHT
#ifndef PLAGUE_LOCAL_EMITTER_SIZE
#define PLAGUE_LOCAL_EMITTER_SIZE 0 //[0 1 2] compile "Local Light Source Size" {0="Quarter block" 1="Half block" 2="Full face"}
#endif
// Side of the centred square each quarter is cut from, as a fraction of the face. Full face (2)
// is 1.0, the whole face.
#if PLAGUE_LOCAL_EMITTER_SIZE==0
const float PLAGUE_LOCAL_EMITTER_SPAN=0.25;
#elif PLAGUE_LOCAL_EMITTER_SIZE==1
const float PLAGUE_LOCAL_EMITTER_SPAN=0.5;
#else
const float PLAGUE_LOCAL_EMITTER_SPAN=1.0;
#endif
#moj_import <fornax_runtime:voxel_local_layout.glsl>
#moj_import <fornax_runtime:voxel_visibility.glsl>
#ifdef PLAGUE_VOXEL_ENTITY_OCCLUDERS
#moj_import <fornax_runtime:entity_occluders.glsl>
#endif
// Caller supplies source word/size accessors, the 2D dither (taken in uniform control flow) and
// voxel_coverage traversal. Primary and reflected surfaces use the same finite segment query;
// there is no screen or receiver-quadrant cache.
vec3 plagueLocalSegmentStart(vec3 point,vec3 geometricNormal) {
    vec3 start=point;
    // Depth roundoff can lie on either side of an axis plane. Recover nearby 1/16-block model
    // planes before the outward bias, without snapping crossed foliage onto cube boundaries.
    vec3 p=fract(u_CameraAbs)+point;
    for(int axis=0;axis<3;axis++) if(abs(geometricNormal[axis])==1.0) {
        float plane=round(p[axis]*16.0)/16.0;
        if(abs(plane-p[axis])<=PLAGUE_LOCAL_PLANE_TOLERANCE) start[axis]+=plane-p[axis];
    }
    start+=geometricNormal*PLAGUE_LOCAL_NUDGE;
    return start;
}
bool plagueLocalSegment(vec3 point,vec3 geometricNormal,vec3 emitter,vec3 emitterNormal) {
    vec3 start=plagueLocalSegmentStart(point,geometricNormal);
    vec3 end=emitter+emitterNormal*PLAGUE_LOCAL_NUDGE;
    vec3 segment=end-start;
    float distance=length(segment);
    if(distance<=PLAGUE_LOCAL_NUDGE) return false;
    // Clear-to-grid-boundary is not visibility to an endpoint outside the grid. A 12-block ray
    // crosses at most 3*12+3 planes; 48 permits empty-section skips and boundary roundoff.
    int d=u_VoxelWindow.w;
    vec3 endGrid=(u_CameraAbs-vec3((u_VoxelWindow.xyz-ivec3((d-1)/2))*16))+end;
    if(any(lessThan(endGrid,vec3(0.0))) || any(greaterThanEqual(endGrid,vec3(d*16)))) return false;
    // Source-side alcove blockers can reject a sample before its ray crosses the open room.
    if(!plagueVoxelSegmentVisible(end,-segment/distance,distance,48)) return false;
#ifdef PLAGUE_VOXEL_ENTITY_OCCLUDERS
    // point and emitter are camera-relative, the same origin the occluder buffer uses, so the
    // segment needs no shift into grid space the way the voxel march above does.
    if(plagueEntityOccluded(end,-segment/distance,distance)) return false;
#endif
    return true;
}
#moj_import <fornax_runtime:voxel_local_aperture.glsl>

// Transmission belongs to rendered thin cutouts, never to a grass cube merely carrying a
// subsurface material. Missing geometry cannot certify a sheet. CROSS is the two-plane ABI;
// a cube face additionally needs an actual cutout mapping with no opaque rendered backing.
bool plagueLocalThinReceiver(vec3 point,vec3 geometricNormal) {
    int d=u_VoxelWindow.w;
    if(d<1 || d>33 || textureSize(u_Input3)!=d*d*d*128 || textureSize(u_Input4)!=d*d*d*1024
            || textureSize(u_Input5)!=d*d*d*1536 || textureSize(u_Input6)!=d*d*d) return false;
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
    int slot=(plagueCoverageMod(section.y,d)*d+plagueCoverageMod(section.z,d))*d+plagueCoverageMod(section.x,d);
    uint summary=texelFetch(u_Input6,slot).r;
    if((summary&0x80000001u)!=1u) return false;
    ivec3 local=cell&15;
    int idx=(local.y<<8)|(local.z<<4)|local.x;
    if((texelFetch(u_Input3,slot*128+(idx>>5)).r&(1u<<uint(idx&31)))==0u) return false;
    int entry=int((texelFetch(u_Input4,slot*1024+(idx>>2)).r>>uint((idx&3)*8))&255u);
    if(entry>=96) return false;
    entry+=slot*96;
    uint flags=texelFetch(u_Input5,entry*16).r;
    if((flags&0x80000000u)!=0u) return true;
    if((flags&0x40000000u)==0u || max(abs(geometricNormal.x),max(abs(geometricNormal.y),abs(geometricNormal.z)))!=1.0
            || plagueVoxelOpaqueFace(entry,geometricNormal)) return false;
    int face=geometricNormal.y!=0.0 ? (geometricNormal.y>0.0?1:0)
            : geometricNormal.z!=0.0 ? (geometricNormal.z>0.0?3:2) : (geometricNormal.x>0.0?5:4);
    return textureSize(u_Input10)==d*d*d*96*42
            && (texelFetch(u_Input10,entry*42+face*7).r&0x03000000u)==0x03000000u;
}
// Three answers from one walk of the emitters, because only one of them is noisy.
//
// `radiance` is what this pixel actually receives, shadows and all, for a caller with nowhere to
// put the pieces. `unshadowed` is the same sum with every emitter treated as visible: smooth,
// deterministic, and carrying the pixel's own texture, normal and relief. `visibility` is the
// fraction of the offered light that got through, weighted by how much each sample was worth.
//
// Multiplied back together they give `radiance` again. Kept apart, a screen-space filter can clean
// the sampling noise out of `visibility` alone, which is the only place it lives, and leave the
// texture untouched. Filtering the product instead blurs the block.
bool plagueLocalLight(vec3 point,vec3 geometricNormal,vec3 normal,vec3 viewDir,
        PlagueMaterial material,vec3 albedo,vec2 jitterUV,out vec3 radiance,out vec3 unshadowed,
        out float visibility) {
    radiance=vec3(0.0);
    unshadowed=vec3(0.0);
    // Nothing offered reads as fully lit: a pixel no emitter reaches is not a shadowed pixel, and
    // zero here would paint it black once the two are multiplied.
    visibility=1.0;
    float offered=0.0;
    float reached=0.0;
    int d=u_VoxelWindow.w;
    if(d<1 || d>33 || plagueLocalSourceSize()!=PLAGUE_LOCAL_SOURCE_WORDS
            || plagueLocalSourceWord(0)!=2u || plagueLocalSourceWord(1)!=uint(PLAGUE_LOCAL_CAPACITY)
            || plagueLocalSourceWord(2)>uint(PLAGUE_LOCAL_CAPACITY)) return false;
    if(any(isnan(point)) || any(isinf(point)) || any(isnan(normal)) || any(isinf(normal))) return false;
    // Authored thin-sheet model: at maximum subsurface response half the diffuse energy goes
    // to each hemisphere. This splits diffuse energy; it adds no extra emitter power and gives
    // solid backing no transmission. It is a local sheet approximation, not a volume BSSRDF.
    float transmission=material.subsurface>0.0 && material.metalness<1.0
            && plagueLocalThinReceiver(point,geometricNormal) ? 0.5*material.subsurface : 0.0;
    ivec3 cameraCell=ivec3(floor(u_CameraAbs));
    vec3 fractional=fract(u_CameraAbs);
    ivec3 receiverCell=cameraCell+ivec3(floor(fractional+point));
    ivec3 receiverSection=receiverCell>>4;
    ivec3 first=u_VoxelWindow.xyz-ivec3((d-1)/2);
    uint total=plagueLocalSourceWord(2);
    if(total==0u) return true;
    // Scan a small inventory directly instead of paying 27 toroidal range lookups per pixel.
    // The switch equals the number of neighbouring sections; both arms test the same domain.
    bool sparse=total<=27u;
    for(int range=0;range<(sparse?1:27);range++) {
        ivec3 section=receiverSection+ivec3(range%3-1,range/9-1,(range/3)%3-1);
        uint begin=0u,count=total;
        if(!sparse) {
            if(any(lessThan(section,first)) || any(greaterThanEqual(section,first+ivec3(d)))) continue;
            int slot=(plagueCoverageMod(section.y,d)*d+plagueCoverageMod(section.z,d))*d
                    +plagueCoverageMod(section.x,d);
            begin=plagueLocalSourceWord(16+slot*2); count=plagueLocalSourceWord(17+slot*2);
            if(begin>total || count>total-begin) continue;
        }
        for(uint index=begin;index<begin+count;index++) {
            int base=PLAGUE_LOCAL_RECORDS+int(index)*PLAGUE_LOCAL_RECORD_WORDS;
            if(plagueLocalSourceWord(base+6)!=1u) continue;
            ivec3 cell=ivec3(plagueLocalSourceWord(base),plagueLocalSourceWord(base+1),plagueLocalSourceWord(base+2));
            ivec3 owner=cell>>4;
            if(sparse) {
                if(any(lessThan(owner,first)) || any(greaterThanEqual(owner,first+ivec3(d)))
                        || any(greaterThan(abs(owner-receiverSection),ivec3(1)))) continue;
            } else if(any(notEqual(owner,section))) continue;
            vec3 sourceOrigin=vec3(cell-cameraCell)-fractional;
            vec3 separation=max(max(sourceOrigin-point,point-sourceOrigin-1.0),vec3(0.0));
            if(dot(separation,separation)>=PLAGUE_LOCAL_REACH*PLAGUE_LOCAL_REACH) continue;
            uint faces=plagueLocalSourceWord(base+7)&63u;
            // How much of its cell this block fills. A glowstone fills it; a torch is a small box
            // inside it. Everything below works in cell coordinates, so the box only narrows the
            // range each face covers.
            vec3 boxLo,boxHi;
            plagueLocalUnpackBox(plagueLocalSourceWord(base+PLAGUE_LOCAL_RECORD_BOX),boxLo,boxHi);
            for(int face=0;face<6;face++) {
                if((faces&(1u<<face))==0u) continue;
                vec3 sourceNormal=plagueLocalNormal(face);
                int faceAxis=face<2 ? 1 : face<4 ? 2 : 0;
                float facePlane=(face&1)==0 ? boxLo[faceAxis] : boxHi[faceAxis];
                vec2 tangentLo=face<2 ? vec2(boxLo.x,boxLo.z)
                        : face<4 ? vec2(boxLo.x,boxLo.y) : vec2(boxLo.y,boxLo.z);
                vec2 tangentHi=face<2 ? vec2(boxHi.x,boxHi.z)
                        : face<4 ? vec2(boxHi.x,boxHi.y) : vec2(boxHi.y,boxHi.z);
                vec2 faceSpan=tangentHi-tangentLo;
                // How big this face really is, in square blocks. A face with no area gives no
                // light, and dividing the clipped area by it has no answer.
                float faceArea=faceSpan.x*faceSpan.y;
                if(!(faceArea>0.0)) continue;
                // A planar emitter's facing sign is identical for every point on that plane.
                // Reject it once, before fetching its four radiance/visibility samples.
                vec2 faceMiddle=tangentLo+faceSpan*0.5;
                vec3 centre=sourceOrigin+(face<2 ? vec3(faceMiddle.x,facePlane,faceMiddle.y)
                        : face<4 ? vec3(faceMiddle,facePlane) : vec3(facePlane,faceMiddle));
                if(dot(sourceNormal,point-centre)<=0.0) continue;
                // Support bound of the face projected on the receiver normal. This only removes a
                // face whose entire area lies behind an opaque receiver hemisphere.
                // Half the face's own width on each axis, zero on the axis it faces along.
                vec3 halfSpan=0.5*(face<2 ? vec3(faceSpan.x,0.0,faceSpan.y)
                        : face<4 ? vec3(faceSpan.x,faceSpan.y,0.0)
                        : vec3(0.0,faceSpan.x,faceSpan.y));
                float extent=dot(abs(geometricNormal),halfSpan);
                if(transmission==0.0 && dot(geometricNormal,centre-point)+extent<=0.0) continue;
                // A certified side wall clips source area continuously instead of switching whole quarter
                // samples. Thin transmission keeps both receiver hemispheres on the ordinary path.
                vec4 aperture=transmission==0.0
                        ? plagueApertureRect(cell,sourceOrigin,face,point,geometricNormal) : vec4(0.0,0.0,1.0,1.0);
                for(int quarter=0;quarter<4;quarter++) {
                    // Authored look choice: light comes from a centred square of side SPAN
                    // (1, 0.5 or 0.25 for Full face, Half block, Quarter block), not the whole
                    // face, so a thin blocker can fully shadow it. The square is cut into its
                    // four quarters first and only then clipped by the aperture, so a certified
                    // side wall still clips smoothly instead of switching a whole quarter on or
                    // off. SPAN 1 is the untouched face.
                    vec2 quarterLo=(1.0-PLAGUE_LOCAL_EMITTER_SPAN)*0.5
                            +vec2(quarter&1,quarter>>1)*(0.5*PLAGUE_LOCAL_EMITTER_SPAN);
                    vec2 areaLo=max(quarterLo,aperture.xy),areaHi=min(quarterLo+0.5*PLAGUE_LOCAL_EMITTER_SPAN,aperture.zw);
                    if(any(lessThanEqual(areaHi,areaLo))) continue;
                    // The square's area is SPAN*SPAN, so dividing by it keeps the total light the
                    // same at every SPAN: four unclipped quarters always sum to 1.0.
                    // As a fraction of the face, so four unclipped quarters always sum to one at
                    // any span and any box. The face's real area multiplies back in below.
                    float clippedArea=(areaHi.x-areaLo.x)*(areaHi.y-areaLo.y)
                            /(faceArea*PLAGUE_LOCAL_EMITTER_SPAN*PLAGUE_LOCAL_EMITTER_SPAN);
                    // TWO points on the same clipped quarter, and which one is used where is the
                    // whole reason the split works.
                    //
                    // The middle is where the light is measured from: distance, both cosines and
                    // the BRDF all read it, and all of them are then the same for neighbouring
                    // pixels. Measuring from the jittered point instead puts the dither into the
                    // brightness as well as the shadow, and no filter over one of them can reach it.
                    //
                    // The jittered point is where the ray is sent, and nowhere else. Neighbouring
                    // pixels asking about different parts of the quarter is what a soft edge is
                    // made of, and it lands in the visibility fraction alone, which is filtered.
                    float areaPlane=facePlane;
                    vec2 centreST=mix(areaLo,areaHi,vec2(0.5));
                    // Each face and quarter looks at a DIFFERENT part of its own square. One
                    // offset shared by all of them moves every sample together, so the twenty-four
                    // agree with each other and their average is exactly as noisy as one of them.
                    // Walking the offset by slot spreads them instead, and twenty-four samples that
                    // disagree average down by nearly five.
                    //
                    // R2 again, for the same reason as anywhere else: each step lands in the
                    // largest gap the earlier ones left, so a handful of slots already covers the
                    // square evenly rather than clumping. Roberts, "The Unreasonable Effectiveness
                    // of Quasirandom Sequences", 2018.
                    vec2 probeST=mix(areaLo,areaHi,fract(jitterUV
                            +float(face*4+quarter)*vec2(0.7548776662466927,0.5698402909980532)));
                    vec3 emitter=sourceOrigin+(face<2 ? vec3(centreST.x,areaPlane,centreST.y)
                            : face<4 ? vec3(centreST,areaPlane) : vec3(areaPlane,centreST));
                    vec3 probe=sourceOrigin+(face<2 ? vec3(probeST.x,areaPlane,probeST.y)
                            : face<4 ? vec3(probeST,areaPlane) : vec3(areaPlane,probeST));
                    vec3 delta=emitter-point;
                    float r2=dot(delta,delta);
                    if(r2<=PLAGUE_LOCAL_NUDGE*PLAGUE_LOCAL_NUDGE || r2>=PLAGUE_LOCAL_REACH*PLAGUE_LOCAL_REACH) continue;
                    float r=sqrt(r2); vec3 direction=delta/r;
                    float sourceCosine=max(dot(sourceNormal,-direction),0.0);
                    float geometricCosine=dot(geometricNormal,direction);
                    if(sourceCosine<=0.0 || (geometricCosine<=0.0 && transmission==0.0)) continue;
                    int sampleBase=base+8+face*16+quarter*4;
                    vec3 le=uintBitsToFloat(uvec3(plagueLocalSourceWord(sampleBase),
                            plagueLocalSourceWord(sampleBase+1),plagueLocalSourceWord(sampleBase+2)));
                    if(any(isnan(le)) || any(isinf(le)) || !any(greaterThan(le,vec3(0.0)))) continue;
                    // Exact zero of the front BRDF, before anything more expensive.
                    if(geometricCosine>0.0 && dot(normal,direction)<=0.0) continue;
                    vec3 response;
                    if(geometricCosine>0.0) {
                        PlagueBrdf brdf=plagueEvaluateBrdf(material,albedo,normal,viewDir,direction);
                        response=brdf.diffuse*albedo*(1.0-transmission)+brdf.specular;
                    } else {
                        // Lambertian transmitted radiance: projected incident area / pi. Fresnel
                        // reflection and metallic absorption remove energy before transmission.
                        response=albedo*(1.0-plagueMaterialF0(material,albedo))*(1.0-material.metalness)
                                *(transmission*max(-geometricCosine,0.0)/PLAGUE_PI);
                    }
                    if(!any(greaterThan(response,vec3(0.0)))) continue;
                    // Quarter radiance stays piecewise constant over its surviving area. Source cosine /
                    // distance squared converts that area; BRDF terms already include receiver cosine.
                    // Times the face's real area: a torch's face is a fraction of a block and
                    // sends a fraction of the light a glowstone's does, at the same brightness.
                    vec3 offer=response*le
                            *(clippedArea*faceArea*sourceCosine*plagueLocalFalloff(r)/r2);
                    // What this sample is worth, so the visibility fraction averages by contribution.
                    // Counting samples instead would let a dim far emitter outvote a bright near one.
                    float share=dot(offer,vec3(0.2126,0.7152,0.0722));
                    unshadowed+=offer;
                    offered+=share;
                    // The march is the expensive part, so it stays last and only runs for a sample
                    // that would contribute. The BRDF above runs for blocked samples as well, which
                    // is arithmetic against a walk through the grid.
                    if(plagueLocalSegment(point,geometricCosine>0.0?geometricNormal:-geometricNormal,probe,sourceNormal)) {
                        radiance+=offer;
                        reached+=share;
                    }
                }
            }
        }
    }
    if(offered>0.0) visibility=clamp(reached/offered,0.0,1.0);
    return !any(isnan(radiance)) && !any(isinf(radiance))
            && !any(isnan(unshadowed)) && !any(isinf(unshadowed));
}
#endif
