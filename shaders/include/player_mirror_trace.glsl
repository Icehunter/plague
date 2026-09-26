#ifndef PLAGUE_PLAYER_MIRROR_TRACE
#define PLAGUE_PLAYER_MIRROR_TRACE

#moj_import <fornax_runtime:player_mirror_guard.glsl>

// Geometry shared by every consumer of the player-mirror MRTs (ssr_trace_water.fsh,
// ssr_trace.fsh). The floor mirror pass renders about one plane, u_PlayerMirrorState.y, the
// standing plane whenever it validates (see WaterPlaneProbe.combine's own doc for why rendering
// about the lower of the two planes was rejected). A consumer that wants a different plane h_c,
// open water under a dock or a bridge deck, does not get a second render: reflecting about h_c is
// the same as reflecting about the render plane h_r then translating along the render axis by
// 2*(h_c - h_r), verified in tools/verify_player_mirror.py's march_mirror_shifted. Every lookup
// below shifts by that amount instead. Each wall mirror pass has no second consumer plane yet, so
// its march always shifts by zero (h_c == h_r), but it shares the same generalized machinery
// (tools/verify_player_mirror_walls.py) instead of a duplicated copy, so the floor's consumer-shift
// feature and a wall's facing-aware reject cannot drift apart from being written twice.
//
// The consumer declares `uniform sampler2D u_MirrorDepth;` (builtin.mirrorDepth) before importing,
// for the floor-only functions below (`projectMirrorGuarded`, `mirrorRecordedPos`,
// `plagueMirrorMarchShifted`). ssr_trace_water.fsh is their only caller. The generalized,
// axis-aware functions instead take their depth sampler as an explicit argument, since a single
// caller (ssr_trace.fsh) reads three different mirror depths in the same frame and no fixed opt-in
// name could serve all three.

// Projects a camera-relative world position through the player-mirror pass's own frustum: the
// camera's projection, then the bottom guard-band remap player_mirror.vsh applies before
// rasterizing (0.5, from tools/verify_player_mirror.py). Lands at the UV and depth the mirror MRT
// was written at, so a sample here reads the same texel the mirror pass wrote for that point.
vec3 projectMirrorGuarded(vec3 worldPos) {
    vec4 clip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(worldPos, 1.0);
    if (clip.w <= 0.0) return vec3(-1.0);
    // Sourced from the shared include instead of restating the 0.5/2.5 constants here:
    // (2*y + 0.5*w)/(2+0.5) equals (2*y + 0.5*w)/2.5.
    plagueMirrorGuardBottom(clip);
    return vec3((clip.xy / clip.w) * 0.5 + 0.5, clip.z / clip.w);
}

// The wall sibling of projectMirrorGuarded: same camera projection, horizontal guard band instead
// of the floor's bottom one (player_mirror_guard.glsl's own doc has both derivations).
vec3 projectMirrorGuardedWall(vec3 worldPos) {
    vec4 clip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(worldPos, 1.0);
    if (clip.w <= 0.0) return vec3(-1.0);
    plagueMirrorGuardHorizontal(clip);
    return vec3((clip.xy / clip.w) * 0.5 + 0.5, clip.z / clip.w);
}

// Exact inverse of projectMirrorGuarded: given a UV and a raw reversed-Z depth read from
// builtin.mirrorDepth, reconstructs the mirrored world position the mirror pass rasterized there.
// It stays in that same space and never reflects back to real space: reflecting one side of a
// distance compare and not the other rejects every recorded surface above the ankles.
vec3 mirrorRecordedPos(vec2 uv, float rawDepth) {
    float xNdc = uv.x * 2.0 - 1.0;
    float yGuardedNdc = uv.y * 2.0 - 1.0;
    float yNdc = plagueMirrorUnguardBottomNdc(yGuardedNdc);
    vec4 worldH = u_InvProjModelView * vec4(xNdc, yNdc, rawDepth, 1.0);
    return worldH.xyz / worldH.w;
}

// The wall sibling of mirrorRecordedPos: same reconstruction, horizontal guard inverted instead.
vec3 mirrorRecordedPosWall(vec2 uv, float rawDepth) {
    float xGuardedNdc = uv.x * 2.0 - 1.0;
    float yNdc = uv.y * 2.0 - 1.0;
    float xNdc = plagueMirrorUnguardHorizontalNdc(xGuardedNdc);
    vec4 worldH = u_InvProjModelView * vec4(xNdc, yNdc, rawDepth, 1.0);
    return worldH.xyz / worldH.w;
}

// The consumer-side march for a plane h_c that may differ from the render plane h_r (pass h_c ==
// h_r for no shift at all). origin and rPrime are the consumer's own real-space reflected-back
// ray. Returns true and fills hitWorld (real space, unshifted) and hitUv on a hit, false on a
// miss.
//
// 24 steps plus 12 bisections: tools/verify_player_mirror.py's own march defaults to 400 steps as
// an exhaustive reference, not a shader budget. 24 was verified against that model's own retention
// and false-positive sweep (unbounded 69/2124 false hits at 24 steps with no thickness gate,
// 11/2124 with the 1.0-block gate below, 135/135 flat-water and 120/126 wave-tilted true hits
// retained either way).
//
// The thickness compare stays in the shifted, mirrored, as-rendered space on both sides, the
// sample and the mirror's own recorded surface, so it is the render-plane compare with the shift
// folded into the sample point. The reject handles a consumer plane other than the render plane:
// the recorded surface's real height (2*h_r - recordedMirrored.y) sitting below h_c minus 0.02
// means the march found something belonging to a part of the body below this consumer's own plane
// (the reflection of a torso above a dock cannot also be the reflection under it), and must not be
// read as this consumer's hit. 0.02 is the same anti-flicker margin player_mirror.fsh's own
// below-plane discard uses.
bool plagueMirrorMarchShifted(vec3 origin, vec3 rPrime, float hC, float hR,
        out vec3 hitWorld, out vec2 hitUv) {
    vec3 shift = vec3(0.0, 2.0 * (hC - hR), 0.0);
    const int STEPS = 24;
    const int BISECTIONS = 12;
    const float REACH = 24.0;
    float prevT = 0.02;
    for (int m = 1; m <= STEPS; m++) {
        float t = 0.02 + (REACH - 0.02) * float(m) / float(STEPS);
        vec3 p = origin + t * rPrime;
        vec3 proj = projectMirrorGuarded(p - shift);
        if (proj.x < 0.0 || proj.x >= 1.0 || proj.y < 0.0 || proj.y >= 1.0 || proj.z <= 0.0) {
            return false;
        }
        float buf = texture(u_MirrorDepth, proj.xy).r;
        // Reversed-Z: nearer is larger, so proj.z < buf means this sample has stepped behind
        // whatever the mirror pass rasterized there, a crossing.
        if (buf > 0.0 && proj.z < buf) {
            float lo = prevT, hi = t;
            for (int b = 0; b < BISECTIONS; b++) {
                float mid = 0.5 * (lo + hi);
                vec3 projm = projectMirrorGuarded(origin + mid * rPrime - shift);
                float bufm = texture(u_MirrorDepth, projm.xy).r;
                if (bufm > 0.0 && projm.z < bufm) { hi = mid; } else { lo = mid; }
            }
            vec3 candidate = origin + hi * rPrime;
            vec3 candidateProj = projectMirrorGuarded(candidate - shift);
            float hitBuf = texture(u_MirrorDepth, candidateProj.xy).r;
            if (hitBuf <= 0.0) {
                return false;
            }
            vec3 recordedMirrored = mirrorRecordedPos(candidateProj.xy, hitBuf);
            if (length(recordedMirrored - (candidate - shift)) >= 1.0) {
                return false;
            }
            // hR/hC are absolute world Y (plane altitudes); recordedMirrored.y is camera-relative
            // (mirrorRecordedPos never adds the camera back in). Subtracting u_CameraAbs.y puts
            // 2*hR on the same camera-relative footing before the compare. Missing that
            // subtraction flips the reject's sign whenever the camera sits away from world Y 0,
            // such as caves or ancient cities, and kills every hit down there.
            if (2.0 * hR - u_CameraAbs.y - recordedMirrored.y < hC - 0.02) {
                return false;
            }
            hitWorld = candidate;
            hitUv = candidateProj.xy;
            return true;
        }
        prevT = t;
    }
    return false;
}

// axis: 0 = floor (reflect and shift Y), 1 = X wall, 2 = Z wall. Picks out one component of a
// vec3, or builds a shift vector with a given amount in the matching slot, the only two places the
// three routes' geometry differs once the guard band is factored out above.
float plagueAxisComponent(vec3 v, int axis) {
    return axis == 0 ? v.y : (axis == 1 ? v.x : v.z);
}

vec3 plagueAxisOffset(float amount, int axis) {
    return axis == 0 ? vec3(0.0, amount, 0.0) : (axis == 1 ? vec3(amount, 0.0, 0.0) : vec3(0.0, 0.0, amount));
}

/**
 * The fully general march, used by all three of ssr_trace.fsh's routes (floor, X wall, Z wall) so
 * those three cannot drift from one another. {@code plagueMirrorMarchShifted} above stays as its
 * own direct copy of this same shape rather than a call into this function, because
 * ssr_trace_water.fsh, its only caller, keeps the floor march bit-identical with the smallest
 * possible blast radius on its one remaining caller. Passing axis 0, facing 1.0, and
 * u_MirrorDepth into this function reduces it to the same formula plagueMirrorMarchShifted already
 * computes (verified algebraically below), which is how ssr_trace.fsh's own floor route reaches it
 * instead.
 *
 * <p>{@code depthSampler} is an explicit argument rather than the opt-in {@code u_MirrorDepth}
 * name the two-argument functions above rely on: ssr_trace.fsh reads three different mirror depths
 * in one frame (mirrorDepth, mirrorXDepth, mirrorZDepth), and GLSL allows a sampler as a plain
 * function parameter (desktop GLSL 330 core, not the bindless-array restriction some ES profiles
 * have), so this is the natural way to keep one march body for all three.
 *
 * <p>{@code facing} generalizes the reject test: the floor's standing plane only ever has one
 * valid up (facing implicitly +1, folded into the unparameterized formula above), but a wall's
 * normal can point either +axis or -axis (u_PlayerMirrorWalls' own facing lane, {-1, 0, +1}), so
 * the reject must flip sign to match. Passing facing = 1.0 reduces this to the original,
 * unparameterized reject: (recordedReal - hC) * 1.0 < -0.02 is the same inequality as
 * recordedReal < hC - 0.02.
 */
bool plagueMirrorMarchGeneral(vec3 origin, vec3 rPrime, float hC, float hR, float facing, int axis,
        sampler2D depthSampler, out vec3 hitWorld, out vec2 hitUv) {
    vec3 shift = plagueAxisOffset(2.0 * (hC - hR), axis);
    const int STEPS = 24;
    const int BISECTIONS = 12;
    const float REACH = 24.0;
    float prevT = 0.02;
    for (int m = 1; m <= STEPS; m++) {
        float t = 0.02 + (REACH - 0.02) * float(m) / float(STEPS);
        vec3 p = origin + t * rPrime;
        vec3 proj = axis == 0 ? projectMirrorGuarded(p - shift) : projectMirrorGuardedWall(p - shift);
        if (proj.x < 0.0 || proj.x >= 1.0 || proj.y < 0.0 || proj.y >= 1.0 || proj.z <= 0.0) {
            return false;
        }
        float buf = texture(depthSampler, proj.xy).r;
        // Reversed-Z: nearer is larger, so proj.z < buf means this sample has stepped behind
        // whatever the mirror pass rasterized there, a crossing.
        if (buf > 0.0 && proj.z < buf) {
            float lo = prevT, hi = t;
            for (int b = 0; b < BISECTIONS; b++) {
                float mid = 0.5 * (lo + hi);
                vec3 projm = axis == 0 ? projectMirrorGuarded(origin + mid * rPrime - shift)
                                       : projectMirrorGuardedWall(origin + mid * rPrime - shift);
                float bufm = texture(depthSampler, projm.xy).r;
                if (bufm > 0.0 && projm.z < bufm) { hi = mid; } else { lo = mid; }
            }
            vec3 candidate = origin + hi * rPrime;
            vec3 candidateProj = axis == 0 ? projectMirrorGuarded(candidate - shift)
                                            : projectMirrorGuardedWall(candidate - shift);
            float hitBuf = texture(depthSampler, candidateProj.xy).r;
            if (hitBuf <= 0.0) {
                return false;
            }
            vec3 recordedMirrored = axis == 0 ? mirrorRecordedPos(candidateProj.xy, hitBuf)
                                               : mirrorRecordedPosWall(candidateProj.xy, hitBuf);
            if (length(recordedMirrored - (candidate - shift)) >= 1.0) {
                return false;
            }
            // hR/hC are absolute-along-the-axis plane positions for the floor (world Y) but
            // camera-relative for a wall (u_PlayerMirrorWalls' own publish contract). Either way,
            // recordedMirrored's matching component is camera-relative (mirrorRecordedPos and
            // mirrorRecordedPosWall never add the camera back in), so only the floor needs the
            // camera subtraction here; a wall's hR/hC are already on that same footing.
            float cameraTerm = axis == 0 ? plagueAxisComponent(u_CameraAbs, axis) : 0.0;
            float recordedReal = 2.0 * hR - cameraTerm - plagueAxisComponent(recordedMirrored, axis);
            if ((recordedReal - hC) * facing < -0.02) {
                return false;
            }
            hitWorld = candidate;
            hitUv = candidateProj.xy;
            return true;
        }
        prevT = t;
    }
    return false;
}

#endif
