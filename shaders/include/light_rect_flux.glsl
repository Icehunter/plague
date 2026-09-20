#ifndef PLAGUE_LIGHT_RECT_FLUX
#define PLAGUE_LIGHT_RECT_FLUX
// The light a flat rectangle of uniform brightness delivers to one point, as a vector.
//
// Its length is how much arrives and its direction is where from, so dotting it with a surface
// normal gives that surface's share exactly: no sampling, no pieces, right at any size and any
// distance. Points spread over a rectangle cannot do that. A floor lying on a bright sheet reads
// a small fraction of the light it should, and cutting the rectangle finer closes the gap far too
// slowly to rescue.
//
// The sum runs over the rectangle's edges: each edge contributes the angle it subtends, pointing
// along the normal of the wedge it and the point make. Lambert, "Photometria", 1760; the vector
// form is Arvo, "The Irradiance Jacobian for Partially Occluded Polyhedral Sources", SIGGRAPH 1994.
vec3 plagueLocalRectFlux(vec3 c0,vec3 c1,vec3 c2,vec3 c3,vec3 point) {
    vec3 v0=normalize(c0-point),v1=normalize(c1-point);
    vec3 v2=normalize(c2-point),v3=normalize(c3-point);
    vec3 flux=vec3(0.0);
    vec3 e=cross(v0,v1); float len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v0,v1),-1.0,1.0))*(e/len);
    e=cross(v1,v2); len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v1,v2),-1.0,1.0))*(e/len);
    e=cross(v2,v3); len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v2,v3),-1.0,1.0))*(e/len);
    e=cross(v3,v0); len=length(e);
    if(len>1e-8) flux+=acos(clamp(dot(v3,v0),-1.0,1.0))*(e/len);
    return 0.5*flux;
}
#endif
