#ifndef PLAGUE_GEOMETRIC_NORMAL
#define PLAGUE_GEOMETRIC_NORMAL
// gNormal.a is SNORM16. Codes 2..7 represent exact axes; 8..16391 encode a 7+7 bit octahedron.
// Code 32767 (historical alpha=1) remains 'geometry not supplied'. Quantization fits positive SNORM.
vec2 plagueNormalSigns(vec2 v) { return mix(vec2(-1.0),vec2(1.0),greaterThanEqual(v,vec2(0.0))); }
float plagueEncodeGeometricNormal(vec3 n) {
    for (int axis=0;axis<3;axis++) if (abs(n[axis]) > 1.0-1e-6)
        return float(2+axis*2+(n[axis]>0.0?1:0))/32767.0;
    n /= abs(n.x)+abs(n.y)+abs(n.z);
    vec2 p = n.z>=0.0 ? n.xy : (1.0-abs(n.yx))*plagueNormalSigns(n.xy);
    ivec2 q = ivec2(round(clamp(p*0.5+0.5,0.0,1.0)*127.0));
    return float(8+q.x+128*q.y)/32767.0;
}
vec3 plagueDecodeGeometricNormal(float encoded,vec3 fallback) {
    int code=int(round(encoded*32767.0));
    if(code>=2 && code<8) {
        vec3 n=vec3(0.0); n[(code-2)/2]=(code&1)==1?1.0:-1.0; return n;
    }
    if(code<8 || code>=16392) return fallback;
    code-=8;
    vec2 p=vec2(code%128,code/128)/127.0*2.0-1.0;
    vec3 n=vec3(p,1.0-abs(p.x)-abs(p.y));
    if(n.z<0.0) n.xy=(1.0-abs(n.yx))*plagueNormalSigns(n.xy);
    return normalize(n);
}
#endif
