#ifndef PLAGUE_GLASS_BEAM_VISIBILITY
#define PLAGUE_GLASS_BEAM_VISIBILITY
#moj_import <fornax_runtime:glass_scene.glsl>

float plagueGlassBeamBoxMaximum(vec3 lo,vec3 hi,vec3 normal) {
    return dot(max(normal,vec3(0.0)),hi)+dot(min(normal,vec3(0.0)),lo);
}

int plagueGlassBeamPlaneAxis(vec3 normal) {
    // Certified model-box faces have an exact signed coordinate axis, not a fitted normal.
    if(abs(normal.x)==1.0 && normal.y==0.0 && normal.z==0.0) return 0;
    if(abs(normal.y)==1.0 && normal.x==0.0 && normal.z==0.0) return 1;
    if(abs(normal.z)==1.0 && normal.x==0.0 && normal.y==0.0) return 2;
    return -1;
}

bool plagueGlassBeamExitSupport(vec3 sweptLo,vec3 sweptHi,vec4 exitPlane,vec3 exitLo,vec3 exitHi,
        bool endpointSource) {
    int axis=plagueGlassBeamPlaneAxis(exitPlane.xyz);
    if(axis<0) return false;
    float coordinate=exitPlane.w/exitPlane[axis];
    if(coordinate<sweptLo[axis] || coordinate>sweptHi[axis]) return false;
    vec3 faceLo=exitLo,faceHi=exitHi;
    faceLo[axis]=coordinate; faceHi[axis]=coordinate;
    if(any(lessThan(faceLo,exitLo)) || any(greaterThan(faceHi,exitHi))) return false;
    // A compound bounding box is not a continuous face. Certify the saved rectangle
    // against one actual box face. Every angular query must still lie inside this rectangle.
    vec3 inside=(faceLo+faceHi)*0.5-exitPlane.xyz*(PLAGUE_GLASS_EPSILON*2.0);
    ivec3 cell=ivec3(floor(plagueGlassGridOrigin()+inside));
    int entry=plagueGlassCell(cell);
    if(entry<0 || plagueGlassMedium(entry).glass==endpointSource) return false;
    uint flags=plagueGlassPaletteWord(entry*16);
    if(endpointSource && (flags&0xc0000000u)!=0u) return false;
    int count=int(flags&15u);
    if(count>8) return false;
    vec3 cellOrigin=vec3(cell)-plagueGlassGridOrigin();
    for(int box=0;box<max(count,1);++box) {
        vec3 lo,hi; plagueGlassBox(entry,box,lo,hi);
        lo+=cellOrigin; hi+=cellOrigin;
        float boxPlane=exitPlane[axis]>0.0 ? hi[axis] : lo[axis];
        if(abs(boxPlane-coordinate)>PLAGUE_GLASS_EPSILON) continue;
        lo[axis]=coordinate; hi[axis]=coordinate;
        if(all(greaterThanEqual(faceLo,lo)) && all(lessThanEqual(faceHi,hi))) return true;
    }
    return false;
}

// All positions share the active glass scene frame. A false result means uncertain, not blocked.
// A true result still requires the per-query exit-domain check. Bounds enclose every segment.
bool plagueGlassBeamCertifyLastLeg(vec3 sweptLo,vec3 sweptHi,vec4 exitPlane,
        vec3 exitLo,vec3 exitHi,vec3 receiverPoint,vec3 receiverNormal,bool endpointSource) {
    if(!plagueGlassBuffersValid() || any(isnan(sweptLo)) || any(isnan(sweptHi))
            || any(isinf(sweptLo)) || any(isinf(sweptHi)) || any(greaterThan(sweptLo,sweptHi))
            || any(isnan(exitPlane)) || any(isinf(exitPlane))
            || any(isnan(exitLo)) || any(isinf(exitLo)) || any(isnan(exitHi)) || any(isinf(exitHi))
            || any(isnan(receiverPoint)) || any(isinf(receiverPoint))
            || any(isnan(receiverNormal)) || any(isinf(receiverNormal)) || dot(receiverNormal,receiverNormal)<=0.0) return false;
    // The volume certificate proves an air segment. A homogeneous glass leg remains valid,
    // but needs per-query medium/occlusion traversal rather than an empty-volume certificate.
    if(plagueGlassAt(plagueGlassBoundaryOffset(receiverPoint,receiverNormal,receiverNormal)).glass) return false;
    if(!plagueGlassBeamExitSupport(sweptLo,sweptHi,exitPlane,exitLo,exitHi,endpointSource)) return false;
    vec3 gridOffset=plagueGlassGridOrigin();
    ivec3 first=ivec3(floor(sweptLo+gridOffset)),last=ivec3(floor(sweptHi+gridOffset));
    ivec3 extent=last-first+1;
    // Reuse the optical traversal's existing cell-work budget. Large volumes fall back to
    // individual rays; reducing this bound affects cost, never the meaning of a clear result.
    if(any(lessThanEqual(extent,ivec3(0))) || any(greaterThan(extent,ivec3(PLAGUE_GLASS_STEPS)))) return false;
    if(extent.x*extent.y*extent.z>PLAGUE_GLASS_STEPS) return false;
    float receiverPlane=dot(receiverPoint,receiverNormal);
    for(int z=first.z;z<=last.z;++z) for(int y=first.y;y<=last.y;++y) for(int x=first.x;x<=last.x;++x) {
        ivec3 cell=ivec3(x,y,z);
        vec3 cellOrigin=vec3(cell)-gridOffset;
        vec3 regionLo=max(cellOrigin,sweptLo),regionHi=min(cellOrigin+vec3(1.0),sweptHi);
        if(any(greaterThan(regionLo,regionHi))) continue;
        if(plagueGlassBeamBoxMaximum(regionLo,regionHi,exitPlane.xyz)<=exitPlane.w
                || plagueGlassBeamBoxMaximum(regionLo,regionHi,receiverNormal)<=receiverPlane) continue;
        int entry=plagueGlassCell(cell);
        if(entry==-2) return false;
        if(entry<0) continue;
        uint flags=plagueGlassPaletteWord(entry*16);
        int count=int(flags&15u);
        // CROSS/cutout transparency cannot establish that a whole continuous volume is clear.
        // Its exact coverage is still available to the per-query optical tracer.
        if((flags&0x80000000u)!=0u || count>8) return false;
        for(int box=0;box<max(count,1);++box) {
            vec3 lo,hi; plagueGlassBox(entry,box,lo,hi);
            // Match the optical boxes' half-open bounds. A sweep entirely on a box's excluded
            // high face has no interior intersection; its included low face remains uncertain.
            if(any(greaterThanEqual(sweptLo,cellOrigin+hi)) || any(lessThan(sweptHi,cellOrigin+lo))) continue;
            lo=max(cellOrigin+lo,regionLo); hi=min(cellOrigin+hi,regionHi);
            if(any(greaterThan(lo,hi))) continue;
            if(plagueGlassBeamBoxMaximum(lo,hi,exitPlane.xyz)<=exitPlane.w
                    || plagueGlassBeamBoxMaximum(lo,hi,receiverNormal)<=receiverPlane) continue;
            // Another glass interface also changes the path family. Only a genuinely empty
            // open segment receives the fast certificate; material transparency is insufficient.
            return false;
        }
    }
    return true;
}

// receiverOriginScene must already use plagueGlassBoundaryOffset toward incoming with the
// receiver's geometric normal. Cache-to-scene is cacheOrigin-cameraOrigin in the gather pass.
bool plagueGlassBeamLastLegDomain(vec3 receiverOriginScene,vec3 incoming,vec4 exitPlaneCache,
        vec3 exitLoCache,vec3 exitHiCache,vec3 cacheOriginMinusSceneOrigin,out float distance) {
    distance=0.0;
    vec3 normal=exitPlaneCache.xyz;
    int axis=plagueGlassBeamPlaneAxis(normal);
    if(axis<0) return false;
    float plane=exitPlaneCache.w+dot(normal,cacheOriginMinusSceneOrigin);
    float denominator=dot(normal,incoming);
    if(denominator>=0.0) return false;
    distance=(plane-dot(normal,receiverOriginScene))/denominator;
    if(isnan(distance) || isinf(distance) || distance<=PLAGUE_GLASS_EPSILON) return false;
    vec3 endpoint=receiverOriginScene+incoming*distance;
    endpoint[axis]=plane/normal[axis];
    vec3 lo=exitLoCache+cacheOriginMinusSceneOrigin,hi=exitHiCache+cacheOriginMinusSceneOrigin;
    if(any(lessThan(endpoint,lo)) || any(greaterThan(endpoint,hi))) return false;
    return true;
}

// Even a certified empty volume has finite exit support. This cheap domain test is required
// for every angular sample, unless the entire angular integration domain was clipped to it.
bool plagueGlassBeamLastLegSupported(vec3 receiverOriginScene,vec3 incoming,vec4 exitPlaneCache,
        vec3 exitLoCache,vec3 exitHiCache,vec3 cacheOriginMinusSceneOrigin) {
    float distance;
    return plagueGlassBeamLastLegDomain(receiverOriginScene,incoming,exitPlaneCache,
        exitLoCache,exitHiCache,cacheOriginMinusSceneOrigin,distance);
}

bool plagueGlassBeamLastLegVisible(vec3 receiverOriginScene,vec3 incoming,vec4 exitPlaneCache,
        vec3 exitLoCache,vec3 exitHiCache,vec3 cacheOriginMinusSceneOrigin,bool endpointSource) {
    float distance;
    if(!plagueGlassBeamLastLegDomain(receiverOriginScene,incoming,exitPlaneCache,
            exitLoCache,exitHiCache,cacheOriginMinusSceneOrigin,distance)) return false;
    vec3 normal=exitPlaneCache.xyz;
    int axis=plagueGlassBeamPlaneAxis(normal);
    float plane=exitPlaneCache.w+dot(normal,cacheOriginMinusSceneOrigin);
    vec3 lo=exitLoCache+cacheOriginMinusSceneOrigin,hi=exitHiCache+cacheOriginMinusSceneOrigin;
    vec3 origin=receiverOriginScene;
    if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+origin)))==-2) return false;
    PlagueGlassMedium medium=plagueGlassAt(origin);
    // A straight last leg may cross model seams inside one identical medium. A physical
    // optical interface would change its direction or throughput and is never skipped here.
    for(int boundary=0;boundary<PLAGUE_GLASS_INTERFACES;++boundary) {
        float remaining=(plane-dot(normal,origin))/dot(normal,incoming);
        if(remaining<=PLAGUE_GLASS_EPSILON) return false;
        PlagueGlassHit hit;
        int status=plagueGlassTrace(origin,incoming,remaining+PLAGUE_GLASS_EPSILON*2.0,false,hit);
        if(status!=1) return false;
        vec3 hitOnPlane=hit.position;
        hitOnPlane[axis]=plane/normal[axis];
        bool endpoint=abs(dot(hit.normal,normal))==1.0
            && abs(hit.distance-remaining)<=PLAGUE_GLASS_EPSILON*2.0
            && abs(dot(normal,hit.position)-plane)<=PLAGUE_GLASS_EPSILON*2.0
            && all(greaterThanEqual(hitOnPlane,lo)) && all(lessThanEqual(hitOnPlane,hi));
        // Source bounds come from a homogeneous emitting run in the source inventory. Its
        // exact opaque face must still exist: a hole or a closer opaque surface is not a source.
        if(endpoint) {
            if(!endpointSource) return hit.glass;
            if(!hit.glass) return true;
            // A source touching glass shares its plane with the glass model's final face.
            // The trace reports that face first; prove the opaque source on its opposite side.
            return plagueGlassBeamExitSupport(hitOnPlane,hitOnPlane,vec4(normal,plane),
                hitOnPlane,hitOnPlane,true);
        }
        if(!hit.glass || hit.distance>=remaining) return false;
        vec3 nextOrigin=plagueGlassBoundaryOffset(hit.position,incoming,hit.normal);
        if(plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+nextOrigin)))==-2) return false;
        PlagueGlassMedium next=plagueGlassAt(nextOrigin);
        if(next.glass!=medium.glass || next.ior!=medium.ior || next.roughness!=medium.roughness
                || any(notEqual(next.absorption,medium.absorption))) return false;
        origin=nextOrigin;
    }
    return false;
}

bool plagueGlassBeamLastLegSupported(vec3 receiverOriginScene,vec3 incoming,vec4 exitPlaneCache,
        vec3 exitLoCache,vec3 exitHiCache,vec3 cacheOriginMinusSceneOrigin,bool endpointSource) {
    return plagueGlassBeamLastLegSupported(receiverOriginScene,incoming,exitPlaneCache,
        exitLoCache,exitHiCache,cacheOriginMinusSceneOrigin);
}

bool plagueGlassBeamLastLegVisible(vec3 receiverOriginScene,vec3 incoming,vec4 exitPlaneCache,
        vec3 exitLoCache,vec3 exitHiCache,vec3 cacheOriginMinusSceneOrigin) {
    return plagueGlassBeamLastLegVisible(receiverOriginScene,incoming,exitPlaneCache,
        exitLoCache,exitHiCache,cacheOriginMinusSceneOrigin,false);
}

bool plagueGlassBeamCertifyLastLeg(vec3 sweptLo,vec3 sweptHi,vec4 exitPlane,
        vec3 exitLo,vec3 exitHi,vec3 receiverPoint,vec3 receiverNormal) {
    return plagueGlassBeamCertifyLastLeg(sweptLo,sweptHi,exitPlane,exitLo,exitHi,receiverPoint,receiverNormal,false);
}
#endif
