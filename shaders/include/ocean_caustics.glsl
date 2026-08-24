#ifndef PLAGUE_OCEAN_CAUSTICS
#define PLAGUE_OCEAN_CAUSTICS

// Underwater caustics: the moving web of bright filaments a wind-driven water surface throws onto
// everything below it.
//
// Built on one fact: a caustic is formed on the water surface, one horizontal plane, not a property
// of the receiver. This file evaluates one field, on one plane, at a point the caller has already
// slid along the sun azimuth by its own depth to the surface. That single projection is where wall
// streaking comes from for free: walking up a wall shrinks the depth to the surface, sliding the
// sampled point along the azimuth, in phase with the floor because it is the same field.
//
// Everything here is added light — never fed into extinction, transmittance, absorption or fog.
// Accordingly this file takes no medium parameters, no depth, no shadow term, no strength slider and
// no camera state. Occlusion and depth-shaping are the resolve's job.
//
// Fragment stage only: plagueCausticsBloomProjected calls dFdx/dFdy, which do not exist outside a
// fragment shader. Both shipped consumers (gbuffer_resolve.fsh, water_composite.fsh) are .fsh; if
// this is ever pulled into a vertex or compute stage the derivative helpers must be gated or moved.
//
// Time is in seconds: `waveTime` is already divided by tick rate and scaled by the caller's rate
// slider, so every rate constant below is per second. Getting this wrong is silent — a tick-rate
// constant reads as twenty-times-too-still water, not as an obvious bug.
//
// water_composite.fsh imports this file ONLY for the two compile-option declarations below (the
// option scanner merges same-name declarations across files); it calls none of this file's code.

// ---------------------------------------------------------------------------------------------
// Compile options. screens.toml binds both identifiers by name in its Caustics group. The option
// scanner's ABI requires the value ladder to be integers, hence the _M (milli) / _PCT (percent)
// suffix convention (cf. PLAGUE_WETNESS_PCT in post/gbuffer_resolve.fsh).
// ---------------------------------------------------------------------------------------------

// Size and rate are runtime sliders in post/gbuffer_resolve.fsh, not options here: this file is
// compiled ahead of its consumers' option blocks, so it cannot forward-reference them. Size arrives
// as a unitless multiplier; rate is applied by the caller to the clock it passes.
//
// What stays here is the TUNED value the slider is a percentage of. 0.100 puts one tile across ten
// blocks, landing a cell at roughly block-face scale. Measured: lit filaments 0.031 blocks wide with
// 0.405 blocks of dark between them, half-decorrelating over 0.033 blocks.
//
// The size slider cannot open the cells up (see CAUSTICS_CELL_LOW below): a sweep across its whole
// range moves the lit-area fraction by under one percent of itself (0.0720 at 0.4x, 0.0718 at 1x,
// 0.0724 at 2x). Size resizes the pattern; it cannot separate it.
#define CAUSTICS_BASE_SCALE 0.100

// ---------------------------------------------------------------------------------------------
// Composition gains, applied by post/gbuffer_resolve.fsh. Deliberately independent of each other
// and of direct caustic strength (each has its own guard). Set together, not separately, by
// measuring each term's average contribution over a lit seabed: web ~78%, crest highlight ~19%,
// halo ~3%.
// ---------------------------------------------------------------------------------------------

// Halo gain.  Half the direct web, because a bloom that competes with the thing blooming reads as
// haze rather than as light spilling off a filament.
#ifndef CAUSTICS_BLOOM_STRENGTH
#define CAUSTICS_BLOOM_STRENGTH 0.5
#endif

// Crest gain. Above 1 on purpose: the ONE term the resolve pushes past display white, so a filament
// core reads as a light source rather than a bright surface. 2.6 saturates the crest well over white
// while the crest area stays under a tenth of a percent of a floor (a spark, not a glare).
#ifndef CAUSTICS_HDR_STRENGTH
#define CAUSTICS_HDR_STRENGTH 2.6
#endif

// Secondary-spill gain.  About an eighth of the direct web: enough that a wall the sun misses stops
// reading as a flat cutout beside a glowing seabed, small enough that it never competes with a real
// caustic on a surface that has one.
#ifndef CAUSTICS_BOUNCE_STRENGTH
#define CAUSTICS_BOUNCE_STRENGTH 0.15
#endif

// ---------------------------------------------------------------------------------------------
// Pattern-field constants. Every one is authored and measured, not published; feature sizes are in
// world blocks at the default scale, rates and lifetimes in SECONDS of wave clock at default speed.
// Measurements come from a numpy model of this same arithmetic, sampling the same texture the shader
// samples, at 200,000-800,000 world points spread over several thousand blocks.
// ---------------------------------------------------------------------------------------------

// TWO decorrelated layers: the minimum the crossing product below needs. A third layer was measured
// and dropped — it tightened the field's value distribution enough that the top of the range stopped
// being reachable.
//
// Rotations differ by 44 degrees, neither near an axis, so no pair of layers shares a tile symmetry
// and the two cannot lock into a moire.
const mat2 CAUSTICS_ROT_A = mat2( 0.9563048, 0.2923717, -0.2923717, 0.9563048); // +17 degrees
const mat2 CAUSTICS_ROT_B = mat2( 0.4848096, 0.8746197, -0.8746197, 0.4848096); // +61 degrees

// Relative spatial frequency of the second layer. 1.93 is deliberately off 2.0 — an exact octave
// would repeat with the first layer every other tile and hand the seabed a visible beat. Fitted to
// the field's own correlation profile: half-decorrelates over 0.033 blocks, mean dark gap 0.405
// blocks. Lower fattens filaments and drags cells apart; raise fills cells in with glitter.
#define CAUSTICS_LAYER_B_FREQ 1.93

// Blend of the two layers into the broad body of the pattern. Sums to 1 so the blend cannot change
// the field's overall level; slightly front-weighted since the first layer carries the coarse cell
// structure the eye tracks.
#define CAUSTICS_LAYER_A_WEIGHT 0.55
#define CAUSTICS_LAYER_B_WEIGHT 0.45

// DRIFT. Each layer travels at a constant velocity across the world plane; the pair is what makes
// crossings dissolve and re-form rather than sliding the whole web rigidly. Authored as a world
// BEARING plus SPEED (plagueCausticsDriftDirection turns the bearing into a uv translation).
//
// THE SPEED is the only number here a measurement fixes: 0.0740 tile widths/second puts the RIDGE
// field's own half-decorrelation at 0.108 seconds of wave clock — measured on the ridge field alone,
// not the shaped field, since the shaping thresholds are a strong nonlinearity that runs the shaped
// field's half-correlation at roughly half the ridge's regardless of drift.
//
// At the default scale, 0.74 blocks per second.
#define CAUSTICS_DRIFT_A 0.0740

// THE BEARINGS are authored and free to be: the field is statistically isotropic, so rotating both
// drifts moves no spatial statistic at all. Chosen ninety degrees apart (parallel drifts never
// re-form the web; opposed drifts just beat along one axis) and placed at least 21 degrees off every
// layer rotation and its perpendiculars, so no drift runs along a layer's own grain.
#define CAUSTICS_DRIFT_BEARING_A  38.0
#define CAUSTICS_DRIFT_BEARING_B 128.0

// Layer B's speed relative to layer A's. Not authored: physics. Deep-water gravity waves travel at
// c = sqrt(g * lambda / (2*pi)) (Airy 1845; Kinsman, "Wind Waves", 1965, ch. 3), so phase speed goes
// as sqrt(wavelength). Layer B is shorter by CAUSTICS_LAYER_B_FREQ, so it travels slower by that root.
#define CAUSTICS_DRIFT_B (CAUSTICS_DRIFT_A * sqrt(CAUSTICS_LAYER_B_FREQ))

// Time-varying domain warp: without it cells are rigid shapes sliding past each other; with it they
// crawl, stretch and re-form. Two sinusoids per output axis, the second mixing both input axes so
// the warp isn't axis-aligned.
//
// Amplitude 0.009 tile-widths (0.013 with the secondary lobe) is about a quarter of the 0.054-tile
// cell spacing: it must PERTURB the cells, not scramble them into noise.
//
// The eight frequencies (written inline in plagueCausticsRidge) sit far below cell frequency
// spatially, and are mutually non-commensurate temporally so the warp never repeats on a short
// cycle. Measured to contribute NOTHING to decorrelation rate: freezing the warp entirely moves
// half-decorrelation from 0.10780 to 0.10781 seconds. These four set how fast cells RE-SHAPE, not
// how fast they decorrelate — that's the drift's job alone.
#define CAUSTICS_WARP_AMPLITUDE 0.009
#define CAUSTICS_WARP_LOBE      0.45

// The second layer gets a REWEIGHTED, AXIS-SWAPPED copy of the same displacement — identical warp on
// both layers would translate the field rigidly and buy nothing.
#define CAUSTICS_WARP_REWEIGHT vec2(-0.72, 0.63)

// How far the broad blend is pulled toward the geometric mean of the layers — the physically
// meaningful step, since the mean is bright only where every layer is bright (an AND, matching a
// real caustic node: where focusing wavefronts intersect). At 1 only crossings survive and the
// connective tissue disappears. 0.45 was fitted jointly with the shaping edges below.
#define CAUSTICS_CROSSING_MIX 0.45

// SHAPING. Two smooth thresholds over different sub-ranges of the ridge field, summed with weights.
//
// CAUSTICS_CELL_LOW is THE SEPARATION CONTROL and the single most consequential number in this file:
// raising it opens GAPS BETWEEN CELLS rather than shrinking every cell uniformly (cell size doesn't
// change, lit fraction does).
//
// 0.293 is the ridge field's 83.7th percentile (84% of the plane stays dark). Measured: lit-area
// fraction 0.163 above zero, 0.072 above a tenth, gap-to-lit run ratio 13.0 (mean lit run 0.031
// blocks, mean gap 0.405 blocks). Push the edge higher and lit area collapses into isolated sparkles.
//
// The size slider does NOT move this: lit-area fraction above a tenth stays within one percent of
// itself across its whole range (0.0720/0.0718/0.0724 at 40/100/200). Separation lives here only.
#define CAUSTICS_CELL_LOW  0.293
#define CAUSTICS_CELL_HIGH 0.770

// The filament core: a narrower, higher band between the ridge field's 98.8th and 99.97th
// percentiles. Only the top 1.2% of the plane grows a core, only the top 0.03% saturates, which
// lets the field reach 1.0 without the surrounding cells washing out.
#define CAUSTICS_FILAMENT_LOW  0.560
#define CAUSTICS_FILAMENT_HIGH 0.920

// THESE TWO WEIGHTS SUM TO EXACTLY 1.0, LOAD-BEARING NOT COSMETIC: downstream thresholds, a power
// and a bloom seed all assume the field reaches 1.0, or the result collapses toward isolated
// sparkles and the resolve's HDR term becomes unreachable. Three-quarters body to one-quarter core
// was fitted against the measured lit-area curve with the sum pinned at 1.
#define CAUSTICS_CELL_WEIGHT     0.75
#define CAUSTICS_FILAMENT_WEIGHT 0.25

// Focus flicker: intensity at a point wavers as wavefronts above it slide past each other. A
// modulation, not a source — rides existing samples, adds no fetch, and must never substitute for
// shaping the field (an oscillation with nothing from the focusing field reads as a wash).
//
// Base and amplitude SUM TO 1 so a saturated cell under a modulation peak still reaches exactly 1.0.
// Spatial frequencies (1.4x, 1.7x cell frequency) keep the flicker finer than the cells it
// modulates. Temporal rates put the shimmer on a 3.3-4.2-tick cycle, the same order as a cell's own
// 2.7-tick lifetime — chosen on the physics, not a fit: at 6% amplitude the flicker moves no
// behaviour-fixture statistic by more than a tenth of a percent.
#define CAUSTICS_FOCUS_BASE      0.94
#define CAUSTICS_FOCUS_AMPLITUDE 0.06
#define CAUSTICS_FOCUS_FREQ_X    165.0
#define CAUSTICS_FOCUS_FREQ_Z    197.0
#define CAUSTICS_FOCUS_RATE_X    1.50
#define CAUSTICS_FOCUS_RATE_Z    1.90

// Crest seed exponent. The smooth threshold picks the crests; the square narrows them further so a
// filament core reads as a light source. A cube was tried and narrowed the seed so far the halo
// detaches into isolated points.
#define CAUSTICS_CREST_EXPONENT 2.0

// Halo reach, in screen pixels. Three pixels: wide enough that a one-pixel filament grows a visible
// glow, small enough to stay compact. Fitted against the halo's measured spread across a sweep of
// per-pixel world footprints from close-up to distant grazing.
#define CAUSTICS_HALO_RADIUS 3.0

// Halo kernel weights: centre plus four ring taps, 0.40 + 4*0.15 == 1.0 EXACTLY — a saturated
// neighbourhood must land precisely at the top of the range, so the clamp is a safety net, not what
// shapes the halo.
#define CAUSTICS_HALO_CENTRE 0.40
#define CAUSTICS_HALO_RING   0.15

// Bounce floor: what an up-facing surface still collects from neighbours' spill. Not zero (looks
// cut out) and not large (a floor already gets the direct caustic; the wall stays the bigger receiver).
#define CAUSTICS_BOUNCE_FLOOR 0.25

// ---------------------------------------------------------------------------------------------
// Internal helpers.  Names, existence and boundaries here are private to this file.
// ---------------------------------------------------------------------------------------------

/**
 * Mirrored wrap: fold the coordinate back on itself each period instead of jumping. A plain repeat
 * lays a visible tile-edge lattice across the seabed, since the web has no other straight lines in
 * it; mirroring costs one abs and the pattern has no handedness to preserve.
 *
 * Triangle wave in [0, 1], even about the origin. The binding wants edge clamping: the half texel
 * either side of a fold is the only place the wrap mode is visible at all.
 */
vec2 plagueCausticsFold(vec2 uv) {
    return 1.0 - abs(fract(uv * 0.5) * 2.0 - 1.0);
}

/**
 * One layer sample.  The pattern rides the red channel of the pack's own committed tileable
 * greyscale focusing texture (shaders/textures/water_caustics.png, bound as causticsTexture).
 */
float plagueCausticsTap(sampler2D tex, vec2 uv) {
    return texture(tex, plagueCausticsFold(uv)).r;
}

/**
 * Turn a world-plane drift bearing into the uv translation per second that a layer's sampler needs.
 *
 * A layer samples at `uv = freq * R * (worldXZ * effective scale)`, so a feature at fixed uv travels
 * at `-(1 / (freq*scale)) * inverse(R) * flow`. Inverting for world velocity `v`: `flow = -freq *
 * scale * R * v`. Only direction is wanted here — freq and scale are scalars and drop out, leaving
 * rotation and sign; the caller supplies magnitude separately.
 *
 * Magnitude is held fixed in uv rather than blocks, deliberately: a cell's lifetime stays independent
 * of the size setting, so the two exposed sliders stay orthogonal.
 *
 * Every argument is a compile-time constant, so this folds away entirely.
 */
vec2 plagueCausticsDriftDirection(mat2 layerRotation, float worldBearingDegrees) {
    float b = radians(worldBearingDegrees);
    return -(layerRotation * vec2(cos(b), sin(b)));
}

/**
 * The ridge field: two warped, counter-drifting, differently-scaled samples of the same tile,
 * blended into a broad body and then pulled toward their geometric mean.
 *
 * `plane` is the horizontal plane coordinate already multiplied by the effective scale; `t` is the wave
 * clock IN SECONDS, already scaled by the caller's rate slider.
 */
float plagueCausticsRidge(sampler2D tex, vec2 plane, float t) {
    // Low-frequency, time-varying displacement.  Each axis is two sinusoids and the second mixes
    // both input axes, so the warp has no preferred direction.
    vec2 warp = CAUSTICS_WARP_AMPLITUDE * vec2(
        sin(1.7 * plane.y + 0.2295 * t) + CAUSTICS_WARP_LOBE * sin(2.3 * (plane.x + plane.y) + 0.1423 * t),
        sin(1.9 * plane.x + 0.1882 * t) + CAUSTICS_WARP_LOBE * sin(2.9 * (plane.x - plane.y) + 0.2708 * t));

    vec2 flowA = CAUSTICS_DRIFT_A * plagueCausticsDriftDirection(CAUSTICS_ROT_A, CAUSTICS_DRIFT_BEARING_A);
    vec2 flowB = CAUSTICS_DRIFT_B * plagueCausticsDriftDirection(CAUSTICS_ROT_B, CAUSTICS_DRIFT_BEARING_B);

    vec2 uvA = CAUSTICS_ROT_A * plane + warp + flowA * t;

    // The swap of warp.yx here, not warp.xy, is what decorrelates the second layer's distortion from
    // the first's.  Shared displacement would translate the combined field rigidly.
    vec2 uvB = CAUSTICS_ROT_B * (plane * CAUSTICS_LAYER_B_FREQ)
             + CAUSTICS_WARP_REWEIGHT * warp.yx + flowB * t;

    float a = plagueCausticsTap(tex, uvA);
    float b = plagueCausticsTap(tex, uvB);

    float broad = CAUSTICS_LAYER_A_WEIGHT * a + CAUSTICS_LAYER_B_WEIGHT * b;

    // Geometric mean: the AND of the layers, where focusing wavefronts actually cross. Guarded
    // before the root since a negative under sqrt is a NaN that would propagate into the resolve.
    float crossings = sqrt(max(a * b, 0.0));

    return mix(broad, crossings, CAUSTICS_CROSSING_MIX);
}

/**
 * The pattern field, in [0, 1] closed at both ends. Shaping happens HERE, where the field is built,
 * and nowhere downstream: sharpening the web at the consumer's end and multiplying a gain back on
 * top throws away the mid-range the cells live in, which is how a web becomes thin dots with no body.
 */
float plagueCausticsPattern(sampler2D tex, vec2 plane, float t) {
    float ridge = plagueCausticsRidge(tex, plane, t);

    float shaped = CAUSTICS_CELL_WEIGHT     * smoothstep(CAUSTICS_CELL_LOW, CAUSTICS_CELL_HIGH, ridge)
                 + CAUSTICS_FILAMENT_WEIGHT * smoothstep(CAUSTICS_FILAMENT_LOW, CAUSTICS_FILAMENT_HIGH, ridge);

    float flicker = CAUSTICS_FOCUS_BASE
                  + CAUSTICS_FOCUS_AMPLITUDE * sin(CAUSTICS_FOCUS_FREQ_X * plane.x + CAUSTICS_FOCUS_RATE_X * t)
                                             * sin(CAUSTICS_FOCUS_FREQ_Z * plane.y + CAUSTICS_FOCUS_RATE_Z * t);

    return clamp(shaped * flicker, 0.0, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Public surface.  These four are the whole live interface.
// ---------------------------------------------------------------------------------------------

/**
 * The caustic web at a point on the water surface, in [0, 1].
 *
 * `surfaceHit` is a world position the caller has ALREADY shifted along the sun azimuth by this
 * fragment's own depth to the surface — the point where the sun ray crossed the surface plane, not
 * the fragment itself. Only its horizontal components are used.
 *
 * `waveTime` is the wave clock in seconds, already tick-rate-divided and rate-slider-scaled by the
 * caller.
 *
 * Orientation is NOT applied here: cos(incidence) is the call site's job, doing it here too would
 * darken every wall twice. No depth or visibility term either — the resolve gates all four caustic
 * contributions behind one sun-visibility product.
 *
 * Safe to call once and reuse: no side effects. The resolve feeds the one returned value into both
 * the direct term and plagueCausticsBloomSeed.
 */
float plagueCausticsProjected(sampler2D tex, vec3 surfaceHit, float waveTime, float sizeMul) {
    return plagueCausticsPattern(tex, surfaceHit.xz * (CAUSTICS_BASE_SCALE * sizeMul), waveTime);
}

/**
 * Isolate the hot focused crests of a pattern value, in [0, 1].
 *
 * Pure function of its argument: no texture fetch, no derivatives, no time — the halo below and the
 * resolve both call it on a value they already have, avoiding extra fetches.
 *
 * The band is the SAME band the filament core uses when the field is shaped, deliberately: a seed
 * that bloomed crests the field itself didn't brighten would put the glow beside the filament
 * instead of on it.
 */
float plagueCausticsBloomSeed(float caustic) {
    float crest = smoothstep(CAUSTICS_FILAMENT_LOW, CAUSTICS_FILAMENT_HIGH, caustic);
    return pow(crest, CAUSTICS_CREST_EXPONENT);
}

/**
 * The bloom halo on the same field, in [0, 1]. Fragment stage only: dFdx/dFdy.
 *
 * Builds its sample coordinate exactly the way plagueCausticsProjected does, same scale and time —
 * if the two ever diverged the halo would sit on a differently-shaped pattern and detach from the
 * light.
 *
 * The offsets come from screen-space derivatives of the plane coordinate: a derivative-sized offset
 * has a footprint constant in SCREEN space, so the halo stays compact at every distance instead of
 * smearing at range like a world-space offset would.
 *
 * Five taps: centre plus plus-and-minus each derivative. Each tap is a full field evaluation plus
 * seed, so the tap count is the entire cost of this function.
 */
float plagueCausticsBloomProjected(sampler2D tex, vec3 surfaceHit, float waveTime, float sizeMul) {
    vec2 plane = surfaceHit.xz * (CAUSTICS_BASE_SCALE * sizeMul);
    vec2 stepX = dFdx(plane) * CAUSTICS_HALO_RADIUS;
    vec2 stepY = dFdy(plane) * CAUSTICS_HALO_RADIUS;

    float halo = CAUSTICS_HALO_CENTRE * plagueCausticsBloomSeed(plagueCausticsPattern(tex, plane, waveTime));
    halo += CAUSTICS_HALO_RING * plagueCausticsBloomSeed(plagueCausticsPattern(tex, plane + stepX, waveTime));
    halo += CAUSTICS_HALO_RING * plagueCausticsBloomSeed(plagueCausticsPattern(tex, plane - stepX, waveTime));
    halo += CAUSTICS_HALO_RING * plagueCausticsBloomSeed(plagueCausticsPattern(tex, plane + stepY, waveTime));
    halo += CAUSTICS_HALO_RING * plagueCausticsBloomSeed(plagueCausticsPattern(tex, plane - stepY, waveTime));

    return clamp(halo, 0.0, 1.0);
}

/**
 * How much secondary caustic spill a surface of this orientation receives, in [0, 1].
 *
 * An up-facing floor already receives the direct caustic and needs almost no bounce; a vertical or
 * downward face receives mostly scattered light and needs it, or a wall reads as a flat cutout
 * beside a glowing seabed. The floor's share is small but strictly positive.
 *
 * Deliberately not a real bounce integral, and the only orientation term in this file: the resolve
 * gates direct/bloom/HDR by cos(incidence) but pointedly does NOT gate the bounce, since the spill's
 * whole point is reaching faces the sun misses.
 */
float plagueCausticsBounceReceiver(vec3 worldNormal) {
    float up = clamp(normalize(worldNormal).y, 0.0, 1.0);
    return mix(1.0, CAUSTICS_BOUNCE_FLOOR, up);
}

// --- The caustic options, on the Water settings page ---------------------------------------------
// Declared here, beside the field they shape. Only gbuffer_resolve.fsh reads them and imports this
// file above its own body, so terrain.fsh never reaching this file is what makes runtime
// declarations safe here (see light_options.glsl's header for the constraint in full).

// Neutral at 1.0: a straight multiplier on the caustic term, with room to fade toward subtle or
// push past physical for taste.
#define u_CausticStrength 1.0 //[0.7..2.0 step 0.1] runtime "Caustic Strength"

// Shimmer: how much the caustics glint and bloom rather than sitting as a steady web. Paired with
// its own depth since the effect is a surface phenomenon — deep water sees sharpness averaged out.
#define u_CausticGlow 1.0 //[0.0..3.0 step 0.1] runtime "Caustic Glow"
#define u_CausticBounce 1.0 //[0.0..2.0 step 0.1] runtime "Caustic Bounce"
#define u_CausticGlowDepth 2 //[0..12 step 1] runtime "Caustic Glow Depth"

// Size and rate of the caustic web itself. Both are PERCENTAGES of the values the pattern was
// tuned at, so they read as plain integers on a slider and 100 is the tuned look.
#define u_CausticScale 100 //[25..200 step 1] runtime "Caustic Scale"
#define u_CausticSpeed 100 //[0..200 step 1] runtime "Caustic Speed"

// Caustics are FORMED by the wave surface, so slowing waves should slow the web. On, rate is taken
// relative to Wave Speed rather than real time; off, the web keeps its own rate. Rate stays live
// either way.
#define u_CausticSyncWaves 1 //[0 1] runtime "Caustic Speed Follows Waves" {0="Off" 1="On"}

#endif // PLAGUE_OCEAN_CAUSTICS
