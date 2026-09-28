#ifndef PLAGUE_GLASS_OPTICS
#define PLAGUE_GLASS_OPTICS

// Reference-distance convention: the resource's linear RGB is transmission through one block.
// Beer (1852), exponential absorption; this is a material convention, not measured glass spectra.
const float PLAGUE_GLASS_REFERENCE_DISTANCE = 1.0;
const float PLAGUE_GLASS_MIN_TRANSMISSION = 1.0 / 65535.0; // One unorm16 quantum keeps log finite.
// Retains the pack's existing unauthored dielectric F0 (labPBR byte 9).
const float PLAGUE_GLASS_FALLBACK_F0 = 9.0 / 255.0;
const float PLAGUE_GLASS_EPSILON = 1.0 / 4096.0; // Shared voxel geometric tolerance, in blocks.
// Work bounds: eight separate slabs need sixteen interfaces before internal reflections.
const int PLAGUE_GLASS_INTERFACES = 16;
const int PLAGUE_GLASS_STEPS = 192; // At most three crossings per block over a four-section ray.
const float PLAGUE_GLASS_VIEW_REACH = 64.0;

float plagueGlassIor(float f0) {
    float root = sqrt(clamp(f0 > 0.5 / 255.0 ? f0 : PLAGUE_GLASS_FALLBACK_F0,
                            0.0, 229.0 / 255.0)); // labPBR dielectric range.
    return (1.0 + root) / (1.0 - root);
}
vec3 plagueGlassAbsorption(vec3 referenceTransmission) {
    return -log(clamp(referenceTransmission, vec3(PLAGUE_GLASS_MIN_TRANSMISSION), vec3(1.0)))
            / PLAGUE_GLASS_REFERENCE_DISTANCE;
}
vec3 plagueGlassAttenuation(vec3 absorption, float distance) {
    return exp(-absorption * max(distance, 0.0));
}

// Fresnel's dielectric equations and Snell's law. The normal faces the incident medium.
// A false result is total internal reflection, not absorption or a zero-length transmitted ray.
bool plagueGlassInterface(vec3 incident, vec3 normal, float before, float after,
        out vec3 transmitted, out float reflectance) {
    float cosine = clamp(-dot(incident, normal), 0.0, 1.0);
    float eta = before / after;
    float sinSquared = eta * eta * max(0.0, 1.0 - cosine * cosine);
    transmitted = vec3(0.0);
    reflectance = 1.0;
    if (sinSquared >= 1.0) return false;
    float exitCosine = sqrt(max(0.0, 1.0 - sinSquared));
    float parallel = (after * cosine - before * exitCosine)
            / max(after * cosine + before * exitCosine, PLAGUE_GLASS_MIN_TRANSMISSION);
    float perpendicular = (before * cosine - after * exitCosine)
            / max(before * cosine + after * exitCosine, PLAGUE_GLASS_MIN_TRANSMISSION);
    reflectance = 0.5 * (parallel * parallel + perpendicular * perpendicular);
    transmitted = normalize(eta * incident + (eta * cosine - exitCosine) * normal);
    return true;
}

// Wang's integer mix, used only to decorrelate independent photon decisions.
uint plagueGlassHash(uint state) {
    state = (state ^ 61u) ^ (state >> 16u);
    state *= 9u;
    state ^= state >> 4u;
    state *= 0x27d4eb2du;
    return state ^ (state >> 15u);
}
float plagueGlassRandom(inout uint state) {
    state = plagueGlassHash(state);
    return float(state >> 8u) / 16777216.0; // Exact 24-bit unit-interval conversion.
}

vec3 plagueGlassCapNormal(vec3 view,float alpha,vec2 draw) {
    // Dupuy and Benyoub (2023), Sampling Visible GGX Normals with Spherical Caps, Eq. 10.
    // Uniform azimuth and elevation over [-V.z,1] avoid rotating a sample frame at normal incidence.
    vec3 stretched=normalize(vec3(view.xy*alpha,view.z));
    float height=(1.0-draw.y)*(1.0+stretched.z);
    float elevation=height-stretched.z;
    float azimuth=6.283185307179586*draw.x;
    float planar=sqrt(max(0.0,(1.0-elevation)*(1.0+elevation)));
    vec2 around=vec2(cos(azimuth),sin(azimuth));
    float radialView=length(stretched.xy);
    vec2 axis=radialView>0.0?stretched.xy/radialView:vec2(1.0,0.0);
    // Rationalize the near-antipodal sum. Directly adding the cap vector to V can erase its
    // positive height at the last 24-bit random stratum and yield an invisible microfacet.
    vec2 added=axis+around;
    float radialSum=radialView+planar;
    float radial=(radialSum>0.0?height*(height-2.0*stretched.z)/radialSum:0.0)
        +planar*dot(added,added)*0.5;
    float transverse=planar*(axis.x*around.y-axis.y*around.x);
    vec2 sum=axis*radial+vec2(-axis.y,axis.x)*transverse;
    return normalize(vec3(sum*alpha,height));
}

// Linear stretch maps GGX to a hemisphere. Alpha is labPBR roughness squared.
vec3 plagueGlassVisibleNormal(vec3 incident,vec3 geometric,float alpha,inout uint state) {
    if(alpha<=0.0) return geometric;
    vec3 a=abs(geometric);
    vec3 axis=a.x<=a.y && a.x<=a.z ? vec3(1.0,0.0,0.0)
            : a.y<=a.z ? vec3(0.0,1.0,0.0) : vec3(0.0,0.0,1.0);
    vec3 tangent=normalize(cross(geometric,axis));
    vec3 bitangent=cross(geometric,tangent);
    vec3 view=vec3(dot(-incident,tangent),dot(-incident,bitangent),dot(-incident,geometric));
    vec2 draw;
    draw.x=plagueGlassRandom(state); draw.y=plagueGlassRandom(state);
    vec3 microfacet=plagueGlassCapNormal(view,alpha,draw);
    return tangent*microfacet.x+bitangent*microfacet.y+geometric*microfacet.z;
}

// Heitz (2014), Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs.
// VNDF sampling and Fresnel branch selection cancel D and F, leaving correlated Smith G2/G1.
// This algebraic form avoids Lambda's divisions by grazing-angle cosines.
float plagueGlassMaskWeight(vec3 incident,vec3 outgoing,vec3 geometric,float alpha) {
    float incomingCosine=abs(dot(incident,geometric));
    float outgoingCosine=abs(dot(outgoing,geometric));
    if(incomingCosine<=0.0 || outgoingCosine<=0.0) return 0.0;
    float alphaSquared=alpha*alpha;
    float incomingRoot=sqrt(alphaSquared+(1.0-alphaSquared)*incomingCosine*incomingCosine);
    float outgoingRoot=sqrt(alphaSquared+(1.0-alphaSquared)*outgoingCosine*outgoingCosine);
    return (incomingCosine+incomingRoot)*outgoingCosine
            /(incomingRoot*outgoingCosine+outgoingRoot*incomingCosine);
}
#endif
