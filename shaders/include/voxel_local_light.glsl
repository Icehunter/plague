#ifndef PLAGUE_VOXEL_LOCAL_LIGHT
#define PLAGUE_VOXEL_LOCAL_LIGHT
// How many shadow rays one pixel may spend on local lights.
//
// Every sample still offers its light. The budget only decides which of them get asked whether
// something stands in the way, and the answer from those carries the rest. It bites on a surface
// made of emitters, where the samples nearly all give the same answer anyway.
//
// A sample earns a ray by being worth at least its share of the budget, so a near lamp keeps its
// own shadow in a scene whose sample count is dominated by something dim and wide. The ceiling
// bounds the work when the shares keep climbing instead of levelling off.
//
// Thirty-two because one glowstone offers twenty-four probes, six faces of four, and spends
// every ray it asks for.
const int PLAGUE_LOCAL_RAY_BUDGET = 32;
// How much of the sky a face has to cover before it is worth cutting into four.
//
// Four probes buy a softer shadow edge only while the face still has an edge worth shaping. Past
// that they are four rays for one answer. A sixteenth of a steradian is a whole block face seen
// head on from four blocks, which is about where a block's own penumbra stops being wider than a
// pixel.
const float PLAGUE_LOCAL_SPLIT_SOLID_ANGLE = 0.0625;
const int PLAGUE_LOCAL_RAY_CEILING = 48;
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
// The light a flat rectangle of uniform brightness delivers to one point, as a vector.
//
// Its length is how much arrives and its direction is where from, so dotting it with a surface
// normal gives that surface's share exactly: no sampling, no pieces, right at any size and any
// distance. Points spread over a rectangle cannot do that. A floor lying on a bright sheet reads
// a small fraction of the light it should, and cutting the rectangle finer closes the gap far too
// slowly to rescue.
//
// The sum runs over the rectangle's edges: each edge contributes the angle it subtends, pointing
// along the normal of the wedge it and the point make. Lambert, "Photometria", 1760; the vector
// form is Arvo, "The Irradiance Jacobian for Partially Occluded Polyhedral Sources", SIGGRAPH 1994.
vec3 plagueLocalRectFlux(vec3 c0,vec3 c1,vec3 c2,vec3 c3,vec3 point) {
    vec3 v0=normalize(c0-point),v1=normalize(c1-point);
    vec3 v2=normalize(c2-point),v3=normalize(c3-point);
    vec3 flux=vec3(0.0);
    vec3 e=cross(v0,v1); float len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v0,v1),-1.0,1.0))*(e/len);
    e=cross(v1,v2); len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v1,v2),-1.0,1.0))*(e/len);
    e=cross(v2,v3); len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v2,v3),-1.0,1.0))*(e/len);
    e=cross(v3,v0); len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v3,v0),-1.0,1.0))*(e/len);
    return 0.5*flux;
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
    // Every sample's worth, which is what sets the bar a sample has to clear to earn a ray.
    float worth=0.0;
    // The worth of the samples a ray was actually spent on, and how much of it got through.
    float offered=0.0;
    float reached=0.0;
    int rays=0;
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
            uint run=plagueLocalSourceWord(base+PLAGUE_LOCAL_RECORD_RUN);
            int face=plagueLocalRunFace(run);
            vec2 runSpan=plagueLocalRunSpan(run);
            int faceAxis=face<2 ? 1 : face<4 ? 2 : 0;
            int axisU=face<4 ? 0 : 1;
            int axisV=face<2 ? 2 : face<4 ? 1 : 2;
            // How many cells the run covers on each axis. One on the axis it faces along.
            vec3 runExtent=vec3(1.0);
            runExtent[axisU]=runSpan.x;
            runExtent[axisV]=runSpan.y;
            vec3 sourceOrigin=vec3(cell-cameraCell)-fractional;
            vec3 separation=max(max(sourceOrigin-point,point-sourceOrigin-runExtent),vec3(0.0));
            if(dot(separation,separation)>=PLAGUE_LOCAL_REACH*PLAGUE_LOCAL_REACH) continue;
            // How much of one cell the emitting block fills. A glowstone fills it; a torch is a
            // small box inside it, and a run wider than one cell is only ever made of blocks that
            // fill theirs. The span carries the rest of the reach past that first cell.
            vec3 boxLo,boxHi;
            plagueLocalUnpackBox(plagueLocalSourceWord(base+PLAGUE_LOCAL_RECORD_BOX),boxLo,boxHi);
            vec3 sourceNormal=plagueLocalNormal(face);
            float facePlane=(face&1)==0 ? boxLo[faceAxis] : boxHi[faceAxis];
            vec2 rectLo=vec2(boxLo[axisU],boxLo[axisV]);
            vec2 rectHi=vec2(boxHi[axisU],boxHi[axisV])+runSpan-vec2(1.0);
            vec2 faceSpan=rectHi-rectLo;
            // How big the run really is, in square blocks. A rectangle with no area gives no
            // light, and dividing the clipped area by it has no answer.
            float faceArea=faceSpan.x*faceSpan.y;
            if(!(faceArea>0.0)) continue;
            // A planar emitter's facing sign is identical for every point on that plane.
            // Reject it once, before fetching any radiance.
            vec2 faceMiddle=rectLo+faceSpan*0.5;
            vec3 centre=sourceOrigin+(face<2 ? vec3(faceMiddle.x,facePlane,faceMiddle.y)
                    : face<4 ? vec3(faceMiddle,facePlane) : vec3(facePlane,faceMiddle));
            if(dot(sourceNormal,point-centre)<=0.0) continue;
            // Support bound of the rectangle projected on the receiver normal. This only removes a
            // run whose entire area lies behind an opaque receiver hemisphere.
            vec3 halfSpan=0.5*(face<2 ? vec3(faceSpan.x,0.0,faceSpan.y)
                    : face<4 ? vec3(faceSpan.x,faceSpan.y,0.0)
                    : vec3(0.0,faceSpan.x,faceSpan.y));
            float extent=dot(abs(geometricNormal),halfSpan);
            if(transmission==0.0 && dot(geometricNormal,centre-point)+extent<=0.0) continue;
            // How much of the sky the rectangle covers: its area times how squarely it faces this
            // pixel, over the distance squared. The shading is exact whatever this says; what it
            // decides is how many shadow probes the rectangle earns.
            vec3 toCentre=centre-point;
            float centre2=max(dot(toCentre,toCentre),1e-8);
            float faceSolidAngle=faceArea*max(dot(sourceNormal,-toCentre*inversesqrt(centre2)),0.0)
                    /centre2;
            bool split=faceSolidAngle>PLAGUE_LOCAL_SPLIT_SOLID_ANGLE;
            // Where the rectangle's four corners are, in the frame everything here works in.
            vec3 uVec=vec3(0.0); uVec[axisU]=1.0;
            vec3 vVec=vec3(0.0); vVec[axisV]=1.0;
            vec3 planeOrigin=sourceOrigin+sourceNormal*0.0;
            planeOrigin[faceAxis]+=facePlane;
            planeOrigin+=uVec*rectLo.x+vVec*rectLo.y;
            vec3 corner1=planeOrigin+uVec*faceSpan.x;
            vec3 corner2=corner1+vVec*faceSpan.y;
            vec3 corner3=planeOrigin+vVec*faceSpan.y;
            vec3 flux=plagueLocalRectFlux(planeOrigin,corner1,corner2,corner3,point);
            // Which way round the corners were listed decides the sign. The receiver is on the
            // face's front, so the light arrives from roughly against the face's own normal.
            if(dot(flux,sourceNormal)>0.0) flux=-flux;
            float front=max(dot(flux,normal),0.0);
            float back=transmission>0.0 ? max(dot(flux,-normal),0.0) : 0.0;
            if(front<=0.0 && back<=0.0) continue;

            // The whole rectangle in one colour, the four quarters averaged. A run is one block
            // kind, so its quarters are the same texture repeated and their average is its light.
            int colourBase=base+8+PLAGUE_LOCAL_RECORD_FACE_COLOUR;
            vec3 le=uintBitsToFloat(uvec3(plagueLocalSourceWord(colourBase),
                    plagueLocalSourceWord(colourBase+4),plagueLocalSourceWord(colourBase+8)));
            if(any(isnan(le)) || any(isinf(le)) || !any(greaterThan(le,vec3(0.0)))) continue;

            // The BRDF is read once, aimed at the middle of the rectangle, and divided by its own
            // cosine because the exact cosine is already inside `front`. For a diffuse surface
            // that is exact; for a highlight it is the standard stand-in point. Karis, "Real
            // Shading in Unreal Engine 4", SIGGRAPH 2013 course notes.
            float centreDistance=sqrt(centre2);
            vec3 dirRep=toCentre*inversesqrt(centre2);
            vec3 offer;
            if(front>0.0) {
                if(dot(normal,dirRep)<=0.0) continue;
                PlagueBrdf brdf=plagueEvaluateBrdf(material,albedo,normal,viewDir,dirRep);
                float nDotL=max(dot(normal,dirRep),1e-3);
                offer=(brdf.diffuse*albedo*(1.0-transmission)+brdf.specular)*(front/nDotL);
            } else {
                // Lambertian transmitted radiance: projected incident area over pi. Fresnel
                // reflection and metallic absorption remove energy before transmission.
                offer=albedo*(1.0-plagueMaterialF0(material,albedo))*(1.0-material.metalness)
                        *(transmission*back/PLAGUE_PI);
            }
            offer*=le*plagueLocalFalloff(centreDistance);
            if(!any(greaterThan(offer,vec3(0.0))) || any(isnan(offer)) || any(isinf(offer))) continue;
            unshadowed+=offer;

            // Everything above is exact and the same every frame. Only whether something stands
            // in the way is sampled, so only that is cut into pieces: each probe speaks for its
            // own quarter of the rectangle, and blocking one loses that quarter.
            int probes=split ? 4 : 1;
            float shareEach=dot(offer,vec3(0.2126,0.7152,0.0722))/float(probes);
            for(int piece=0;piece<probes;piece++) {
                worth+=shareEach;
                // The march is the expensive part, so it only runs while the budget holds.
                if(rays>=PLAGUE_LOCAL_RAY_CEILING
                        || shareEach*float(PLAGUE_LOCAL_RAY_BUDGET)<worth) continue;
                rays++;
                offered+=shareEach;
                // Neighbouring pixels asking about different parts of the piece is what a soft
                // edge is made of, and it lands in the visibility fraction alone, which is
                // filtered. R2 again, walked per piece so the probes spread rather than agree:
                // each step lands in the largest gap the earlier ones left. Roberts, "The
                // Unreasonable Effectiveness of Quasirandom Sequences", 2018.
                vec2 pieceSize=faceSpan/float(probes==4 ? 2 : 1);
                vec2 pieceLo=rectLo+vec2(piece&1,piece>>1)*pieceSize;
                vec2 probeST=pieceLo+pieceSize*fract(jitterUV
                        +float(face*4+piece)*vec2(0.7548776662466927,0.5698402909980532));
                vec3 probe=sourceOrigin+(face<2 ? vec3(probeST.x,facePlane,probeST.y)
                        : face<4 ? vec3(probeST,facePlane) : vec3(facePlane,probeST));
                if(plagueLocalSegment(point,front>0.0?geometricNormal:-geometricNormal,probe,sourceNormal)) {
                    reached+=shareEach;
                }
            }
        }
    }
    if(offered>0.0) visibility=clamp(reached/offered,0.0,1.0);
    // The fraction measured from the samples that got a ray, applied to every sample's light.
    // Under the budget this is the same sum the marched samples alone would have given.
    radiance=unshadowed*visibility;
    return !any(isnan(radiance)) && !any(isinf(radiance))
            && !any(isnan(unshadowed)) && !any(isinf(unshadowed));
}
#endif
