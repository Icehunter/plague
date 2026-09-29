#moj_import <fornax_runtime:voxel_palette_layout.glsl>
#ifndef PLAGUE_GLASS_RASTER_SCENE
#define PLAGUE_GLASS_RASTER_SCENE

#ifndef PLAGUE_GLASS_SCENE
// The caller binds the shared voxel buffers and appends u_MaterialAtlas after its existing inputs.
uint plagueGlassOccupancyWord(int word) { return texelFetch(u_VoxelOccupancy,word).r; }
uint plagueGlassPayloadWord(int word) { return texelFetch(u_VoxelPayload,word).r; }
uint plagueGlassPaletteWord(int word) { return texelFetch(u_VoxelPalette,word).r; }
uint plagueGlassSummaryWord(int word) { return texelFetch(u_VoxelBrickSummary,word).r; }
uint plagueGlassFaceWord(int word) { return texelFetch(u_Input10,word).r; }
vec4 plagueGlassAlbedo(vec2 uv) { return textureLod(u_Input9,uv,0.0); }
vec4 plagueGlassMaterial(vec2 uv) { return textureLod(u_MaterialAtlas,uv,0.0); }
int plagueGlassPaletteCapacity() { return plagueVoxelPaletteCapacity(textureSize(u_VoxelPalette),u_VoxelWindow.w); }
bool plagueGlassBuffersValid() {
    int d=u_VoxelWindow.w;
    return d>0 && d<=33 && textureSize(u_VoxelOccupancy)==d*d*d*128
        && textureSize(u_VoxelPayload)==d*d*d*1024 && plagueVoxelPaletteCapacity(textureSize(u_VoxelPalette),d)>0
        && textureSize(u_VoxelBrickSummary)==d*d*d && plagueVoxelMaterialBuffersValid(textureSize(u_VoxelPalette),textureSize(u_Input10),d);
}
#moj_import <fornax_runtime:glass_scene.glsl>
#endif
#endif
