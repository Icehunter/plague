#ifndef PLAGUE_LOCAL_LIGHT_SOURCE
#define PLAGUE_LOCAL_LIGHT_SOURCE
#moj_import <fornax_runtime:voxel_local_layout.glsl>
#moj_import <fornax_runtime:light_rect_flux.glsl>

// Both visibility backends use these offers and the same complete inventory. A different
// source cap or BRDF would shadow the direct RGB sum with an unrelated distribution.
uint plagueLocalSourceWord(int word);
int plagueLocalSourceSize();

struct PlagueLocalSourceIterator {
    bool valid;
    bool sparse;
    int range;
    int dimension;
    uint total;
    uint index;
    uint end;
    ivec3 receiverSection;
    ivec3 first;
    ivec3 section;
};

PlagueLocalSourceIterator plagueLocalSourceBegin(vec3 point) {
    PlagueLocalSourceIterator it;
    it.valid=false; it.sparse=false; it.range=0; it.dimension=u_VoxelWindow.w;
    it.total=0u; it.index=0u; it.end=0u;
    it.receiverSection=ivec3(0); it.first=ivec3(0); it.section=ivec3(0);
    int d=it.dimension;
    if(d<1 || d>33 || plagueLocalSourceSize()!=PLAGUE_LOCAL_SOURCE_WORDS
            || any(isnan(point)) || any(isinf(point))) return it;
    if(plagueLocalSourceWord(0)!=2u || plagueLocalSourceWord(1)!=uint(PLAGUE_LOCAL_CAPACITY)
            || plagueLocalSourceWord(2)>uint(PLAGUE_LOCAL_CAPACITY)) return it;
    it.valid=true;
    it.total=plagueLocalSourceWord(2);
    it.receiverSection=(ivec3(floor(u_CameraAbs))+ivec3(floor(fract(u_CameraAbs)+point)))>>4;
    it.first=u_VoxelWindow.xyz-ivec3((d-1)/2);
    // One direct scan costs less than 27 neighbour range lookups at this inventory size.
    it.sparse=it.total<=27u;
    return it;
}

bool plagueLocalSourceNext(inout PlagueLocalSourceIterator it,out int base) {
    base=0;
    if(!it.valid) return false;
    while(true) {
        while(it.index>=it.end) {
            if(it.range>=(it.sparse?1:27)) return false;
            int range=it.range++;
            it.section=it.receiverSection+ivec3(range%3-1,range/9-1,(range/3)%3-1);
            uint begin=0u,count=it.total;
            if(!it.sparse) {
                if(any(lessThan(it.section,it.first))
                        || any(greaterThanEqual(it.section,it.first+ivec3(it.dimension)))) continue;
                ivec3 slotCell=ivec3(plagueLocalSectionMod(it.section.x,it.dimension),
                        plagueLocalSectionMod(it.section.y,it.dimension),plagueLocalSectionMod(it.section.z,it.dimension));
                int slot=(slotCell.y*it.dimension+slotCell.z)*it.dimension+slotCell.x;
                begin=plagueLocalSourceWord(16+slot*2); count=plagueLocalSourceWord(17+slot*2);
                if(begin>it.total || count>it.total-begin) continue;
            }
            it.index=begin; it.end=begin+count;
        }
        base=PLAGUE_LOCAL_RECORDS+int(it.index++)*PLAGUE_LOCAL_RECORD_WORDS;
        if(plagueLocalSourceWord(base+6)!=1u) continue;
        ivec3 cell=ivec3(plagueLocalSourceWord(base),plagueLocalSourceWord(base+1),plagueLocalSourceWord(base+2));
        ivec3 owner=cell>>4;
        if(it.sparse) {
            if(any(lessThan(owner,it.first)) || any(greaterThanEqual(owner,it.first+ivec3(it.dimension)))
                    || any(greaterThan(abs(owner-it.receiverSection),ivec3(1)))) continue;
        } else if(any(notEqual(owner,it.section))) continue;
        return true;
    }
}

struct PlagueLocalSource {
    vec3 offer;
    vec3 sourceOrigin;
    vec3 sourceNormal;
    vec2 rectLo;
    vec2 faceSpan;
    float facePlane;
    float front;
    int face;
};

bool plagueLocalSourceCandidate(int base,vec3 point,vec3 geometricNormal,vec3 normal,
        vec3 viewDir,PlagueMaterial material,vec3 albedo,float transmission,
        out PlagueLocalSource candidate) {
    ivec3 cell=ivec3(plagueLocalSourceWord(base),plagueLocalSourceWord(base+1),plagueLocalSourceWord(base+2));
    ivec3 cameraCell=ivec3(floor(u_CameraAbs));
    vec3 fractional=fract(u_CameraAbs);
    uint run=plagueLocalSourceWord(base+PLAGUE_LOCAL_RECORD_RUN);
    int face=plagueLocalRunFace(run);
    vec2 runSpan=plagueLocalRunSpan(run);
    int faceAxis=face<2 ? 1 : face<4 ? 2 : 0;
    int axisU=face<4 ? 0 : 1;
    int axisV=face<2 ? 2 : face<4 ? 1 : 2;
    vec3 runExtent=vec3(1.0);
    runExtent[axisU]=runSpan.x;
    runExtent[axisV]=runSpan.y;
    vec3 sourceOrigin=vec3(cell-cameraCell)-fractional;
    vec3 separation=max(max(sourceOrigin-point,point-sourceOrigin-runExtent),vec3(0.0));
    if(dot(separation,separation)>=PLAGUE_LOCAL_REACH*PLAGUE_LOCAL_REACH) return false;
    // The box covers one source cell; the run span extends it across touching full cells.
    vec3 boxLo,boxHi;
    plagueLocalUnpackBox(plagueLocalSourceWord(base+PLAGUE_LOCAL_RECORD_BOX),boxLo,boxHi);
    vec3 sourceNormal=plagueLocalNormal(face);
    float facePlane=(face&1)==0 ? boxLo[faceAxis] : boxHi[faceAxis];
    vec2 rectLo=vec2(boxLo[axisU],boxLo[axisV]);
    vec2 rectHi=vec2(boxHi[axisU],boxHi[axisV])+runSpan-vec2(1.0);
    vec2 faceSpan=rectHi-rectLo;
    float faceArea=faceSpan.x*faceSpan.y;
    if(!(faceArea>0.0)) return false;
    // Every point on this source plane has the same facing sign.
    vec2 faceMiddle=rectLo+faceSpan*0.5;
    vec3 centre=sourceOrigin+(face<2 ? vec3(faceMiddle.x,facePlane,faceMiddle.y)
            : face<4 ? vec3(faceMiddle,facePlane) : vec3(facePlane,faceMiddle));
    if(dot(sourceNormal,point-centre)<=0.0) return false;
    // Reject only rectangles that lie wholly behind an opaque receiver's plane.
    vec3 halfSpan=0.5*(face<2 ? vec3(faceSpan.x,0.0,faceSpan.y)
            : face<4 ? vec3(faceSpan.x,faceSpan.y,0.0)
            : vec3(0.0,faceSpan.x,faceSpan.y));
    float extent=dot(abs(geometricNormal),halfSpan);
    if(transmission==0.0 && dot(geometricNormal,centre-point)+extent<=0.0) return false;
    vec3 toCentre=centre-point;
    // This squared-distance floor limits inverse length to 10000 at coincident samples.
    float centre2=max(dot(toCentre,toCentre),1e-8);
    vec3 uVec=vec3(0.0); uVec[axisU]=1.0;
    vec3 vVec=vec3(0.0); vVec[axisV]=1.0;
    vec3 planeOrigin=sourceOrigin;
    planeOrigin[faceAxis]+=facePlane;
    planeOrigin+=uVec*rectLo.x+vVec*rectLo.y;
    vec3 corner1=planeOrigin+uVec*faceSpan.x;
    vec3 corner2=corner1+vVec*faceSpan.y;
    vec3 corner3=planeOrigin+vVec*faceSpan.y;
    vec3 flux=plagueLocalRectFlux(planeOrigin,corner1,corner2,corner3,point);
    // Corner order sets the sign; incident flux must point against the source normal.
    if(dot(flux,sourceNormal)>0.0) flux=-flux;
    float front=max(dot(flux,normal),0.0);
    float back=transmission>0.0 ? max(dot(flux,-normal),0.0) : 0.0;
    if(front<=0.0 && back<=0.0) return false;

    // Stored source radiance is the mean of four face quarters, shared across the whole run.
    int colourBase=base+8+PLAGUE_LOCAL_RECORD_FACE_COLOUR;
    vec3 le=uintBitsToFloat(uvec3(plagueLocalSourceWord(colourBase),
            plagueLocalSourceWord(colourBase+4),plagueLocalSourceWord(colourBase+8)));
    if(any(isnan(le)) || any(isinf(le)) || !any(greaterThan(le,vec3(0.0)))) return false;

    // Evaluate the BRDF toward the face centre, then replace its cosine with the area integral.
    // This is exact for Lambertian diffuse; highlights use a representative point.
    // Karis, "Real Shading in Unreal Engine 4", SIGGRAPH 2013 course notes.
    float centreDistance=sqrt(centre2);
    vec3 dirRep=toCentre*inversesqrt(centre2);
    vec3 offer;
    if(front>0.0) {
        if(dot(normal,dirRep)<=0.0) return false;
        PlagueBrdf brdf=plagueEvaluateBrdf(material,albedo,normal,viewDir,dirRep);
        // Representative-point cosine floor bounds the area-light correction to 1000.
        float nDotL=max(dot(normal,dirRep),1e-3);
        offer=(brdf.diffuse*albedo*(1.0-transmission)+brdf.specular)*(front/nDotL);
    } else {
        // Lambertian transmitted radiance: projected incident area over pi. Fresnel
        // reflection and metallic absorption remove energy before transmission.
        offer=albedo*(1.0-plagueMaterialF0(material,albedo))*(1.0-material.metalness)
                *(transmission*back/PLAGUE_PI);
    }
    offer*=le*plagueLocalFalloff(centreDistance);
    if(!any(greaterThan(offer,vec3(0.0))) || any(isnan(offer)) || any(isinf(offer))) return false;
    candidate.offer=offer; candidate.sourceOrigin=sourceOrigin; candidate.sourceNormal=sourceNormal;
    candidate.rectLo=rectLo; candidate.faceSpan=faceSpan; candidate.facePlane=facePlane;
    candidate.front=front; candidate.face=face;
    return true;
}
#endif
