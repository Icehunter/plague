// Fixed-budget GI path estimator. The retained direct caustic producer is unchanged.
#moj_import <fornax_runtime:brdf.glsl>
uint plagueGlassGiCacheWord(int i){return cacheWords[i];}
int plagueGlassGiEmitter(PlagueGlassHit hit,vec3 direction,out vec3 radiance) {
    radiance=vec3(0.0);
    bool found=false;
    uint count=plagueGlassGiCacheWord(2),rows=plagueGlassGiCacheWord(7);
    // Compact admitted inventory only. Integer AABB/face tests precede colour decoding.
    // Cost is linear in admitted source count at opaque endpoints; profile dense inventories.
    for(uint lane=0u;lane<count;++lane) {
        uint source=plagueGlassGiCacheWord(PLAGUE_GLASS_CACHE_SOURCES+int(lane));
        if(source>=rows) return -1;
        int row=PLAGUE_GLASS_CACHE_ROWS+int(source)*PLAGUE_LOCAL_RECORD_WORDS;
        ivec3 cell=ivec3(plagueGlassGiCacheWord(row),plagueGlassGiCacheWord(row+1),plagueGlassGiCacheWord(row+2));
        // Four-bit run span adds at most 15; five-bit box high is at most 31/16.
        // Their sum fits this 17-cell coarse envelope, before exact plane/tangent tests.
        vec3 relative=hit.position+(PLAGUE_GLASS_SCENE_ORIGIN-vec3(cell));
        if(any(lessThan(relative,vec3(-PLAGUE_LOCAL_PLANE_TOLERANCE)))
                || any(greaterThan(relative,vec3(17.0+PLAGUE_LOCAL_PLANE_TOLERANCE)))) continue;
        if(plagueGlassGiCacheWord(row+6)!=1u) continue;
        uint run=plagueGlassGiCacheWord(row+PLAGUE_LOCAL_RECORD_RUN);
        int face=plagueLocalRunFace(run);
        if(face>5) return -1;
        vec3 normal=plagueLocalNormal(face);
        if(dot(normal,direction)>=0.0 || dot(normal,hit.normal)<=0.0) continue;
        int axis=face<2?1:face<4?2:0;
        int uAxis=face<4?0:1,vAxis=face<2?2:face<4?1:2;
        vec3 lo,hi;plagueLocalUnpackBox(plagueGlassGiCacheWord(row+PLAGUE_LOCAL_RECORD_BOX),lo,hi);
        vec2 span=plagueLocalRunSpan(run);
        hi[uAxis]+=span.x-1.0;hi[vAxis]+=span.y-1.0;
        float plane=(face&1)==0?lo[axis]:hi[axis];
        if(abs(relative[axis]-plane)>PLAGUE_LOCAL_PLANE_TOLERANCE
                || relative[uAxis]<lo[uAxis] || relative[uAxis]>=hi[uAxis]
                || relative[vAxis]<lo[vAxis] || relative[vAxis]>=hi[vAxis]) continue;
        vec3 value=uintBitsToFloat(uvec3(plagueGlassGiCacheWord(row+11),
            plagueGlassGiCacheWord(row+15),plagueGlassGiCacheWord(row+19)));
        if(any(isnan(value)) || any(isinf(value))) return -1;
        value=max(value,vec3(0.0));
        if(!any(greaterThan(value,vec3(0.0)))) continue;
        // Half-open tangents give shared run edges one owner. Overlapping positive rows are
        // unavailable rather than silently duplicating Le or choosing an inventory order.
        if(found) return -1;
        radiance=value;found=true;
    }
    return found?1:0;
}


int plagueGlassGiCandidates,plagueGlassGiPriorOpaque;
bool plagueGlassGiLastOpaque,plagueGlassGiSelectedOpaque;
PlagueGlassHit plagueGlassGiSelectedHit;
vec3 plagueGlassGiSelectedFlux,plagueGlassGiSelectedIncoming;
vec4 plagueGlassGiSelectedPlane;
vec3 plagueGlassGiSelectedLo,plagueGlassGiSelectedHi;
bool plagueGlassGiSelectedSource;
float plagueGlassGiSelectedDistance,plagueGlassGiSelectedKind;
// Reservoir sampling: each of K eligible vertices has probability 1/K. Store incident
// flux before this receiver BRDF, multiply the selected record by K once after completion.
int plagueGlassGiFinish(out PlagueGlassHit receiver,out vec3 flux,out vec3 direction){
    if(plagueGlassGiCandidates==0)return 2;
    receiver=plagueGlassGiSelectedHit;
    flux=plagueGlassGiSelectedFlux*float(plagueGlassGiCandidates);
    direction=-plagueGlassGiSelectedIncoming;
    plagueGlassLastPlane=plagueGlassGiSelectedPlane;
    plagueGlassLastLo=plagueGlassGiSelectedLo;
    plagueGlassLastHi=plagueGlassGiSelectedHi;
    plagueGlassLastIsSource=plagueGlassGiSelectedSource;
    plagueGlassPathDistance=plagueGlassGiSelectedDistance;
    plagueGlassGiLastOpaque=plagueGlassGiSelectedOpaque;
    return 1;
}
int plagueGlassGiOpaque(PlagueGlassHit hit,inout vec3 origin,inout vec3 direction,inout vec3 flux,
    inout uint state,bool crossed,inout PlagueGlassMedium medium){
    // An outward crossing of a closed opaque box came from inside solid. Such a suffix cannot carry
    // transmitted radiance through that solid or create an interior diffuse reflection.
    // End its known absorbed path while preserving previously visited valid candidates.
    uint opaqueFlags=plagueGlassPaletteWord(hit.entry*16);
    if((opaqueFlags&0xc0000000u)==0u && dot(hit.normal,direction)>=0.0) return 0;
    vec3 emission;
    int source=plagueGlassGiEmitter(hit,direction,emission);
    if(source<0)return -1;
    if(source>0)return 0;
    vec2 uv;
    vec3 tint;
    if(!plagueGlassUv(hit.entry,hit.local,hit.normal,uv,tint))return -1;
    vec3 encoded=plagueGlassMaterial(uv).rgb;
    PlagueMaterial material=plagueDecodeMaterial(encoded.r,encoded.g,encoded.b);
    vec3 albedo=plagueSrgbToLinear(plagueGlassAlbedo(uv).rgb)*tint;
    vec3 normal=dot(hit.normal,direction)<0.0?hit.normal:-hit.normal;
    // Close the existing finite source integration domain once at its first opaque incidence.
    // Later receiver vertices inherit this prefix weight; their added bounce distance is not a new source falloff.
    if(plagueGlassGiPriorOpaque==0) flux*=plagueLocalFalloff(plagueGlassPathDistance);
    // Direct clear-air incidence belongs to the area-light estimator; every later opaque
    // incidence is indirect irradiance, whether or not its prefix encountered glass.
    if((crossed || plagueGlassGiPriorOpaque>0) && material.metalness<1.0){
     ++plagueGlassGiCandidates;
     if(plagueGlassRandom(state)*float(plagueGlassGiCandidates)<1.0){
      plagueGlassGiSelectedHit=hit;
      plagueGlassGiSelectedHit.normal=normal;
      plagueGlassGiSelectedFlux=flux;
      plagueGlassGiSelectedIncoming=-direction;
      plagueGlassGiSelectedPlane=plagueGlassLastPlane;
      plagueGlassGiSelectedLo=plagueGlassLastLo;
      plagueGlassGiSelectedHi=plagueGlassLastHi;
      plagueGlassGiSelectedSource=plagueGlassLastIsSource;
      plagueGlassGiSelectedOpaque=plagueGlassGiLastOpaque;
      plagueGlassGiSelectedDistance=plagueGlassPathDistance;
      // Kind 2 is additive irradiance after an opaque bounce; kind 0 refines direct transmission.
      plagueGlassGiSelectedKind=plagueGlassGiPriorOpaque>0?2.0:0.0;
     }
    }
    vec3 incident=direction;
    if(material.metalness==1.0){
     // Heitz (2014), visible-normal GGX reflection: f*cos/pdf=F*G2/G1.
     vec3 h=plagueGlassVisibleNormal(incident,normal,material.alpha,state);
     direction=reflect(incident,h);
     if(dot(normal,direction)<=0.0)return 0;
     flux*=plagueFresnel(material,albedo,max(dot(-incident,h),0.0))*plagueGlassMaskWeight(incident,direction,normal,material.alpha);
    }else{
     // Lambert cosine sampling: (albedo/pi)*cos/(cos/pi)=albedo. No extra cosine/pi.
     float r=sqrt(plagueGlassRandom(state)),phi=2.0*3.141592653589793*plagueGlassRandom(state);
     vec3 tangent=normalize(cross(abs(normal.y)<1.0?vec3(0,1,0):vec3(1,0,0),normal));
     vec3 bitangent=cross(normal,tangent);
     direction=tangent*(r*cos(phi))+bitangent*(r*sin(phi))+normal*sqrt(max(1.0-r*r,0.0));
     flux*=albedo*(1.0-material.metalness);
    }
    if(any(isnan(flux)) || any(isinf(flux)))return -1;
    if(max(flux.x,max(flux.y,flux.z))<=0.0)return 0;
    // Certify the actual finite face of one model box. A union of separated boxes is not a face.
    // The traced model cell is integral in the active scene grid.
    vec3 cellOrigin=round(plagueGlassGridOrigin()+hit.position-hit.local)-plagueGlassGridOrigin();
    // Box geometry belongs to the traced face. A ray may hit a backface from inside a
    // model: orienting its scattering normal must not switch the certified face to the
    // opposite side of the box. Plane orientation still follows the outgoing hemisphere.
    int axis=plagueGlassBeamPlaneAxis(hit.normal);
    if(axis<0)return -1;
    bool found=false;
    int boxes=int(plagueGlassPaletteWord(hit.entry*16)&15u);
    for(int box=0;box<max(boxes,1);++box){
     vec3 lo,hi;
     plagueGlassBox(hit.entry,box,lo,hi);lo+=cellOrigin;hi+=cellOrigin;
     float plane=hit.normal[axis]>0.0?hi[axis]:lo[axis];
     if(abs(plane-hit.position[axis])>PLAGUE_GLASS_EPSILON)continue;
     lo[axis]=plane;hi[axis]=plane;
     if(any(lessThan(hit.position,lo-vec3(PLAGUE_GLASS_EPSILON))) || any(greaterThan(hit.position,hi+vec3(PLAGUE_GLASS_EPSILON))))continue;
     // Use the selected model face, with scattering orientation retained separately.
     plagueGlassLastPlane=vec4(normal,normal[axis]*plane);
     plagueGlassLastLo=lo;
     plagueGlassLastHi=hi;found=true;break;
    }
    if(!found)return -1;
    plagueGlassLastIsSource=false;
    plagueGlassGiLastOpaque=true;++plagueGlassGiPriorOpaque;
    origin=plagueGlassBoundaryOffset(hit.position,direction,normal);
    if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+origin)))==-2)return -1;
    medium=plagueGlassAt(origin);
    return 1;
}
int plagueGlassGiTransportFirstBranch(inout vec3 origin,inout vec3 direction,inout vec3 throughput,float reach,
        bool photon,inout uint randomState,out PlagueGlassHit receiver,out bool crossed,out float firstDistance,
        int firstBranch,out float firstWeight,out bool firstSelected,out bool splitApplied) {
#ifdef PLAGUE_GLASS_RECORD_PATH
    plagueGlassLastPlane=plagueGlassEmissionPlane;
    plagueGlassPathDistance=0.0;
    plagueGlassLastLo=plagueGlassEmissionLo; plagueGlassLastHi=plagueGlassEmissionHi;
    plagueGlassLastIsSource=dot(plagueGlassEmissionPlane.xyz,plagueGlassEmissionPlane.xyz)>0.0;
#endif
    plagueGlassGiCandidates=0; plagueGlassGiPriorOpaque=0; plagueGlassGiLastOpaque=false;
    crossed=false; firstDistance=-1.0;
    firstWeight=1.0; firstSelected=true; splitApplied=false;
    float remaining=reach;
    // Measured total path quality domain; the initial source leg retains its original reach.
    // Extend once after the first successful opaque scatter, never once per bounce.
    bool extendedOpaqueBudget=false;
    PlagueGlassMedium current=plagueGlassAt(origin);
    for(int event=0;event<PLAGUE_GLASS_INTERFACES;++event) {
        int status=plagueGlassTrace(origin,direction,remaining,false,receiver);
        if(status!=1) return status<0?-1:plagueGlassGiFinish(receiver,throughput,direction);
        throughput*=plagueGlassAttenuation(current.absorption,receiver.distance);
        remaining-=receiver.distance;
#ifdef PLAGUE_GLASS_RECORD_PATH
        plagueGlassPathDistance+=receiver.distance;
#endif
        if(max(throughput.x,max(throughput.y,throughput.z))<=0.0) return plagueGlassGiFinish(receiver,throughput,direction);
        if(!receiver.glass) {
            int opaque=plagueGlassGiOpaque(receiver,origin,direction,throughput,randomState,crossed,current);
            if(opaque<0) return -1;
            if(opaque>0 && !extendedOpaqueBudget){remaining=max(float(PLAGUE_GLASS_PATH_REACH)-plagueGlassPathDistance,0.0);extendedOpaqueBudget=true;}
            if(opaque==0 || remaining<=PLAGUE_GLASS_EPSILON)
                return plagueGlassGiFinish(receiver,throughput,direction);
            continue;
        }
        if(!crossed) firstDistance=plagueGlassPathDistance;
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
                    int opaque=plagueGlassGiOpaque(receiver,origin,direction,throughput,randomState,crossed,current);
                    if(opaque<0) return -1;
                    if(opaque>0 && !extendedOpaqueBudget){remaining=max(float(PLAGUE_GLASS_PATH_REACH)-plagueGlassPathDistance,0.0);extendedOpaqueBudget=true;}
                    if(opaque==0 || remaining<=PLAGUE_GLASS_EPSILON)
                        return plagueGlassGiFinish(receiver,throughput,direction);
                    continue;
                }
            }
        }
        // Connected equal-index media have no Fresnel surface, even if their absorption differs.
        if(current.ior==nextMedium.ior) {
#ifdef PLAGUE_GLASS_RECORD_PATH
            // A model seam inside an identical medium is not an optical interface. Retaining
            // it would split the same path family according to which block seam a ray crossed.
            if(current.glass!=nextMedium.glass || current.roughness!=nextMedium.roughness
                    || any(notEqual(current.absorption,nextMedium.absorption))) {
                if(!plagueGlassRecordBoundary(receiver,direction)) return -1;
                plagueGlassGiLastOpaque=false;
            }
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
            if(firstWeight<=0.0) { throughput=vec3(0.0); return plagueGlassGiFinish(receiver,throughput,direction); }
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
            return plagueGlassGiFinish(receiver,throughput,direction);
        }
        throughput*=plagueGlassMaskWeight(incident,direction,n,alpha);
        if(max(throughput.x,max(throughput.y,throughput.z))<=0.0) return plagueGlassGiFinish(receiver,throughput,direction);
#ifdef PLAGUE_GLASS_RECORD_PATH
        if(!plagueGlassRecordBoundary(receiver,direction)) return -1;
        plagueGlassGiLastOpaque=false;
#endif
        origin=plagueGlassBoundaryOffset(receiver.position,direction,receiver.normal);
        if(remaining<=PLAGUE_GLASS_EPSILON) return plagueGlassGiFinish(receiver,throughput,direction);
    }
    // The estimator covers this finite event/reach domain. Exhausting known work finalizes
    // visited candidates; only missing scene/material data discards an incomplete reservoir.
    return plagueGlassGiFinish(receiver,throughput,direction);
}


int plagueGlassGiTransport(inout vec3 origin,inout vec3 direction,inout vec3 flux,float reach,inout uint state,out PlagueGlassHit hit,out bool crossed,out float firstDistance){
 float w;
 bool selected,split;
 return plagueGlassGiTransportFirstBranch(origin,direction,flux,reach,true,state,hit,crossed,firstDistance,-1,w,selected,split);
}
