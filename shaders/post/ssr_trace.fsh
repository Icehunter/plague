#version 330

// Screen-space reflections: one mirror ray per pixel, marched through the Hi-Z pyramid.
//
// One mirror ray, not a roughness cone: a per-pixel GGX cone against spatially-static noise gives
// adjacent pixels permanently different hits — a stable speckle no temporal filter can average away.
// The glossy lobe is reconstructed spatially instead, by ssr_blur's roughness-driven radius; the
// jitter here only breaks up banding.
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
// For plagueUntonemapApprox: sceneHistory is display-referred and everything downstream of this
// pass is scene-referred linear HDR. One shared inverse, not a second hand-maintained copy.
#moj_import <fornax_runtime:tonemap.glsl>

uniform sampler2D u_GNormal; // builtin.gNormal
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GMaterial; // builtin.gMaterial: r = smoothness, g = F0, b = porosity/SSS
uniform sampler2D u_GMotion; // builtin.gMotion: reprojects the hit into last frame
uniform sampler2D u_SceneHistory_history; // sceneHistory.history: last frame's finished image
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

/** Camera-relative world position back to screen UV + reversed-Z NDC depth. */
vec3 projectToScreen(vec3 pos) {
    vec4 clip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(pos, 1.0);
    return vec3((clip.xy / clip.w) * 0.5 + 0.5, clip.z / clip.w);
}

/** Per-pixel jitter, spatially static. Only ever rotates the ray inside a ~4 degree cap. */
vec2 rayJitter(vec2 fragCoord) {
    float a = fract(sin(dot(fragCoord, vec2(12.9898, 78.233))) * 43758.5453);
    float b = fract(sin(dot(fragCoord, vec2(39.3468, 11.135))) * 24634.6345);
    return vec2(a, b);
}

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

    // Mirror direction, jittered inside a hard ~4 degree cap (see the header). alphaR is the usual
    // perceptual-roughness square, used only to widen the cap toward the rough end.
    vec3 mirror = reflect(viewDir, normal);
    vec2 xi = rayJitter(gl_FragCoord.xy);
    float alphaR = (1.0 - smoothness) * (1.0 - smoothness);
    vec3 up = abs(mirror.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 t = normalize(cross(up, mirror));
    vec3 b = cross(mirror, t);
    float cosTheta = mix(1.0, mix(1.0, 0.998, alphaR), xi.x);
    float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));
    float phi = xi.y * 6.2831853;
    vec3 rayDir = normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + mirror * cosTheta);

    // A bump cannot reflect through its opaque supporting face. This is known occlusion,
    // not a missing screen hit: black confidence prevents sky/world recovery behind the face.
    vec3 geometricNormal = plagueDecodeGeometricNormal(packedNormal.a, normal);
    if (dot(rayDir, geometricNormal) <= 0.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
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
    // X wall: the receiver's own X sits within 0.05 block of the wall's own plane. This plane is
    // already camera-relative, WallPlaneProbe's own publish contract, with no u_CameraAbs term,
    // unlike the floor's absolute standing plane above. The receiver's geometric normal must both
    // read as horizontal on the X axis and point the same way the wall's own recorded face does.
    // No shift: a wall mirror has one consumer only, itself, so hC == hR always.
    } else if (u_PlayerMirrorWalls.x != 0.0 && abs(geometricNormal.x) > 0.95
            && sign(geometricNormal.x) == u_PlayerMirrorWalls.x
            && abs(origin.x - u_PlayerMirrorWalls.y) < 0.05) {
        vec3 coverageProj = projectMirrorGuardedWall(origin);
        if (coverageProj.x >= 0.0 && coverageProj.x < 1.0
                && coverageProj.y >= 0.0 && coverageProj.y < 1.0 && coverageProj.z > 0.0
                && texture(u_MirrorXDepth, coverageProj.xy).r > 0.0) {
            vec3 rPrime = mirror;
            rPrime.x = -rPrime.x;
            vec3 hitWorld;
            vec2 hitUv;
            if (plagueMirrorMarchGeneral(origin, rPrime, u_PlayerMirrorWalls.y, u_PlayerMirrorWalls.y,
                    u_PlayerMirrorWalls.x, 1, u_MirrorXDepth, hitWorld, hitUv)) {
                vec4 mirrorSample = texture(u_MirrorXHdr, hitUv);
                vec2 mdist = abs(hitUv - 0.5) * 2.0;
                float mirrorEdge = clamp(1.0 - pow(max(mdist.x, mdist.y), 8.0), 0.0, 1.0);
                mirrorHit = true;
                mirrorDistance = length(hitWorld - origin);
                mirrorColour = mirrorSample.rgb / max(mirrorSample.a, 1e-4);
                mirrorConfidence = clamp(mirrorSample.a, 0.0, 1.0) * mirrorEdge;
            }
        }
    // Z wall: same shape as the X wall, its own plane/facing lanes and axis.
    } else if (u_PlayerMirrorWalls.z != 0.0 && abs(geometricNormal.z) > 0.95
            && sign(geometricNormal.z) == u_PlayerMirrorWalls.z
            && abs(origin.z - u_PlayerMirrorWalls.w) < 0.05) {
        vec3 coverageProj = projectMirrorGuardedWall(origin);
        if (coverageProj.x >= 0.0 && coverageProj.x < 1.0
                && coverageProj.y >= 0.0 && coverageProj.y < 1.0 && coverageProj.z > 0.0
                && texture(u_MirrorZDepth, coverageProj.xy).r > 0.0) {
            vec3 rPrime = mirror;
            rPrime.z = -rPrime.z;
            vec3 hitWorld;
            vec2 hitUv;
            if (plagueMirrorMarchGeneral(origin, rPrime, u_PlayerMirrorWalls.w, u_PlayerMirrorWalls.w,
                    u_PlayerMirrorWalls.z, 2, u_MirrorZDepth, hitWorld, hitUv)) {
                vec4 mirrorSample = texture(u_MirrorZHdr, hitUv);
                vec2 mdist = abs(hitUv - 0.5) * 2.0;
                float mirrorEdge = clamp(1.0 - pow(max(mdist.x, mdist.y), 8.0), 0.0, 1.0);
                mirrorHit = true;
                mirrorDistance = length(hitWorld - origin);
                mirrorColour = mirrorSample.rgb / max(mirrorSample.a, 1e-4);
                mirrorConfidence = clamp(mirrorSample.a, 0.0, 1.0) * mirrorEdge;
            }
        }
    }

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

    // Colour comes from last frame's finished image, reprojected: this frame's scene colour isn't
    // available yet (the resolve that produces it consumes this pass's output).
    vec2 historyUv = hit.xy - texture(u_GMotion, hit.xy).rg;
#if FX_UPSCALE != 0
    // Upscalers store reconstructed, unjittered scene history. Motion excludes jitter, while
    // hit.xy still contains this frame's NDC jitter; the NDC-to-UV conversion contributes 1/2.
    historyUv -= 0.5 * u_JitterOffset;
#endif
    if (historyUv.x < 0.0 || historyUv.x > 1.0 || historyUv.y < 0.0 || historyUv.y > 1.0) {
        if (mirrorHit) {
            fragColor = vec4(mirrorColour, mirrorConfidence);
            return;
        }
        fragColor = vec4(0.0);
        return;
    }
    // sceneHistory is display-referred (exposed, tonemapped, graded); everything downstream here is
    // linear scene-referred, so it must be untonemapped or reflections get tonemapped twice.
    // plagueUntonemapApprox is the same inverse the forward-fog composite uses — a bare
    // `pow(x, 2.2)` was tried first and is wrong by an exposure-dependent factor (~2.75x too bright
    // at u_Exposure 1.65); tools/verify_ssr.py pins the round-trip error and rejects that regression.
    // Still approximate: the operator's luminance-coupled extras have no closed-form inverse, so
    // reflections of very bright sources come back slightly dimmer than the thing they reflect.
    vec3 displayColor = texture(u_SceneHistory_history, historyUv).rgb;
    vec3 color = plagueUntonemapApprox(displayColor);

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
