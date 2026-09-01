#version 330

// Water-specific reflection resolve: nine-tap footprint scaled by roughness, cross-surface donors
// rejected, then temporal accumulation via a motion vector derived here from builtin.waterDepth
// rather than builtin.gMotion (which carries the seabed's motion, not the surface's).
//
// A separate file from ssr_blur.fsh because FullscreenPassRunner keys shader identity on the
// `shader` path alone — two passes naming one file would compile to the same program.
//
// Reprojection assumes the water surface doesn't translate horizontally: wave displacement
// (plagueWaveSurfaceDisplacement) is asserted purely vertical, so world XZ under a water pixel is
// fixed even though the surface itself now moves (up to ~0.19-0.37 blocks vertically). The residual
// vertical error is small against the roughness blur radius and left unreprojected.
//
// A camera+wave motion vector isn't just expensive, it's unbuildable: the wave clock
// (u_SkyState.w) has no previous-frame counterpart to diff against.
//
// A moving crest still shows up as a colour-domain change even with correct reprojection, since the
// reflected direction swings with the normal (measured ~0.54 deg/frame normal turn at 60fps,
// tools/verify_ssr.py). Two things catch it: temporal history weight varies 0.35 (mirror) to 0.58
// (rough) rather than a fixed blend, and neighbourhood clipping bounds history into this frame's
// confident 3x3 box before blending — nothing in the geometry domain can see a wave, so the colour
// domain is the only place to catch one.
//
// No second (motion) attachment: doesn't fit the existing target (out of spare bits at usable
// precision), and a real second attachment costs five engine files for a value already
// reconstructible from the depth sample this pass reads. u_CameraDelta was the one engine addition
// needed — both model-view matrices in u_Globals are rotation-only, so previous-frame matrices alone
// could reproject a stationary camera but not a moving one.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

uniform sampler2D u_Input0; // ssrWaterRaw
uniform sampler2D u_Input1; // ssrWater.history
uniform sampler2D u_Input2; // builtin.waterDepth: reversed-Z, 0.0 = no water
uniform sampler2D u_Input3; // builtin.waterNormal: raw world normal + signed water flags

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="Fancy" 2="Fast"}
#define SSR_WATER_MODE 2 //[0 1 2] compile "Water Surface" {0="Vanilla" 1="Shaded" 2="Reflective"}
#define PLAGUE_WATER_REFLECTION_DEBUG 0 //[0 1 2 3 4] compile "Water Reflection View" {0="Off" 1="Roughness" 2="Trace Confidence" 3="Fallback Sky" 4="Source Mix"}

const vec2 PLAGUE_WATER_FILTER_OFFSETS[9] = vec2[9](
    vec2( 0.0,  0.0),
    vec2( 1.0,  0.0), vec2(-1.0,  0.0),
    vec2( 0.0,  1.0), vec2( 0.0, -1.0),
    vec2( 1.0,  1.0), vec2(-1.0,  1.0),
    vec2( 1.0, -1.0), vec2(-1.0, -1.0)
);
const float PLAGUE_WATER_FILTER_WEIGHTS[9] = float[9](
    0.24,
    0.12, 0.12, 0.12, 0.12,
    0.07, 0.07, 0.07, 0.07
);

// Relative threshold, not ssr_blur's absolute 0.05: an absolute distance test collapses over a lake's
// range (measured largest valid-reprojection disagreement 1.9e-4, 260x under 0.05, so it'd never fire).
const float SSR_WATER_DISOCCLUSION_RATIO = 0.25;

in vec2 texCoord;
out vec4 fragColor;

// Depth alone can't distinguish a lake from a neighbouring waterfall pixel; this also checks normal
// agreement to reject cross-slope donors before they become a borrowed rectangle of sky.
float plagueWaterSurfaceAgreement(vec2 uv, float centerDepth, vec3 centerNormal) {
    float sampleDepth = texture(u_Input2, uv).r;
    if (sampleDepth <= 0.0) {
        return 0.0;
    }

    vec4 sampleSurface = texture(u_Input3, uv);
    vec3 sampleNormal;
    float sampleRoughness;
    float sampleFlags;
    plagueDecodeWaterReflectionSurface(
            sampleSurface, sampleNormal, sampleRoughness, sampleFlags);
    if (abs(sampleFlags) < 0.5) {
        return 0.0;
    }

    float depthRatio = abs(centerDepth - sampleDepth) / max(centerDepth, sampleDepth);
    float depthAgreement = 1.0 - smoothstep(0.03, 0.15, depthRatio);
    float normalAgreement = smoothstep(0.72, 0.96,
            clamp(dot(centerNormal, sampleNormal), -1.0, 1.0));
    return depthAgreement * normalAgreement;
}

void main() {
    // Early-out for non-water pixels (most of the frame). Writes zero rather than discarding, since
    // this target ping-pongs and a discard would keep the value from two frames ago.
    float centerDepth = texture(u_Input2, texCoord).r;
    if (centerDepth <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    vec2 texelSize = 1.0 / vec2(textureSize(u_Input0, 0));
    vec4 centerSurface = texture(u_Input3, texCoord);
    vec3 centerNormal;
    float centerRoughness;
    float centerFlags;
    plagueDecodeWaterReflectionSurface(
            centerSurface, centerNormal, centerRoughness, centerFlags);
    if (abs(centerFlags) < 0.5) {
        fragColor = vec4(0.0);
        return;
    }
    vec4 raw = texture(u_Input0, texCoord);
    vec4 resolved = raw;

    float normalizedRoughness = clamp(
            (centerRoughness - PLAGUE_WATER_MIN_ROUGHNESS)
            / (PLAGUE_WATER_MAX_ROUGHNESS - PLAGUE_WATER_MIN_ROUGHNESS),
            0.0, 1.0);
    float radiusPx = mix(0.35, 6.0, normalizedRoughness);
    vec3 filteredColour = vec3(0.0);
    float filteredConfidence = 0.0;
    float filterWeight = 0.0;
    for (int tap = 0; tap < 9; tap++) {
        vec2 sampleUv = clamp(
                texCoord + PLAGUE_WATER_FILTER_OFFSETS[tap] * texelSize * radiusPx,
                texelSize * 0.5, vec2(1.0) - texelSize * 0.5);
        vec4 sampleValue = texture(u_Input0, sampleUv);
        float confidence = clamp(sampleValue.a, 0.0, 1.0);
        float agreement = plagueWaterSurfaceAgreement(
                sampleUv, centerDepth, centerNormal);
        float weight = confidence * agreement * PLAGUE_WATER_FILTER_WEIGHTS[tap];
        filteredColour += sampleValue.rgb * weight;
        filteredConfidence += confidence * weight;
        filterWeight += weight;
    }
    if (filterWeight > 1e-5) {
        float confidence = filteredConfidence / filterWeight;
        if (raw.a <= 0.0) {
            confidence = min(confidence * filterWeight, 0.45);
        }
        resolved = vec4(filteredColour / filterWeight, clamp(confidence, 0.0, 1.0));
    }

    // u_InvProjModelView is the jittered inverse deliberately: it must agree with the rasterized
    // waterDepth it's inverting.
    vec4 world = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, centerDepth, 1.0);
    vec3 posNow = world.xyz / world.w;

    // + u_CameraDelta reprojects into the previous frame's camera space, the pairing terrain.vsh gets
    // for free from u_PrevRegionOffset.
    vec4 prevClip = u_PrevProjectionMatrix * u_PrevModelViewMatrix
            * vec4(posNow + u_CameraDelta.xyz, 1.0);

    bool validHistory = prevClip.w > 0.0; // behind the previous eye: no history of it exists
    vec2 previousUv = texCoord;
    if (validHistory) {
        // Jitter subtracted from both frames, as terrain.vsh does it; checked equal against
        // terrain.vsh's form in tools/verify_ssr.py.
        vec2 motion = ((texCoord * 2.0 - 1.0 - u_JitterOffset)
                - (prevClip.xy / prevClip.w - u_PrevJitterOffset)) * 0.5;
        previousUv = texCoord - motion;
        validHistory = previousUv.x >= 0.0 && previousUv.x <= 1.0
                && previousUv.y >= 0.0 && previousUv.y <= 1.0;
    }
    if (validHistory) {
        float prevDepth = texture(u_Input2, previousUv).r;
        // No water at the reprojected pixel means history there is a hard zero (early-out above);
        // blending it would drag a real reflection toward black.
        validHistory = prevDepth > 0.0
                && abs(centerDepth - prevDepth)
                        <= SSR_WATER_DISOCCLUSION_RATIO * max(centerDepth, prevDepth)
                && plagueWaterSurfaceAgreement(previousUv, centerDepth, centerNormal) > 0.25;
    }

    if (validHistory) {
        // Misses excluded from the clip box deliberately: a miss writes vec4(0), which would drop
        // every lower bound to zero and let any stale-dark value through unclamped.
        vec4 lo = vec4(1e30);
        vec4 hi = vec4(-1e30);
        bool haveBounds = false;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec2 sampleUv = texCoord + vec2(float(x), float(y)) * texelSize;
                vec4 n = texture(u_Input0, sampleUv);
                if (n.a <= 0.0 || plagueWaterSurfaceAgreement(
                        sampleUv, centerDepth, centerNormal) <= 0.25) {
                    continue;
                }
                lo = min(lo, n);
                hi = max(hi, n);
                haveBounds = true;
            }
        }
        if (haveBounds) {
            vec4 history = clamp(texture(u_Input1, previousUv), lo, hi);
            float historyWeight = mix(0.35, 0.58, normalizedRoughness);
            resolved = mix(resolved, history, historyWeight);
        }
    }

    fragColor = resolved;
}
