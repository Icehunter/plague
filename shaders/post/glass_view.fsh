#version 330 core
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:glass_options.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:brdf.glsl>
#moj_import <fornax_runtime:emission.glsl>
#moj_import <fornax_runtime:material_options.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>

#define PLAGUE_GLASS_REFRACTION 1 //[0 1] compile "Glass Refraction" {0="Off" 1="On"}
#define PLAGUE_LOCAL_SHADOWS 0 //[0 1] compile "Traced Block Light" {0="Off" 1="On"}

uniform sampler2D u_SceneHdrComposited;
uniform sampler2D u_Depth;
uniform sampler2D u_GNormal;
uniform sampler2D u_MaterialAtlas;
uniform usamplerBuffer u_VoxelLocalRadiance;
// The shared voxel helpers require blockAtlas at 9 and voxelFaceTexture at 10.
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
#moj_import <fornax_runtime:voxel_coverage.glsl>

uint plagueGlassOccupancyWord(int word) { return texelFetch(u_VoxelOccupancy,word).r; }
uint plagueGlassPayloadWord(int word) { return texelFetch(u_VoxelPayload,word).r; }
uint plagueGlassPaletteWord(int word) { return texelFetch(u_VoxelPalette,word).r; }
uint plagueGlassSummaryWord(int word) { return texelFetch(u_VoxelBrickSummary,word).r; }
uint plagueGlassFaceWord(int word) { return texelFetch(u_Input10,word).r; }
vec4 plagueGlassAlbedo(vec2 uv) { return textureLod(u_Input9,uv,0.0); }
vec4 plagueGlassMaterial(vec2 uv) { return textureLod(u_MaterialAtlas,uv,0.0); }
bool plagueGlassBuffersValid() {
    int d=u_VoxelWindow.w;
    if(d<1 || d>33) return false;
    int slots=d*d*d;
    return textureSize(u_VoxelOccupancy)==slots*128 && textureSize(u_VoxelPayload)==slots*1024
        && textureSize(u_VoxelPalette)==slots*1536 && textureSize(u_VoxelBrickSummary)==slots
        && textureSize(u_Input10)==slots*96*42;
}
#moj_import <fornax_runtime:glass_scene.glsl>

uint plagueLocalSourceWord(int word) { return texelFetch(u_VoxelLocalRadiance,word).r; }
int plagueLocalSourceSize() { return textureSize(u_VoxelLocalRadiance); }
#define PLAGUE_LOCAL_REFLECTED
#moj_import <fornax_runtime:voxel_local_light.glsl>

in vec2 texCoord;
out vec4 fragColor;

vec3 plagueGlassViewPoint(vec2 uv,float depth) {
    vec4 point=u_InvProjModelView*vec4(uv*2.0-1.0,depth,1.0);
    return point.xyz/point.w;
}

bool plagueGlassViewCertificate(vec3 direction,float reach,bool opaqueEndpoint) {
    // Every raster translucent surface behind the marker will be suppressed. A cell whose
    // translucent model lacks a closed-volume certificate must therefore reject the whole pixel.
    vec3 grid=plagueGlassGridOrigin();
    ivec3 cell=ivec3(floor(grid+direction*PLAGUE_GLASS_EPSILON));
    ivec3 step=ivec3(sign(direction));
    vec3 delta=vec3(1e30),next=vec3(1e30); // Shared DDA's unbounded-axis sentinel.
    for(int axis=0;axis<3;++axis) if(step[axis]!=0) {
        delta[axis]=abs(1.0/direction[axis]);
        next[axis]=(float(cell[axis]+max(step[axis],0))-grid[axis])/direction[axis];
    }
    float walked=0.0;
    for(int walk=0;walk<PLAGUE_GLASS_STEPS && walked<reach;++walk) {
        int entry=plagueGlassCell(cell);
        if(entry==-2) return false;
        if(entry>=0) {
            bool blended=false;
            for(int face=0;face<6;++face)
                blended=blended || (plagueGlassFaceWord(entry*42+face*7)&0x80000000u)!=0u;
            if(blended && !plagueGlassMedium(entry).glass) return false;
        }
        float crossing=min(next.x,min(next.y,next.z));
        for(int axis=0;axis<3;++axis) if(next[axis]<=crossing) {
            cell[axis]+=step[axis]; next[axis]+=delta[axis];
        }
        walked=crossing;
    }
    if(walked<reach) return false;

    vec3 origin=vec3(0.0);
    float travelled=0.0;
    // The tolerance covers one before/after boundary nudge and depth reconstruction roundoff.
    float tolerance=PLAGUE_GLASS_EPSILON*4.0;
    for(int boundary=0;boundary<PLAGUE_GLASS_INTERFACES;++boundary) {
        PlagueGlassHit hit;
        int status=plagueGlassTrace(origin,direction,reach-travelled+tolerance,false,hit);
        if(status<0) return false;
        if(status==0) return !opaqueEndpoint;
        travelled+=hit.distance;
        if(!hit.glass) return opaqueEndpoint && abs(travelled-reach)<=tolerance;
        vec3 after=plagueGlassBoundaryOffset(hit.position,direction,hit.normal);
        vec3 afterGrid=plagueGlassGridOrigin()+after;
        int entry=plagueGlassCell(ivec3(floor(afterGrid)));
        if(entry==-2) return false;
        if(entry>=0 && !plagueGlassMedium(entry).glass && plagueGlassContains(entry,fract(afterGrid))) {
            vec3 local=plagueGlassGridOrigin()+hit.position-vec3(ivec3(floor(afterGrid)));
            vec3 normal=dot(direction,hit.normal)<0.0 ? hit.normal : -hit.normal;
            vec2 uv; vec3 tint;
            uint flags=plagueGlassPaletteWord(entry*16);
            bool opaque=(flags&0x80000000u)==0u && ((flags&0xc0000000u)==0u
                    || !plagueGlassUv(entry,local,normal,uv,tint) || plagueGlassAlbedo(uv).a>=0.5);
            if(opaque) return opaqueEndpoint && abs(travelled-reach)<=tolerance;
        }
        // A glass exit can share the opaque depth with a touching lamp. Test that neighbour
        // first; a glass surface without opaque backing still needs its painted raster texel.
        if(opaqueEndpoint && abs(travelled-reach)<=tolerance) return false;
        origin=after;
        travelled+=PLAGUE_GLASS_EPSILON*2.0;
        if(travelled>=reach) return !opaqueEndpoint;
    }
    return false;
}

bool plagueGlassViewScreen(PlagueGlassHit hit,out vec3 radiance) {
    radiance=vec3(0.0);
    vec4 clip=u_ProjectionMatrix*u_ModelViewMatrix*vec4(hit.position,1.0);
    if(clip.w<=0.0) return false;
    vec2 uv=clip.xy/clip.w*0.5+0.5;
    if(any(lessThan(uv,vec2(0.0))) || any(greaterThanEqual(uv,vec2(1.0)))) return false;
    ivec2 extent=textureSize(u_Depth,0);
    ivec2 pixel=ivec2(uv*vec2(extent));
    vec2 sampleUv=(vec2(pixel)+0.5)/vec2(extent);
    float depth=texelFetch(u_Depth,pixel,0).r;
    if(depth<=0.0) return false;
    vec4 packed=texelFetch(u_GNormal,pixel,0);
    if(dot(packed.xyz,packed.xyz)<=0.0) return false;
    vec3 normal=plagueDecodeGeometricNormal(packed.a,normalize(packed.xyz));
    // The same geometric-facing criterion as local-light history; a wall cannot donate floor light.
    if(dot(normal,hit.normal)<0.9) return false;
    vec3 actual=plagueGlassViewPoint(sampleUv,depth);
    vec3 pixelX=plagueGlassViewPoint(sampleUv+vec2(1.0/float(extent.x),0.0),depth)-actual;
    vec3 pixelY=plagueGlassViewPoint(sampleUv+vec2(0.0,1.0/float(extent.y)),depth)-actual;
    // One pixel diagonal bounds nearest-sample support; the geometric tolerance covers voxel nudges.
    float support=length(pixelX)+length(pixelY)+PLAGUE_GLASS_EPSILON*2.0;
    if(length(actual-hit.position)>support
            || abs(dot(actual-hit.position,hit.normal))>PLAGUE_GLASS_EPSILON*2.0) return false;
    radiance=max(texelFetch(u_SceneHdrComposited,pixel,0).rgb,vec3(0.0));
    return true;
}

bool plagueGlassViewShade(PlagueGlassHit hit,vec3 direction,out vec3 radiance) {
    radiance=vec3(0.0);
    vec2 uv; vec3 tint;
    if(!plagueGlassUv(hit.entry,hit.local,hit.normal,uv,tint)) return false;
    vec4 texel=plagueGlassAlbedo(uv);
    vec4 encoded=plagueGlassMaterial(uv);
    vec3 albedo=plagueSrgbToLinear(texel.rgb)*tint;
    PlagueMaterial material=plagueDecodeMaterial(encoded.r,encoded.g,encoded.b);
    float intrinsic=float(plagueGlassPaletteWord(hit.entry*16+15)&255u)/255.0;
    radiance=plagueEmittedRadiance(albedo,
            plagueSourceLuminance(albedo,intrinsic,encoded.a,u_AuthoredEmission));
    // Off-screen recovery contains only measured emitters and their shadowed BRDF response.
    // It does not infer sky, bounce light, or reflected content from an unrelated screen pixel.
    vec3 local,unshadowed,visibility;
    if(!plagueLocalLight(hit.position,hit.normal,hit.normal,-direction,material,albedo,
            vec2(0.5),local,unshadowed,visibility)) return false;
    radiance+=local;
    return !any(isnan(radiance)) && !any(isinf(radiance));
}

float plagueGlassViewCertificateDistance(float distance) {
    // IEEE binary16 has ten fraction bits. Round toward the camera before the attachment's
    // nearest rounding, so a stored certificate cannot move behind its own forward glass face.
    // Trace distances are at least EPSILON, above binary16's smallest normal value.
    float quantum=exp2(floor(log2(max(distance,PLAGUE_GLASS_EPSILON)))-10.0);
    return floor(distance/quantum)*quantum;
}

bool plagueGlassViewBranch(vec3 incident,uint initialState,float cameraIor,int branch,
        out vec3 colour,out float weight,out bool selected,out bool splitApplied) {
    vec3 origin=vec3(0.0),direction=incident,throughput=vec3(1.0);
    uint state=initialState;
    PlagueGlassHit receiver;
    bool crossed; float firstDistance;
    int status=plagueGlassTransportFirstBranch(origin,direction,throughput,PLAGUE_GLASS_VIEW_REACH,
            true,state,receiver,crossed,firstDistance,branch,weight,selected,splitApplied);
    // Geometric microfacet rejection is a real zero sample. Substituting raster colour would
    // condition away dark paths and make rough glass create light.
    colour=vec3(0.0);
    if(status==2) return true;
    if(status!=1 || !crossed) return false;
    vec3 radiance;
    if(!plagueGlassViewScreen(receiver,radiance)
            && !plagueGlassViewShade(receiver,direction,radiance)) return false;
    // Radiance carries (eta_incident/eta_transmitted)^2. A touching receiver may be reached
    // from inside the glass, so the terminal incident medium need not be air.
    PlagueGlassMedium receiverMedium=plagueGlassAt(plagueGlassBoundaryOffset(receiver.position,-direction,receiver.normal));
    float eta=cameraIor/receiverMedium.ior;
    throughput*=eta*eta;
    colour=throughput*radiance;
    return !any(isnan(colour)) && !any(isinf(colour));
}

void main() {
    vec3 background=texture(u_SceneHdrComposited,texCoord).rgb;
    fragColor=vec4(background,-1.0);
#if PLAGUE_GLASS_TRANSPORT != 0 && PLAGUE_GLASS_REFRACTION != 0
    if(!plagueGlassBuffersValid()) return;
    float depth=texture(u_Depth,texCoord).r;
    vec3 point=plagueGlassViewPoint(texCoord,max(depth,1e-6));
    vec3 direction=normalize(point);
    if(depth>0.0 && length(point)>PLAGUE_GLASS_VIEW_REACH) return;
    float firstReach=depth>0.0 ? min(length(point)+PLAGUE_GLASS_EPSILON*2.0,PLAGUE_GLASS_VIEW_REACH)
            : PLAGUE_GLASS_VIEW_REACH;
    PlagueGlassHit first;
    if(plagueGlassTrace(vec3(0.0),direction,firstReach,true,first)!=1) return;
    float rasterReach=depth>0.0 ? length(point) : PLAGUE_GLASS_VIEW_REACH;
    if(!plagueGlassViewCertificate(direction,rasterReach,depth>0.0)) return;
    PlagueGlassMedium cameraMedium=plagueGlassAt(vec3(0.0));
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    uint state=plagueGlassHash(uint(pixel.x)+uint(pixel.y)*uint(textureSize(u_Depth,0).x)
            ^uint(u_FrameState.x));
    float certificate=plagueGlassViewCertificateDistance(first.distance);
    vec3 reflection,transmission;
    float reflectionWeight,transmissionWeight;
    bool reflectionSelected,transmissionSelected,reflectionSplit,transmissionSplit;
    bool reflectionValid=plagueGlassViewBranch(direction,state,cameraMedium.ior,0,reflection,reflectionWeight,
            reflectionSelected,reflectionSplit);
    if(!reflectionSplit) {
        if(reflectionValid) fragColor=vec4(max(reflection,vec3(0.0)),certificate);
        return;
    }
    bool transmissionValid=plagueGlassViewBranch(direction,state,cameraMedium.ior,1,transmission,transmissionWeight,
            transmissionSelected,transmissionSplit);
    // Conditional expectation over the first Fresnel choice (Pharr et al., PBRT, 4th ed.,
    // Improving Efficiency: splitting). Shared initial state gives one GGX normal and the same
    // continuation stream as the original selected path. Later interfaces remain stochastic.
    vec3 colour;
    if(reflectionValid && transmissionValid) {
        colour=reflectionWeight*reflection+transmissionWeight*transmission;
    } else if(reflectionSelected) {
        if(!reflectionValid) return;
        colour=reflection;
    } else {
        if(!transmissionValid) return;
        colour=transmission;
    }
    // If either branch cannot resolve, retain the original selected branch without its weight.
    // Dropping missing energy or choosing only a successful branch biases colour and brightness.
    // An unresolved original branch leaves alpha negative, retaining raster ownership.
    fragColor=vec4(max(colour,vec3(0.0)),certificate);
#endif
}
