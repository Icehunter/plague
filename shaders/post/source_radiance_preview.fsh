#version 330 core

// Owner-reviewed diagnostic states; byte-identical in terrain.fsh. This view emits no scene light.
#define PLAGUE_SOURCE_RADIANCE 0 //[0 1 2] compile "Source Colour Preview" {0="Off" 1="Source Colour" 2="Compare Emission"}

uniform sampler2DArray u_Input0; // consolidatedGbuf: existing RGB, canonical RGB, then surface class
uniform sampler2D u_Input1;      // opaque depth; water/forward surfaces are outside this preview
in vec2 texCoord;
out vec4 fragColor;

void main() {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
#if PLAGUE_SOURCE_RADIANCE > 0
    // All inputs and output are full resolution. Exact texels preserve depth edges and classes;
    // linear filtering would invent a terrain class between an entity and a block entity.
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (texelFetch(u_Input1, pixel, 0).r <= 0.0) return; // reversed-Z clear value is sky
    // gAo.a's ABI uses quarter steps: 4 = solid terrain, 2 = cutout terrain, others are excluded.
    int surfaceClass = int(round(texelFetch(u_Input0, ivec3(pixel, 2), 0).a * 4.0));
    if (surfaceClass != 4 && surfaceClass != 2) return;

    int sourceLayer = 1;
#if PLAGUE_SOURCE_RADIANCE == 2
    // Equal screen halves are the comparison layout: existing emission left, candidate right.
    if (texCoord.x < 0.5) sourceLayer = 0;
#endif
    // Terrain already stored the fixed Le/(1+Le) display mapping in sRGB. Decode/tonemap here
    // would apply it twice; alpha stays opaque so no normal scene colour can leak into the view.
    fragColor.rgb = texelFetch(u_Input0, ivec3(pixel, sourceLayer), 0).rgb;
#endif
}
