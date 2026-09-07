#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

#define PLAGUE_VOXEL_COVERAGE 0 //[0 1 2] compile "Voxel Reflection Coverage" {0="Off" 1="First Surface" 2="Behind Cutouts"}
// Test radius: four to sixteen chunks, one whole chunk at a time.
#define u_LightReach 4.0 //[4.0..16.0 step 1.0] runtime "Voxel Diagnostic Reach (Chunks)"

uniform sampler2D u_Input0; // current water surface
uniform sampler2D u_Input1; // current water depth
uniform sampler2D u_Input2; // opaque depth, to exclude hidden water
#moj_import <fornax_runtime:voxel_coverage.glsl>
in vec2 texCoord;
out vec4 fragColor;

void main() {
    fragColor = vec4(0.0);
#if PLAGUE_VOXEL_COVERAGE != 0
    vec3 normal;
    float roughness, flags;
    plagueDecodeWaterReflectionSurface(texture(u_Input0, texCoord), normal, roughness, flags);
    float depth = texture(u_Input1, texCoord).r;
    if (abs(flags) < 0.5 || depth <= 0.0 || texture(u_Input2, texCoord).r >= depth) return;
    vec4 h = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec3 origin = h.xyz / h.w;
    float state = plagueVoxelCoverage(origin + normal * PLAGUE_COVERAGE_EPSILON,
                                     reflect(normalize(origin), normal));
    // Flat marker colours, not light or albedo. Amber means the water sits outside the grid.
    vec3 colour = state == 1.0 ? vec3(0.0, 1.0, 0.0)
                : state == 2.0 ? vec3(1.0, 0.0, 1.0)
                : state == 3.0 ? vec3(1.0, 0.5, 0.0)
                : state == 4.0 ? vec3(1.0, 0.0, 0.0)
                : state == 5.0 ? vec3(0.0, 1.0, 1.0) : vec3(1.0);
    fragColor = vec4(colour, 1.0);
#endif
}
