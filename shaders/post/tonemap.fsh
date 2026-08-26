#version 330 core

// Linear HDR -> displayable sRGB. A separate pass so bloom, exposure metering and grading can read
// true scene-referred values before the curve squeezes them into display range; the curve itself
// lives in shaders/include/tonemap.glsl, shared with forward-draw fog compositing so both land in
// the same colour space.
#moj_import <fornax_runtime:tonemap.glsl>
// For the underwater blur below: u_WaterState (the gate), u_InvProjModelView (world distance from
// depth). Costs nothing when dry, since the whole blur sits behind a uniform branch.
#moj_import <fornax:globals.glsl>
// For plagueChunksToBlocks, converting the blur's own start/end options into blocks. (light_and_
// ambient first, since underwater.glsl's colour helpers take PlagueLighting.)
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:underwater.glsl>

uniform sampler2D u_Input0; // sceneHdrRefracted: linear, unbounded, finished composite (water, clouds, veil)
uniform sampler2D u_Input1; // builtin.depth: reversed-Z, so 0.0 is the far plane
uniform sampler2D u_Input2; // bloomFinal: half-res bloom pyramid, linear; zero-cleared when bloom is gated off
uniform sampler2D u_Input3; // builtin.waterDepth: translucent boundary depth, reversed-Z
uniform sampler2D u_Input4; // exposure: 1x1 smoothed scene luma accumulator (exposure_measure.fsh), 0.0 if unrun
uniform sampler2D u_Input5; // underwaterBlurred: half-resolution scene Gaussian
uniform sampler2D u_Input6; // builtin.noise, the camera water transition mask
uniform sampler2D u_Input7; // waterVolumeShaftsResolved: full-resolution linear shaft radiance

// Only u_Param3 is read here; the trailing sun/celestial fields other passes append are left
// undeclared, since the engine binds the full u_PassParams buffer regardless of block coverage.
layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
};

in vec2 texCoord;
out vec4 fragColor;

// --- Options ---------------------------------------------------------------------------------------
// TONEMAP_OPERATOR and the six grading sliders are declared in tonemap.glsl. Only options this
// PASS owns are here.

// Compile option: bloom owns eight passes and eight render targets, so off must cost nothing.
#define BLOOM_ENABLED //[] compile "Bloom"

// Declared here byte-identical to gbuffer_resolve.fsh (loader requirement); without it the #ifdef
// below never fires and this pass discards the sky the resolve just painted.
#define SKY_PROCEDURAL //[] compile "Procedural Sky"

#moj_import <fornax_runtime:water_options.glsl>
const float PLAGUE_UW_VIEW_PI = 3.14159265359;
const float PLAGUE_UW_VIEW_INV_SQRT_TWO = 0.70710678118;
// Exact orthogonal unit directions from the 3-4-5 triangle. Independent directions prevent the
// field from collapsing into the single diagonal compression wave this replaces.
const vec2 PLAGUE_UW_VIEW_DIR_X = vec2(0.8, 0.6);
const vec2 PLAGUE_UW_VIEW_DIR_Y = vec2(-0.6, 0.8);
// Unequal, opposite drifts keep the two axes from translating as one rigid lattice. The second
// spatial rate is non-integer relative to the first, so their shapes do not share a short repeat.
const float PLAGUE_UW_VIEW_RATE_X = 0.72;
const float PLAGUE_UW_VIEW_RATE_Y = -0.91;
const float PLAGUE_UW_VIEW_FREQ_Y = 0.83;
const float PLAGUE_UW_VIEW_PHASE_Y = 1.57079632679;

// mix() toward the blurred image, not an add: an additive composite of unthresholded, whole-image
// bloom lays a milky veil over everything at any strength worth seeing.
#define u_BloomStrength 0.32 //[0.0..0.5 step 0.01] runtime "Bloom Strength"

// Measurement lives in exposure_measure.fsh; this arm turns its smoothed scene luminance into a
// multiplier. Default on: Plague has no fixed absolute-luminance reference to protect, and a fixed
// exposure cannot make a dark underwater scene read correctly at any manual tuning.
#define AUTO_EXPOSURE //[] compile "Auto Exposure"
// Bounds on the derived MULTIPLIER, not the measured luminance (it's the reciprocal, so clamping
// the measurement would reverse the sliders' sense). Min caps darkening of bright scenes; Max caps
// brightening of dark ones.
#define u_AutoExposureMin 0.25 //[0.1..1.0 step 0.05] runtime "Auto Exposure Min"
#define u_AutoExposureMax 2.5 //[1.0..8.0 step 0.5] runtime "Auto Exposure Max"

vec2 plagueTonemapDepthPair(vec2 uv) {
    return vec2(texture(u_Input1, uv).r, texture(u_Input3, uv).r);
}

float plagueTonemapDistance(vec2 uv, float depth) {
    if (depth <= 0.0) {
        return 1e4;
    }
    vec4 h = u_InvProjModelView * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return length(h.xyz / max(abs(h.w), 1e-6) * sign(h.w));
}

// Depth-aware 2x2 reconstruction for half-resolution underwater fields: bilinear weights preserve
// smooth beams, full-resolution depth rejects taps from another silhouette.
vec3 plagueUwBilateralUpsample(sampler2D source, vec2 uv) {
    vec2 sourceSize = vec2(textureSize(source, 0));
    vec2 sourcePos = uv * sourceSize - 0.5;
    vec2 base = floor(sourcePos);
    vec2 fraction = fract(sourcePos);
    vec2 centerDepths = plagueTonemapDepthPair(uv);
    float centerDepth = max(centerDepths.x, centerDepths.y);
    float centerDistance = plagueTonemapDistance(uv, centerDepth);
    float centerWaterFront = step(centerDepths.x, centerDepths.y);
    vec3 sum = vec3(0.0);
    float weightSum = 0.0;
    for (int y = 0; y < 2; ++y) {
        for (int x = 0; x < 2; ++x) {
            vec2 corner = vec2(float(x), float(y));
            vec2 tapUv = clamp((base + corner + 0.5) / sourceSize, vec2(0.0), vec2(1.0));
            vec2 tapDepths = plagueTonemapDepthPair(tapUv);
            float tapDepth = max(tapDepths.x, tapDepths.y);
            float tapDistance = plagueTonemapDistance(tapUv, tapDepth);
            float tapWaterFront = step(tapDepths.x, tapDepths.y);
            vec2 axisWeight = mix(vec2(1.0) - fraction, fraction, corner);
            float spatialWeight = axisWeight.x * axisWeight.y;
            float depthScale = max(1.0, min(centerDistance, tapDistance) * 0.06);
            float depthWeight = exp(-abs(tapDistance - centerDistance) / depthScale);
            float topologyWeight = 1.0 - 0.95 * abs(centerWaterFront - tapWaterFront);
            float weight = spatialWeight * depthWeight * topologyWeight;
            vec3 tap = texture(source, tapUv).rgb;
            if (!any(isnan(tap)) && !any(isinf(tap))) {
                sum += max(tap, vec3(0.0)) * weight;
                weightSum += weight;
            }
        }
    }
    // All 4 taps across a depth/topology discontinuity collapses weight toward 0, so fall back to a
    // plain bilinear fetch rather than manufacture black from dividing by a near-zero sum.
    if (weightSum < 0.05) {
        return texture(source, uv).rgb;
    }
    return sum / weightSum;
}

// Water-on-camera distortion, driven by Fornax's signed transition envelope (u_WaterState.w). A
// FINAL-FRAME UV remap only: it changes neither colour nor opacity.
vec2 plagueWaterCameraUv(vec2 uv) {
    float entryAmount = max(-u_WaterState.w, 0.0); // 1 -> 0 over 1 s
    float exitAmount = max(u_WaterState.w, 0.0);   // 1 -> 0 over 1 s
    float distortMask = 0.0;
    float aspectRatio = u_PassTexelSize.y / max(u_PassTexelSize.x, 1e-8);

    if (exitAmount > 1e-4) {
        vec2 exitScale = vec2(0.5, 0.25 + exitAmount * exitAmount * 0.25)
                * vec2(aspectRatio, 1.0);
        vec2 exitNoiseUv = (uv - vec2(0.0, exitAmount)) * exitScale;
        float waterDrops = texture(u_Input6, exitNoiseUv).r;
        // The rising threshold above shrinks how much of the noise field survives as exitAmount
        // falls, but not how bright a surviving droplet is: a texel just over threshold reaches
        // the same peak near exitAmount == 0 as at exitAmount == 1. Surviving droplets held
        // near-constant opacity until the tracker's hard zero, then vanished in the one frame
        // direction resets. The trailing exitAmount factor fades that residual opacity to true
        // zero over the same second the droplets are shrinking, so the last ones dim out instead
        // of popping off. Ceiling is u_WaterSplashStrength (water_options.glsl), not hardcoded.
        waterDrops = sqrt(min(max(waterDrops
                - (1.0 - sqrt(exitAmount)) * 0.7, 0.0) * (1.0 + exitAmount), 1.0))
                * u_WaterSplashStrength * exitAmount;
        distortMask = max(distortMask, waterDrops);
    }

    if (entryAmount > 1e-4) {
        vec2 entryNoiseUv = (0.5 + (uv - 0.5) * sqrt(entryAmount))
                * vec2(aspectRatio, 1.0);
        // Capped at the same ceiling the exit arm above uses (its own trailing multiplier).
        // Uncapped, a bright noise texel at entryAmount's peak (the dive-in frame) drove this to
        // ~1.0, which collapses remapped toward dead-center UV for that pixel: large swatches of
        // the frame briefly sample one screen-center point instead of the real underwater scene,
        // reading as the whole veil/tint dropping out for the splash's ~1 s decay. Ceiling is
        // u_WaterSplashStrength (water_options.glsl), not hardcoded.
        float waterSplash = texture(u_Input6, entryNoiseUv).r * entryAmount * u_WaterSplashStrength;
        distortMask = max(distortMask, waterSplash);
    }

    vec2 remapped = 0.5 + (uv - 0.5) * (1.0 - distortMask);
    return clamp(remapped, u_PassTexelSize * 1.5,
            vec2(1.0) - u_PassTexelSize * 1.5);
}

// The view warp applies here, at the final scene read, rather than in underwater_refraction, so one
// frameUv drives scene colour, shafts, depth, blur and bloom together instead of drifting apart.
vec2 plagueUnderwaterViewUv(vec2 uv) {
#if PLAGUE_UNDERWATER
    if (u_WaterState.x <= 0.5 || u_UnderwaterViewWarpPixels <= 0.0) {
        return uv;
    }

    float cameraWaterDepth = max(u_WaterState.z - u_CameraAbs.y, 0.0);
    float submergedFade = smoothstep(0.08, 0.55, cameraWaterDepth);
    float amplitudePixels = max(u_UnderwaterViewWarpPixels, 0.0) * submergedFade;
    if (amplitudePixels <= 0.0) {
        return uv;
    }

    // Screen-height units: one horizontal pixel and one vertical pixel advance the phase by the
    // same physical amount, regardless of aspect ratio.
    float aspectRatio = u_PassTexelSize.y / max(u_PassTexelSize.x, 1e-8);
    vec2 viewPosition = vec2((uv.x - 0.5) * aspectRatio, uv.y - 0.5);
    float waveNumber = PLAGUE_UW_VIEW_PI * max(u_UnderwaterWarpBends, 0.5);
    float time = u_SkyState.w / 20.0;
    float phaseX = dot(viewPosition, PLAGUE_UW_VIEW_DIR_X) * waveNumber
                 + time * PLAGUE_UW_VIEW_RATE_X;
    float phaseY = dot(viewPosition, PLAGUE_UW_VIEW_DIR_Y) * waveNumber
                 * PLAGUE_UW_VIEW_FREQ_Y + time * PLAGUE_UW_VIEW_RATE_Y
                 + PLAGUE_UW_VIEW_PHASE_Y;
    vec2 field = vec2(sin(phaseX), sin(phaseY)) * PLAGUE_UW_VIEW_INV_SQRT_TWO;

    // Reserve the authored amplitude at every edge, then oscillate inside it: a continuous overscan
    // instead of collapsing several output pixels onto one frozen border texel.
    vec2 margin = amplitudePixels * u_PassTexelSize;
    vec2 safeUv = mix(margin, vec2(1.0) - margin, uv);
    return safeUv + field * amplitudePixels * u_PassTexelSize;
#else
    return uv;
#endif
}

void main() {
    // Temporary bisect (LabPBR decode audit): u_Param3 is a GBufferDebugView ordinal (see
    // gbuffer_resolve.fsh's DBG_* block). Debug views write raw, untonemapped data, so this bails
    // out before the blur/bloom/curve/dither below re-quantize bytes meant to be read raw. Must run
    // before the sky discard below, or SKY_PROCEDURAL-off discards sky pixels the resolve already
    // wrote debug data into for SHADOW_MAP_VIEW and later full-screen views.
    int debugView = int(u_Param3 + 0.5);
    // DBG_EXPOSURE (ordinal 15): the one debug view this pass answers itself instead of passing
    // through raw scene data, so it is checked before the generic bail-out below.
    if (debugView == 15) {
        float dbgExposureLuma = texture(u_Input4, vec2(0.5)).r;
#ifdef AUTO_EXPOSURE
        float dbgAutoExposure = clamp(0.18 / max(dbgExposureLuma, 1e-4),
                u_AutoExposureMin, u_AutoExposureMax);
#else
        float dbgAutoExposure = 1.0;
#endif
        // Halved before display: the multiplier's range exceeds 1.0, and an unscaled display would
        // clip everything above 1.0x to flat white.
        fragColor = vec4(vec3(clamp(dbgAutoExposure * 0.5, 0.0, 1.0)), 1.0);
        return;
    }
    if (debugView != 0) {
        fragColor = vec4(texture(u_Input0, texCoord).rgb, 1.0);
        return;
    }

    vec2 frameUv = plagueUnderwaterViewUv(plagueWaterCameraUv(texCoord));
    vec3 hdr = texture(u_Input0, frameUv).rgb;

    // Sky handling must match the resolve's exactly. With SKY_PROCEDURAL the resolve paints the dome
    // into sceneHdr, so tonemap it normally; without it sceneHdr holds LAST FRAME's discarded value,
    // so this must discard too and let vanilla's sky show through. Reversed-Z: far plane is 0.0.
#ifndef SKY_PROCEDURAL
    if (texture(u_Input1, frameUv).r <= 0.0) {
        discard;
    }
#endif

#if PLAGUE_UNDERWATER && WATER_BLUR
    // Underwater blur: scattering defocuses as well as tints/attenuates. The Gaussian kernel lives
    // in underwater_blur_h.fsh/underwater_blur_v.fsh; this only decides, per pixel, how much to
    // blend toward that already-finished blur.
    if (u_WaterState.x > 0.5 && u_UwBlurRadius > 0.0 && u_UwBlurStrength > 0.0) {
        vec2 uwCenterDepths = plagueTonemapDepthPair(frameUv);
        float uwOpaqueDepth = uwCenterDepths.x;
        float uwWaterDepth = uwCenterDepths.y;
        float uwDepth = max(uwOpaqueDepth, uwWaterDepth); // reversed-Z: larger is nearer
        // Miss pixels (plagueTonemapDistance's 1e4 sentinel) are clamped to the blur's own end
        // distance rather than left at the raw sentinel, so open water gets the ramp's max blend by
        // construction rather than by accident.
        float uwDist = min(plagueTonemapDistance(frameUv, uwDepth),
                           plagueChunksToBlocks(u_UwBlurEnd));
        // Start/end deliberately decoupled from the fog distance slider, which used to double as
        // this and coupled two unrelated controls. max(end - start, 1.0) keeps the divide safe if
        // they coincide.
        float uwBlurStartBlocks = plagueChunksToBlocks(u_UwBlurStart);
        float uwBlurEndBlocks = plagueChunksToBlocks(u_UwBlurEnd);
        float uwDistRamp = clamp((uwDist - uwBlurStartBlocks)
                                 / max(uwBlurEndBlocks - uwBlurStartBlocks, 1.0), 0.0, 1.0);
        // Baseline floor: being underwater carries some optical diffusion even before the start
        // distance. 0.18 (down from 0.30) after live testing showed 0.30 eating mid-distance
        // texture in open-ocean framings.
        const float UW_BLUR_BASELINE = 0.18;
        float uwAmount = mix(UW_BLUR_BASELINE, 1.0, smoothstep(0.0, 1.0, uwDistRamp));
        vec3 uwBlurred = plagueUwBilateralUpsample(u_Input5, frameUv);
        // Ceiling at 0.92, not 1.0: at blend 1.0 mix() fully replaces the signal with the blur's own
        // flat average colour instead of blending toward it.
        float uwBlurBlend = clamp(u_UwBlurStrength, 0.0, 0.92) * uwAmount;
        hdr = mix(hdr, uwBlurred, uwBlurBlend);
    }
#endif

    // Guard before anything else: a NaN or negative from an earlier pass propagates through every
    // operator below and is miserable to trace back to its source once it reaches the screen.
    hdr = max(hdr, vec3(0.0));
    if (any(isnan(hdr))) {
        hdr = vec3(0.0);
    }

#ifdef BLOOM_ENABLED
    // Blended before exposure and the curve, in scene-referred linear light: bloom is light that
    // scattered in the lens, so it belongs to the scene the curve is measuring. mix(), not +=.
    vec3 bloom = texture(u_Input2, frameUv).rgb;
    bloom = max(bloom, vec3(0.0));
    if (!any(isnan(bloom))) {
        hdr = mix(hdr, bloom, u_BloomStrength);
    }
#endif

    // Shafts join after the underwater Gaussian and bloom pyramid, so neither spatial filter can
    // spread them across a terrain edge. They remain before the final exposure multiplier below.
    vec3 resolvedShafts = max(texture(u_Input7, frameUv).rgb, vec3(0.0));
    if (!any(isnan(resolvedShafts)) && !any(isinf(resolvedShafts))) {
        hdr += resolvedShafts;
    }

#ifdef AUTO_EXPOSURE
    // Grey-world auto-exposure (0.18 mid-grey target over exposure_measure.fsh's luma), MULTIPLIED
    // into hdr here rather than folded into tonemap.glsl's u_Exposure: that slider is a user's
    // manual trim that must stay meaningful as a bias, and forward draws share plagueTonemapAndGrade
    // but have no exposure texture, so this factor must never reach that shared entry point.
    //
    // plagueUntonemapApprox cannot invert this factor (it never reaches a forward-draw shader), so a
    // forward fog blend carries a bounded error, up to how far the clamped factor strays from 1.0.
    float exposureLuma = texture(u_Input4, vec2(0.5)).r;
    float autoExposure = clamp(0.18 / max(exposureLuma, 1e-4), u_AutoExposureMin, u_AutoExposureMax);
    hdr *= autoExposure;
#endif

    // Exposure, operator, display encode, grade: all in tonemap.glsl. Forward draws call this same
    // function on their fog colour, keeping both in the same colour space by construction.
    vec3 display = plagueTonemapAndGrade(hdr);

    // Display-space dither on the finished value, the last arithmetic before quantization, which is
    // the only place dithering defeats banding (dithering the scene-space mix upstream doesn't work,
    // since the tonemap re-quantizes it). Two independent hashes summed for a triangular
    // distribution: IGN's diagonal structure draws visible lines along a band boundary instead.
    uvec2 uwPix = uvec2(gl_FragCoord.xy);
    uint h1 = uwPix.x * 1664525u + uwPix.y * 1013904223u;
    h1 = (h1 ^ (h1 >> 16u)) * 2246822519u;
    uint h2 = uwPix.x * 3266489917u + uwPix.y * 668265263u;
    h2 = (h2 ^ (h2 >> 15u)) * 374761393u;
    float quantDither = (float(h1 & 0xFFFFu) + float(h2 & 0xFFFFu)) / 65535.0 - 1.0; // -1..1 triangular
    display += quantDither / 255.0;

    fragColor = vec4(display, 1.0);
}
