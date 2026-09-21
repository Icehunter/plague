#version 330 core
#moj_import <fornax:globals.glsl>
#moj_import <fornax:ray_answer.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:shadow_debug.glsl>

uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GNormal; // builtin.gNormal
// The complete raster map remains the fallback for every receiving point.
uniform sampler2DShadow u_SunShadowMap; // complete sunShadowMap
#define SUN_SHADOW_MAP u_SunShadowMap
uniform sampler2D u_SunShadowMapRaw; // sunShadowMapRaw (existing reserved binding)
uniform sampler2D u_RtTerrainShadowDepth; // rtTerrainShadowDepth
uniform sampler2D u_SunEntityShadowMapRaw; // sunEntityShadowMapRaw
uniform sampler2D u_GMotion; // builtin.gMotion, debug views only
// sunShadowHits, a texel buffer, so it binds with no sampler object and costs nothing against the
// sampler ceiling this file has to share.
uniform usamplerBuffer u_SunShadowHits;
// rtShadowComposite.history, last input so every earlier slot keeps its index: this pass's own
// previous frame, held for a pixel a rebuild burst leaves with no fresh ray answer at all.
uniform sampler2D u_RtShadowComposite_history;
uint plagueSunShadowWord(int word) { return texelFetch(u_SunShadowHits, word).r; }
// One record is nine words: distance at 0, the tier that answered it at 7. The rest of the record
// belongs to the bounce path that shares this layout and is not read here.
const uint PLAGUE_SUN_SHADOW_HIT_WORDS = 9u;
const uint PLAGUE_SUN_SHADOW_WORD_DISTANCE = 0u;
const uint PLAGUE_SUN_SHADOW_WORD_TIER = 7u;
// Two receiving points this far apart in depth are not the same point, so one's held history must
// not paint the other. As a fraction of depth: this format is reversed and nonlinear, so a fixed
// gap would mean different things near and far.
const float PLAGUE_SUN_SHADOW_HISTORY_DEPTH_REJECT = 0.02;
#define SHADOW_COMPARISON_MAP u_SunShadowMap
#define SHADOW_RAW_MAP u_SunShadowMapRaw
#define RT_TERRAIN_SHADOW_DEPTH u_RtTerrainShadowDepth
#define ENTITY_SHADOW_RAW_MAP u_SunEntityShadowMapRaw
float plagueRtSelectedSum = 0.0;
#define PLAGUE_SHADOW_RECORD_COVERAGE(coverage) plagueRtSelectedSum += (coverage)
#moj_import <fornax_runtime:shadow_handoff.glsl>
#define SUN_SHADOW_LOOKUP(receiver, uv, reference) plagueShadowLookup(receiver, uv, reference)

// The resolve_hdr name supplies the same active sun/moon direction as the lighting resolve.
layout(std140) uniform u_PassParams {
    vec2 u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4 u_SunDirection;
};
in vec2 texCoord;
out vec4 fragColor;
// The map read inside this include stays correct with the raster map off: that map is then a
// placeholder cleared to "no occluder anywhere", so a read of it is a full-light answer.
#if defined(SHADOWS) || RT_SHADOWS
#moj_import <fornax_runtime:shadow_filter.glsl>
#endif

// Preserve the seabed caustic query's own light-direction bias and out-of-map dark fallback.
float plagueCausticSunVisibility(vec3 receiver, vec3 sunDir) {
    vec4 clip = u_SunViewProj * vec4(receiver + sunDir * 0.08, 1.0);
    vec3 ndc = clip.xyz / max(clip.w, 1e-6);
    float distortion = length(ndc.xy) * u_ShadowMapParams.x + (1.0 - u_ShadowMapParams.x);
    vec2 uv = ndc.xy / distortion * 0.5 + 0.5;
    if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0
            || ndc.z <= 0.0 || ndc.z >= 1.0) return 0.0;
    return plagueShadowLookup(receiver, uv, ndc.z);
}

void main() {
    fragColor = vec4(1.0, 1.0, 1.0, 0.0);
// Reachable with the raster map off, as long as the traced tier is on: the lookups below already
// choose the traced answer where one exists and fall back to the raster map otherwise, and that
// map reads as full light on its own when nothing draws into it.
#if defined(SHADOWS) || RT_SHADOWS
#ifdef PLAGUE_DEBUG_VIEWS
    int debugView = int(u_Param3 + 0.5);
    if (debugView == DBG_MOTION) {
        // Keep the same brightness boost this debug view already used, before handing off as
        // RGBA16F. Returning early, before the depth check, also keeps motion visible on sky
        // pixels and frees up resolve's motion input.
        fragColor = vec4(abs(texture(u_GMotion, texCoord).rg) * 40.0, 0.0, 1.0);
        return;
    }
    if (debugView == DBG_SHADOW_MAP_VIEW) {
        // This view reads the shadow map directly, including pixels where the camera sees sky.
        ivec2 mapTexel = ivec2(texCoord * vec2(textureSize(SHADOW_RAW_MAP, 0)));
        fragColor = plagueShadowDebugMapColor(texelFetch(SHADOW_RAW_MAP, mapTexel, 0).r);
        return;
    }
#endif
    float depth = texture(u_Depth, texCoord).r;
    vec4 worldH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
    vec3 worldPos = worldH.xyz / (abs(worldH.w) > 1e-6 ? worldH.w : 1.0);
    vec3 shadingNormal = texture(u_GNormal, texCoord).rgb;
    // Match the lighting pass's surface plane and offset, including the entity fallback normal.
    // The plane is worked out before any early return, so a sky pixel at the edge can't break it
    // for its neighbors.
    vec3 planeNormal = cross(dFdx(worldPos), dFdy(worldPos));
    float planeLength = length(planeNormal);
    planeNormal = planeLength > 1e-6 ? planeNormal / planeLength : shadingNormal;
    if (dot(planeNormal, shadingNormal) < 0.0) planeNormal = -planeNormal;
    if (depth <= 0.0) return;
#ifdef PLAGUE_DEBUG_VIEWS
    if (debugView == DBG_SHADOW_DEPTH_COMPARE) {
        // Match resolve's fallback for the shading normal and for a missing light direction,
        // but not its geometric bias.
        vec3 normal = dot(shadingNormal, shadingNormal) > 1e-6
                ? normalize(shadingNormal) : vec3(0.0, 1.0, 0.0);
        vec3 light = u_SunDirection.xyz;
        vec3 debugSunDir = dot(light, light) > 1e-6
                ? normalize(light) : normalize(vec3(0.3, 0.9, 0.2));
        vec3 coordinates = plagueShadowDebugCoordinates(worldH.xyz / worldH.w, normal, debugSunDir);
        ivec2 mapTexel = ivec2(clamp(coordinates.xy, 0.0, 1.0)
                              * vec2(textureSize(SHADOW_RAW_MAP, 0)));
        float storedDepth = texelFetch(SHADOW_RAW_MAP, mapTexel, 0).r;
        fragColor = vec4(coordinates.z, 0.0, storedDepth, 0.0);
        return;
    }
#endif
    vec3 sunDir = normalize(u_SunDirection.xyz);
    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);
    float direct = sunVisibility(worldPos, planeNormal, sunDir, rainFactor);
#if RT_SHADOWS
    // Row major on the CURRENT screen width, the same width the seed pass reads off the same depth
    // target this frame. A window bigger than the ray buffer's own count leaves the far rows of
    // the screen with no record at all; the bound check below is what keeps that fall-through
    // reaching the raster answer above instead of reading past the buffer.
    int sunShadowWidth = textureSize(u_Depth, 0).x;
    uint sunShadowIndex = uint(gl_FragCoord.y) * uint(sunShadowWidth) + uint(gl_FragCoord.x);
    uint sunShadowBase = sunShadowIndex * PLAGUE_SUN_SHADOW_HIT_WORDS;
    if (sunShadowBase + PLAGUE_SUN_SHADOW_HIT_WORDS <= uint(textureSize(u_SunShadowHits))) {
        int sunShadowTier = int(plagueSunShadowWord(int(sunShadowBase + PLAGUE_SUN_SHADOW_WORD_TIER)));
        if (sunShadowTier != FORNAX_RAY_TIER_NONE) {
            float sunShadowDistance = uintBitsToFloat(
                    plagueSunShadowWord(int(sunShadowBase + PLAGUE_SUN_SHADOW_WORD_DISTANCE)));
            // A miss (negative distance) means the sun was reached; anything else is a caster.
            float terrainLit = sunShadowDistance < 0.0 ? 1.0 : 0.0;
            // The traced ray only ever meets terrain: a mob or the player standing in the beam has
            // no mesh for it to hit. Its rastered depth is read at the same receiving point the
            // raster path already projects into, and the two answers are combined rather than one
            // throwing away the other.
            vec3 entityCoordinates = plagueShadowDebugCoordinates(worldPos, planeNormal, sunDir);
            float entityLit = 1.0;
            if (entityCoordinates.x > 0.0 && entityCoordinates.x < 1.0
                    && entityCoordinates.y > 0.0 && entityCoordinates.y < 1.0
                    && entityCoordinates.z > 0.0 && entityCoordinates.z < 1.0) {
                ivec2 entitySize = textureSize(SHADOW_RAW_MAP, 0);
                ivec2 entityTexel = clamp(ivec2(entityCoordinates.xy * vec2(entitySize)),
                        ivec2(0), entitySize - 1);
                entityLit = step(entityCoordinates.z,
                        texelFetch(ENTITY_SHADOW_RAW_MAP, entityTexel, 0).r);
            }
            direct = min(terrainLit, entityLit);
#if PLAGUE_SUN_SHADOW_VIEW
            // Branch codes, not light. The resolve turns each into a flat colour. The two halves
            // are kept apart on purpose: one number cannot say whether the terrain ray or the
            // entity map is what called this point blocked.
            // A caster met almost at once is the ray meeting the very face it left, which is a
            // different fault from a caster standing a way off. One number for both would hide it.
            // A distance of exactly nought is not a caster at nought blocks, it is a record with
            // no distance written into it. Telling that apart from a real near hit is the whole
            // reason these are separate codes.
            direct = terrainLit <= 0.5
                    ? (sunShadowDistance == 0.0 ? 0.5 : (sunShadowDistance < 0.25 ? 0.6 : 0.7))
                    : (entityLit <= 0.5 ? 0.8 : 0.9);
#endif
        } else {
            // A rebuild burst answers no ray at all for one or more whole frames, every provider
            // bailing at once. That is not a caster appearing, so painting the raster answer over
            // the whole screen is what flashes it fully lit the instant it happens: that map reads
            // as open sky wherever the raster option is off. This pixel's own last answer is
            // reprojected instead.
            //
            // A point the reprojection cannot place keeps the raster answer already worked out
            // above. Naming a number here instead would be inventing one: nought paints the
            // surface black and one paints it lit, and a whole screen doing either at once is the
            // very flash this branch exists to stop.
            vec2 motion = texture(u_GMotion, texCoord).rg;
            vec2 previousCoord = texCoord - motion;
            float heldDirect = direct;
            bool held = false;
            if (previousCoord.x >= 0.0 && previousCoord.x <= 1.0
                    && previousCoord.y >= 0.0 && previousCoord.y <= 1.0) {
                float previousDepth = texture(u_Depth, previousCoord).r;
                if (abs(depth - previousDepth)
                        <= PLAGUE_SUN_SHADOW_HISTORY_DEPTH_REJECT * max(depth, 1e-4)) {
                    heldDirect = texture(u_RtShadowComposite_history, previousCoord).r;
                    held = true;
                }
            }
            direct = heldDirect;
#if PLAGUE_SUN_SHADOW_VIEW
            direct = held ? 0.5 : 0.3;
#endif
        }
    }
#endif
    float rtSelected = plagueRtSelectedSum / float(2 * SHADOW_SAMPLES);
    float ambient = sunVisibilityAt(worldPos, planeNormal, sunDir, rainFactor,
                                    PLAGUE_SHADOW_AMBIENT_BROADEN);
    fragColor = vec4(direct, ambient, plagueCausticSunVisibility(worldPos, sunDir),
                     rtSelected);
#endif
}
