#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:brdf.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>
#moj_import <fornax_runtime:local_light_mode.glsl>

uniform sampler2D u_Input0; // builtin.gNormal
uniform sampler2DArray u_Input1; // consolidated GBuffer: albedo/material/AO
uniform sampler2D u_Input2; // builtin.depth
// Slots 3..6/9/10 use the existing shared voxel traversal's buffer/atlas names.
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
#moj_import <fornax_runtime:voxel_coverage.glsl>
uniform sampler2D u_Input11; // cloudShadowMask packed into the otherwise unused output alpha
uniform usamplerBuffer u_Input7; // sparse local radiance
uint plagueLocalSourceWord(int word) { return texelFetch(u_Input7,word).r; }
int plagueLocalSourceSize() { return textureSize(u_Input7); }
uniform usamplerBuffer u_Input12; // entityOccluders, last input so every earlier slot keeps its index
float plagueEntityOccluderWord(int word) { return uintBitsToFloat(texelFetch(u_Input12,word).r); }
int plagueEntityOccluderSize() { return textureSize(u_Input12); }
// Only this pass binds entityOccluders. voxel_local_light.glsl reads it behind this guard, so the
// reflection recovery pass, which shares that include but has no such buffer, still compiles.
#define PLAGUE_VOXEL_ENTITY_OCCLUDERS
#moj_import <fornax_runtime:voxel_local_jitter.glsl>
#moj_import <fornax_runtime:voxel_local_light.glsl>
in vec2 texCoord;
out vec4 fragColor;
void main() {
    fragColor=vec4(0.0,0.0,0.0,texture(u_Input11,texCoord).r);
#if PLAGUE_LOCAL_LIGHTING != 0
    float depth=texture(u_Input2,texCoord).r;
    if(depth<=0.0) return;
    vec4 world=u_InvProjModelView*vec4(texCoord*2.0-1.0,depth,1.0);
    vec3 point=world.xyz/world.w;
    vec4 packedNormal=texture(u_Input0,texCoord);
    if(dot(packedNormal.xyz,packedNormal.xyz)==0.0) return;
    vec3 normal=normalize(packedNormal.xyz);
    vec3 geometricNormal=plagueDecodeGeometricNormal(packedNormal.a,normal);
    vec3 viewDir=normalize(-point);
    vec4 encodedMaterial=texture(u_Input1,vec3(texCoord,1.0));
    vec3 albedo=plagueSrgbToLinear(texture(u_Input1,vec3(texCoord,0.0)).rgb);
    PlagueMaterial material=plagueDecodeMaterial(encodedMaterial.r,encodedMaterial.g,encodedMaterial.b);
    // A voxel underneath an entity/particle is not the rendered receiver. Only the exact terrain
    // cutout draw class can opt into the geometry-backed thin-sheet response (quarter-step ABI).
    float surfaceClass=texture(u_Input1,vec3(texCoord,2.0)).a;
    if(abs(surfaceClass-0.5)>=0.125) material.subsurface=0.0;
    vec3 radiance;
    if(plagueLocalLight(point,geometricNormal,normal,viewDir,material,albedo,radiance))
        fragColor.rgb=radiance;
#endif
}
