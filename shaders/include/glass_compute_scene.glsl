#ifndef PLAGUE_GLASS_COMPUTE_SCENE
#define PLAGUE_GLASS_COMPUTE_SCENE
#ifndef PLAGUE_GLASS_BINDING_START
#define PLAGUE_GLASS_BINDING_START 2
#endif
// Seven consecutive, appended scene inputs. Changing their order changes the storage-buffer ABI.
layout(std430,set=0,binding=PLAGUE_GLASS_BINDING_START) readonly buffer GlassOccupancy { uint glassOccupancy[]; };
layout(std430,set=0,binding=PLAGUE_GLASS_BINDING_START+1) readonly buffer GlassPayload { uint glassPayload[]; };
layout(std430,set=0,binding=PLAGUE_GLASS_BINDING_START+2) readonly buffer GlassPalette { uint glassPalette[]; };
layout(std430,set=0,binding=PLAGUE_GLASS_BINDING_START+3) readonly buffer GlassSummary { uint glassSummary[]; };
layout(std430,set=0,binding=PLAGUE_GLASS_BINDING_START+4) readonly buffer GlassFaces { uint glassFaces[]; };
layout(set=0,binding=PLAGUE_GLASS_BINDING_START+5) uniform sampler2D u_GlassAlbedoAtlas;
layout(set=0,binding=PLAGUE_GLASS_BINDING_START+6) uniform sampler2D u_GlassMaterialAtlas;
uint plagueGlassOccupancyWord(int word) { return glassOccupancy[word]; }
uint plagueGlassPayloadWord(int word) { return glassPayload[word]; }
uint plagueGlassPaletteWord(int word) { return glassPalette[word]; }
uint plagueGlassSummaryWord(int word) { return glassSummary[word]; }
uint plagueGlassFaceWord(int word) { return glassFaces[word]; }
vec4 plagueGlassAlbedo(vec2 uv) { return textureLod(u_GlassAlbedoAtlas,uv,0.0); }
vec4 plagueGlassMaterial(vec2 uv) { return textureLod(u_GlassMaterialAtlas,uv,0.0); }
bool plagueGlassBuffersValid() {
    int d=u_VoxelWindow.w;
    return d>0 && d<=33 && glassOccupancy.length()==d*d*d*128 && glassPayload.length()==d*d*d*1024
        && glassPalette.length()==d*d*d*1536 && glassSummary.length()==d*d*d && glassFaces.length()==d*d*d*96*42;
}
#moj_import <fornax_runtime:glass_scene.glsl>
#endif
