#moj_import <fornax_runtime:voxel_palette_layout.glsl>
#ifndef PLAGUE_VOXEL_LOCAL_LIGHT
#define PLAGUE_VOXEL_LOCAL_LIGHT
// How many shadow rays one pixel may spend on local lights.
//
// Every sample still offers its light. The budget only decides which of them get asked whether
// something stands in the way, and the answer from those carries the rest. It bites on a surface
// made of emitters, where the samples nearly all give the same answer anyway.
//
// Primary visibility draws this many stratified samples from the complete emitter distribution.
// Reflected surfaces have no primary-view denominator and retain the bounded probe walk.
//
// Twenty-four because one glowstone offers exactly that: six faces, four probes each, and it
// spends every ray it asks for.
const int PLAGUE_LOCAL_RAY_BUDGET = 24;
const int PLAGUE_LOCAL_RAY_CEILING = 48;
#moj_import <fornax_runtime:voxel_local_layout.glsl>
#moj_import <fornax_runtime:voxel_visibility.glsl>
#moj_import <fornax_runtime:light_rect_flux.glsl>
#ifdef PLAGUE_VOXEL_ENTITY_OCCLUDERS
#moj_import <fornax_runtime:entity_occluders.glsl>
#endif
// The existing light reservoir's 32-bit LCG; the upper 24 bits fit exactly in a float.
float plagueLocalDraw(inout uint state) {
    state=state*747796405u+2891336453u;
    return float(state>>8)/16777216.0;
}
// Caller supplies source word/size accessors, the 2D dither (taken in uniform control flow) and
// voxel_coverage traversal. Primary and reflected surfaces use the same finite segment query;
// there is no screen or receiver-quadrant cache.
bool plagueLocalReceiverBuffersValid() {
    int d=u_VoxelWindow.w;
    return textureSize(u_VoxelOccupancy)==d*d*d*128 && textureSize(u_VoxelPayload)==d*d*d*1024
            && plagueVoxelPaletteCapacity(textureSize(u_VoxelPalette),d)>0 && textureSize(u_VoxelBrickSummary)==d*d*d;
}
int plagueLocalReceiverCapacity() { return plagueVoxelPaletteCapacity(textureSize(u_VoxelPalette),u_VoxelWindow.w); }
bool plagueLocalReceiverFacesValid() { int d=u_VoxelWindow.w; return plagueVoxelMaterialBuffersValid(textureSize(u_VoxelPalette),textureSize(u_Input10),d); }
uint plagueLocalReceiverOccupancy(int word) { return texelFetch(u_VoxelOccupancy,word).r; }
uint plagueLocalReceiverPayload(int word) { return texelFetch(u_VoxelPayload,word).r; }
uint plagueLocalReceiverPalette(int word) { return texelFetch(u_VoxelPalette,word).r; }
uint plagueLocalReceiverSummary(int word) { return texelFetch(u_VoxelBrickSummary,word).r; }
uint plagueLocalReceiverFace(int word) { return texelFetch(u_Input10,word).r; }
#moj_import <fornax_runtime:local_light_receiver.glsl>
#moj_import <fornax_runtime:local_light_source.glsl>
vec3 plagueLocalSegmentStart(vec3 point,vec3 geometricNormal) {
    return plagueLocalSurfacePoint(point,geometricNormal)+geometricNormal*PLAGUE_LOCAL_NUDGE;
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

// Which half of the answer this caller wants.
//
// The light is exact and smooth and carries the pixel's own texture, so it is worked out for every
// pixel. Whether something stands in the way is sampled and then averaged over frames and over
// neighbours before anything sees it, so it has no business being asked per pixel at all: that
// half runs on a smaller image and is stretched back over this one.
//
// Primary visibility uses the same BRDF as the unshadowed pass: a different weighting would
// shadow one emitter's colour with another emitter's ray.
//
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
        out vec3 visibility) {
    radiance=vec3(0.0);
    unshadowed=vec3(0.0);
    // Nothing offered reads as fully lit: a pixel no emitter reaches is not a shadowed pixel, and
    // zero here would paint it black once the two are multiplied.
    visibility=vec3(1.0);
    // Every sample's worth, which is what sets the bar a sample has to clear to earn a ray.
    float worth=0.0;
    // The worth of the samples a ray was actually spent on, and how much of it got through.
    vec3 offered=vec3(0.0);
    vec3 reached=vec3(0.0);
    int rays=0;
#ifdef PLAGUE_LOCAL_VISIBILITY_ONLY
    vec3 expectedLight=plagueLocalVisibilityDenominator();
    float expectedWorth=dot(expectedLight,vec3(0.2126,0.7152,0.0722));
    float sampleSpacing=expectedWorth/float(PLAGUE_LOCAL_RAY_BUDGET);
    uint sampleState=floatBitsToUint(jitterUV.x)^floatBitsToUint(jitterUV.y)*747796405u;
    float sampleOffset=plagueLocalDraw(sampleState);
    float samplePosition=sampleOffset*sampleSpacing;
#endif
    int d=u_VoxelWindow.w;
    if(d<1 || d>33 || plagueLocalSourceSize()!=PLAGUE_LOCAL_SOURCE_WORDS
            || plagueLocalSourceWord(0)!=2u || plagueLocalSourceWord(1)!=uint(PLAGUE_LOCAL_CAPACITY)
            || plagueLocalSourceWord(2)>uint(PLAGUE_LOCAL_CAPACITY)) return false;
    if(any(isnan(point)) || any(isinf(point)) || any(isnan(normal)) || any(isinf(normal))) return false;
    // Use the same unbiased model plane for source support and visibility. Captured grass at
    // y=72.9999986 admitted an entire below-ground lamp; its true y=73 plane rejects that source.
    point=plagueLocalSurfacePoint(point,geometricNormal);
    // Authored thin-sheet model: at maximum subsurface response half the diffuse energy goes
    // to each hemisphere. This splits diffuse energy; it adds no extra emitter power and gives
    // solid backing no transmission. It is a local sheet approximation, not a volume BSSRDF.
    float transmission=material.subsurface>0.0 && material.metalness<1.0
            && plagueLocalThinReceiver(point,geometricNormal) ? 0.5*material.subsurface : 0.0;
    PlagueLocalSourceIterator iterator=plagueLocalSourceBegin(point);
    if(!iterator.valid) return false;
    if(iterator.total==0u) return true;
    int base;
    while(plagueLocalSourceNext(iterator,base)) {
            PlagueLocalSource candidate;
            if(!plagueLocalSourceCandidate(base,point,geometricNormal,normal,viewDir,material,
                    albedo,transmission,candidate)) continue;
            vec3 offer=candidate.offer;
            vec3 sourceOrigin=candidate.sourceOrigin,sourceNormal=candidate.sourceNormal;
            vec2 rectLo=candidate.rectLo,faceSpan=candidate.faceSpan;
            float facePlane=candidate.facePlane,front=candidate.front;
            int face=candidate.face;
            unshadowed+=offer;

#if defined(PLAGUE_LOCAL_VISIBILITY_ONLY) || defined(PLAGUE_LOCAL_REFLECTED)
            // Everything above is exact and the same every frame. Only whether something stands
            // in the way is sampled, so only that is cut into pieces: each probe speaks for its
            // own share of the rectangle, and blocking one loses that share.
            //
            // Four, cut two by two, and the same four wherever the rectangle is. One probe
            // leaves a pixel's visibility at nothing or everything, and the jitter is locked to
            // world position, so the same point takes the same probe every frame. Varying the
            // count by distance puts a hard edge in the grain wherever the count changes.
            //
            // How many there are decides what the smoothing costs. Probes are rays, frames of
            // waiting are how long a block edit takes to land, and a wider filter over neighbours
            // eats the shadow edge. Four is what the frame rate affords; the wait is bought with
            // the other two instead. The ray budget bounds it.
            const int PLAGUE_LOCAL_PROBE_SIDE=2;
            const int PLAGUE_LOCAL_PROBES=PLAGUE_LOCAL_PROBE_SIDE*PLAGUE_LOCAL_PROBE_SIDE;
            float shareEach=dot(offer,vec3(0.2126,0.7152,0.0722))/float(PLAGUE_LOCAL_PROBES);
            for(int piece=0;piece<PLAGUE_LOCAL_PROBES;piece++) {
#ifdef PLAGUE_LOCAL_VISIBILITY_ONLY
                float endWorth=worth+shareEach;
                // Systematic importance sampling: one random offset on a uniform CDF lattice.
                // Each interval receives its RGB contribution divided by its sampling PDF.
                while(expectedWorth>0.0 && samplePosition<endWorth && rays<PLAGUE_LOCAL_RAY_BUDGET) {
                    vec2 pieceSize=faceSpan/float(PLAGUE_LOCAL_PROBE_SIDE);
                    vec2 pieceLo=rectLo+vec2(piece%PLAGUE_LOCAL_PROBE_SIDE,
                            piece/PLAGUE_LOCAL_PROBE_SIDE)*pieceSize;
                    float probeU=plagueLocalDraw(sampleState);
                    float probeV=plagueLocalDraw(sampleState);
                    vec2 probeST=pieceLo+pieceSize*vec2(probeU,probeV);
                    vec3 probe=sourceOrigin+(face<2 ? vec3(probeST.x,facePlane,probeST.y)
                            : face<4 ? vec3(probeST,facePlane) : vec3(facePlane,probeST));
                    if(plagueLocalSegment(point,front>0.0?geometricNormal:-geometricNormal,probe,sourceNormal))
                        reached+=offer*(sampleSpacing/(shareEach*float(PLAGUE_LOCAL_PROBES)));
                    rays++;
                    samplePosition=(float(rays)+sampleOffset)*sampleSpacing;
                }
                worth=endWorth;
#else
                worth+=shareEach;
                // The march is the expensive part, so it only runs while the budget holds.
                if(rays>=PLAGUE_LOCAL_RAY_CEILING
                        || shareEach*float(PLAGUE_LOCAL_RAY_BUDGET)<worth) continue;
                rays++;
                offered+=offer/float(PLAGUE_LOCAL_PROBES);
                // Neighbouring pixels asking about different parts of the piece is what a soft
                // edge is made of, and it lands in the visibility fraction alone, which is
                // filtered. R2 again, walked per piece so the probes spread rather than agree:
                // each step lands in the largest gap the earlier ones left. Roberts, "The
                // Unreasonable Effectiveness of Quasirandom Sequences", 2018.
                vec2 pieceSize=faceSpan/float(PLAGUE_LOCAL_PROBE_SIDE);
                vec2 pieceLo=rectLo+vec2(piece%PLAGUE_LOCAL_PROBE_SIDE,
                        piece/PLAGUE_LOCAL_PROBE_SIDE)*pieceSize;
                vec2 probeST=pieceLo+pieceSize*fract(jitterUV
                        +float(face*PLAGUE_LOCAL_PROBES+piece)
                                *vec2(0.7548776662466927,0.5698402909980532));
                vec3 probe=sourceOrigin+(face<2 ? vec3(probeST.x,facePlane,probeST.y)
                        : face<4 ? vec3(probeST,facePlane) : vec3(facePlane,probeST));
                if(plagueLocalSegment(point,front>0.0?geometricNormal:-geometricNormal,probe,sourceNormal)) {
                    reached+=offer/float(PLAGUE_LOCAL_PROBES);
                }
#endif
            }
#endif
    }
#ifdef PLAGUE_LOCAL_VISIBILITY_ONLY
    offered=expectedLight;
#endif
    for(int channel=0;channel<3;channel++)
        if(offered[channel]>0.0) visibility[channel]=reached[channel]/offered[channel];
    // The fraction measured from the samples that got a ray, applied to every sample's light.
    // Under the budget this is the same sum the marched samples alone would have given.
    radiance=unshadowed*visibility;
    return !any(isnan(radiance)) && !any(isinf(radiance))
            && !any(isnan(unshadowed)) && !any(isinf(unshadowed));
}
#endif
