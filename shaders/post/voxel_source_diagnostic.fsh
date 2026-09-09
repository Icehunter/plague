#version 330
#moj_import <fornax:globals.glsl>

// Default Off keeps the normal graph unchanged. These views only read data; they add no light.
#define PLAGUE_SOURCE_DIAGNOSTIC 0 //[0 1 2 3] compile "Voxel Source Inventory" {0="Off" 1="Sources" 2="Freshness" 3="Face Colours"}

uniform sampler2D u_Input0; // opaque depth: sections behind water are terrain, not reflected hits
uniform sampler2D u_Input1; // section status written by the compute pass, not the raw voxel data
in vec2 texCoord;
out vec4 fragColor;

int plagueSourceMod(int a, int d) { return ((a % d) + d) % d; }

void main() {
    fragColor = vec4(0.0);
#if PLAGUE_SOURCE_DIAGNOSTIC == 1 || PLAGUE_SOURCE_DIAGNOSTIC == 2
    float depth = texture(u_Input0, texCoord).r;
    if (depth <= 0.0) return;
    // These bright marker colors are status codes, not real light color or strength.
    vec3 marker = vec3(1.0);
    int d = u_VoxelWindow.w;
    if (d <= 0 || d > 33) { fragColor = vec4(marker, 1.0); return; }
    vec4 h = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec3 relative = h.xyz / h.w;
    // Nudge just inside the depth surface; 1/4096 block matches the existing voxel entry nudge.
    vec3 world = u_CameraAbs + relative + normalize(relative) / 4096.0;
    ivec3 section = ivec3(floor(world / 16.0));
    ivec3 first = u_VoxelWindow.xyz - ivec3((d - 1) / 2);
    ivec3 localSection = section - first;
    if (any(lessThan(localSection, ivec3(0))) || any(greaterThanEqual(localSection, ivec3(d)))) {
        fragColor = vec4(1.0, 0.5, 0.0, 1.0); return; // amber: outside coverage
    }
    int slot = (plagueSourceMod(section.y, d) * d + plagueSourceMod(section.z, d)) * d
               + plagueSourceMod(section.x, d);
    ivec2 size = textureSize(u_Input1, 0);
    vec4 status = texelFetch(u_Input1, ivec2(slot % size.x, slot / size.x), 0);
    // A cleared status image has never been written, and must not look like valid coverage.
    if (status.a < 1.0) { fragColor = vec4(1.0); return; }
    status.a -= 1.0;
    marker = status.rgb;
    // Status alpha >= 2 marks missing data, kept opaque so it cannot look like valid coverage.
    if (status.a >= 2.0) { fragColor = vec4(marker, 1.0); return; }
#if PLAGUE_SOURCE_DIAGNOSTIC == 1
    // Eight-pixel warning stripes are a chosen UI look for this debug view.
    if (status.a == 1.0 && (int(gl_FragCoord.x + gl_FragCoord.y) & 7) < 2)
        marker = vec3(1.0, 0.0, 1.0);
#endif
    // Half blend keeps the scene visible under the marker, so it never reads as real lighting.
    fragColor = vec4(marker, 0.5);
#endif
}
