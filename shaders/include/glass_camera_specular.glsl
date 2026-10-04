#ifndef PLAGUE_GLASS_CAMERA_SPECULAR
#define PLAGUE_GLASS_CAMERA_SPECULAR
#moj_import <fornax_runtime:glass_options.glsl>
// Caller supplies glass_compute_scene, brdf, glass_photon_cache and these cache accessors.
// Positions use the caller optical scene origin (normally camera-relative in primary gather).
uint plagueGlassCameraCacheWord(int word);
int plagueGlassCameraCacheSize();
// Separate path family: emitted optical radiance and a photon-certified diffuse endpoint
// must not share compositor ownership. Reset for every primary sample, including rejected draws.
vec3 plagueGlassCameraIndirect=vec3(0.0);
bool plagueGlassCameraIndirectAvailable=true;
#ifdef PLAGUE_GLASS_CAMERA_INDIRECT
int plagueGlassCameraOpaqueIndirect(PlagueGlassHit hit,vec3 direction,inout uint state,out vec3 radiance);
#endif

// 1 = answered nonzero, 0 = certified zero, -1 = unavailable. An unavailable lane invalidates
// a whole multi-lane estimate; averaging only answered lanes conditions the sampling distribution.
bool plagueGlassCameraFinite(vec3 v) { return !any(isnan(v)) && !any(isinf(v)); }
bool plagueGlassCameraReady() {
    return plagueGlassCameraCacheSize()==PLAGUE_GLASS_CACHE_WORDS
        && plagueGlassCameraCacheWord(0)==PLAGUE_GLASS_CACHE_TAG
        && plagueGlassCameraCacheWord(2)<=uint(PLAGUE_LOCAL_CAPACITY)
        && plagueGlassCameraCacheWord(7)<=uint(PLAGUE_LOCAL_CAPACITY)
        && plagueGlassBuffersValid();
}

// Mean source Le is reciprocal to photon pi*A*Le/N. Texture emission, shaded scene colour,
// inverse-square attenuation and area factors would each change the forward source model.
int plagueGlassCameraEmitter(PlagueGlassHit hit,vec3 direction,out vec3 radiance) {
    radiance=vec3(0.0);
    bool found=false;
    uint count=plagueGlassCameraCacheWord(2),rows=plagueGlassCameraCacheWord(7);
    // Compact admitted inventory only. Integer AABB/face tests precede colour decoding.
    // Cost is linear in admitted source count at opaque endpoints; profile dense inventories.
    for(uint lane=0u;lane<count;++lane) {
        uint source=plagueGlassCameraCacheWord(PLAGUE_GLASS_CACHE_SOURCES+int(lane));
        if(source>=rows) return -1;
        int row=PLAGUE_GLASS_CACHE_ROWS+int(source)*PLAGUE_LOCAL_RECORD_WORDS;
        ivec3 cell=ivec3(plagueGlassCameraCacheWord(row),plagueGlassCameraCacheWord(row+1),plagueGlassCameraCacheWord(row+2));
        // Four-bit run span adds at most 15; five-bit box high is at most 31/16.
        // Their sum fits this 17-cell coarse envelope, before exact plane/tangent tests.
        vec3 relative=hit.position+(PLAGUE_GLASS_SCENE_ORIGIN-vec3(cell));
        if(any(lessThan(relative,vec3(-PLAGUE_LOCAL_PLANE_TOLERANCE)))
                || any(greaterThan(relative,vec3(17.0+PLAGUE_LOCAL_PLANE_TOLERANCE)))) continue;
        if(plagueGlassCameraCacheWord(row+6)!=1u) continue;
        uint run=plagueGlassCameraCacheWord(row+PLAGUE_LOCAL_RECORD_RUN);
        int face=plagueLocalRunFace(run);
        if(face>5) return -1;
        vec3 normal=plagueLocalNormal(face);
        if(dot(normal,direction)>=0.0 || dot(normal,hit.normal)<=0.0) continue;
        int axis=face<2?1:face<4?2:0;
        int uAxis=face<4?0:1,vAxis=face<2?2:face<4?1:2;
        vec3 lo,hi;plagueLocalUnpackBox(plagueGlassCameraCacheWord(row+PLAGUE_LOCAL_RECORD_BOX),lo,hi);
        vec2 span=plagueLocalRunSpan(run);
        hi[uAxis]+=span.x-1.0;hi[vAxis]+=span.y-1.0;
        float plane=(face&1)==0?lo[axis]:hi[axis];
        if(abs(relative[axis]-plane)>PLAGUE_LOCAL_PLANE_TOLERANCE
                || relative[uAxis]<lo[uAxis] || relative[uAxis]>=hi[uAxis]
                || relative[vAxis]<lo[vAxis] || relative[vAxis]>=hi[vAxis]) continue;
        vec3 value=uintBitsToFloat(uvec3(plagueGlassCameraCacheWord(row+11),
            plagueGlassCameraCacheWord(row+15),plagueGlassCameraCacheWord(row+19)));
        if(!plagueGlassCameraFinite(value)) return -1;
        value=max(value,vec3(0.0));
        if(!any(greaterThan(value,vec3(0.0)))) continue;
        // Half-open tangents give shared run edges one owner. Overlapping positive rows are
        // unavailable rather than silently duplicating Le or choosing an inventory order.
        if(found) return -1;
        radiance=value;found=true;
    }
    return found?1:0;
}

// A source touching glass emits into its adjacent medium. At the terminal contact there is no
// glass-to-air interface: the opaque endpoint wins, matching the photon launch/receiver convention.
int plagueGlassCameraContact(inout PlagueGlassHit hit,vec3 direction,vec3 after) {
    vec3 grid=plagueGlassGridOrigin()+after;
    int entry=plagueGlassCell(ivec3(floor(grid)));
    if(entry==-2) return -1;
    if(entry<0 || !plagueGlassContains(entry,fract(grid))) return 0;
    if(plagueGlassMedium(entry).glass) return 0;
    uint flags=plagueGlassPaletteWord(entry*16);
    if((flags&0x80000000u)!=0u) return 0;
    vec3 local=plagueGlassGridOrigin()+hit.position-vec3(ivec3(floor(grid)));
    vec3 normal=dot(direction,hit.normal)<0.0?hit.normal:-hit.normal;
    vec2 uv;vec3 tint;
    if((flags&0xc0000000u)!=0u && plagueGlassUv(entry,local,normal,uv,tint)
            && plagueGlassAlbedo(uv).a<0.5) return 0;
    hit.entry=entry;hit.local=local;hit.normal=normal;hit.glass=false;
    return 1;
}

// Conductor-only opaque continuation. 0 = nonmetal terminal, 1 = reflected continuation,
// 2 = sampled zero (outside hemisphere), -1 = missing material data. This adds no diffuse lobe.
#ifdef PLAGUE_GLASS_CAMERA_INDIRECT
int plagueGlassCameraConductor(PlagueGlassHit hit,vec3 incident,inout uint state,
        out vec3 outgoing,out vec3 response) {
    outgoing=vec3(0.0);response=vec3(0.0);
    vec2 uv;vec3 tint;
    if(!plagueGlassUv(hit.entry,hit.local,hit.normal,uv,tint)) return -1;
    vec3 encoded=plagueGlassMaterial(uv).rgb;
    PlagueMaterial material=plagueDecodeMaterial(encoded.r,encoded.g,encoded.b);
    if(material.metalness!=1.0) return 0;
    if(dot(hit.normal,-incident)<=0.0) return 2;
    vec3 h=plagueGlassVisibleNormal(incident,hit.normal,material.alpha,state);
    outgoing=reflect(incident,h);
    if(dot(hit.normal,outgoing)<=0.0) return 2;
    vec3 albedo=plagueSrgbToLinear(plagueGlassAlbedo(uv).rgb)*tint;
    // Heitz (2014): GGX VNDF reflection f*cos/pdf = F*G2/G1. The shared mask ratio
    // cancels D analytically; the directional-light response cap must not absorb path energy.
    response=plagueFresnel(material,albedo,max(dot(-incident,h),0.0))
        *plagueGlassMaskWeight(incident,outgoing,hit.normal,material.alpha);
    return plagueGlassCameraFinite(response) && plagueGlassCameraFinite(outgoing)?1:-1;
}
#endif

int plagueGlassCameraRadiance(vec3 origin,vec3 direction,inout uint state,int budget,out vec3 radiance) {
    radiance=vec3(0.0);
    if(!plagueGlassCameraReady() || !plagueGlassCameraFinite(origin)
            || !plagueGlassCameraFinite(direction) || dot(direction,direction)<=0.0) return -1;
    direction=normalize(direction);
    if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+origin)))==-2) return -1;
    PlagueGlassMedium current=plagueGlassAt(origin);
    vec3 weight=vec3(1.0);
    float pathReach=PLAGUE_LOCAL_REACH;
#ifdef PLAGUE_GLASS_CAMERA_INDIRECT
    pathReach=float(PLAGUE_GLASS_PATH_REACH);
#endif
    float remaining=pathReach;
    // Backward paths apply finite source integration only on the source-to-first-opaque
    // leg. Opaque bounces consume the optical work domain, not another source falloff.
    float sourceLegDistance=0.0;
    bool touched=false;
    int opaqueBounces=0;
    // Same work ceiling as forward optical transport. Caller may request a smaller budget;
    // exhaustion is unknown, never an extra source of black samples or an opaque miss.
    for(int event=0;event<min(budget,PLAGUE_GLASS_INTERFACES);++event) {
        PlagueGlassHit hit;
        int status=plagueGlassTrace(origin,direction,remaining,false,hit);
        if(status<0) return -1;
        if(status==0) return 0;
        weight*=plagueGlassAttenuation(current.absorption,hit.distance);
        remaining-=hit.distance;
        sourceLegDistance+=hit.distance;
        if(!plagueGlassCameraFinite(weight)) return -1;
        if(!any(greaterThan(weight,vec3(0.0)))) return 0;
        if(hit.glass) {
            // Family includes Fresnel reflection without a transmitted crossing, as photons do.
            touched=true;
            vec3 after=plagueGlassBoundaryOffset(hit.position,direction,hit.normal);
            if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+after)))==-2) return -1;
            PlagueGlassMedium next=plagueGlassAt(after);
            if(current.glass && !next.glass) {
                int contact=plagueGlassCameraContact(hit,direction,after);
                if(contact<0) return -1;
            }
            if(hit.glass) {
                if(current.ior==next.ior) { origin=after;current=next;continue; }
                vec3 normal=dot(direction,hit.normal)<0.0?hit.normal:-hit.normal;
                float alpha=max(current.glass?current.roughness:0.0,next.glass?next.roughness:0.0);
                vec3 halfNormal=plagueGlassVisibleNormal(direction,normal,alpha,state);
                vec3 transmitted;float fresnel;
                bool canTransmit=plagueGlassInterface(direction,halfNormal,current.ior,next.ior,transmitted,fresnel);
                bool reflected=!canTransmit || plagueGlassRandom(state)<fresnel;
                vec3 outgoing=reflected?reflect(direction,halfNormal):transmitted;
                float side=dot(outgoing,normal);
                if((reflected && side<=0.0) || (!reflected && side>=0.0)) return 0;
                // Walter et al. (2007): radiance transport has eta_i^2/eta_t^2; Fresnel branch
                // selection cancels F or (1-F), and VNDF leaves correlated Smith G2/G1.
                if(!reflected) { float eta=current.ior/next.ior;weight*=eta*eta; }
                weight*=plagueGlassMaskWeight(direction,outgoing,normal,alpha);
                if(!reflected) current=next;
                direction=outgoing;
                origin=plagueGlassBoundaryOffset(hit.position,direction,hit.normal);
                if(remaining<=PLAGUE_GLASS_EPSILON) return -1;
                continue;
            }
        }
        // Sources terminate before reflective continuation, including emissive conductors.
        // A source reached after an opaque reflection belongs only to the indirect family.
        vec3 emitted;
        int endpoint=plagueGlassCameraEmitter(hit,direction,emitted);
        if(endpoint<0) {plagueGlassCameraIndirectAvailable=false;return -1;}
        if(endpoint==1) {
            vec3 value=weight*emitted*plagueLocalFalloff(sourceLegDistance);
            if(!plagueGlassCameraFinite(value)) {plagueGlassCameraIndirectAvailable=false;return -1;}
            if(opaqueBounces>0) {plagueGlassCameraIndirect+=value;return 0;}
            if(!touched) return 0; // Primary clear-air direct lighting already owns this path.
            radiance=value;
            return any(greaterThan(value,vec3(0.0)))?1:0;
        }
#ifdef PLAGUE_GLASS_CAMERA_INDIRECT
        vec3 outgoing,response;
        int conductor=plagueGlassCameraConductor(hit,direction,state,outgoing,response);
        if(conductor<0) {plagueGlassCameraIndirectAvailable=false;return -1;}
        if(conductor==2) return 0;
        if(conductor==1) {
            weight*=response;
            if(!any(greaterThan(weight,vec3(0.0)))) return 0;
            ++opaqueBounces;
            sourceLegDistance=0.0;
            direction=outgoing;
            origin=plagueGlassBoundaryOffset(hit.position,direction,hit.normal);
            if(remaining<=PLAGUE_GLASS_EPSILON) {plagueGlassCameraIndirectAvailable=false;return -1;}
            continue;
        }
        vec3 indirect;
        int indirectStatus=plagueGlassCameraOpaqueIndirect(hit,direction,state,indirect);
        plagueGlassCameraIndirectAvailable=indirectStatus>=0;
        if(indirectStatus>0) plagueGlassCameraIndirect+=weight*indirect;
#endif
        return 0;
    }
    // Existing finite event/work domain covers both glass interfaces and opaque continuations.
    // Exhaustion is unavailable, never a black sample accepted into either history estimate.
    plagueGlassCameraIndirectAvailable=false;
    return -1;
}

// Halton (1960): radical inverse in coprime bases 2 and 3. Cranley/Patterson (1976):
// a uniform per-receiver torus shift preserves uniform marginals while decorrelating pixels.
// Bases 2/3 are the first two primes; 2^-32 converts reversed uint bits to [0,1).
vec2 plagueGlassCameraPrimaryDraw(uint receiverSeed,uint sampleIndex) {
    // Domain-separation salt retained from the measured isolated sequence fixture.
    uint shiftState=plagueGlassHash(receiverSeed^plagueGlassHash(8193u));
    vec2 shift;shift.x=plagueGlassRandom(shiftState);shift.y=plagueGlassRandom(shiftState);
    float inverseThree=0.0,place=1.0/3.0;
    uint digits=sampleIndex;
    while(digits>0u) { inverseThree+=float(digits%3u)*place;place/=3.0;digits/=3u; }
    return fract(vec2(float(bitfieldReverse(sampleIndex))*exp2(-32.0),inverseThree)+shift);
}
vec3 plagueGlassCameraNormalDraw(vec3 view,vec3 normal,float alpha,vec2 draw) {
    // Same orthonormal change of basis as the shared visible-normal sampler; only its input
    // uniforms change. The spherical-cap map and exact VNDF PDF remain paired.
    vec3 a=abs(normal);
    vec3 axis=a.x<=a.y && a.x<=a.z ? vec3(1.0,0.0,0.0)
            : a.y<=a.z ? vec3(0.0,1.0,0.0) : vec3(0.0,0.0,1.0);
    vec3 tangent=normalize(cross(normal,axis)),bitangent=cross(normal,tangent);
    vec3 localView=vec3(dot(view,tangent),dot(view,bitangent),dot(view,normal));
    vec3 h=plagueGlassCapNormal(localView,alpha,draw);
    return tangent*h.x+bitangent*h.y+normal*h.z;
}

// Caller supplies normalized shading/geometric normals and view, as reconstructed in gather.
int plagueGlassCameraSpecularCore(vec3 point,vec3 normal,vec3 geometric,vec3 view,PlagueMaterial material,
        vec3 albedo,inout uint state,int budget,vec2 primaryDraw,bool usePrimaryDraw,out vec3 radiance) {
    radiance=vec3(0.0);
    plagueGlassCameraIndirect=vec3(0.0);
    plagueGlassCameraIndirectAvailable=true;
    if(!plagueGlassCameraFinite(normal) || !plagueGlassCameraFinite(geometric)
            || !plagueGlassCameraFinite(view) || !plagueGlassCameraFinite(albedo)
            || !(material.alpha>0.0)) return -1;
    float nv=dot(normal,view);
    if(nv<=0.0 || dot(geometric,view)<=0.0) return 0;
    vec3 h;
    if(usePrimaryDraw) {
        // Advance the original stream exactly as the two primary uniforms would. Downstream
        // interface and Fresnel draws retain a separate pseudorandom stream and their meanings.
        plagueGlassRandom(state);plagueGlassRandom(state);
        h=plagueGlassCameraNormalDraw(view,normal,material.alpha,primaryDraw);
    } else h=plagueGlassVisibleNormal(-view,normal,material.alpha,state);
    vec3 incoming=reflect(-view,h);
    // No resampling: rejected geometric/shading hemispheres retain their probability mass.
    if(dot(geometric,incoming)<=0.0 || dot(normal,incoming)<=0.0) return 0;
    // Heitz (2014): exact GGX VNDF reflection f*cos/pdf = F*G2/G1. D cancels;
    // the directional-light response cap is not part of sampled radiance transport.
    // Preserve labPBR's absent-reflectance gate used by the material BRDF.
    vec3 present=step(vec3(0.5/255.0),plagueMaterialF0(material,albedo));
    vec3 response=plagueFresnel(material,albedo,max(dot(view,h),0.0))*present
        *plagueGlassMaskWeight(-view,incoming,normal,material.alpha);
    if(!plagueGlassCameraFinite(response)) return -1;
    if(!any(greaterThan(response,vec3(0.0)))) return 0;
    vec3 incident;
    int status=plagueGlassCameraRadiance(plagueGlassBoundaryOffset(point,geometric,geometric),
        incoming,state,budget,incident);
    if(status<0) plagueGlassCameraIndirectAvailable=false;
    plagueGlassCameraIndirect*=response;
    if(!plagueGlassCameraFinite(plagueGlassCameraIndirect)) {
        plagueGlassCameraIndirect=vec3(0.0);plagueGlassCameraIndirectAvailable=false;
    }
    if(status!=1) return status;
    radiance=response*incident;
    if(!plagueGlassCameraFinite(radiance)) { radiance=vec3(0.0);return -1; }
    return any(greaterThan(radiance,vec3(0.0)))?1:0;
}
// Preserve the original hash-sampled API for all existing callers and fixtures.
int plagueGlassCameraSpecular(vec3 point,vec3 normal,vec3 geometric,vec3 view,PlagueMaterial material,
        vec3 albedo,inout uint state,int budget,out vec3 radiance) {
    return plagueGlassCameraSpecularCore(point,normal,geometric,view,material,albedo,state,budget,
        vec2(0.0),false,radiance);
}
int plagueGlassCameraSpecularSequence(vec3 point,vec3 normal,vec3 geometric,vec3 view,PlagueMaterial material,
        vec3 albedo,inout uint state,int budget,uint receiverSeed,uint sampleIndex,out vec3 radiance) {
    return plagueGlassCameraSpecularCore(point,normal,geometric,view,material,albedo,state,budget,
        plagueGlassCameraPrimaryDraw(receiverSeed,sampleIndex),true,radiance);
}
#endif
