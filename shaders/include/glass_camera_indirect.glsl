#ifndef PLAGUE_GLASS_CAMERA_INDIRECT
#define PLAGUE_GLASS_CAMERA_INDIRECT
#moj_import <fornax_runtime:glass_gi_photons.glsl>
#moj_import <fornax_runtime:glass_camera_direct.glsl>

// Disjoint endpoint families: cached photons supply source paths that touched glass; one
// direct area-source draw supplies clear-air paths. The camera leg need not cross a pane.
int plagueGlassCameraOpaqueIndirect(PlagueGlassHit hit,vec3 direction,inout uint state,out vec3 radiance) {
    radiance=vec3(0.0);
    if(dot(hit.normal,-direction)<=0.0) return 0;
    vec2 uv;vec3 tint;
    if(!plagueGlassUv(hit.entry,hit.local,hit.normal,uv,tint)) return -1;
    vec3 encoded=plagueGlassMaterial(uv).rgb;
    PlagueMaterial material=plagueDecodeMaterial(encoded.r,encoded.g,encoded.b);
    // labPBR conductors absorb the transmitted share; a Lambert continuation must not
    // invent diffuse transport through their opaque endpoint.
    if(material.metalness==1.0) return 0;
    vec3 local,sun;
    if(!plagueGiPhotonIrradiance(hit.position,hit.normal,local,sun)) return -1;
    vec3 albedo=plagueSrgbToLinear(plagueGlassAlbedo(uv).rgb)*tint;
    vec3 direct;
    if(plagueGlassCameraOpaqueDirect(hit,-direction,material,albedo,state,direct)<0) return -1;
    // Lambert's diffuse radiance is irradiance * reflectance / pi, as in gi_resolve.
    radiance=direct+local*albedo*((1.0-material.metalness)/PLAGUE_PI);
    if(any(isnan(radiance)) || any(isinf(radiance))) {radiance=vec3(0.0);return -1;}
    return any(greaterThan(radiance,vec3(0.0)))?1:0;
}
#endif
