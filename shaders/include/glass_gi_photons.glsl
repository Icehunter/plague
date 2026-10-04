#ifndef PLAGUE_GLASS_GI_PHOTONS
#define PLAGUE_GLASS_GI_PHOTONS
#moj_import <fornax_runtime:glass_photons.glsl>
#moj_import <fornax_runtime:glass_photon_cache.glsl>
#moj_import <fornax_runtime:glass_beam.glsl>
#moj_import <fornax_runtime:glass_beam_visibility.glsl>

bool plagueGiPhotonCellSupported(ivec3 cell,vec3 point,vec3 normal) {
    vec3 lo=vec3(cell)*PLAGUE_GI_PHOTON_HASH_CELL-point;
    vec3 hi=lo+vec3(PLAGUE_GI_PHOTON_HASH_CELL);
    // Closed bounds conservatively enclose the half-open bin. Expand by the existing
    // geometric epsilon to avoid rejecting support at floating-point cell boundaries.
    lo-=vec3(PLAGUE_GLASS_EPSILON); hi+=vec3(PLAGUE_GLASS_EPSILON);
    vec3 closest=max(max(lo,-hi),vec3(0.0));
    if(dot(closest,closest)>PLAGUE_GI_PHOTON_RADIUS*PLAGUE_GI_PHOTON_RADIUS) return false;
    vec3 positive=max(normal,vec3(0.0)),negative=min(normal,vec3(0.0));
    float minimum=dot(positive,lo)+dot(negative,hi);
    float maximum=dot(positive,hi)+dot(negative,lo);
    return minimum<=PLAGUE_GLASS_EPSILON*8.0 && maximum>=-PLAGUE_GLASS_EPSILON*8.0;
}

// A world-space density estimate at an opaque GI hit, including off-screen receivers.
// False is unavailable and must hold GI history; a valid empty index is an answered zero.
// Camera-only work/variance budget. Exact reference is zero; GI resolve always stays exact.
// Default four: actual frame65 matched-camera replay cut dispatch333ms to153ms with
// empirical equal-time variance0.46x across floor/wall/metal regions; no brightness tuning.
bool plagueGiPhotonIrradianceExact(vec3 point,vec3 geometric,out vec3 local,out vec3 sun,out vec3 higher) {
    local=vec3(0.0); sun=vec3(0.0); higher=vec3(0.0);
    if(!plagueGlassBuffersValid() || giPhotonCache.length()<7
            || giPhotonCache[0]!=PLAGUE_GLASS_CACHE_TAG
            || giPhotonHeads.length()<int(PLAGUE_GLASS_HASH_SIZE)
            || giPhotonLinks.length()<int(PLAGUE_GLASS_PHOTONS)
            || giPhotonWords.length()<int(PLAGUE_GLASS_PHOTONS*PLAGUE_GLASS_PHOTON_WORDS)
            || giPhotonBeams.length()<int(PLAGUE_GLASS_PHOTONS*PLAGUE_GLASS_BEAM_WORDS)) return false;
    if(any(isnan(point)) || any(isinf(point)) || any(isnan(geometric))
            || any(isinf(geometric)) || dot(geometric,geometric)<=0.0) return false;
    vec3 cacheOrigin=vec3(ivec3(giPhotonCache[4],giPhotonCache[5],giPhotonCache[6]));
    vec3 transportPoint=point+(u_CameraAbs-cacheOrigin);
    // Captured-scene replay: classify this exact origin once, lazily when a beam needs it.
    // Scene/palette/atlas inputs must remain immutable during this dispatch. Unknown origin
    // rejects only that visibility candidate; a valid empty photon index still answers zero.
    vec3 receiverOrigin=plagueGlassBoundaryOffset(point,geometric,geometric);
    bool receiverReady=false,receiverValid=false;
    PlagueGlassMedium receiverMedium=PlagueGlassMedium(false,1.0,vec3(0.0),0.0);
    vec3 radius=vec3(PLAGUE_GI_PHOTON_RADIUS);
    ivec3 first=ivec3(floor((transportPoint-radius)/PLAGUE_GI_PHOTON_HASH_CELL));
    ivec3 last=ivec3(floor((transportPoint+radius)/PLAGUE_GI_PHOTON_HASH_CELL));
    // Receiver bank eligibility is invariant across cells. Keep all six original axis
    // predicates, including multiple supported banks for finite non-unit query normals.
    uint supportedBanks=1u; // Generic-bank bit zero is always visited.
    for(uint bank=1u;bank<7u;++bank)
        if(plagueGlassNormalBankSupported(bank,geometric)) supportedBanks|=1u<<bank;
    for(int z=first.z;z<=last.z;++z) for(int y=first.y;y<=last.y;++y) for(int x=first.x;x<=last.x;++x) {
        ivec3 cell=ivec3(x,y,z);
        // Skip only cells whose entire volume is outside the unchanged density support.
        // Malformed records in unvisited buckets cannot be diagnosed by this local lookup.
        if(!plagueGiPhotonCellSupported(cell,transportPoint,geometric)) continue;
        // Shared masked cell hash plus the unchanged bank stride. Ascending set-bit order
        // preserves the exact irradiance sum order and all malformed-record validation.
        uint cellBucket=plagueGlassNormalBucket(cell,0u);
        for(uint banks=supportedBanks;banks!=0u;banks&=banks-1u) {
            uint bank=uint(findLSB(banks));
            uint bucket=cellBucket+bank*(PLAGUE_GLASS_HASH_SIZE/PLAGUE_GLASS_NORMAL_BANKS);
            uint node=giPhotonHeads[bucket],visits=0u;
            while(node!=0u) {
                if(node>PLAGUE_GLASS_PHOTONS || visits++>=PLAGUE_GLASS_PHOTONS) return false;
                uint index=node-1u,base=index*PLAGUE_GLASS_PHOTON_WORDS;
                node=giPhotonLinks[index];
                vec4 photon=giPhotonWords[base];
                if(photon.w==0.0 || any(isnan(photon)) || any(isinf(photon))) return false;
                // Different queried cells can share a hash bucket. Count a record only in its
                // actual cell, or the same photon can add energy several times at a boundary.
                if(any(notEqual(ivec3(floor(photon.xyz/PLAGUE_GI_PHOTON_HASH_CELL)),cell))) continue;
                vec4 energy=giPhotonWords[base+1u];
                if(energy.a!=0.0 && energy.a!=2.0) continue;
                vec3 difference=photon.xyz-transportPoint;
                vec3 receiverNormal=giPhotonWords[base+3u].xyz;
                // Keep the primary gather's receiver-plane and normal certification; the wider
                // GI radius changes only the tangential density footprint.
                // Axis banks were certified by the exact signed-axis predicate above.
                if((bank==0u && dot(receiverNormal,geometric)<0.99)
                        || abs(dot(difference,geometric))>PLAGUE_GLASS_EPSILON*8.0) continue;
                float squaredDistance=dot(difference,difference);
                if(squaredDistance>=PLAGUE_GI_PHOTON_RADIUS*PLAGUE_GI_PHOTON_RADIUS) continue;
                vec3 incoming=giPhotonWords[base+2u].xyz;
                if(dot(geometric,incoming)<=0.0) continue;
                uint beamBase=index*PLAGUE_GLASS_BEAM_WORDS;
                if(giPhotonBeams[beamBase+5u].w==-2.0 || giPhotonBeams[beamBase+5u].w==-4.0) {
                    if(!receiverReady) {
                        receiverReady=true;
                        receiverValid=plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+receiverOrigin)))!=-2;
                        if(receiverValid) receiverMedium=plagueGlassAt(receiverOrigin);
                    }
                    if(!receiverValid) continue;
                    bool opaqueEndpoint=giPhotonBeams[beamBase+5u].w==-4.0;
                    bool visible=plagueGlassBeamLastLegVisibleInMedium(receiverOrigin,incoming,
                        giPhotonBeams[beamBase+6u],giPhotonBeams[beamBase+7u].xyz,
                        giPhotonBeams[beamBase+8u].xyz,cacheOrigin-u_CameraAbs,
                        !opaqueEndpoint && (int(giPhotonBeams[beamBase+9u].w)&65536)!=0,
                        receiverMedium,opaqueEndpoint);
                    if(!visible) continue;
                }
                if(any(isnan(energy)) || any(isinf(energy))) return false;
                // Flux per receiving area already includes the geometric cosine and source
                // sampling probability. The caller applies the secondary Lambert BRDF once.
                if(energy.a==2.0) higher+=energy.rgb*plagueGiPhotonKernel(squaredDistance);
                else local+=energy.rgb*plagueGiPhotonKernel(squaredDistance);
            }
        }
    }
    return true;
}
#if PLAGUE_GLASS_VISIBILITY_SAMPLES > 0
bool plagueGiPhotonIrradianceSampledTry(vec3 point,vec3 geometric,out vec3 local,out vec3 sun,out vec3 higher,out bool needsExact) {
    needsExact=false;
    local=vec3(0.0); sun=vec3(0.0); higher=vec3(0.0);
    if(!plagueGlassBuffersValid() || giPhotonCache.length()<7
            || giPhotonCache[0]!=PLAGUE_GLASS_CACHE_TAG
            || giPhotonHeads.length()<int(PLAGUE_GLASS_HASH_SIZE)
            || giPhotonLinks.length()<int(PLAGUE_GLASS_PHOTONS)
            || giPhotonWords.length()<int(PLAGUE_GLASS_PHOTONS*PLAGUE_GLASS_PHOTON_WORDS)
            || giPhotonBeams.length()<int(PLAGUE_GLASS_PHOTONS*PLAGUE_GLASS_BEAM_WORDS)) return false;
    if(any(isnan(point)) || any(isinf(point)) || any(isnan(geometric))
            || any(isinf(geometric)) || dot(geometric,geometric)<=0.0) return false;
    vec3 cacheOrigin=vec3(ivec3(giPhotonCache[4],giPhotonCache[5],giPhotonCache[6]));
    vec3 transportPoint=point+(u_CameraAbs-cacheOrigin);
    // Captured-scene replay: classify this exact origin once, lazily when a beam needs it.
    // Scene/palette/atlas inputs must remain immutable during this dispatch. Unknown origin
    // rejects only that visibility candidate; a valid empty photon index still answers zero.
    vec3 receiverOrigin=plagueGlassBoundaryOffset(point,geometric,geometric);
    bool receiverReady=false,receiverValid=false;
    PlagueGlassMedium receiverMedium=PlagueGlassMedium(false,1.0,vec3(0.0),0.0);
    // Talbot, Cline & Egbert (2005), Importance Resampling for Global Illumination,
    // https://doi.org/10.2312/EGWR/EGSR05/139-146; own discrete derivation below.
    // Weighted online reservoir: each trial selects i with probability w_i / sum(w).
    // Hence C_i * sum(w) / w_i is an unbiased estimator of sum(C_i); independent
    // trials are averaged. abs(max channel) allows signed exceptional flux too.
    uint selected[PLAGUE_GLASS_VISIBILITY_SAMPLES];
    float selectedWeight[PLAGUE_GLASS_VISIBILITY_SAMPLES];
    vec3 selectedFlux[PLAGUE_GLASS_VISIBILITY_SAMPLES];
    uint selectionState=plagueGlassHash(uint(u_FrameState.x));
    vec3 worldPoint=point+u_CameraAbs;
    selectionState=plagueGlassHash(selectionState^floatBitsToUint(worldPoint.x));
    selectionState=plagueGlassHash(selectionState^floatBitsToUint(worldPoint.y));
    selectionState=plagueGlassHash(selectionState^floatBitsToUint(worldPoint.z));
    selectionState=plagueGlassHash(selectionState^floatBitsToUint(geometric.x));
    selectionState=plagueGlassHash(selectionState^floatBitsToUint(geometric.y));
    selectionState=plagueGlassHash(selectionState^floatBitsToUint(geometric.z));
    float totalWeight=0.0; bool exceptional=false;
    for(int trial=0;trial<PLAGUE_GLASS_VISIBILITY_SAMPLES;++trial) {
        selected[trial]=0xffffffffu; selectedWeight[trial]=0.0; selectedFlux[trial]=vec3(0.0);
    }
    vec3 radius=vec3(PLAGUE_GI_PHOTON_RADIUS);
    ivec3 first=ivec3(floor((transportPoint-radius)/PLAGUE_GI_PHOTON_HASH_CELL));
    ivec3 last=ivec3(floor((transportPoint+radius)/PLAGUE_GI_PHOTON_HASH_CELL));
    // Bank support depends only on this receiver. Retain every original predicate,
    // including multiple axis banks for non-unit query normals; visit them in ascending order.
    uint supportedBanks=1u; // Bit zero is the always-supported generic bank.
    for(uint bank=1u;bank<7u;++bank)
        if(plagueGlassNormalBankSupported(bank,geometric)) supportedBanks|=1u<<bank;
    for(int z=first.z;z<=last.z;++z) for(int y=first.y;y<=last.y;++y) for(int x=first.x;x<=last.x;++x) {
        ivec3 cell=ivec3(x,y,z);
        // Skip only cells whose entire volume is outside the unchanged density support.
        // Malformed records in unvisited buckets cannot be diagnosed by this local lookup.
        if(!plagueGiPhotonCellSupported(cell,transportPoint,geometric)) continue;
        // All banks use the same masked cell hash. Compute it once, then add the original
        // bank stride; this preserves buckets, candidate order, and reservoir RNG order.
        uint cellBucket=plagueGlassNormalBucket(cell,0u);
        for(uint banks=supportedBanks;banks!=0u;banks&=banks-1u) {
            uint bank=uint(findLSB(banks));
            uint bucket=cellBucket+bank*(PLAGUE_GLASS_HASH_SIZE/PLAGUE_GLASS_NORMAL_BANKS);
            uint node=giPhotonHeads[bucket],visits=0u;
            while(node!=0u) {
                if(node>PLAGUE_GLASS_PHOTONS || visits++>=PLAGUE_GLASS_PHOTONS) return false;
                uint index=node-1u,base=index*PLAGUE_GLASS_PHOTON_WORDS;
                node=giPhotonLinks[index];
                vec4 photon=giPhotonWords[base];
                if(photon.w==0.0 || any(isnan(photon)) || any(isinf(photon))) return false;
                // Different queried cells can share a hash bucket. Count a record only in its
                // actual cell, or the same photon can add energy several times at a boundary.
                if(any(notEqual(ivec3(floor(photon.xyz/PLAGUE_GI_PHOTON_HASH_CELL)),cell))) continue;
                vec4 energy=giPhotonWords[base+1u];
                if(energy.a!=0.0 && energy.a!=2.0) continue;
                vec3 difference=photon.xyz-transportPoint;
                vec3 receiverNormal=giPhotonWords[base+3u].xyz;
                // Keep the primary gather's receiver-plane and normal certification; the wider
                // GI radius changes only the tangential density footprint.
                // Axis banks were certified by the exact signed-axis predicate above.
                if((bank==0u && dot(receiverNormal,geometric)<0.99)
                        || abs(dot(difference,geometric))>PLAGUE_GLASS_EPSILON*8.0) continue;
                float squaredDistance=dot(difference,difference);
                if(squaredDistance>=PLAGUE_GI_PHOTON_RADIUS*PLAGUE_GI_PHOTON_RADIUS) continue;
                vec3 incoming=giPhotonWords[base+2u].xyz;
                if(dot(geometric,incoming)<=0.0) continue;
                // Preserve the exact reference's exceptional-data policy, which checks flux
                // only after visibility. Re-run that reference if a proposal cannot be formed.
                if(any(isnan(energy)) || any(isinf(energy)))
                    { exceptional=true; continue; }
                uint candidateBeam=index*PLAGUE_GLASS_BEAM_WORDS;
                if(giPhotonBeams[candidateBeam+5u].w==-2.0 || giPhotonBeams[candidateBeam+5u].w==-4.0) {
                    float candidateDistance;
                    if(!plagueGlassBeamLastLegDomain(receiverOrigin,incoming,
                            giPhotonBeams[candidateBeam+6u],giPhotonBeams[candidateBeam+7u].xyz,
                            giPhotonBeams[candidateBeam+8u].xyz,cacheOrigin-u_CameraAbs,
                            candidateDistance)) continue;
                    if(!receiverReady) {
                        receiverReady=true;
                        receiverValid=plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+receiverOrigin)))!=-2;
                        if(receiverValid) receiverMedium=plagueGlassAt(receiverOrigin);
                    }
                    if(!receiverValid) continue;
                }
                vec3 flux=energy.rgb*plagueGiPhotonKernel(squaredDistance);
                float weight=max(max(abs(flux.x),abs(flux.y)),abs(flux.z));
                if(isnan(weight) || isinf(weight) || isinf(totalWeight+weight))
                    { exceptional=true; continue; }
                if(weight<=0.0) continue;
                totalWeight+=weight;
                for(int trial=0;trial<PLAGUE_GLASS_VISIBILITY_SAMPLES;++trial) {
                    if(plagueGlassRandom(selectionState)*totalWeight<weight) {
                        selected[trial]=index; selectedWeight[trial]=weight; selectedFlux[trial]=flux;
                    }
                }
            }
        }
    }
    if(exceptional) { needsExact=true; return false; }
    // Each reservoir lane retains its own contribution. Visibility is deterministic for
    // a repeated photon at this receiver, so cache its answer in one bit per lane.
    // The declared visibility budgets use at most eight lanes, within a uint's bits.
    uint visibilityMask=0u;
    for(int trial=0;trial<PLAGUE_GLASS_VISIBILITY_SAMPLES;++trial) {
        uint index=selected[trial];
        if(index==0xffffffffu) continue;
        uint base=index*PLAGUE_GLASS_PHOTON_WORDS,beamBase=index*PLAGUE_GLASS_BEAM_WORDS;
        bool repeated=false,visible=true;
        for(int prior=0;prior<trial;++prior) {
            if(selected[prior]==index) {
                visible=(visibilityMask&(1u<<uint(prior)))!=0u;
                repeated=true;
                break;
            }
        }
        if(!repeated) {
            vec3 incoming=giPhotonWords[base+2u].xyz;
            if(giPhotonBeams[beamBase+5u].w==-2.0 || giPhotonBeams[beamBase+5u].w==-4.0) {
                if(!receiverReady) {
                    receiverReady=true;
                    receiverValid=plagueGlassCell(ivec3(floor(plagueGlassGridOrigin()+receiverOrigin)))!=-2;
                    if(receiverValid) receiverMedium=plagueGlassAt(receiverOrigin);
                }
                visible=receiverValid;
                if(visible) {
                    bool opaqueEndpoint=giPhotonBeams[beamBase+5u].w==-4.0;
                    visible=plagueGlassBeamLastLegVisibleInMedium(receiverOrigin,incoming,
                        giPhotonBeams[beamBase+6u],giPhotonBeams[beamBase+7u].xyz,
                        giPhotonBeams[beamBase+8u].xyz,cacheOrigin-u_CameraAbs,
                        !opaqueEndpoint && (int(giPhotonBeams[beamBase+9u].w)&65536)!=0,
                        receiverMedium,opaqueEndpoint);
                }
            }
        }
        if(visible) visibilityMask|=1u<<uint(trial);
        if(!visible) continue;
        vec3 contribution=(selectedFlux[trial]/selectedWeight[trial])
            *(totalWeight/float(PLAGUE_GLASS_VISIBILITY_SAMPLES));
        if(any(isnan(contribution)) || any(isinf(contribution)))
            { needsExact=true; return false; }
        if(giPhotonWords[base+1u].a==2.0) higher+=contribution;
        else local+=contribution;
    }
    return true;
}
// Exceptional proposals rerun the exact policy once; ordinary unavailable results retain
// their original outputs and status. Keeping one call site avoids duplicating the large
// exact traversal when the native compiler inlines this camera endpoint helper.
bool plagueGiPhotonIrradianceSampled(vec3 point,vec3 geometric,out vec3 local,out vec3 sun,out vec3 higher) {
    bool needsExact;
    bool available=plagueGiPhotonIrradianceSampledTry(point,geometric,local,sun,higher,needsExact);
    if(needsExact) return plagueGiPhotonIrradianceExact(point,geometric,local,sun,higher);
    return available;
}

#endif
// GI resolve applies a nonlinear first-hit overlap subtraction; its estimate must stay exact.
bool plagueGiPhotonIrradiance(vec3 point,vec3 geometric,out vec3 local,out vec3 sun,out vec3 higher) {
    return plagueGiPhotonIrradianceExact(point,geometric,local,sun,higher);
}
// Camera endpoints consume the sum of both path families exactly once. GI resolve keeps
// them separate because only first-hit transmission overlaps its direct lamp estimator.
bool plagueGiPhotonIrradiance(vec3 point,vec3 geometric,out vec3 local,out vec3 sun) {
    vec3 higher;
    #if PLAGUE_GLASS_VISIBILITY_SAMPLES > 0
    bool available=plagueGiPhotonIrradianceSampled(point,geometric,local,sun,higher);
#else
    bool available=plagueGiPhotonIrradianceExact(point,geometric,local,sun,higher);
#endif
    local+=higher;
    return available;
}
#endif
