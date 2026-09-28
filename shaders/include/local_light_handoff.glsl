#ifndef PLAGUE_LOCAL_LIGHT_HANDOFF
#define PLAGUE_LOCAL_LIGHT_HANDOFF

#moj_import <fornax_runtime:local_light_mode.glsl>
#moj_import <fornax_runtime:gi_grid.glsl>
// Work budget: two chunks near the eye. The four-chunk maximum plus the twelve-block lamp
// reach stays inside the engine's nominal 96-block local mesh-query window.
#define u_LocalRtDistance 2 //[1..4 step 1] runtime "Traced Block Light Distance (Chunks)"

float plagueLocalRtPreference(vec3 receiver) {
#if PLAGUE_LOCAL_LIGHTING != 0 && PLAGUE_LOCAL_SHADOWS != 0
    float radius=u_LocalRtDistance*16.0;
    // Blend methods over one 16-block section without changing the light's energy.
    return 1.0-smoothstep(max(radius-16.0,0.0),radius,length(receiver));
#elif PLAGUE_LOCAL_SHADOWS != 0
    return 1.0;
#else
    return 0.0;
#endif
}

#ifdef PLAGUE_LOCAL_RT_GATHER
// Callers bind u_Depth, u_GNormal and this frame's u_GiLightVisRaw before importing.
struct PlagueLocalRtAnswer {
    vec3 rgb;
    float coverage;
    bool complete;
};

PlagueLocalRtAnswer plagueLocalRtGather(vec2 screenUv,vec3 here,vec3 normal) {
    PlagueLocalRtAnswer answer;
    answer.rgb=vec3(0.0); answer.coverage=0.0; answer.complete=false;
#if PLAGUE_LOCAL_SHADOWS != 0
    vec2 side=vec2(textureSize(u_GiLightVisRaw,0));
    vec2 place=plagueGiGridPlace(screenUv,side),base=floor(place),f=fract(place);
    bool complete=true,current=true;
    // GI uses this 0.05-block near-field plane allowance. Keep it below terrain-step height.
    const float tolerance=0.05;
    for(int y=0;y<=1;++y) for(int x=0;x<=1;++x) {
        float bilinear=(x==0?1.0-f.x:f.x)*(y==0?1.0-f.y:f.y);
        if(bilinear<=0.0) continue;
        ivec2 cell=ivec2(clamp(base+vec2(x,y),vec2(0.0),side-1.0));
        vec2 uv=plagueGiDepthUv(plagueGiCellUv(vec2(cell),side),textureSize(u_Depth,0));
        float depth=texture(u_Depth,uv).r;
        vec4 packed=texture(u_GNormal,uv),sampleVis=texelFetch(u_GiLightVisRaw,cell,0);
        // RT alone may shade from held history. Held data cannot skip current voxel work.
        bool answered=sampleVis.a>0.0;
        bool available=answered;
#if PLAGUE_LOCAL_LIGHTING == 0
        available=sampleVis.a!=0.0;
#endif
        if(!answered) current=false;
        if(depth<=0.0 || dot(packed.xyz,packed.xyz)<=1e-6 || !available) {
            complete=false; continue;
        }
        vec3 n=plagueDecodeGeometricNormal(packed.a,normalize(packed.xyz));
        if(dot(normal,n)<0.9) { complete=false; continue; }
        vec4 world=u_InvProjModelView*vec4(uv*2.0-1.0,depth,1.0);
        vec3 there=world.xyz/world.w;
        float separation=max(abs(dot(there-here,normal)),abs(dot(there-here,n)));
        float planeWeight=1.0-smoothstep(0.0,tolerance,separation);
        if(planeWeight<=0.0) { complete=false; continue; }
        float weight=bilinear*planeWeight;
        answer.rgb+=sampleVis.rgb*weight;
        answer.coverage+=weight;
    }
    // All donors match this face. Roundoff in their weight sum must not trigger voxel work;
    // full ownership still requires a current answer from every donor.
    if(complete && answer.coverage>0.0) {
        answer.rgb/=answer.coverage;
        answer.coverage=1.0;
        answer.complete=current;
    }
#endif
    return answer;
}
#endif
#endif
