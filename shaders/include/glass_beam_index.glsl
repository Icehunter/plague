#ifndef PLAGUE_GLASS_BEAM_INDEX
#define PLAGUE_GLASS_BEAM_INDEX
#moj_import <fornax_runtime:glass_photons.glsl>

// A rectangle no wider than its level's tile crosses at most two tiles on either axis.
// Four owned nodes per photon therefore cover every support, without an admission counter.
const uint PLAGUE_GLASS_BEAM_LINKS_PER_PHOTON=4u;
// Sixteen raster pixels is the base indexing tile; it changes candidate work, never light support.
const uint PLAGUE_GLASS_BEAM_TILE=16u;
const uint PLAGUE_GLASS_BEAM_INDEX_HEADS=65536u; // One hash head per allocated photon.

int plagueGlassBeamLevelForExtent(uint extent) {
    uint side=PLAGUE_GLASS_BEAM_TILE;
    int level=0;
    // Positive signed texture dimensions fit before the uint side reaches 2^31.
    while(side<extent) { side<<=1; ++level; }
    return level;
}
int plagueGlassBeamTopLevel(ivec2 size) {
    return plagueGlassBeamLevelForExtent(uint(max(size.x,size.y)));
}
ivec3 plagueGlassBeamCell(ivec2 pixel,int level) {
    return ivec3(uvec2(pixel)/(PLAGUE_GLASS_BEAM_TILE<<uint(level)),uint(level));
}
uint plagueGlassBeamIndexBucket(ivec3 key) {
    uint mixed=plagueGlassHash(uint(key.x));
    mixed=plagueGlassHash(mixed^uint(key.y));
    return plagueGlassHash(mixed^uint(key.z))&(PLAGUE_GLASS_BEAM_INDEX_HEADS-1u);
}

bool plagueGlassBeamIndexBounds(mat4 clipFromCache,vec3 centre,vec3 extent0,vec3 extent1,
        vec3 extent2,ivec2 size,out ivec2 lower,out ivec2 upper,out int level) {
    vec2 minimum=vec2(1.0),maximum=vec2(-1.0);
    int front=0;
    bool unknown=false;
    for(int corner=0;corner<8;++corner) {
        vec3 point=centre+extent0*((corner&1)==0?-1.0:1.0)
                +extent1*((corner&2)==0?-1.0:1.0)+extent2*((corner&4)==0?-1.0:1.0);
        vec4 clip=clipFromCache*vec4(point,1.0);
        if(any(isnan(clip))||any(isinf(clip))) { unknown=true; continue; }
        if(clip.w<=0.0) continue;
        ++front;
        vec2 ndc=clip.xy/clip.w;
        if(any(isnan(ndc))||any(isinf(ndc))) { unknown=true; continue; }
        if(front==1) { minimum=ndc; maximum=ndc; }
        else { minimum=min(minimum,ndc); maximum=max(maximum,ndc); }
    }
    lower=ivec2(0); upper=size-1; level=plagueGlassBeamTopLevel(size);
    if(unknown || (front>0 && front<8)) return true; // Near-eye support belongs to the global level.
    if(front==0 || any(lessThan(maximum,vec2(-1.0))) || any(greaterThan(minimum,vec2(1.0)))) return false;
    vec2 first=(clamp(minimum,vec2(-1.0),vec2(1.0))*0.5+0.5)*vec2(size)-0.5;
    vec2 last=(clamp(maximum,vec2(-1.0),vec2(1.0))*0.5+0.5)*vec2(size)-0.5;
    // Outward rounding includes the raster footprint of boundary pixels, including odd extents.
    lower=clamp(ivec2(floor(first)),ivec2(0),size-1);
    upper=clamp(ivec2(ceil(last)),ivec2(0),size-1);
    level=plagueGlassBeamLevelForExtent(uint(max(upper.x-lower.x,upper.y-lower.y)+1));
    return true;
}
#endif
