#ifndef PLAGUE_GLASS_CAMERA_DIRECT
#define PLAGUE_GLASS_CAMERA_DIRECT
// Caller supplies the same admitted source cache as camera emitter lookup.
uint plagueGlassCameraCacheWord(int word);
int plagueGlassCameraCacheSize();

// Covers only this path: source -> air -> opaque camera endpoint. Source -> glass ->
// opaque paths already belong to the GI photon map, including refraction/caustics; accepting
// them here would count that illumination twice. Unknown geometry invalidates history.
int plagueGlassCameraOpaqueDirect(PlagueGlassHit hit,vec3 view,PlagueMaterial material,
        vec3 albedo,inout uint state,out vec3 radiance) {
    radiance=vec3(0.0);
    uint count=plagueGlassCameraCacheWord(2),rows=plagueGlassCameraCacheWord(7);
    if(plagueGlassCameraCacheSize()!=PLAGUE_GLASS_CACHE_WORDS
            || plagueGlassCameraCacheWord(0)!=PLAGUE_GLASS_CACHE_TAG
            || count>uint(PLAGUE_LOCAL_CAPACITY) || rows>uint(PLAGUE_LOCAL_CAPACITY)) return -1;
    float total=0.0,selectedWeight=0.0;
    vec3 selectedLo=vec3(0.0),selectedHi=vec3(0.0),selectedNormal=vec3(0.0),selectedLe=vec3(0.0);
    int selectedU=0,selectedV=0;
    // Weighted reservoir sampling gives one area source probability w/sum(w). Importance
    // may approximate distance; the returned estimator uses the exact sampled geometry/PDF.
    for(uint lane=0u;lane<count;++lane) {
        uint source=plagueGlassCameraCacheWord(PLAGUE_GLASS_CACHE_SOURCES+int(lane));
        if(source>=rows) return -1;
        int row=PLAGUE_GLASS_CACHE_ROWS+int(source)*PLAGUE_LOCAL_RECORD_WORDS;
        if(plagueGlassCameraCacheWord(row+6)!=1u) continue;
        uint run=plagueGlassCameraCacheWord(row+PLAGUE_LOCAL_RECORD_RUN);
        int face=plagueLocalRunFace(run);
        if(face>5) return -1;
        int axis=face<2?1:face<4?2:0,uAxis=face<4?0:1,vAxis=face<2?2:face<4?1:2;
        vec3 normal=plagueLocalNormal(face),lo,hi;
        plagueLocalUnpackBox(plagueGlassCameraCacheWord(row+PLAGUE_LOCAL_RECORD_BOX),lo,hi);
        vec2 span=plagueLocalRunSpan(run);
        hi[uAxis]+=span.x-1.0;hi[vAxis]+=span.y-1.0;
        float plane=(face&1)==0?lo[axis]:hi[axis];lo[axis]=plane;hi[axis]=plane;
        vec3 origin=vec3(ivec3(plagueGlassCameraCacheWord(row),plagueGlassCameraCacheWord(row+1),
            plagueGlassCameraCacheWord(row+2)))-PLAGUE_GLASS_SCENE_ORIGIN;
        lo+=origin;hi+=origin;
        vec3 centre=(lo+hi)*0.5,extent=(hi-lo)*0.5;
        if(dot(normal,hit.position-centre)<=0.0
                || dot(hit.normal,centre-hit.position)+dot(abs(hit.normal),extent)<=0.0) continue;
        vec3 separation=max(max(lo-hit.position,hit.position-hi),vec3(0.0));
        if(dot(separation,separation)>=PLAGUE_LOCAL_REACH*PLAGUE_LOCAL_REACH) continue;
        float area=(hi[uAxis]-lo[uAxis])*(hi[vAxis]-lo[vAxis]);
        // Existing source representation: mean radiance of the emitting run's face quarters,
        // matching photon launch Le. This is not a per-texel emission reconstruction.
        vec3 le=uintBitsToFloat(uvec3(plagueGlassCameraCacheWord(row+11),
            plagueGlassCameraCacheWord(row+15),plagueGlassCameraCacheWord(row+19)));
        if(any(isnan(le)) || any(isinf(le))) return -1;
        le=max(le,vec3(0.0));
        // Linear-sRGB luminance has positive support for every nonzero nonnegative source.
        float importance=dot(le,vec3(0.2126,0.7152,0.0722))*area
            /max(dot(centre-hit.position,centre-hit.position),PLAGUE_GLASS_EPSILON*PLAGUE_GLASS_EPSILON);
        if(!(importance>0.0)) continue;
        total+=importance;
        if(plagueGlassRandom(state)*total<=importance) {
            selectedWeight=importance;selectedLo=lo;selectedHi=hi;selectedNormal=normal;
            selectedLe=le;selectedU=uAxis;selectedV=vAxis;
        }
    }
    if(!(selectedWeight>0.0)) return 0;
    if(isnan(total) || isinf(total)) return -1;
    vec3 target=selectedLo;
    target[selectedU]=mix(selectedLo[selectedU],selectedHi[selectedU],plagueGlassRandom(state));
    target[selectedV]=mix(selectedLo[selectedV],selectedHi[selectedV],plagueGlassRandom(state));
    vec3 displacement=target-hit.position;
    float distance2=dot(displacement,displacement),distance=sqrt(distance2);
    if(!(distance>PLAGUE_GLASS_EPSILON)) return 0;
    vec3 light=displacement/distance;
    float sourceCosine=max(dot(selectedNormal,-light),0.0);
    if(dot(hit.normal,light)<=0.0 || sourceCosine<=0.0) return 0;
    vec3 start=plagueGlassBoundaryOffset(hit.position,hit.normal,hit.normal);
    vec3 end=target+selectedNormal*PLAGUE_GLASS_EPSILON*2.0;
    vec3 segment=end-start;float reach=length(segment);
    if(!(reach>0.0)) return 0;
    if(plagueGlassAt(start).glass) return 0;
    PlagueGlassHit blocker;
    int status=plagueGlassTrace(start,segment/reach,reach,false,blocker);
    if(status<0) return -1;
    if(status>0) return 0; // Opaque blocker or glass-family path, both exact zero here.
    float area=(selectedHi[selectedU]-selectedLo[selectedU])*(selectedHi[selectedV]-selectedLo[selectedV]);
    // Area-light rendering equation: dA * cos(source)/r^2 times the cosine-bearing diffuse
    // BRDF. Divide by p(source)*p(area); one shadow segment, independent of source count.
    radiance=selectedLe*albedo*plagueEvaluateBrdf(material,albedo,hit.normal,view,light).diffuse
        *(area*sourceCosine*total/(distance2*selectedWeight))*plagueLocalFalloff(distance);
    return any(greaterThan(radiance,vec3(0.0)))?1:0;
}
#endif
