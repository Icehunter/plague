#ifndef PLAGUE_GLASS_GLOSSY_HISTORY
#define PLAGUE_GLASS_GLOSSY_HISTORY
#ifndef PLAGUE_GLASS_GATHER_OUTPUT_SHIFT
#define PLAGUE_GLASS_GATHER_OUTPUT_SHIFT 0
#endif
// Fornax binds storage=true targets, including .history, as storage images. Sampler
// declarations compile offline but make the live Vulkan pipeline fail to build.
layout(rgba32f,set=0,binding=18) uniform readonly image2D u_GlossyHistoryPrevious;
layout(rgba32f,set=0,binding=19) uniform readonly image2D u_GlossySurfacePrevious;
layout(rgba32f,set=0,binding=20) uniform readonly image2D u_GlossySignaturePrevious;
layout(rgba32f,set=0,binding=21) uniform readonly image2D u_GlossyStatePrevious;
layout(rgba32f,set=0,binding=24+PLAGUE_GLASS_GATHER_OUTPUT_SHIFT) uniform writeonly image2D u_GlossyHistory;
layout(rgba32f,set=0,binding=25+PLAGUE_GLASS_GATHER_OUTPUT_SHIFT) uniform writeonly image2D u_GlossySurface;
layout(rgba32f,set=0,binding=26+PLAGUE_GLASS_GATHER_OUTPUT_SHIFT) uniform writeonly image2D u_GlossySignature;
layout(rgba32f,set=0,binding=27+PLAGUE_GLASS_GATHER_OUTPUT_SHIFT) uniform writeonly image2D u_GlossyState;
// Float32 represents every integer through 2^24 exactly. Reserve one batch before
// exhaustion so stationary means keep converging without repeated sample indices.
const float PLAGUE_GLASS_GLOSSY_HISTORY_SAMPLES=16777216.0-float(PLAGUE_GLASS_GLOSSY_SAMPLES);
shared uint plagueGlassGlossyFrameAccepted;
bool plagueGlassGlossyFinite(vec4 value) { return !any(isnan(value)) && !any(isinf(value)); }

// RGB8_UNORM is Fornax's GMaterial/GAlbedo ABI. Numeric RGB24 integers fit float32 exactly;
// bitcasting into a float instead would permit NaN canonicalization to destroy the signature.
float plagueGlassGlossyRgb24(vec3 colour) {
    uvec3 bytes=uvec3(round(clamp(colour,0.0,1.0)*255.0));
    return float(bytes.x|(bytes.y<<8u)|(bytes.z<<16u));
}
bool plagueGlassGlossyFrameReady(ivec2 size) {
    if(!plagueGlassCameraReady()
            || (plagueGlassCameraCacheWord(1)!=0u
                && plagueGlassCameraCacheWord(PLAGUE_GLASS_CACHE_HISTORY_REASON)!=16u)
            || any(notEqual(u_CameraDelta.xyz,vec3(0.0)))
            || any(notEqual(u_JitterOffset,u_PrevJitterOffset))) return false;
    if(any(notEqual(imageSize(u_GlossyHistoryPrevious),size))
            || any(notEqual(imageSize(u_GlossySurfacePrevious),size))
            || any(notEqual(imageSize(u_GlossySignaturePrevious),size))
            || any(notEqual(imageSize(u_GlossyStatePrevious),ivec2(5,1)))) return false;
    vec4 state=imageLoad(u_GlossyStatePrevious,ivec2(4,0));
    // The engine frame counter wraps at 720720. A disabled/gapped pass cannot resurrect history.
    float previous=float((uint(u_FrameState.x)+720719u)%720720u);
    if(!all(equal(state,vec4(previous,float(PLAGUE_GLASS_GLOSSY_SAMPLES),u_WorldBounds.w,1.0)))) return false;
    for(int column=0;column<4;++column)
        if(any(notEqual(imageLoad(u_GlossyStatePrevious,ivec2(column,0)),u_InvProjModelViewNoJitter[column]))) return false;
    return true;
}
void plagueGlassGlossyPublishState(ivec2 pixel) {
    if(pixel.y==0 && pixel.x<5) {
        vec4 value=pixel.x<4?u_InvProjModelViewNoJitter[pixel.x]
            :vec4(u_FrameState.x,float(PLAGUE_GLASS_GLOSSY_SAMPLES),u_WorldBounds.w,1.0);
        imageStore(u_GlossyState,pixel,value);
    }
}
bool plagueGlassGlossyGeometryReady(vec3 receiverCache) {
    if(plagueGlassCameraCacheWord(1)==0u) return true;
    if(plagueGlassCameraCacheWord(PLAGUE_GLASS_CACHE_HISTORY_REASON)!=16u) return false;
    ivec3 anchor=ivec3(plagueGlassCameraCacheWord(4),plagueGlassCameraCacheWord(5),plagueGlassCameraCacheWord(6));
    ivec3 low,high;
    for(int axis=0;axis<3;++axis) {
        low[axis]=int(plagueGlassCameraCacheWord(PLAGUE_GLASS_CACHE_HISTORY_LO+axis));
        high[axis]=int(plagueGlassCameraCacheWord(PLAGUE_GLASS_CACHE_HISTORY_HI+axis));
    }
    if(any(greaterThan(low,high))) return false;
    vec3 lo=vec3(low-anchor),hi=vec3(high-anchor);
    vec3 separation=max(max(lo-receiverCache,receiverCache-hi),vec3(0.0));
    // A camera endpoint is at most PATH_REACH from this receiver, and any contributing
    // GI photon path is at most PATH_REACH from its deposit (density support radius0.5).
    // A reconstructed last leg may end elsewhere on its saved finite face: run spans are
    // four-bit+1, and box coordinates are five-bit /16. Thus maximum face diameter
    // is(15+31/16)*sqrt(2), including source-contact runs and protruding models.
    // Sum of triangle-inequality bounds also covers grazing rays; no angle division is used.
    // One block conservatively covers all16 transport events' epsilon offsets/probes and
    // float error in camera-relative coordinates (epsilon=1/4096, endpoints offset<=10eps).
    float reach=max(float(PLAGUE_GLASS_PATH_REACH),float(PLAGUE_LOCAL_REACH));
    float radius=2.0*reach+PLAGUE_GI_PHOTON_RADIUS+(15.0+31.0/16.0)*sqrt(2.0)+1.0;
    return dot(separation,separation)>radius*radius;
}
bool plagueGlassGlossyReceiverReady(vec4 old,vec4 oldSurface,vec4 oldSignature,
        vec4 surface,vec3 signature,vec3 receiverCache) {
    // Exact depth avoids an unproved world-space disocclusion tolerance. Jitter changes reset
    // above; this deliberately accumulates stationary, unjittered receivers only.
    return plagueGlassGlossyFrameAccepted!=0u && plagueGlassGlossyGeometryReady(receiverCache)
        && plagueGlassGlossyFinite(old)
        && plagueGlassGlossyFinite(oldSignature) && all(greaterThanEqual(old.rgb,vec3(0.0)))
        && old.a>=1.0 && old.a<=PLAGUE_GLASS_GLOSSY_HISTORY_SAMPLES && old.a==floor(old.a)
        && all(equal(oldSurface,surface)) && all(equal(oldSignature.xyz,signature))
        && oldSignature.w>=old.a && oldSignature.w==floor(oldSignature.w)
        // Both count and sequence must retain exact integer increments; exhaustion resets history.
        && oldSignature.w<=16777216.0-float(PLAGUE_GLASS_GLOSSY_SAMPLES);
}
vec4 plagueGlassGlossyAccumulate(vec4 old,vec3 batchSum) {
    float count=float(PLAGUE_GLASS_GLOSSY_SAMPLES);
    float total=old.a+count;
    // Cumulative arithmetic mean: a fixed EMA retains temporal variance after warmup.
    // Mixing batch means also avoids multiplying bright finite radiance by a large count.
    return vec4(mix(old.rgb,batchSum/count,count/total),total);
}
#endif
