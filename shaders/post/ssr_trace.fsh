#version 330

// Screen-space reflections: one mirror ray per pixel, marched through the Hi-Z pyramid.
//
// The ray follows the receiver's mirror direction. ssr_blur reconstructs the material's glossy
// lobe; a screen-pixel direction perturbation would change a fixed receiver's hit as the view turns.
//
// Hit acceptance is crossing + linear thickness, never proximity: accepting a "near" ray grows a
// false outline around every reflected silhouette, and dithers pixel to pixel at distance.
//
// Depth comparisons happen in linear camera-relative blocks, never raw NDC deltas: reversed-Z is
// non-linear near the camera, so a fixed NDC epsilon means something different at 5 blocks vs 50.
//
// Run by two passes at two resolutions (`ssr_trace_fancy` full-scale, `ssr_trace_fast` half-scale,
// see graph.toml's reflections block) with no #ifdef between them. Every screen-space quantity is
// derived from the full-res depth texture, never u_PassTexelSize, so Fast fires a quarter as many
// of the same rays rather than coarser ones.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>

uniform sampler2D u_GNormal; // builtin.gNormal
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GMaterial; // builtin.gMaterial: r = smoothness, g = F0, b = porosity/SSS
uniform sampler2D u_GMotion; // builtin.gMotion: reprojects the hit into last frame
uniform sampler2D u_SceneHdrComposited_history; // last frame's linear HDR scene, before glass is drawn
uniform sampler2D u_Hiz; // hiz: full mip chain, read with explicit levels
// Appended last: positional inputs, append never insert. Both arms, ssr_trace_fancy and
// ssr_trace_fast, share this one file.
uniform sampler2D u_MirrorHdr; // mirrorHdr: the player's own reflection, already lit
uniform sampler2D u_MirrorDepth; // builtin.mirrorDepth: reversed-Z, 0.0 = no reflection here
// player_mirror_trace.glsl's own opt-in contract: declare u_MirrorDepth (above) before importing.
#moj_import <fornax_runtime:player_mirror_trace.glsl>
// Appended again: positional inputs, append never insert. The two wall families' own depth
// textures are read through plagueMirrorMarchGeneral's explicit sampler argument, not the opt-in
// u_MirrorDepth name above. That name belongs to the floor alone: one caller reads three different
// mirror depths in the same frame, so no single fixed name could serve all three.
uniform sampler2D u_MirrorXHdr; // mirrorXHdr: the player's own X-wall reflection, already lit
uniform sampler2D u_MirrorXDepth; // builtin.mirrorXDepth: reversed-Z, 0.0 = no reflection here
uniform sampler2D u_MirrorZHdr; // mirrorZHdr: the player's own Z-wall reflection, already lit
uniform sampler2D u_MirrorZDepth; // builtin.mirrorZDepth: reversed-Z, 0.0 = no reflection here

#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "World Reflections" {0="Off" 1="On"}
#if PLAGUE_VOXEL_REFLECTIONS != 0
// Appended after all mirror inputs. Only a confirmed wall-player hit spends this bounded query;
// world recovery is merged later and carries confidence, not the distance needed to hide a body.
#define PLAGUE_VOXEL_ALPHA_CUTOUTS
#define PLAGUE_VOXEL_TEXTURED_FACES
#define u_Input9 u_BlockAtlas
#define u_Input10 u_VoxelFaceTexture
#moj_import <fornax_runtime:voxel_coverage.glsl>
#undef u_Input9
#undef u_Input10
#endif

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2; // Hi-Z level count; supplied ONLY for a pass named ssr_trace_fancy/ssr_trace_fast
    float u_Param3;
    vec3  u_SunDirection;
};

#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="High" 2="Epic"}
#define u_SsrMaxDistance 32.0 //[16.0..256.0 step 4.0] runtime "Reflection Distance"
#define u_SsrTraceQuality 64.0 //[16.0..96.0 step 4.0] runtime "Reflection Quality"

in vec2 texCoord;
out vec4 fragColor; // rgb = reflected colour, a = hit confidence [0,1]

/** Camera-relative world position for a screen UV and its reversed-Z depth. */
vec3 worldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    return world.xyz / world.w;
}

// Raster depth belongs to its nearest texel centre, including at fractional trace hits.
vec3 reflectionSurfaceAt(vec2 uv, float depth) {
    vec2 size = vec2(textureSize(u_Depth, 0));
    vec2 center = (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
    return worldPosAt(center, depth);
}

/** Camera-relative world position back to screen UV + reversed-Z NDC depth. */
vec3 projectToScreen(vec3 pos) {
    vec4 clip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(pos, 1.0);
    return vec3((clip.xy / clip.w) * 0.5 + 0.5, clip.z / clip.w);
}

#if PLAGUE_VOXEL_REFLECTIONS != 0
bool plagueMirrorWorldBlocked(vec3 origin, vec3 normal, vec3 direction, float distanceToBody) {
    vec3 start = origin + normal * PLAGUE_COVERAGE_EPSILON;
    // A segment crosses at most |dx|+|dy|+|dz| cell boundaries, plus its initial cell and
    // endpoint rounding. This bounds transparent continuation by geometry, not a layer preset.
    int cells = int(ceil(distanceToBody * dot(abs(direction), vec3(1.0)))) + 3;
    for (int layer = 0; layer < cells; ++layer) {
        float remaining = distanceToBody - dot(start - origin, direction);
        if (remaining <= 0.0) return false;
        vec3 point, faceNormal, local;
        uint colour;
        int entry;
        float state = plagueVoxelTraceMaterialBounded(start, direction, remaining, cells,
                point, faceNormal, colour, entry, local);
        // Missing/pending/outside data cannot prove an occluder. Keep the existing screen answer.
        if (state != 1.0) return false;
        uint flags = texelFetch(u_VoxelPalette, entry * 16).r;
        // Cutout/CROSS hits already passed their texel alpha test. The independent opaque-face
        // flag preserves full grass backing even when its overlay prevents a single UV mapping.
        if ((flags & 0xc0000000u) != 0u || plagueVoxelOpaqueFace(entry, faceNormal)) return true;
        vec4 texel;
        if (!plagueVoxelFaceSample(entry, local, faceNormal, texel)) return false;
        // Match world reflection's 8-bit alpha criterion; translucent glass must not erase a body.
        if (texel.a >= 0.99) return true;
        float exitDistance = 1e30; // unbounded along a parallel axis, as in voxel_coverage.glsl
        for (int axis = 0; axis < 3; ++axis) {
            if (direction[axis] == 0.0) continue;
            exitDistance = min(exitDistance,
                    ((direction[axis] > 0.0 ? 1.0 : 0.0) - local[axis]) / direction[axis]);
        }
        start = point + direction * (max(exitDistance, 0.0) + PLAGUE_COVERAGE_EPSILON);
    }
    return false; // exhausted/unknown is not confirmed opaque coverage
}
#endif

void main() {
    float depth = texture(u_Depth, texCoord).r;
    if (depth <= 0.0) {          // reversed-Z: 0.0 is the cleared far plane, i.e. sky
        fragColor = vec4(0.0);
        return;
    }

    vec4 packedNormal = texture(u_GNormal, texCoord);
    vec3 n = packedNormal.xyz;
    if (dot(n, n) < 1e-6) {
        fragColor = vec4(0.0);
        return;
    }
    vec3 normal = normalize(n);

    // gMaterial already carries wetness: terrain.fsh applies puddles before writing the G-buffer,
    // so this is the wetted smoothness with no re-derivation needed, and it cannot disagree with
    // what the blur and the resolve see.
    float smoothness = texture(u_GMaterial, texCoord).r;

    // Surfaces the resolve will never show a reflection on skip the march entirely. Kept in step
    // with the resolve's own smoothnessFade lower bound.
    if (smoothness < 0.1) {
        fragColor = vec4(0.0);
        return;
    }

    vec3 origin = worldPosAt(texCoord, depth);
    vec3 viewDir = normalize(origin); // the camera sits at the origin in camera-relative space
    vec3 geometricNormal = plagueDecodeGeometricNormal(packedNormal.a, normal);

    // Mirror direction: the bump normal's reflection folded back above the geometric horizon
    // instead of rejected, the same walk the world reflection pass uses (Schuessler, Heitz,
    // Hanika and Dachsbacher, Microfacet-based Normal Mapping for Robust Monte Carlo Path
    // Tracing, 2017).
    vec3 wp = normal;
    vec3 wg = geometricNormal;
    vec3 mirror;
    if (dot(wp, wg) < 0.9999) {
        vec3 wt = -normalize(wp - dot(wp, wg) * wg);
        if (dot(-viewDir, wp) > 1e-4) {
            mirror = reflect(viewDir, wp);
            if (dot(mirror, wg) <= 0.0) mirror = reflect(mirror, wt);
            if (dot(mirror, wg) <= 0.0) mirror = reflect(mirror, wp);
        } else {
            mirror = reflect(viewDir, wt);
            if (dot(mirror, wg) <= 0.0) mirror = reflect(mirror, wp);
        }
    } else {
        mirror = reflect(viewDir, wp);
    }
    if (dot(mirror, wg) < 1e-3) mirror = normalize(mirror + wg * (1e-3 - dot(mirror, wg)));

    vec3 rayDir = mirror;

    // The horizon nudge above divides by the renormalized length, which can leave the dot product
    // a hair under 1e-3; catch that residual here rather than rejecting the pixel outright.
    if (dot(rayDir, geometricNormal) < 1e-3) {
        rayDir = normalize(rayDir + geometricNormal * (1e-3 - dot(rayDir, geometricNormal)));
    }

    // --- The player's own reflection, opaque consumer -----------------------------------------
    //
    // Reached only past SSR's own smoothness gate above, and correctly so: a mirror image is a
    // specular reflection, and a fully matte surface does not produce one. Sitting past that gate
    // is the physics, not a limitation of this placement.
    //
    // Three routes, chosen by the geometric normal (already decoded above) and disjoint by
    // construction: a unit normal cannot read as up (|n.y| > 0.95) and as either horizontal axis
    // (|n.x| or |n.z| > 0.95) at the same time, so at most one of the three tests below can pass
    // for any one receiver (tools/verify_player_mirror_walls.py measures this: 0 of 25600
    // receivers routed to more than one mirror). A facing lane of 0 means no wall was found on
    // that axis at all, WallPlaneProbe's own "0 = invalid" convention. sign(n.x) can never equal
    // exactly 0.0 for a normal this close to axis-aligned, so the routing test below already
    // excludes it without a separate check, but the guard is named explicitly anyway.
    bool mirrorHit = false;
    bool wallMirrorHit = false;
    vec3 mirrorColour = vec3(0.0);
    float mirrorConfidence = 0.0;
    float mirrorDistance = 1e30;

    // Floor: receiver within 0.05 block of the standing plane w. Solid tops sit at an exact
    // height, not wave-displaced like the water consumer's 1.0-block tolerance: a slab one step
    // down sits at a different height and must not borrow the plane. The render plane
    // must be valid, not the -1e4 sentinel.
    float mirrorStandPlane = u_PlayerMirrorState.w;
    float mirrorRenderPlane = u_PlayerMirrorState.y;
    float receiverAltitude = u_CameraAbs.y + origin.y;
    if (u_PlayerMirrorState.x > 0.5 && mirrorStandPlane > -1000.0
            && geometricNormal.y > 0.95
            && abs(receiverAltitude - mirrorStandPlane) < 0.05) {
        // Reflecting about the standing plane is the same as reflecting about the render plane,
        // the same standing plane when it validated, so this is normally a no-op shift, then
        // translating y by 2*(w - y). player_mirror_trace.glsl's own doc has the general form.
        vec3 mirrorShift = vec3(0.0, 2.0 * (mirrorStandPlane - mirrorRenderPlane), 0.0);
        // Coverage reject first: this receiver's own surface point, shifted the same way,
        // projected through the mirror's own guarded frustum, lands where the planar identity
        // says the mirror covers it. A cleared texel there means nothing reflects here.
        vec3 coverageProj = projectMirrorGuarded(origin - mirrorShift);
        if (coverageProj.x >= 0.0 && coverageProj.x < 1.0
                && coverageProj.y >= 0.0 && coverageProj.y < 1.0 && coverageProj.z > 0.0
                && texture(u_MirrorDepth, coverageProj.xy).r > 0.0) {
            vec3 rPrime = mirror;
            rPrime.y = -rPrime.y;
            vec3 hitWorld;
            vec2 hitUv;
            if (plagueMirrorMarchGeneral(origin, rPrime, mirrorStandPlane, mirrorRenderPlane,
                    1.0, 0, u_MirrorDepth, hitWorld, hitUv)) {
                vec4 mirrorSample = texture(u_MirrorHdr, hitUv);
                vec2 mdist = abs(hitUv - 0.5) * 2.0;
                float mirrorEdge = clamp(1.0 - pow(max(mdist.x, mdist.y), 8.0), 0.0, 1.0);
                mirrorHit = true;
                mirrorDistance = length(hitWorld - origin);
                // Un-premultiply: mirrorHdr is linear-filtered and a cleared texel is vec4(0), see
                // ssr_trace_water.fsh's own identical comment for the mechanism.
                mirrorColour = mirrorSample.rgb / max(mirrorSample.a, 1e-4);
                mirrorConfidence = clamp(mirrorSample.a, 0.0, 1.0) * mirrorEdge;
            }
        }
    // Wall receivers choose their own plane. The engine probe chooses the capture plane only:
    // a nearer grass block must not replace every visible iron-wall receiver with its own plane.
    // A shifted receiver can start behind the capture camera, so the march owns coverage; testing
    // the receiver's initial projected texel would reject valid hits before the ray enters it.
    } else if (u_PlayerMirrorWalls.x != 0.0 && abs(geometricNormal.x) > 0.95
            && sign(geometricNormal.x) == u_PlayerMirrorWalls.x) {
        vec3 rPrime = mirror;
        rPrime.x = -rPrime.x;
        vec3 hitWorld;
        vec2 hitUv;
        if (plagueMirrorMarchGeneral(origin, rPrime, origin.x, u_PlayerMirrorWalls.y,
                u_PlayerMirrorWalls.x, 1, u_MirrorXDepth, hitWorld, hitUv)) {
            vec4 mirrorSample = texture(u_MirrorXHdr, hitUv);
            vec2 mdist = abs(hitUv - 0.5) * 2.0;
            float mirrorEdge = clamp(1.0 - pow(max(mdist.x, mdist.y), 8.0), 0.0, 1.0);
            mirrorHit = true;
            wallMirrorHit = true;
            mirrorDistance = length(hitWorld - origin);
            mirrorColour = mirrorSample.rgb / max(mirrorSample.a, 1e-4);
            mirrorConfidence = clamp(mirrorSample.a, 0.0, 1.0) * mirrorEdge;
        }
    } else if (u_PlayerMirrorWalls.z != 0.0 && abs(geometricNormal.z) > 0.95
            && sign(geometricNormal.z) == u_PlayerMirrorWalls.z) {
        vec3 rPrime = mirror;
        rPrime.z = -rPrime.z;
        vec3 hitWorld;
        vec2 hitUv;
        if (plagueMirrorMarchGeneral(origin, rPrime, origin.z, u_PlayerMirrorWalls.w,
                u_PlayerMirrorWalls.z, 2, u_MirrorZDepth, hitWorld, hitUv)) {
            vec4 mirrorSample = texture(u_MirrorZHdr, hitUv);
            vec2 mdist = abs(hitUv - 0.5) * 2.0;
            float mirrorEdge = clamp(1.0 - pow(max(mdist.x, mdist.y), 8.0), 0.0, 1.0);
            mirrorHit = true;
            wallMirrorHit = true;
            mirrorDistance = length(hitWorld - origin);
            mirrorColour = mirrorSample.rgb / max(mirrorSample.a, 1e-4);
            mirrorConfidence = clamp(mirrorSample.a, 0.0, 1.0) * mirrorEdge;
        }
    }
#if PLAGUE_VOXEL_REFLECTIONS != 0
    // Run before every mirror fallback, including camera-facing rays whose screen march skips.
    // Suppressing only this candidate lets the later world-recovery pass supply the nearer block.
    if (wallMirrorHit && plagueMirrorWorldBlocked(origin, geometricNormal, rayDir, mirrorDistance)) {
        mirrorHit = false;
    }
#endif

    // A ray pointing back at the camera has nothing resolvable in screen space. The player mirror
    // is a separate lookup, not a screen-space one, so it can still answer here.
    if (dot(rayDir, viewDir) < -0.9) {
        if (mirrorHit) {
            fragColor = vec4(mirrorColour, mirrorConfidence);
            return;
        }
        fragColor = vec4(0.0);
        return;
    }

    // Clip before projecting the endpoint: a point behind the camera has negative clip w, and the
    // perspective divide flips its NDC position, corrupting the screen-space direction for the
    // whole march (floor reflections viewed from above are the common case).
    float rayLen = u_SsrMaxDistance;
    {
        float wOrigin = (u_ProjectionMatrix * u_ModelViewMatrix * vec4(origin, 1.0)).w;
        float wEnd = (u_ProjectionMatrix * u_ModelViewMatrix * vec4(origin + rayDir * rayLen, 1.0)).w;
        const float W_MIN = 0.1;
        if (wEnd < W_MIN) {
            rayLen *= clamp((wOrigin - W_MIN) / max(wOrigin - wEnd, 1e-5), 0.02, 1.0);
        }
    }

    vec3 ssOrigin = vec3(texCoord, depth);
    vec3 ssDir = projectToScreen(origin + rayDir * rayLen) - ssOrigin;

    // Start ~2 texels along the ray so the first cell test cannot self-hit.
    ivec2 fullSize = textureSize(u_Depth, 0);
    float s = 2.0 / max(abs(ssDir.x) * float(fullSize.x), abs(ssDir.y) * float(fullSize.y));

    int level = 0;
    int levelCount = max(int(u_Param2), 1);
    float hitS = -1.0;

    for (int i = 0; i < int(u_SsrTraceQuality); i++) {
        if (s >= 1.0) {
            break;
        }
        vec3 p = ssOrigin + ssDir * s;
        // Left the screen, or passed the far plane (reversed-Z: z decreasing toward 0).
        if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z <= 0.0) {
            break;
        }

        ivec2 levelSize = textureSize(u_Hiz, level);
        // min() guards p.xy == 1.0 exactly: an out-of-bounds texelFetch is undefined, not clamped.
        ivec2 cell = min(ivec2(p.xy * vec2(levelSize)), levelSize - 1);
        float tileClosest = texelFetch(u_Hiz, cell, level).r;

        if (p.z > tileClosest) {
            // Reversed-Z: larger is nearer, so the ray is in front of EVERYTHING in this tile.
            // Nothing here can be hit; skip straight to the tile boundary and coarsen.
            vec2 cellMin = vec2(cell) / vec2(levelSize);
            vec2 cellMax = (vec2(cell) + 1.0) / vec2(levelSize);
            vec2 tNext;
            tNext.x = ssDir.x != 0.0 ? ((ssDir.x > 0.0 ? cellMax.x : cellMin.x) - ssOrigin.x) / ssDir.x : 1e30;
            tNext.y = ssDir.y != 0.0 ? ((ssDir.y > 0.0 ? cellMax.y : cellMin.y) - ssOrigin.y) / ssDir.y : 1e30;
            s = min(tNext.x, tNext.y) + 1e-5; // the epsilon pushes into the next cell, never onto its edge
            level = min(level + 1, levelCount - 1);
        } else if (level > 0) {
            level--; // something in this tile is in the way: refine before believing it
        } else {
            // This is the only place a hit can be taken. `level == 0` here, the only way to
            // reach this part of the code, so `tileClosest` above is already the depth for
            // this cell at this level. No need to read it again.
            vec3 scenePos = worldPosAt(p.xy, tileClosest);
            vec3 rayPos = worldPosAt(p.xy, p.z);
            float behind = length(rayPos) - length(scenePos); // > 0: the ray has crossed BEHIND the surface
            // Linear thickness window: the lower bound rejects the ray's own start surface, the
            // upper bound rejects a ray that passed far behind something (smeared streaks).
            if (behind > 0.02 && behind < 1.0 && distance(rayPos, origin) > 0.15) {
                hitS = s;
                break;
            }
            s += 1.0 / max(float(max(levelSize.x, levelSize.y)), 1.0);
        }
    }

    // Every zero-confidence miss below can still be answered by the player mirror: it is a
    // separate lookup, not a screen-space one, so an SSR miss/backface/off-screen-history reject
    // does not mean there is nothing to show here.
    if (hitS < 0.0) {
        if (mirrorHit) {
            fragColor = vec4(mirrorColour, mirrorConfidence);
            return;
        }
        fragColor = vec4(0.0); // miss: zero colour AND zero confidence, never a fabricated fallback
        return;
    }

    vec3 hit = ssOrigin + ssDir * hitS;

    // Backface rejection: a hit whose normal points along the ray struck the surface's far side
    // (e.g. a roof's sunlit top standing in for its unrendered underside).
    vec3 hn = texture(u_GNormal, hit.xy).xyz;
    if (dot(hn, hn) > 1e-6 && dot(normalize(hn), rayDir) > 0.0) {
        if (mirrorHit) {
            fragColor = vec4(mirrorColour, mirrorConfidence);
            return;
        }
        fragColor = vec4(0.0);
        return;
    }

    // Colour comes from last frame's scene, reprojected: this frame's scene colour isn't available
    // yet (the resolve that produces it consumes this pass's output).
    vec2 historyUv = hit.xy - texture(u_GMotion, hit.xy).rg;
    if (historyUv.x < 0.0 || historyUv.x > 1.0 || historyUv.y < 0.0 || historyUv.y > 1.0) {
        if (mirrorHit) {
            fragColor = vec4(mirrorColour, mirrorConfidence);
            return;
        }
        fragColor = vec4(0.0);
        return;
    }
    // The scene before glass and other translucent blocks are drawn. The finished image has glass
    // over whatever is behind it, and a reflected ray that never crossed that glass must not take
    // its colour. The world trace adds glass only where the reflected ray crosses it.
    //
    // Gather on the raster hit plane. The accepted ray endpoint can lie up to one block behind
    // it; using that endpoint rejects the real hit and can instead admit a different surface.
    // Existing hit-gather tolerance: 0.1 blocks. Face compatibility matches ssr_blur's 0.9 gate.
    const float SSR_HIT_PLANE_TOLERANCE = 0.1;
    const float SSR_HIT_NORMAL_REJECT = 0.9;
    float hitDepth = texture(u_Depth, hit.xy).r;
    vec3 hitWorld = reflectionSurfaceAt(hit.xy, hitDepth);
    vec4 hitPackedNormal = texture(u_GNormal, hit.xy);
    vec3 hitFace = vec3(0.0);
    if (dot(hitPackedNormal.xyz, hitPackedNormal.xyz) >= 1e-6) {
        hitFace = plagueDecodeGeometricNormal(hitPackedNormal.a, normalize(hitPackedNormal.xyz));
    }
    vec3 colorSum = vec3(0.0);
    float colorWeight = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 tapHit = hit.xy + vec2(float(x), float(y)) / vec2(fullSize);
            if (tapHit.x < 0.0 || tapHit.x > 1.0 || tapHit.y < 0.0 || tapHit.y > 1.0) continue;
            float tapDepth = texture(u_Depth, tapHit).r;
            if (tapDepth <= 0.0) continue;
            vec4 tapPackedNormal = texture(u_GNormal, tapHit);
            if (dot(tapPackedNormal.xyz, tapPackedNormal.xyz) < 1e-6) continue;
            vec3 tapFace = plagueDecodeGeometricNormal(tapPackedNormal.a, normalize(tapPackedNormal.xyz));
            if (dot(tapFace, hitFace) < SSR_HIT_NORMAL_REJECT) continue;
            vec3 separation = reflectionSurfaceAt(tapHit, tapDepth) - hitWorld;
            if (max(abs(dot(separation, hitFace)), abs(dot(separation, tapFace)))
                    > SSR_HIT_PLANE_TOLERANCE) continue;
            vec2 tapHistoryUv = tapHit - texture(u_GMotion, tapHit).rg;
            if (tapHistoryUv.x < 0.0 || tapHistoryUv.x > 1.0
                    || tapHistoryUv.y < 0.0 || tapHistoryUv.y > 1.0) continue;
            colorSum += texture(u_SceneHdrComposited_history, tapHistoryUv).rgb;
            colorWeight += 1.0;
        }
    }
    // Missing surface normals may leave no compatible taps; retain the accepted hit's point
    // sample in that case. Ray penetration depth does not select this fallback.
    vec3 color = colorWeight > 0.0 ? colorSum / colorWeight
            : texture(u_SceneHdrComposited_history, historyUv).rgb;

    // Confidence: the edge ramp is steep and late so reflections stay full strength across most of
    // the frame; the length term fades out the least reliable, longest rays.
    vec2 cdist = abs(hit.xy - 0.5) * 2.0;
    float edgeFade = clamp(1.0 - pow(max(cdist.x, cdist.y), 8.0), 0.0, 1.0);
    float lengthFade = 1.0 - clamp(hitS, 0.0, 1.0) * 0.35;

    // Nearest wins between the real Hi-Z hit and the player mirror: a block between the receiver
    // and its own reflection must occlude it, the same physical fact ssr_trace_water.fsh's own
    // arbitration enforces.
    if (mirrorHit) {
        vec3 ssrHitWorld = worldPosAt(hit.xy, hit.z);
        float ssrDistance = length(ssrHitWorld - origin);
        if (mirrorDistance < ssrDistance) {
            fragColor = vec4(mirrorColour, mirrorConfidence);
            return;
        }
    }

    fragColor = vec4(color, edgeFade * lengthFade);
}
