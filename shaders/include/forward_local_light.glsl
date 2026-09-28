#ifndef PLAGUE_FORWARD_LOCAL_LIGHT
#define PLAGUE_FORWARD_LOCAL_LIGHT

// Appended buffer inputs are independent of terrain's eight texture samplers.
uniform usamplerBuffer u_GeomBuffer0; // voxelLocalRadiance
uniform usamplerBuffer u_GeomBuffer1; // voxelOccupancy
uniform usamplerBuffer u_GeomBuffer2; // voxelPayload
uniform usamplerBuffer u_GeomBuffer3; // voxelPalette
uniform usamplerBuffer u_GeomBuffer4; // voxelBrickSummary
uniform usamplerBuffer u_GeomBuffer5; // voxelFaceTexture
#define u_VoxelOccupancy u_GeomBuffer1
#define u_VoxelPayload u_GeomBuffer2
#define u_VoxelPalette u_GeomBuffer3
#define u_VoxelBrickSummary u_GeomBuffer4
#define u_Input10 u_GeomBuffer5
#define u_Input9 u_BlockTex
#define u_MaterialAtlas u_MaterialTex
#define PLAGUE_VOXEL_EXTERNAL_BUFFERS
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
#moj_import <fornax_runtime:voxel_coverage.glsl>
#moj_import <fornax_runtime:glass_raster_scene.glsl>
uint plagueLocalSourceWord(int word) { return texelFetch(u_GeomBuffer0,word).r; }
int plagueLocalSourceSize() { return textureSize(u_GeomBuffer0); }
// Forward surfaces have no visibility history. Use the existing bounded secondary-surface
// estimator, with exact RGB source/BRDF energy and voxel visibility at this fragment.
#define PLAGUE_LOCAL_REFLECTED
#moj_import <fornax_runtime:voxel_local_light.glsl>
#moj_import <fornax_runtime:voxel_local_jitter.glsl>

bool plagueForwardLocalLight(vec3 point,vec3 geometricNormal,vec3 normal,vec3 viewDir,
        PlagueMaterial material,vec3 albedo,vec2 jitterUV,out vec3 radiance) {
    radiance=vec3(0.0);
    if(!plagueGlassBuffersValid() || plagueLocalSourceSize()!=PLAGUE_LOCAL_SOURCE_WORDS) return false;
    int d=u_VoxelWindow.w;
    ivec3 section=(ivec3(floor(u_CameraAbs))+ivec3(floor(fract(u_CameraAbs)+point)))>>4;
    ivec3 first=u_VoxelWindow.xyz-ivec3((d-1)/2);
    // The source reach fits the receiver's 27 neighbouring sections. Pending or out-of-window
    // geometry cannot prove a zero-light result; retain the original forward lightmap instead.
    for(int range=0;range<27;range++) {
        ivec3 neighbour=section+ivec3(range%3-1,range/9-1,(range/3)%3-1);
        if(any(lessThan(neighbour,first)) || any(greaterThanEqual(neighbour,first+ivec3(d)))) return false;
        int slot=(plagueCoverageMod(neighbour.y,d)*d+plagueCoverageMod(neighbour.z,d))*d
                +plagueCoverageMod(neighbour.x,d);
        if((texelFetch(u_VoxelBrickSummary,slot).r&0x80000000u)!=0u) return false;
    }
    vec3 unshadowed,visibility;
    bool valid=plagueLocalLight(point,geometricNormal,normal,viewDir,material,albedo,jitterUV,
            radiance,unshadowed,visibility);
    if(!valid) radiance=vec3(0.0);
    return valid;
}
#endif
