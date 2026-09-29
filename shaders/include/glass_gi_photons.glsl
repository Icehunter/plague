#ifndef PLAGUE_GLASS_GI_PHOTONS
#define PLAGUE_GLASS_GI_PHOTONS
#moj_import <fornax_runtime:glass_photons.glsl>
#moj_import <fornax_runtime:glass_photon_cache.glsl>
#moj_import <fornax_runtime:glass_beam.glsl>
#moj_import <fornax_runtime:glass_beam_visibility.glsl>

// A world-space density estimate at an opaque GI hit, including off-screen receivers.
// False is unavailable and must hold GI history; a valid empty index is an answered zero.
bool plagueGiPhotonIrradiance(vec3 point,vec3 geometric,out vec3 local,out vec3 sun) {
    local=vec3(0.0); sun=vec3(0.0);
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
    vec3 radius=vec3(PLAGUE_GLASS_GATHER_RADIUS);
    ivec3 first=ivec3(floor((transportPoint-radius)/PLAGUE_GLASS_HASH_CELL));
    ivec3 last=ivec3(floor((transportPoint+radius)/PLAGUE_GLASS_HASH_CELL));
    for(int z=first.z;z<=last.z;++z) for(int y=first.y;y<=last.y;++y) for(int x=first.x;x<=last.x;++x) {
        ivec3 cell=ivec3(x,y,z);
        uint node=giPhotonHeads[plagueGlassBucket(cell)],visits=0u;
        while(node!=0u) {
            if(node>PLAGUE_GLASS_PHOTONS || visits++>=PLAGUE_GLASS_PHOTONS) return false;
            uint index=node-1u,base=index*PLAGUE_GLASS_PHOTON_WORDS;
            node=giPhotonLinks[index];
            vec4 photon=giPhotonWords[base];
            if(photon.w==0.0 || any(isnan(photon)) || any(isinf(photon))) return false;
            // Different queried cells can share a hash bucket. Count a record only in its
            // actual cell, or the same photon can add energy several times at a boundary.
            if(any(notEqual(ivec3(floor(photon.xyz/PLAGUE_GLASS_HASH_CELL)),cell))) continue;
            vec4 energy=giPhotonWords[base+1u];
            if(energy.a!=0.0) continue;
            vec3 difference=photon.xyz-transportPoint;
            vec3 receiverNormal=giPhotonWords[base+3u].xyz;
            // Identical acceptance footprint to the primary surface photon gather.
            if(dot(receiverNormal,geometric)<0.99
                    || abs(dot(difference,geometric))>PLAGUE_GLASS_EPSILON*8.0) continue;
            float squaredDistance=dot(difference,difference);
            if(squaredDistance>=PLAGUE_GLASS_GATHER_RADIUS*PLAGUE_GLASS_GATHER_RADIUS) continue;
            vec3 incoming=giPhotonWords[base+2u].xyz;
            if(dot(geometric,incoming)<=0.0) continue;
            uint beamBase=index*PLAGUE_GLASS_BEAM_WORDS;
            if(giPhotonBeams[beamBase+5u].w==-2.0 && !plagueGlassBeamLastLegVisible(
                    plagueGlassBoundaryOffset(point,geometric,geometric),incoming,
                    giPhotonBeams[beamBase+6u],giPhotonBeams[beamBase+7u].xyz,
                    giPhotonBeams[beamBase+8u].xyz,cacheOrigin-u_CameraAbs,
                    (int(giPhotonBeams[beamBase+9u].w)&65536)!=0)) continue;
            if(any(isnan(energy)) || any(isinf(energy))) return false;
            // Flux per receiving area already includes the geometric cosine and source
            // sampling probability. The caller applies the secondary Lambert BRDF once.
            local+=energy.rgb*plagueGlassKernel(squaredDistance);
        }
    }
    return true;
}
#endif
