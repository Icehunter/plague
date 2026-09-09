#version 330 core
#moj_import <fornax_runtime:color.glsl>
#define PLAGUE_SOURCE_DIAGNOSTIC 0 //[0 1 2 3] compile "Voxel Source Inventory" {0="Off" 1="Sources" 2="Freshness" 3="Face Colours"}
uniform sampler2D u_Input0;
in vec2 texCoord;
out vec4 fragColor;

void main() {
    fragColor = vec4(0.0);
#if PLAGUE_SOURCE_DIAGNOSTIC == 3
    // Same upper-right half-viewport panel as the cloud diagnostic; nearest reads preserve samples.
    if (any(lessThan(texCoord,vec2(0.5)))) return;
    ivec2 size = textureSize(u_Input0,0);
    ivec2 pixel = clamp(ivec2((texCoord*2.0-1.0)*vec2(size)),ivec2(0),size-1);
    vec4 sampleValue = texelFetch(u_Input0,pixel,0);
    // Grey unused, magenta rejected; black is a valid non-emitting sample, including a cutout gap.
    vec3 colour = sampleValue.a == 0.0 ? vec3(0.125) : vec3(1.0,0.0,1.0);
    if (sampleValue.a > 0.0) {
        vec3 radiance = max(sampleValue.rgb,vec3(0.0));
        // Same fixed Reinhard (2002) display mapping as Source Colour Preview, applied once.
        colour = plagueLinearToSrgb(radiance/(vec3(1.0)+radiance));
    }
    fragColor = vec4(colour,1.0);
#endif
}
