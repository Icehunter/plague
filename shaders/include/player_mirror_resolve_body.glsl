// Lights the player's own reflection: reconstructs the real, unreflected position and samples
// the real normal from its own mirror MRT, so self-shadowing and sky and block light land on
// the true surface rather than its mirror image, then writes a single lit HDR colour that
// ssr_trace(_water) composites into the final reflection.
//
// Shared by all three axis wrappers (shaders/post/player_mirror_resolve{,_x,_z}.fsh). Each one
// declares its own family's four samplers (the MIRROR_*_SAMPLER macros) and defines
// PLAGUE_MIRROR_AXIS (0 for floor, 1 for x wall, 2 for z wall) before importing this file, so the
// reconstruction and lighting body lives here once and the three axes cannot drift apart.
//
// Minimal by design, not gbuffer_resolve's full lit-surface path: direct sun with the shadow
// lookup, sky ambient from the sky light lane, block light from its lane. No specular, since no
// BRDF or material response is decoded here; no SSR, since this pass has nothing left to reflect;
// no fog, since the water surface's own compositing already fogs whatever it draws, mirror
// included. No AO lane and no emission lane either, since the mirror MRT carries neither (see
// PlayerMirrorTargets), so both feed plagueDoLighting as their neutral values, full AO and zero
// emission, instead of real data.
//
// Uses plagueOverworldLighting's small arity overload with no options buffer, the same one
// terrain.fsh's forward lit arms use, instead of building the full CUSTOM_LIGHT_COLORS palette
// from runtime options. This is an accepted simplification: live palette edits do not reach the
// mirror. Reflections are rarely studied closely enough for that gap to read as wrong, and
// building the roughly twenty uniform palette struct here would work against staying minimal.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:surface_lighting.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:player_mirror_guard.glsl>

// Bound as a hardware comparison sampler, like every other consumer of this builtin. texture()
// returns the depth test result, not the stored depth.
uniform sampler2DShadow u_SunShadowMap; // sunShadowMap
#define SUN_SHADOW_MAP u_SunShadowMap
uniform sampler2D u_SunShadowMapRaw; // sunShadowMapRaw, the blocker-distance search's raw depths
#define SHADOW_RAW_MAP u_SunShadowMapRaw
// Macros above must precede this import: shadow_filter.glsl's plagueShadowPenumbraUv references
// SHADOW_RAW_MAP directly in its own body, compiled at import time, not deferred.
#if defined(SHADOWS) || RT_SHADOWS
#moj_import <fornax_runtime:shadow_filter.glsl>
#endif

// Same layout gbuffer_resolve.fsh's own u_PassParams uses: the active light (sun by day, moon once
// it sets) in .xyz, true sun elevation (positive only while the real sun is up) in .w.
layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4  u_SunDirection;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    float mirrorDepth = texture(MIRROR_DEPTH_SAMPLER, texCoord).r;

    // Reconstruction: mirror UV to guarded NDC to the pack's standard unproject.
    //
    // Same texCoord-to-NDC mapping every consumer of this camera's own G-buffer uses
    // (gbuffer_resolve.fsh's own `texCoord * 2.0 - 1.0`). The mirror MRT is rasterized by the
    // same graphics pipeline as any other geometry pass, so nothing about reading it back is
    // mirror-specific except the guard band, inverted next by player_mirror_guard.glsl's shared
    // formula.
    float xNdcGuarded = texCoord.x * 2.0 - 1.0;
    float yNdcGuarded = texCoord.y * 2.0 - 1.0;
#if PLAGUE_MIRROR_AXIS == 0
    float xNdc = xNdcGuarded;
    float yNdc = plagueMirrorUnguardBottomNdc(yNdcGuarded);
#else
    float xNdc = plagueMirrorUnguardHorizontalNdc(xNdcGuarded);
    float yNdc = yNdcGuarded;
#endif

    vec4 clip = vec4(xNdc, yNdc, mirrorDepth, 1.0);
    vec4 worldH = u_InvProjModelView * clip;
    vec3 mirroredPos = worldH.xyz / worldH.w; // camera-relative, mirrored

    // The real position is the mirrored one reflected back across the plane. This is the exact
    // inverse of the vertex body's own mirrored assignment (player_mirror_body_vsh.glsl).
    vec3 realPos = mirroredPos;
#if PLAGUE_MIRROR_AXIS == 0
    realPos.y = 2.0 * (u_PlayerMirrorState.y - u_CameraAbs.y) - mirroredPos.y;
#elif PLAGUE_MIRROR_AXIS == 1
    // Camera-relative already, per WallPlaneProbe's publish contract, so no camera term here,
    // unlike the floor's absolute plane height above.
    realPos.x = 2.0 * u_PlayerMirrorWalls.y - mirroredPos.x;
#else
    realPos.z = 2.0 * u_PlayerMirrorWalls.w - mirroredPos.z;
#endif

    vec4 normalSample = texture(MIRROR_NORMAL_SAMPLER, texCoord);
    vec3 n = normalSample.xyz;
    // The real, unreflected normal. The fragment body writes it this way so lighting lands on
    // the true surface, not its mirror image (see player_mirror_body_fsh.glsl).
    vec3 realNormal = dot(n, n) > 1e-6 ? normalize(n) : vec3(0.0, 1.0, 0.0);

    // Same geometric-plane bias gbuffer_resolve.fsh (shadowGeomNormal) and rt_shadow_composite.fsh
    // (planeNormal) both feed plaguePrepareSunVisibility instead of the shading normal. The
    // screen-space derivative of the reconstructed position is the plane this rasterizer actually
    // put down, while the shading normal is per-vertex and can sit at a real angle to it. At the
    // player model's small scale, that angle is enough for the shading normal to read the body as
    // self-shadowed even at noon in open sun, an offset gbuffer_resolve's terrain-scale callers
    // rarely notice at their scale. The derivative of realPos is the local surface plane regardless
    // of which world axis it was reflected across, so this bias works the same for all three axes.
    //
    // Worked out before any early return below, same reason rt_shadow_composite.fsh's own comment
    // gives: dFdx/dFdy is undefined once some invocations in a 2x2 quad have returned and others have
    // not, so a cleared texel at the mirror's silhouette edge must not be allowed to skip this and
    // leave its live neighbors with a garbage derivative.
    vec3 shadowGeomNormal = cross(dFdx(realPos), dFdy(realPos));
    float shadowGeomLen = length(shadowGeomNormal);
    shadowGeomNormal = shadowGeomLen > 1e-6 ? shadowGeomNormal / shadowGeomLen : realNormal;
    if (dot(shadowGeomNormal, realNormal) < 0.0) {
        shadowGeomNormal = -shadowGeomNormal;
    }

    // Cleared texel: nothing drew here this frame (the falling-edge clear, an off-frustum guard-band
    // row, or the caster not running). Coverage is 0, the contract the trace reads.
    if (mirrorDepth <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    vec4 albedoSample = texture(MIRROR_ALBEDO_SAMPLER, texCoord);
    vec3 albedo = plagueSrgbToLinear(albedoSample.rgb);
    float skyLight = albedoSample.a;
    float blockLight = texture(MIRROR_MATERIAL_SAMPLER, texCoord).a;

    vec3 s = u_SunDirection.xyz;
    vec3 sunDir = dot(s, s) > 1e-6 ? normalize(s) : normalize(vec3(0.3, 0.9, 0.2));

    float rainFactor = clamp(u_SkyState.x, 0.0, 1.0);
    float trueSunHeight = u_SunDirection.w;

    // Direct sun with the shadow lookup.
    //
    // Computed fresh in world space, not sampled from rtShadowComposite: that texture answers for
    // the main camera's own screen grid, and the mirror's real position is arbitrary reflected
    // geometry with no corresponding main-camera pixel to read it from. sunVisibility() is
    // shadow_filter.glsl's one-call wrapper around the same raster shadow-map query
    // rt_shadow_composite.fsh builds its own answer from. The traced-tier refinement that pass
    // layers on top (ray-hit buffers, entity map, temporal history) is left out here, per this
    // file's minimal scope stated above.
    float shadow = 1.0;
#if defined(SHADOWS) || RT_SHADOWS
    shadow = sunVisibility(realPos, shadowGeomNormal, sunDir, rainFactor);
#endif

    // Parity with gbuffer_resolve.fsh's own shadow softening (plagueDoLighting), simplified to
    // skyLight alone since this pass has no underwater shadowSkyGate branch to choose between:
    // a moonlit shadow fades toward lit rather than reading as sharp as a noon one, since real
    // moonlight is about a millionth of sunlight and a hard edge from it reads wrong. `shadow`
    // itself stays the raw comparison above for the debug views; only what reaches the composite
    // below is softened.
    float dayFactor = smoothstep(-0.08, 0.08, trueSunHeight);
    float casterStrength = mix(0.18, 1.0, dayFactor);
    float shadowForLighting = mix(1.0, shadow, clamp(skyLight, 0.0, 1.0) * casterStrength);

    // Sky ambient and sun, ambient, and block light colours, from the same functions
    // gbuffer_resolve uses (light_and_ambient_colors.glsl and surface_lighting.glsl), fed the
    // small arity fallback lighting table. See this file's header for why.
    PlagueLighting lighting = plagueOverworldLighting(
            max(u_SkyColor.rgb, vec3(0.0)), trueSunHeight, u_SkyState.y,
            rainFactor, u_ScreenBrightness);

    vec3 sunDirTrue = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
            ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);
    PlagueSkyColors skyColours = plagueSkyColors(max(u_SkyColor.rgb, vec3(0.0)),
            sunDirTrue, lighting.sunVisibility, rainFactor, u_CameraAbs.y);
    PlagueSurfaceLighting surfaceLighting = plagueSurfaceLighting(lighting, skyColours,
            sunDir, sunDirTrue, rainFactor, vec3(1.0), trueSunHeight, u_CameraAbs.y, vec3(1.0));

    float moonPhaseInf = plagueMoonPhaseInfluence(u_SkyCelestial.w, lighting.sunVisibility2);

    // No AO lane, no emission lane in this MRT (see this file's header): 1.0 is "no darkening", 0.0
    // is "no self-emission", the neutral values plagueDoLighting expects for surfaces it has no
    // per-texel data for.
    PlagueLitResult litResult = plagueDoLighting(
            surfaceLighting.sunColour, surfaceLighting.ambientColour,
            realNormal, sunDir,
            shadowForLighting, blockLight, skyLight,
            1.0, 0.0, albedo, vec3(0.0), surfaceLighting.blockLightColour,
            lighting.noonFactor, lighting.sunVisibility2, lighting.rainFactor,
            u_ScreenBrightness, moonPhaseInf, vec3(1.0), -1.0, vec3(0.0));

    // Parity with gbuffer_resolve.fsh's own kD, the energy split between what a surface reflects
    // and what it transmits back out as diffuse. This MRT carries no material data at all: F0 and
    // metalness are both forced to zero in player_mirror_body_fsh.glsl, a fully neutral dielectric,
    // so specularAlbedo is zero and kD reduces to vec3(1.0) today. Kept as a named, computed term
    // rather than folded away, so this line needs no revisit once labPBR reaches this variant and
    // specularAlbedo stops being zero.
    vec3 specularAlbedoNeutral = vec3(0.0);
    float metalnessNeutral = 0.0;
    vec3 kD = (1.0 - specularAlbedoNeutral) * (1.0 - metalnessNeutral);

    vec3 lit = kD * litResult.diffuse * albedo + litResult.emitted;

    // Debug: the reflection itself displays the chosen term (alpha, the coverage this pass reports
    // downstream, is unchanged either way). Gated on the axis, not on whether u_MirrorDebug happens
    // to be declared: PLAGUE_MIRROR_AXIS is this file's own plain compile-time integer, with no
    // runtime-option machinery attached to it, so this guard is unambiguous regardless of how the
    // pack's option scanner treats a runtime-annotated define elsewhere. u_MirrorDebug is declared
    // in the floor wrapper only: this reflection has nowhere else on screen to be read back, and
    // one instance of the option is enough to diagnose any of the three, since the mechanism this
    // file implements is identical for all three and a defect in it would show on the floor too.
#if PLAGUE_MIRROR_AXIS == 0
    if (u_MirrorDebug > 0.5) {
        vec3 debugColour;
        if (u_MirrorDebug < 1.5) {
            debugColour = vec3(shadow);
        } else if (u_MirrorDebug < 2.5) {
            debugColour = albedo;
        } else if (u_MirrorDebug < 3.5) {
            debugColour = vec3(skyLight);
        } else if (u_MirrorDebug < 4.5) {
            debugColour = vec3(blockLight);
        } else if (u_MirrorDebug < 5.5) {
            // Pushed 0.8 block along the sun direction from the same realPos, past the body's own
            // roughly 0.6 block thickness (the widest torso and leg span in the vanilla player
            // model): a diagnostic reference reading, not part of the lit result. If this reads
            // dark where `shadow` above also reads dark, the two cannot both be real self-occlusion,
            // so something upstream of the compare (the reconstructed position, the projection, or
            // the bound map) is wrong instead. Computed only here, not with `shadow` above, since
            // this is a second full filtered shadow query and this view is the only reader of it.
            float sunProbe = 1.0;
#if defined(SHADOWS) || RT_SHADOWS
            sunProbe = sunVisibility(realPos + sunDir * 0.8, shadowGeomNormal, sunDir, rainFactor);
#endif
            debugColour = vec3(sunProbe);
        } else if (u_MirrorDebug < 6.5) {
            // Independent of any lighting: paints the reconstructed absolute height against the
            // render plane alone. player_mirror_body_fsh.glsl already discards below or behind it,
            // so red here means the reconstruction disagrees with its own source geometry, which is
            // enough on its own to point at a bug. 2.5 blocks is a standing player's own height
            // (vanilla is about 1.8, and the crouched and swimming poses plus the guard band's own
            // extra reach both fit under it), so green ramping across that span reads as a body, not
            // as noise. Floor only, the one axis this view was built against: a wall pass reports
            // the same realPos.y relative to nothing in particular, which is fine since the debug
            // option lives on the floor wrapper alone.
            float heightAboveRenderPlane = (realPos.y + u_CameraAbs.y) - u_PlayerMirrorState.y;
            if (heightAboveRenderPlane < 0.0) {
                debugColour = vec3(1.0, 0.0, 0.0);
            } else if (heightAboveRenderPlane <= 2.5) {
                debugColour = vec3(0.0, clamp(heightAboveRenderPlane / 2.5, 0.0, 1.0), 0.0);
            } else {
                debugColour = vec3(0.0, 0.0, 1.0);
            }
        } else {
            // The three remaining checks, since position and normal are already cleared by Real
            // Height: the raw comparison itself, whether the projection even landed in the map, and
            // whether a real sun direction reached this pass at all.
            float rawCompare = 0.0;
            float inBoundsFlag = 0.0;
#if defined(SHADOWS) || RT_SHADOWS
            PlagueShadowReceiver chainReceiver = plaguePrepareSunVisibility(realPos, shadowGeomNormal, sunDir);
            inBoundsFlag = chainReceiver.inBounds ? 1.0 : 0.0;
            if (chainReceiver.inBounds) {
                rawCompare = textureLod(SUN_SHADOW_MAP, vec3(chainReceiver.uv, chainReceiver.depth), 0.0);
            }
#endif
            debugColour = vec3(rawCompare, inBoundsFlag, u_SunDirection.y * 0.5 + 0.5);
        }
        fragColor = vec4(debugColour, 1.0);
        return;
    }
#endif

    fragColor = vec4(lit, 1.0);
}
