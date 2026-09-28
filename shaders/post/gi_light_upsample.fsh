#version 330

// One RGB visibility estimate owns each share of the light. Current RT covers nearby receivers;
// voxel visibility fills the distance transition and any RT donor that could not answer.
#define PLAGUE_LOCAL_SHADOWS 0 //[0 1] compile "Traced Block Light" {0="Off" 1="On"}
#define PLAGUE_LOCAL_LIGHTING 0 //[0 1] compile "Local Coloured Light" {0="Off" 1="On"}
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>

uniform sampler2D u_GiLightVisRaw; // current RGB visibility; positive alpha certifies a fresh answer
uniform sampler2D u_Depth;
uniform sampler2D u_GNormal;
uniform sampler2D u_VoxelLocalVisVoxel; // voxel RGB visibility, alpha history age
#define PLAGUE_LOCAL_RT_GATHER
#moj_import <fornax_runtime:local_light_handoff.glsl>

in vec2 texCoord;
out vec4 fragColor;

void main() {
    fragColor=vec4(1.0,1.0,1.0,0.0);
    vec2 uv=plagueGiDepthUv(texCoord,textureSize(u_Depth,0));
    float depth=texture(u_Depth,uv).r;
    vec4 packed=texture(u_GNormal,uv);
    if(depth<=0.0 || dot(packed.xyz,packed.xyz)<=1e-6) return;
    vec3 normal=plagueDecodeGeometricNormal(packed.a,normalize(packed.xyz));
    vec4 world=u_InvProjModelView*vec4(uv*2.0-1.0,depth,1.0);
    vec3 here=world.xyz/world.w;
    float preference=plagueLocalRtPreference(here);
    PlagueLocalRtAnswer traced=plagueLocalRtGather(texCoord,here,normal);
    vec3 rgb=preference*traced.rgb;
    float support=preference*traced.coverage;
#if PLAGUE_LOCAL_LIGHTING != 0
    float voxelWeight=1.0-clamp(support,0.0,1.0);
    // The voxel pass used this same gather before choosing to skip. No held RT age can remove
    // current fallback work, and the two backend weights sum to one rather than adding energy.
    vec4 voxel=texture(u_VoxelLocalVisVoxel,texCoord);
    if(voxelWeight>0.0 && voxel.a>0.0) {
        rgb+=voxelWeight*voxel.rgb;
        support+=voxelWeight;
    }
#endif
    fragColor=vec4(rgb,support>0.0?1.0:0.0);
}
