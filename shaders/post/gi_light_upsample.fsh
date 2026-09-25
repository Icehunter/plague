#version 330

// Merges the traced lamp visibility and the voxel probe's own visibility at the screen's own
// size, writing the one target voxel_local_combine reads.
//
// gi_light_resolve averaged one ray a cell over frames on a grid far coarser than the screen. This
// pass reads the four cells around each pixel, keeps the ones on the same surface, and upsamples
// that fraction to a pixel. Where no ray answered this cell it falls back to the voxel probe's own
// accumulated visibility, and where neither is running the pixel is reported unfound, so
// voxel_local_combine's own depth and normal aware filter and its multiply run unchanged either way.

#define PLAGUE_LOCAL_SHADOWS 0 //[0 1] compile "Traced Block Light" {0="Off" 1="On"}
#define PLAGUE_LOCAL_LIGHTING 1 //[0 1] compile "Local Coloured Light" {0="Off" 1="On"}
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:gi_grid.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>

uniform sampler2D u_GiLightVisRaw; // giLightVisRaw, r visibility averaged over frames, g frames gathered
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GNormal; // builtin.gNormal
uniform sampler2D u_VoxelLocalVisVoxel; // voxelLocalVisVoxel, r voxel visibility averaged over frames

in vec2 texCoord;
out vec4 fragColor;

vec2 plagueLightSurfaceUv(vec2 uv) {
    // Nearest depth belongs to its texel centre; unprojecting at the requested fractional UV
    // puts the point off a slanted surface, including when the sampler clamps at a screen edge.
    vec2 extent = vec2(textureSize(u_Depth, 0));
    return (clamp(floor(uv * extent), vec2(0.0), extent - 1.0) + 0.5) / extent;
}

void main() {
    // Fully lit where nothing is computed: a pixel no lamp reaches is not a shadowed pixel.
    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
    vec2 surfaceUv = plagueLightSurfaceUv(texCoord);
    float depth = texture(u_Depth, surfaceUv).r;
    vec4 packed = texture(u_GNormal, surfaceUv);
    // The flat face, decoded from gNormal's alpha, not the bumped normal in its rgb: the plane
    // and facing tests below must compare against the same stable face the grid's own surface
    // uses, and a bumped normal changes texel to texel on leaves and defeats them.
    vec3 normal = dot(packed.xyz, packed.xyz) > 1e-6
            ? plagueDecodeGeometricNormal(packed.a, normalize(packed.xyz)) : vec3(0.0);
    if (depth <= 0.0 || dot(normal, normal) <= 1e-6) {
        return;
    }

    // The traced answer where a ray answered this cell; else the voxel probe's own accumulated
    // visibility where that is running; else nothing found. A merged lightmap cannot subtract one
    // lamp; g records whether a supported source answered, not a vanilla fallback.
    float r;
    float g;
#if PLAGUE_LOCAL_SHADOWS != 0
    // Camera-relative world position of this pixel, for the plane weight below.
    vec4 clipHere = vec4(surfaceUv * 2.0 - 1.0, depth, 1.0);
    vec4 worldHere = u_InvProjModelView * clipHere;
    vec3 here = worldHere.xyz / worldHere.w;
    // Reuse the GI history near-field precision allowance in blocks. Distance must not expand
    // support across separate terrain steps; matching surfaces retain their full coverage.
    const float tolerance = 0.05;

    // Gather only answered cells on this surface. Lost coverage stays dark rather than being
    // divided away or filled from a different terrain face that happened to see a lamp.
    vec2 side = vec2(textureSize(u_GiLightVisRaw, 0));
    vec2 place = plagueGiGridPlace(texCoord, side);
    vec2 base = floor(place);
    vec2 f = place - base;
    vec2 total = vec2(0.0);
    for (int y = 0; y <= 1; ++y) {
        for (int x = 0; x <= 1; ++x) {
            vec2 cell = clamp(base + vec2(x, y), vec2(0.0), side - 1.0);
            vec2 cellUv = plagueLightSurfaceUv(plagueGiCellUv(cell, side));
            float cellDepth = texture(u_Depth, cellUv).r;
            if (cellDepth <= 0.0) {
                continue;
            }
            vec4 cellPacked = texture(u_GNormal, cellUv);
            vec3 cellN = dot(cellPacked.xyz, cellPacked.xyz) > 1e-6
                    ? plagueDecodeGeometricNormal(cellPacked.a, normalize(cellPacked.xyz)) : vec3(0.0);
            if (dot(cellN, cellN) <= 1e-6) {
                continue;
            }
            // Match GI history's geometric-facing criterion; bumped normals do not identify a face.
            if (dot(normal, cellN) < 0.9) continue;
            vec2 sampleVis = texelFetch(u_GiLightVisRaw, ivec2(cell), 0).rg;
            if (sampleVis.y <= 0.0) continue;
            vec4 clipThere = vec4(cellUv * 2.0 - 1.0, cellDepth, 1.0);
            vec4 worldThere = u_InvProjModelView * clipThere;
            vec3 there = worldThere.xyz / worldThere.w;
            float separation = max(abs(dot(there - here, normal)),
                                   abs(dot(there - here, cellN)));
            float planeWeight = 1.0 - smoothstep(0.0, tolerance, separation);
            float bilinear = (x == 0 ? 1.0 - f.x : f.x) * (y == 0 ? 1.0 - f.y : f.y)
                    * planeWeight;
            total += vec2(sampleVis.x, 1.0) * bilinear;
        }
    }
    // The second component is supported coverage, not interpolated history age. An unanswered
    // sample cannot certify visibility even if another corner has accumulated history.
    vec2 answer = total;

#if PLAGUE_LOCAL_LIGHTING != 0
    // Fill missing coverage continuously when voxel visibility is available. Switching to it
    // only at zero traced coverage would jump as a donor leaves the surface support.
    r = answer.x + (1.0 - clamp(answer.y, 0.0, 1.0))
            * texture(u_VoxelLocalVisVoxel, texCoord).r;
    g = 1.0;
#else
    // Unsupported coverage cannot certify visibility without an independent voxel answer.
    r = answer.x;
    g = answer.y > 0.0 ? 1.0 : 0.0;
#endif
#elif PLAGUE_LOCAL_LIGHTING != 0
    r = texture(u_VoxelLocalVisVoxel, texCoord).r;
    g = 1.0;
#else
    r = 1.0;
    g = 0.0;
#endif
    fragColor = vec4(r, g, 0.0, 1.0);
}
