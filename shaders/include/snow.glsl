// Static snow dusting on exposed, up-facing surfaces: runs in the geometry stage (terrain.fsh),
// where the texture, UVs, alpha shape and real face normal are all still available. No time
// integration, no compute pass, no block IDs — ground vs foliage is told apart by ALPHA_CUTOUT
// (Sodium's own define for the cutout sub-draw). A mob cannot reach this code: entities and block
// entities are separate programs with their own gAoOut write.
// Every constant below is measured in tools/verify_snow_dusting.py.

// v_FaceNormal is NOT a continuous normal: FornaxChunkVertex snaps each quad to its dominant
// cardinal axis. The +Y bucket spans up to 45-54.74 degrees from vertical, closely matching snow's
// real angle of repose (38-45 degrees) — the engine's axis snap doubles as the physically correct
// facing test, for free (partition verified in verify_snow_dusting.py checks 4a-4d). Cross models
// (grass, flowers) get NO snow: their dominant axis is horizontal, and there is no per-vertex
// normal here to fix that without an engine change.
// Smoothstep rather than step: the input is quantised to {-1, 0, 1}, so the window is exact on
// every value that can actually arrive.
float plagueSnowFacing(float faceNormalY) {
    return smoothstep(0.5, 0.9, faceNormalY);
}

// --- Shelter --------------------------------------------------------------------------------------

// Same window plaguePuddleAmount uses on v_SkyLight, deliberately: rain and snow must not disagree
// about which surfaces are open to the sky. Time-independent (sky light, not the lightmap), so a
// dusting placed by this does not change at dusk.
float plagueSnowShelter(float skyLight) {
    return smoothstep(0.80, 0.95, skyLight);
}

// --- Noise ----------------------------------------------------------------------------------------

// builtin.noise sampled REPEAT, R and G only (never B): B is a 4-octave FBM that concentrates near
// 0.5 by the central limit theorem, so it barely reaches a threshold.
// World scales chosen so the combined pattern repeats only every 1000 blocks (lcm derivation in
// tools/verify_snow_dusting.py check 5c).
const float PLAGUE_SNOW_NOISE_FINE  = 0.09;
const float PLAGUE_SNOW_NOISE_BROAD = 0.011;
const float PLAGUE_SNOW_NOISE_LEAF  = 0.25;

// Fixed rotation, (cos, sin) of 31.7 degrees, applied to every lookup: builtin.noise is a
// value-noise lattice, and unrotated its level sets run along block edges, reading as hard square
// patches. One angle for all three octaves preserves the 1000-block period exactly (check 5d);
// three separate angles never would. Must be a true unit vector, or the "rotation" carries a scale
// and the period becomes approximate.
const vec2 PLAGUE_SNOW_NOISE_ROT = vec2(0.8506508, 0.5257311); // 31.72 degrees

vec2 plagueSnowRotate(vec2 p) {
    return vec2(p.x * PLAGUE_SNOW_NOISE_ROT.x - p.y * PLAGUE_SNOW_NOISE_ROT.y,
                p.x * PLAGUE_SNOW_NOISE_ROT.y + p.y * PLAGUE_SNOW_NOISE_ROT.x);
}

// Per-octave Nyquist fade windows, in blocks of pixel footprint measured in the SAMPLED coordinate.
// Not optional: builtin.noise has only one mip level, so an unfaded octave aliases into per-pixel
// sparkle at distance instead of blurring away (check 8). Measured in the sampled coordinate,
// not the surface, because the foliage lookup's vertical axis is compressed
// (PLAGUE_SNOW_LEAF_SQUASH) and its sample point moves faster than the surface on a tilted plate —
// measuring the surface would under-report the rate and let that octave alias on exactly the
// plates it exists for.
const vec2 PLAGUE_SNOW_FADE_FINE  = vec2(0.35, 1.00);
const vec2 PLAGUE_SNOW_FADE_BROAD = vec2(1.40, 4.00);
const vec2 PLAGUE_SNOW_FADE_LEAF  = vec2(0.12, 0.40);

/** Width of a pixel in whatever 2D coordinate the two derivative vectors describe. */
float plagueSnowFootprint(vec2 ddx, vec2 ddy) {
    vec2 w = abs(ddx) + abs(ddy);
    return max(w.x, w.y);
}

/** The same, for the foliage lookup, whose third axis is real; see PLAGUE_SNOW_LEAF_SQUASH. */
float plagueSnowFootprint(vec3 ddx, vec3 ddy) {
    vec3 w = abs(ddx) + abs(ddy);
    return max(max(w.x, w.y), w.z);
}

// --- Ground ---------------------------------------------------------------------------------------

// Octave weights. Both are applied to (noise - 0.5), so the field is centred on 0.5 whatever the
// noise distribution is, and the amount option below therefore means the same thing at every scale.
const float PLAGUE_SNOW_GROUND_BROAD = 0.62; // which AREAS are snowy
const float PLAGUE_SNOW_GROUND_FINE  = 0.38; // ragged edges within them

// Snow settles into height-map lows (mortar grooves, plank seams) like puddles do, but CENTRED on
// 0.5 rather than puddles' uncentred (1 - height): puddles has an engine wetness ramp to anchor to,
// a static dusting does not. 0.18, down from an initial 0.30 that let the height map dominate and
// the noise stop mattering (measured: height 0 -> 0.83 coverage, height 1 -> 0.21).
const float PLAGUE_SNOW_HEIGHT_BIAS = 0.18;

// Coverage window, placed so the field's measured distribution (mean 0.458, sd 0.155 over 200k
// points) gives 0.75 mean coverage at 100% amount with 8% bare ground, 0.27 at 25%, 1.00 at 200%
// (verify_snow_dusting.py checks 6a-6c).
const float PLAGUE_SNOW_GROUND_LO = 0.20;
const float PLAGUE_SNOW_GROUND_HI = 0.48;

// --- Foliage --------------------------------------------------------------------------------------
//
// Three foliage-specific problems, each answered differently from a per-pixel deferred approach:
//   1. FACING: plagueSnowFacing above.
//   2. GREY: a thin-film albedo model reads grey over dark needles at mid coverage. Foliage
//      instead gets snow's full albedo and a near-binary transfer (a texel is snow or needle, not
//      a blend) — only possible per-texel, before lighting.
//   3. FLAT PALE SLAB: uniform coverage cuts a visible plane through a canopy, so foliage gets
//      MORE interior break-up than ground: a 0.25-block octave on top of the clump octave.
const float PLAGUE_SNOW_LEAF_BROAD = 0.70; // which sprays are laden
const float PLAGUE_SNOW_LEAF_FINE  = 0.60; // needles showing through within one

// Threshold and half-width of the near-binary transfer. SHARP keeps foliage out of the grey
// middle; SOFT is what it widens to as the leaf octave fades under the Nyquist window, so a
// distant canopy converges to the field's mean instead of flipping whole plates white.
const float PLAGUE_SNOW_LEAF_T     = 0.52;
const float PLAGUE_SNOW_LEAF_SHARP = 0.045;
const float PLAGUE_SNOW_LEAF_SOFT  = 0.200;

// Vertical structure: the foliage lookup has a REAL third axis, unlike ground.
//
// A 2D-texture lookup is a linear map onto a plane, and any such map has a direction along which
// the field is exactly constant — any quad containing that direction gets a mathematically
// straight snow boundary across it. FAILED APPROACH, do not repeat: shearing the XZ lookup by
// height decorrelates vertically but tilts that constant-direction kernel into exactly the steep
// quads leaf plates use, producing visible parallel diagonal streaks (measured: edge coherence
// 0.61 vs 0.10 on a flat quad). No shear magnitude avoids this on all tilted plates.
//
// Instead: two 2D fetches make one 3D fetch, sampling the same field at two height slices and
// interpolating (smoothstepped, matching the lattice's own per-axis filtering). The slice offset
// is the R2 low-discrepancy pair for the plastic number, in UV so it's one constant for every
// octave and preserves the 1000-block horizontal period exactly (check 5g). Both fetches rely on
// builtin.noise having only ONE mip level, so the UV jump at each slice boundary can't pick a
// garbage LOD.
const vec2 PLAGUE_SNOW_SLICE_STEP = vec2(0.7548777, 0.5698403);

// Cells per tile in builtin.noise's two channels — turns an octave's world scale into its slice
// spacing.
const float PLAGUE_SNOW_R_CELLS = 16.0;
const float PLAGUE_SNOW_G_CELLS = 32.0;

// Vertical cell compression, derived (not tuned) so foliage's worst-case conditioning over the
// dominant-axis "up" bucket (theta <= 54.7356 deg) exactly matches the ground lookup's own
// foreshortening limit of sqrt(3): solving sqrt((1+2k^2)/3) = sqrt(3) gives k = 2 exactly, so
// foliage is never worse conditioned than ground anywhere in the bucket (check 7f). GROUND
// deliberately has NO vertical axis at all — a stepped plaza must read as one continuous
// snowfield, and any height dependence would give each step its own unrelated pattern.
const float PLAGUE_SNOW_LEAF_SQUASH = 2.0;

/** One octave of 3D value noise, from two fetches of the 2D lattice. */
vec4 plagueSnowSlicedNoise(sampler2D noiseTex, vec2 uv, float yCells) {
    float slice = floor(yCells);
    // The lattice's own interpolant (NoiseTexture.channelValue smoothsteps each axis), so the third
    // axis is filtered exactly like the two the texture already has.
    float t = yCells - slice;
    t = t * t * (3.0 - 2.0 * t);
    return mix(texture(noiseTex, uv + fract(PLAGUE_SNOW_SLICE_STEP * slice)),
               texture(noiseTex, uv + fract(PLAGUE_SNOW_SLICE_STEP * (slice + 1.0))), t);
}

// --- Snow's own material --------------------------------------------------------------------------

// Albedo in gAlbedoOut's own space: DISPLAY-encoded, matching how terrain.fsh stores the atlas
// sample. Must STAY display-encoded — gbuffer_resolve decodes gAlbedo on read, so linearising here
// too would decode snow twice and turn it grey. One value, not a thin/deep pair: a static dusting
// has no depth to spend that on.
const vec3 PLAGUE_SNOW_ALBEDO = vec3(0.90, 0.92, 0.96);

// Chosen against this pack's own reflection floor: gbuffer_resolve zeroes reflection weight at or
// below smoothness 0.1 and ssr_trace/ssr_blur early-out there too, so sitting below it is both the
// physically honest read (snow is a rough scatterer) and the cheap one. Raise past 0.1 to give
// snow a sheen, at the cost of a full SSR trace on every snow pixel.
const float PLAGUE_SNOW_SMOOTHNESS = 0.08;

// How much baked AO and parallax self-shadow a full covering removes: a layer of snow bridges the
// relief that produced them. Lower on foliage, whose baked AO is most of what gives a canopy
// depth — lifting it fully turns a laden spruce into a pale blob.
const float PLAGUE_SNOW_AO_LIFT_GROUND  = 0.80;
const float PLAGUE_SNOW_AO_LIFT_FOLIAGE = 0.50;

// How far the surface normal is pulled toward the flat face normal (world up, since only +Y-facing
// quads are ever snowed). Ground pulls most of the way; foliage only half, since a canopy's
// readable structure is its plates catching light differently — pulling them all upward flattens
// it to a pale blob.
const float PLAGUE_SNOW_FLATTEN_GROUND  = 0.70;
const float PLAGUE_SNOW_FLATTEN_FOLIAGE = 0.35;

// How far one step of the amount option shifts the coverage threshold — a shift, not a rescale, so
// 25% thins from the edges inward and 200% closes the bare patches.
const float PLAGUE_SNOW_BIAS_SPAN = 0.30;

// --- Assembly -------------------------------------------------------------------------------------

/**
 * Coverage on SOLID terrain, 0..1.
 *
 * `worldXZ` must be ABSOLUTE world coordinates: camera-relative would anchor the pattern to the
 * player and the snowfield would slide as they walked. No time input — the same block is snowy on
 * day 1 and day 400.
 *
 * `height` is the labPBR height at this texel (already parallax-offset), 0 deepest, 1 at surface.
 * `dPosX`/`dPosY` are dFdx/dFdy of world position, taken BEFORE any cutout discard, for the
 * Nyquist fades above.
 */
float plagueSnowGroundCoverage(sampler2D noiseTex, vec2 worldXZ, float faceNormalY, float skyLight,
                               float height, float bias, vec3 dPosX, vec3 dPosY) {
    float gate = plagueSnowFacing(faceNormalY) * plagueSnowShelter(skyLight);
    if (gate <= 0.0) {
        return 0.0;
    }

    // Derivatives rotated along with the lookup, so the footprint is measured in the same space
    // that's actually sampled.
    vec2 pos = plagueSnowRotate(worldXZ);
    float footprint = plagueSnowFootprint(plagueSnowRotate(dPosX.xz), plagueSnowRotate(dPosY.xz));

    float broad = texture(noiseTex, pos * PLAGUE_SNOW_NOISE_BROAD).g - 0.5;
    float fine  = texture(noiseTex, pos * PLAGUE_SNOW_NOISE_FINE).r  - 0.5;
    broad *= 1.0 - smoothstep(PLAGUE_SNOW_FADE_BROAD.x, PLAGUE_SNOW_FADE_BROAD.y, footprint);
    fine  *= 1.0 - smoothstep(PLAGUE_SNOW_FADE_FINE.x,  PLAGUE_SNOW_FADE_FINE.y,  footprint);

    float field = 0.5
            + PLAGUE_SNOW_GROUND_BROAD * broad
            + PLAGUE_SNOW_GROUND_FINE * fine
            + (0.5 - height) * PLAGUE_SNOW_HEIGHT_BIAS
            + bias;

    return smoothstep(PLAGUE_SNOW_GROUND_LO, PLAGUE_SNOW_GROUND_HI, field) * gate;
}

/**
 * Coverage on CUTOUT terrain (leaves, bushes), 0..1. Takes the full absolute world POSITION (not
 * just XZ) since the field is 3D; see PLAGUE_SNOW_LEAF_SQUASH. No height-map term: a leaf sprite's
 * alpha already carries its shape. Near-binary transfer on purpose — see the GREY problem above.
 */
float plagueSnowFoliageCoverage(sampler2D noiseTex, vec3 worldPos, float faceNormalY, float skyLight,
                                float bias, vec3 dPosX, vec3 dPosY) {
    float gate = plagueSnowFacing(faceNormalY) * plagueSnowShelter(skyLight);
    if (gate <= 0.0) {
        return 0.0;
    }

    vec2 pos = plagueSnowRotate(worldPos.xz);
    float lift = worldPos.y * PLAGUE_SNOW_LEAF_SQUASH;
    // The lookup coordinate's OWN derivative, not the surface's: the vertical axis is compressed,
    // so the sample point moves faster than the surface on a tilted plate. The slice step itself
    // is NOT differentiated — it's piecewise constant in height.
    float footprint = plagueSnowFootprint(
            vec3(plagueSnowRotate(dPosX.xz), dPosX.y * PLAGUE_SNOW_LEAF_SQUASH),
            vec3(plagueSnowRotate(dPosY.xz), dPosY.y * PLAGUE_SNOW_LEAF_SQUASH));

    float broad = plagueSnowSlicedNoise(noiseTex, pos * PLAGUE_SNOW_NOISE_BROAD,
            lift * PLAGUE_SNOW_NOISE_BROAD * PLAGUE_SNOW_G_CELLS).g - 0.5;
    float leaf  = plagueSnowSlicedNoise(noiseTex, pos * PLAGUE_SNOW_NOISE_LEAF,
            lift * PLAGUE_SNOW_NOISE_LEAF  * PLAGUE_SNOW_R_CELLS).r - 0.5;
    broad *= 1.0 - smoothstep(PLAGUE_SNOW_FADE_BROAD.x, PLAGUE_SNOW_FADE_BROAD.y, footprint);
    // Both attenuates the octave and widens the transfer, so a distant field converges to its
    // mean rather than the broad octave's own hard edge.
    float leafFade = smoothstep(PLAGUE_SNOW_FADE_LEAF.x, PLAGUE_SNOW_FADE_LEAF.y, footprint);
    leaf *= 1.0 - leafFade;

    float field = 0.5
            + PLAGUE_SNOW_LEAF_BROAD * broad
            + PLAGUE_SNOW_LEAF_FINE * leaf
            + bias;

    float halfWidth = mix(PLAGUE_SNOW_LEAF_SHARP, PLAGUE_SNOW_LEAF_SOFT, leafFade);
    return smoothstep(PLAGUE_SNOW_LEAF_T - halfWidth, PLAGUE_SNOW_LEAF_T + halfWidth, field) * gate;
}

/**
 * Lays snow on the G-BUFFER INPUTS, before anything is written — same reasoning as
 * plagueApplyPuddle: snow is a different material on top, not a tint, and the resolve can't
 * recover a normal or roughness already baked into the G-buffer.
 *
 * F0 and the conductor flag are DELIBERATELY untouched: snow's F0 (0.04) is close enough to
 * typical terrain to change nothing visible, while on a metal it would turn iron into plastic (the
 * F0 byte encodes WHICH metal it is).
 */
void plagueApplySnow(float coverage, float aoLift, float flatten,
                     inout vec3 albedo, inout vec3 normal, vec3 faceNormal,
                     inout float smoothness, inout float bakedAo, inout float pomShadow) {
    if (coverage <= 0.0) {
        return;
    }

    albedo = mix(albedo, PLAGUE_SNOW_ALBEDO, coverage);
    smoothness = mix(smoothness, PLAGUE_SNOW_SMOOTHNESS, coverage);
    bakedAo   = mix(bakedAo,   1.0, coverage * aoLift);
    pomShadow = mix(pomShadow, 1.0, coverage * aoLift);
    normal = normalize(mix(normal, faceNormal, coverage * flatten));
}
