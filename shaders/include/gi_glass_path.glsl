#ifndef PLAGUE_GI_GLASS_PATH
#define PLAGUE_GI_GLASS_PATH

// Two uvec4s per original GI sample. Status is independent of the native hit tier:
// a disabled query may answer as a miss, but must never become a sky sample.
const uint PLAGUE_GI_PATH_DISABLED = 0u;
const uint PLAGUE_GI_PATH_ACTIVE = 1u;
const uint PLAGUE_GI_PATH_TERMINAL = 2u;
const uint PLAGUE_GI_PATH_ZERO = 3u;
const uint PLAGUE_GI_PATH_UNKNOWN = 4u;
struct PlagueGiGlassPath {
    vec3 throughput;
    uint status;
    vec3 bearing;
    uint randomState;
};
PlagueGiGlassPath plagueGiGlassPathDecode(uvec4 weight, uvec4 initial) {
    return PlagueGiGlassPath(uintBitsToFloat(weight.xyz),weight.w,
        uintBitsToFloat(initial.xyz),initial.w);
}
uvec4 plagueGiGlassPathWeight(PlagueGiGlassPath path) {
    return uvec4(floatBitsToUint(path.throughput),path.status);
}
uvec4 plagueGiGlassPathInitial(PlagueGiGlassPath path) {
    return uvec4(floatBitsToUint(path.bearing),path.randomState);
}

#ifdef PLAGUE_GI_GLASS_PATH_TRANSPORT
// The caller includes glass_compute_scene first. Keeping optics behind this guard lets the
// final GI evaluator share the state ABI without declaring another optical descriptor set.
bool plagueGiGlassFinite(vec3 value) {
    return !any(isnan(value)) && !any(isinf(value));
}
void plagueGiGlassStop(inout PlagueGiGlassPath path, uint status) {
    path.status=status;
    if(status==PLAGUE_GI_PATH_ZERO) path.throughput=vec3(0.0);
}

// One straight segment is validated by the actual native closest hit BEFORE changing direction.
// The glass-only traversal is bounded strictly by that distance: an opaque boundary at the
// same distance wins, including a receiver touching the glass exit. No voxel opaque hit is
// substituted for native UV/tint/normal metadata. The finalizer sets allowBoundary=false.
void plagueGiGlassAdvance(inout vec4 originAndMin,inout vec4 directionAndMax,
        inout PlagueGiGlassPath path,uint nativeHit[9],bool allowBoundary) {
    if(path.status!=PLAGUE_GI_PATH_ACTIVE) return;
    if(nativeHit[7]==0u || !plagueGlassBuffersValid()) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    vec3 origin=originAndMin.xyz;
    vec3 rawDirection=directionAndMax.xyz;
    float reach=directionAndMax.w,minimum=originAndMin.w;
    float nativeDistance=uintBitsToFloat(nativeHit[0]);
    if(!plagueGiGlassFinite(origin) || !plagueGiGlassFinite(rawDirection)
            || dot(rawDirection,rawDirection)<=0.0 || isnan(reach) || isinf(reach)
            || isnan(minimum) || isinf(minimum) || minimum<0.0 || reach<=minimum
            || isnan(nativeDistance) || isinf(nativeDistance)) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    vec3 direction=normalize(rawDirection);
    if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+origin)))==-2) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    PlagueGlassMedium current=plagueGlassAt(origin);
    float limit=nativeDistance>=0.0 ? min(reach,nativeDistance) : reach;
    if(limit<minimum) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    if(minimum>0.0) {
        // Native geometry cannot validate a bend inside its excluded interval. Even an
        // air-to-air slab hidden wholly below tMin needs transport, so comparing only the
        // two endpoint media is insufficient. Hold this sample instead of skipping it.
        PlagueGlassHit excluded;
        // Translate the helper's epsilon start to zero, including boundaries closer than
        // epsilon to the original origin. The ordinary native interval starts at tMin.
        if(plagueGlassTrace(origin-direction*PLAGUE_GLASS_EPSILON,direction,
                minimum+PLAGUE_GLASS_EPSILON,true,excluded)!=0) {
            plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
        }
    }
    // plagueGlassTrace starts at its shared epsilon. Translating by (tMin-epsilon)
    // preserves the native interval start instead of silently tracing below request.tMin.
    float shift=minimum-PLAGUE_GLASS_EPSILON;
    PlagueGlassHit boundary;
    int optical=plagueGlassTrace(origin+direction*shift,direction,limit-shift,true,boundary);
    if(optical<0) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    if(optical==0) {
        // A finite ray that remains inside glass has not established a sky escape.
        if(nativeDistance<0.0 && current.glass) {
            plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
        }
        path.throughput*=plagueGlassAttenuation(current.absorption,limit);
        plagueGiGlassStop(path,max(path.throughput.x,max(path.throughput.y,path.throughput.z))>0.0
            ? PLAGUE_GI_PATH_TERMINAL : PLAGUE_GI_PATH_ZERO);
        return;
    }
    if(!allowBoundary) {
        // Work exhaustion is unavailable; the resolve holds history rather than adding black.
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    float distance=boundary.distance+shift;
    path.throughput*=plagueGlassAttenuation(current.absorption,distance);
    if(max(path.throughput.x,max(path.throughput.y,path.throughput.z))<=0.0) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_ZERO); return;
    }
    vec3 after=plagueGlassBoundaryOffset(boundary.position,direction,boundary.normal);
    if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+after)))==-2) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    PlagueGlassMedium next=plagueGlassAt(after);
    vec3 outgoing=direction;
    if(current.ior!=next.ior) {
        vec3 normal=dot(direction,boundary.normal)<0.0 ? boundary.normal : -boundary.normal;
        float alpha=max(current.glass?current.roughness:0.0,next.glass?next.roughness:0.0);
        vec3 microfacet=plagueGlassVisibleNormal(direction,normal,alpha,path.randomState);
        vec3 transmitted; float fresnel;
        bool canTransmit=plagueGlassInterface(direction,microfacet,current.ior,next.ior,transmitted,fresnel);
        bool reflected=!canTransmit || plagueGlassRandom(path.randomState)<fresnel;
        outgoing=reflected ? reflect(direction,microfacet) : transmitted;
        float side=dot(outgoing,normal);
        if((reflected && side<=0.0) || (!reflected && side>=0.0)) {
            plagueGiGlassStop(path,PLAGUE_GI_PATH_ZERO); return;
        }
        // Radiance transport across Snell refraction scales by (incident IOR / outgoing IOR)^2.
        // Fresnel branch probabilities cancel their own BSDF factors. Walter et al. (2007):
        // Microfacet Models for Refraction through Rough Surfaces; Smith G2/G1 is shared with
        // the existing flux tracer. Photon transport is deliberately unaffected by this mode.
        if(!reflected) {
            float eta=current.ior/next.ior;
            path.throughput*=eta*eta;
        }
        path.throughput*=plagueGlassMaskWeight(direction,outgoing,normal,alpha);
    }
    if(!plagueGiGlassFinite(path.throughput) || !plagueGiGlassFinite(outgoing)) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    if(max(path.throughput.x,max(path.throughput.y,path.throughput.z))<=0.0) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_ZERO); return;
    }
    float remaining=reach-distance;
    if(remaining<=PLAGUE_GLASS_EPSILON) {
        plagueGiGlassStop(path,PLAGUE_GI_PATH_UNKNOWN); return;
    }
    // As in the existing optical tracer, numerical boundary offsets do not reset path reach.
    // The offset already excludes the departed face; reusing GI's 0.001 tMin here would skip
    // close receivers. Native and optical queries both receive this same continued interval.
    originAndMin=vec4(plagueGlassBoundaryOffset(boundary.position,outgoing,boundary.normal),0.0);
    directionAndMax=vec4(outgoing,remaining);
}
#endif
#endif
