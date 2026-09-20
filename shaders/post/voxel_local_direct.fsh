#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:brdf.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>
#moj_import <fornax_runtime:local_light_mode.glsl>

uniform sampler2D u_GNormal; // builtin.gNormal
uniform sampler2DArray u_ConsolidatedGbuf; // consolidated GBuffer: albedo/material/AO
uniform sampler2D u_Depth; // builtin.depth
// Slots 3..6/9/10 use the existing shared voxel traversal's buffer/atlas names.
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
#moj_import <fornax_runtime:voxel_coverage.glsl>
uniform sampler2D u_CloudShadowMask; // cloudShadowMask packed into the otherwise unused output alpha
uniform usamplerBuffer u_VoxelLocalRadiance; // sparse local radiance
uint plagueLocalSourceWord(int word) { return texelFetch(u_VoxelLocalRadiance,word).r; }
int plagueLocalSourceSize() { return textureSize(u_VoxelLocalRadiance); }
uniform usamplerBuffer u_EntityOccluders; // entityOccluders, last input so every earlier slot keeps its index
float plagueEntityOccluderWord(int word) { return uintBitsToFloat(texelFetch(u_EntityOccluders,word).r); }
int plagueEntityOccluderSize() { return textureSize(u_EntityOccluders); }
// Only this pass binds entityOccluders. voxel_local_light.glsl reads it behind this guard, so the
// reflection recovery pass, which shares that include but has no such buffer, still compiles.
#define PLAGUE_VOXEL_ENTITY_OCCLUDERS
#moj_import <fornax_runtime:voxel_local_jitter.glsl>
#moj_import <fornax_runtime:voxel_local_light.glsl>
in vec2 texCoord;
// ONE output. A fullscreen pass may declare exactly one, and a second is not a compile error: the
// graph never builds at all and every frame retries, which reads as a black screen.
//
// rgb is the light this pixel would receive with nothing in the way: smooth, carrying the pixel's
// own texture, normal and relief, and exact rather than sampled. Alpha is unused; what got through
// is worked out by voxel_local_visibility on a smaller image. The cloud shadow rides in
// voxelLocalDirect's alpha, and voxel_local_combine reads it straight from the mask to put it there.
out vec4 fragColor;
void main() {
    // Fully lit where nothing is computed: a pixel no emitter reaches is not a shadowed pixel.
    fragColor=vec4(0.0,0.0,0.0,1.0);
#if PLAGUE_LOCAL_LIGHTING != 0
    float depth=texture(u_Depth,texCoord).r;
    // Reconstructed and dithered BEFORE any early return. plagueLocalJitter takes a screen
    // derivative, which is only defined when every pixel of a 2 by 2 quad reaches it; behind a
    // branch the quad diverges and the cell size comes back as garbage.
    vec4 world=u_InvProjModelView*vec4(texCoord*2.0-1.0,max(depth,1e-6),1.0);
    vec3 point=world.xyz/world.w;
    vec2 jitterUV=plagueLocalJitter(point);
    if(depth<=0.0) return;
    vec4 packedNormal=texture(u_GNormal,texCoord);
    if(dot(packedNormal.xyz,packedNormal.xyz)==0.0) return;
    vec3 normal=normalize(packedNormal.xyz);
    vec3 geometricNormal=plagueDecodeGeometricNormal(packedNormal.a,normal);
    vec3 viewDir=normalize(-point);
    vec4 encodedMaterial=texture(u_ConsolidatedGbuf,vec3(texCoord,1.0));
    vec3 albedo=plagueSrgbToLinear(texture(u_ConsolidatedGbuf,vec3(texCoord,0.0)).rgb);
    PlagueMaterial material=plagueDecodeMaterial(encodedMaterial.r,encodedMaterial.g,encodedMaterial.b);
    // A voxel underneath an entity/particle is not the rendered receiver. Only the exact terrain
    // cutout draw class can opt into the geometry-backed thin-sheet response (quarter-step ABI).
    float surfaceClass=texture(u_ConsolidatedGbuf,vec3(texCoord,2.0)).a;
    if(abs(surfaceClass-0.5)>=0.125) material.subsurface=0.0;
    vec3 radiance;
    vec3 unshadowed;
    float visibility;
    if(plagueLocalLight(point,geometricNormal,normal,viewDir,material,albedo,jitterUV,radiance,
            unshadowed,visibility)) {
        fragColor=vec4(unshadowed,1.0);
    }
#endif
}
