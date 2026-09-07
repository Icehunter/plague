#version 330

// Water reflection resolve: nine taps scaled by roughness, donors from another surface rejected,
// then temporal accumulation. The motion vector is built here from builtin.waterDepth, not
// builtin.gMotion, which carries the seabed's motion and not the surface's.
//
// A separate file from ssr_blur.fsh because FullscreenPassRunner keys shader identity on the
// `shader` path alone: two passes naming one file compile to the same program.
//
// Reprojection assumes the water surface does not move sideways: wave displacement
// (plagueWaveSurfaceDisplacement) is asserted purely vertical, so world XZ under a water pixel is
// fixed while the surface moves up and down by up to 0.19 to 0.37 blocks. That leftover vertical
// error is small against the roughness blur radius and is left unreprojected. A camera plus wave
// motion vector cannot be built at any price: the wave clock (u_SkyState.w) has no previous-frame
// value to diff against.
//
// A moving crest still shows as a colour change even with correct reprojection: the reflected
// direction swings with the normal (measured 0.54 deg per frame at 60fps, tools/verify_ssr.py).
// Nothing in the geometry domain can see a wave, so two colour guards catch it: history weight
// runs 0.35 (mirror) to 0.58 (rough) rather than a fixed blend, and clipping bounds history into
// this frame's confident 3x3 box first.
//
// No second (motion) attachment: it does not fit the existing target at usable precision, and a
// real one costs five engine files for a value this pass can rebuild from the depth it reads.
// u_CameraDelta comes from the engine: both model-view matrices in u_Globals are rotation only, so
// previous-frame matrices alone reproject a still camera but not a moving one.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

uniform sampler2D u_Input0; // ssrWaterRaw
#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "Voxel SSR Recovery" {0="Off" 1="On"}
#if PLAGUE_VOXEL_REFLECTIONS != 0
uniform sampler2D u_Input4; // half-resolution current SSR + voxel fallback
#endif
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

// Relative threshold, not ssr_blur's absolute 0.05: a fixed distance test breaks down over a lake's
// range. Largest measured valid-reprojection gap is 1.9e-4, 260x under 0.05, so it would never fire.
const float SSR_WATER_DISOCCLUSION_RATIO = 0.25;

in vec2 texCoord;
out vec4 fragColor;

// Keep the full-size SSR donors. Only weak rays look at the half-size fallback.
vec4 plagueWaterRaw(vec2 uv) {
    vec4 screen = texture(u_Input0, uv);
#if PLAGUE_VOXEL_REFLECTIONS != 0
    if (u_WaterState.x > 0.5) { screen.a = abs(screen.a); return screen; }
    // A trusted surface is geometry, even where its confidence has faded toward sky.
    if (screen.a > 0.5) return vec4(screen.rgb, 1.0);
    if (screen.a <= 0.5) {
        vec4 fallback = texture(u_Input4, uv);
        // Empty fallback pixels are zero. Divide the coverage back out at the half-size edge.
        if (fallback.a > 0.5) {
            // Fade at the trusted-donor edge rather than switching colour outright.
            // Negative confidence means sky, and must never tint a known geometry hit.
            float screenWeight = smoothstep(0.0, 0.5, max(screen.a, 0.0));
            return vec4(mix(fallback.rgb / fallback.a, screen.rgb, screenWeight), 1.0);
        }
    }
#endif
    screen.a = abs(screen.a); // Put sky confidence back when no geometry was found.
    return screen;
}

// Depth alone cannot tell a lake from a waterfall pixel beside it, so this checks the normals too
// and rejects donors on a different slope before they become a borrowed patch of sky.
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
    // Early out for non-water pixels, most of the frame. Writes zero rather than discarding: this
    // target ping-pongs, and a discard would keep the value from two frames back.
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
    vec4 raw = plagueWaterRaw(texCoord);
    vec4 resolved = raw;

    float normalizedRoughness = clamp(
            (centerRoughness - PLAGUE_WATER_MIN_ROUGHNESS)
            / (PLAGUE_WATER_MAX_ROUGHNESS - PLAGUE_WATER_MIN_ROUGHNESS),
            0.0, 1.0);
    float radiusPx = mix(0.35, 6.0, normalizedRoughness);
    vec3 filteredColour = vec3(0.0);
    float filteredConfidence = 0.0;
    float filterWeight = 0.0;
    // filterWeight with confidence left out. The ratio is the fraction of the neighbourhood that hit.
    float coverageWeight = 0.0;
    for (int tap = 0; tap < 9; tap++) {
        vec2 sampleUv = clamp(
                texCoord + PLAGUE_WATER_FILTER_OFFSETS[tap] * texelSize * radiusPx,
                texelSize * 0.5, vec2(1.0) - texelSize * 0.5);
        vec4 sampleValue = plagueWaterRaw(sampleUv);
        float confidence = clamp(sampleValue.a, 0.0, 1.0);
        float agreement = plagueWaterSurfaceAgreement(
                sampleUv, centerDepth, centerNormal);
        float weight = confidence * agreement * PLAGUE_WATER_FILTER_WEIGHTS[tap];
        filteredColour += sampleValue.rgb * weight;
        filteredConfidence += confidence * weight;
        filterWeight += weight;
        coverageWeight += agreement * PLAGUE_WATER_FILTER_WEIGHTS[tap];
    }
    // A miss is filled only when it is a pinhole inside a hit region. Filling at the edge bleeds
    // the hit outward as a halo over water that rightly missed. Half: a pinhole has hits all round,
    // an edge has hits on one side.
    bool fillableMiss = raw.a > 0.0 || filterWeight >= 0.5 * coverageWeight;
    if (filterWeight > 1e-5 && fillableMiss) {
        float confidence = filteredConfidence / filterWeight;
        if (raw.a <= 0.0) {
            confidence = min(confidence * filterWeight, 0.45);
        }
        resolved = vec4(filteredColour / filterWeight, clamp(confidence, 0.0, 1.0));
    }

    // u_InvProjModelView is the jittered inverse on purpose: it must match the drawn waterDepth
    // it inverts.
    vec4 world = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, centerDepth, 1.0);
    vec3 posNow = world.xyz / world.w;

    // + u_CameraDelta reprojects into the previous frame's camera space, the pairing terrain.vsh
    // gets free from u_PrevRegionOffset.
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
        // No water at the reprojected pixel means history there is a hard zero, from the early
        // out above. Blending it would drag a real reflection toward black.
        validHistory = prevDepth > 0.0
                && abs(centerDepth - prevDepth)
                        <= SSR_WATER_DISOCCLUSION_RATIO * max(centerDepth, prevDepth)
                && plagueWaterSurfaceAgreement(previousUv, centerDepth, centerNormal) > 0.25;
    }

    if (validHistory) {
        // Misses are kept out of the clip box on purpose: a miss writes vec4(0), which would drop
        // every lower bound to zero and let any stale dark value through unclamped.
        vec4 lo = vec4(1e30);
        vec4 hi = vec4(-1e30);
        bool haveBounds = false;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec2 sampleUv = texCoord + vec2(float(x), float(y)) * texelSize;
                vec4 n = plagueWaterRaw(sampleUv);
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
