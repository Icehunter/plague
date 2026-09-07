#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "Voxel SSR Recovery" {0="Off" 1="On"}
uniform sampler2D u_Input0; // water normal
uniform sampler2D u_Input1; // water depth
uniform sampler2D u_Input2; // opaque depth
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
// Reuse the trace's four buffer slots: this pass has no SSR or shadow input at slots 7 and 8.
#define u_Input9 u_Input7
#define u_Input10 u_Input8
#moj_import <fornax_runtime:voxel_coverage.glsl>
#undef u_Input9
#undef u_Input10

layout(std140) uniform u_PassParams {
    vec2 u_PassTexelSize; float u_Param2; float u_Param3;
    vec4 u_SunDirection;
};
in vec2 texCoord;
out vec4 fragColor;

float plagueVoxelGlitterMask(vec3 origin, vec3 normal, vec3 lightDir) {
    if (lightDir.y <= 0.0) return 1.0;
    float alignment = max(dot(reflect(normalize(origin), normal), lightDir), 0.0);
    // Same exponent 640 as water_composite. Spend a ray only above 1/65536 of the glitter's
    // peak: a limit on work, not a guess about sky.
    if (pow(alignment, 640.0) <= 1.0 / 65536.0) return 1.0;
    vec3 point, faceNormal; uint colour;
    float state = plagueVoxelTrace(origin + normal * PLAGUE_COVERAGE_EPSILON,
            lightDir, point, faceNormal, colour);
    // Only a confirmed hit hides the glitter. Missing or waiting data leaves the screen-space
    // answer alone; the grid's edge never proves sky.
    return state == 1.0 ? 0.0 : 1.0;
}

void main() {
    // Multiplying keeps the first pass's non-water marker and its sun and moon lanes.
    fragColor = vec4(1.0);
#if PLAGUE_VOXEL_REFLECTIONS != 0
    if (u_WaterState.x > 0.5) return;
    vec3 normal; float roughness, flags;
    plagueDecodeWaterReflectionSurface(texture(u_Input0, texCoord), normal, roughness, flags);
    float depth = texture(u_Input1, texCoord).r;
    if (abs(flags) < 0.5 || depth <= 0.0 || texture(u_Input2, texCoord).r >= depth) return;
    vec4 h = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    fragColor.r = plagueVoxelGlitterMask(h.xyz / h.w, normal, u_SunDirection.xyz);
#endif
}
