#version 330

// Raw, half-resolution single-scattering integration over the finite raster water interval.
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:light_options.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:atmosphere.glsl>
#moj_import <fornax_runtime:main_lighting.glsl>
#moj_import <fornax_runtime:water_waves.glsl>
#moj_import <fornax_runtime:water_options.glsl>
#define PLAGUE_WATER_MESH_DISPLACEMENT 1 //[0 1] compile "Water Mesh Displacement" {0="Off" 1="Standard"}

uniform sampler2D u_Input0;       // waterVolumeInterval
uniform sampler2DShadow u_Input1; // sunShadowMap
uniform sampler2D u_Input2;       // builtin.noise

#moj_import <fornax_runtime:water_volume_source.glsl>

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec4  u_SunDirection; // xyz active sun/moon direction; w true-sun elevation
};

#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="Balanced" 2="High"}
#define WATER_ABSORPTION_TINT 1 //[0 1] compile "Underwater Tint" {0="Off" 1="On"}

in vec2 texCoord;
out vec4 fragColor;

// Stable Fornax debug ids. They deliberately do not equal these views' enum ordinals.
const int PLAGUE_DEBUG_WATER_SHAFT_INTERVAL = 64;
const int PLAGUE_DEBUG_WATER_SHAFT_REFRACTIVE_FOCUS = 65;
const int PLAGUE_DEBUG_WATER_SHAFT_SHADOW_VISIBILITY = 66;
const int PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER = 67;

bool plagueWaterShaftDebugActive(int debugView) {
    return debugView >= PLAGUE_DEBUG_WATER_SHAFT_INTERVAL
            && debugView <= PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER;
}

bool plagueWaterShaftReasonIs(float encodedReason, float expectedReason) {
    // RGBA16F stores these eighth-step values exactly. The tolerance also makes the view readable
    // along half-resolution boundaries where the target's required linear filter mixes pixels.
    return abs(encodedReason - expectedReason) < 0.055;
}

vec3 plagueWaterShaftIntervalDebug(
        vec4 encodedInterval,
        PlagueWaterVolumeInterval interval,
        float waterState) {
    // Valid: green dry interval, cyan submerged interval.
    if (interval.valid) {
        return vec3(0.0, 1.0, interval.submerged ? 1.0 : 0.0);
    }

    if (any(isnan(encodedInterval)) || any(isinf(encodedInterval))) {
        return vec3(1.0); // non-finite value reached the stored ABI
    }

    float encodedRevision = floor(encodedInterval.a);
    float reason = fract(encodedInterval.a);
    // Producer failures live only in revision zero. A valid record also uses fractional alpha for
    // its octahedral normal, so interpreting the fraction without this integer guard produces false
    // reason colours—the first live diagnostic screenshot exposed exactly that ambiguity.
    if (encodedRevision < 1.0) {
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_INPUT)) {
            return vec3(1.0, 0.35, 0.0); // non-finite producer input
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_OPTICAL)) {
            return vec3(0.0, 0.25, 1.0); // invalid optical cap / clarity
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_SURFACE_DISTANCE)) {
            return vec3(0.0, 1.0, 0.35); // surface depth reconstruction failed
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_OPAQUE_DISTANCE)) {
            return vec3(0.55, 0.0, 1.0); // opaque depth reconstruction failed
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_ENTRY_DISTANCE)) {
            return vec3(1.0); // dry-camera water entry reconstruction failed
        }
        if (plagueWaterShaftReasonIs(reason, PLAGUE_WATER_INTERVAL_FAILURE_EMPTY)) {
            return vec3(1.0, 0.0, 0.0); // no non-empty water segment was produced
        }
        if (reason <= 0.001) {
            // Yellow means this pass sees a dry camera. Red means the camera is submerged but the
            // producer target remained at its unwritten/cleared identity.
            return waterState <= 0.5 ? vec3(1.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        }
        return vec3(1.0, 0.0, 1.0); // unknown producer failure tag
    }

    // The producer marked this as valid, so show the exact ABI predicate that rejected the stored
    // record. Yellow = revision, blue = packed-normal lane, orange = entry, red = exit.
    if (encodedRevision != PLAGUE_WATER_MEDIUM_REVISION) {
        return vec3(1.0, 1.0, 0.0);
    }
    if (!plagueWaterVolumePackedNormalYValid(reason)) {
        return vec3(0.0, 0.25, 1.0);
    }
    float encodedEntry = encodedInterval.r > 0.0 ? 0.0
            : -encodedInterval.r - PLAGUE_WATER_INTERVAL_EPSILON;
    if (encodedInterval.r <= 0.0 && encodedEntry < 0.0) {
        return vec3(1.0, 0.35, 0.0);
    }
    if (encodedInterval.g <= encodedEntry) {
        return vec3(1.0, 0.0, 0.0);
    }
    return vec3(1.0, 0.0, 1.0); // decoder and diagnostic predicates disagree
}

vec3 plagueWaterShaftFocusDebug(float focusSum, float sampleCount) {
    if (sampleCount <= 0.0 || !plagueWaterSourceFinite(focusSum)) {
        return vec3(1.0, 0.0, 1.0);
    }
    float focus = max(focusSum / sampleCount, 0.125);
    float signedFocus = clamp(log2(focus) / 3.0, -1.0, 1.0);
    // Blue = spreading, green = neutral, red = converging/bright caustic ray tube.
    return vec3(max(signedFocus, 0.0), 1.0 - abs(signedFocus),
            max(-signedFocus, 0.0));
}

vec3 plagueWaterShaftShadowDebug(float visibilitySum, float sampleCount) {
    if (sampleCount <= 0.0 || !plagueWaterSourceFinite(visibilitySum)) {
        return vec3(1.0, 0.0, 1.0);
    }
    return vec3(clamp(visibilitySum / sampleCount, 0.0, 1.0));
}

vec3 plagueWaterShaftRawScatterDebug(vec3 scatter) {
    // Display mapping only. Production scatter remains linear HDR when this view is not selected.
    return vec3(1.0) - exp(-max(scatter, vec3(0.0)) * 32.0);
}

#moj_import <fornax_runtime:water_volume_integrate.glsl>

void main() {
    int debugView = int(u_Param3 + 0.5);
    bool debugActive = plagueWaterShaftDebugActive(debugView);
    // Magenta means the selected diagnostic reached this shader but a prerequisite failed before
    // that signal could be measured. It is intentionally distinct from genuine zero scatter.
    fragColor = debugActive ? vec4(1.0, 0.0, 1.0, 1.0) : vec4(0.0);

#if PLAGUE_UNDERWATER && WATER_SCATTERING_QUALITY != 0
    ivec2 intervalSize = textureSize(u_Input0, 0);
    ivec2 intervalCoord = clamp(
            ivec2(gl_FragCoord.xy), ivec2(0), intervalSize - ivec2(1));
    vec4 encodedInterval = texelFetch(u_Input0, intervalCoord, 0);
    PlagueWaterVolumeInterval interval = plagueDecodeWaterVolumeInterval(encodedInterval);
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_INTERVAL) {
        fragColor = vec4(plagueWaterShaftIntervalDebug(
                encodedInterval, interval, u_WaterState.x), 1.0);
        return;
    }

    // The additive shaft field is a submerged-camera effect. Dry cameras keep the established water
    // interface and scene pipeline byte-for-byte; in particular this pass must never tint the scene
    // behind an above-water surface again.
    if (u_WaterState.x <= 0.5) {
        return;
    }

    if (!interval.valid) {
        return;
    }

    vec3 scatter;
    vec3 diagnostics;
    if (!plagueWaterIntegrate(interval, texCoord, gl_FragCoord.xy, u_PassTexelSize,
            u_Input2, u_Input1, scatter, diagnostics)) {
        return;
    }
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_REFRACTIVE_FOCUS) {
        fragColor = vec4(plagueWaterShaftFocusDebug(
                diagnostics.x, diagnostics.z), 1.0);
        return;
    }
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_SHADOW_VISIBILITY) {
        fragColor = vec4(plagueWaterShaftShadowDebug(
                diagnostics.y, diagnostics.z), 1.0);
        return;
    }
    if (debugView == PLAGUE_DEBUG_WATER_SHAFT_RAW_SCATTER) {
        fragColor = vec4(plagueWaterShaftRawScatterDebug(scatter), 1.0);
        return;
    }
    fragColor = vec4(max(scatter, vec3(0.0)), interval.revision);
#endif
}
