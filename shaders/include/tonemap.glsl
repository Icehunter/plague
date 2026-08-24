// The display transform: linear scene-referred HDR -> display-referred sRGB.
//
// Shared by tonemap.fsh and by forward draws (vanilla geometry composited after
// GraphRunner.finishDeferred()), which must carry fog through the same curve the frame took or land
// in a different colour space from what it's blending into. Order is fixed: exposure, then the
// operator, then the display transform, then the grade — exposure decides which part of the scene's
// range the operator's shoulder falls across, so applying it later just brightens already-compressed
// highlights.
#ifndef PLAGUE_TONEMAP_INCLUDE
#define PLAGUE_TONEMAP_INCLUDE

// The display transform's encode half lives in color.glsl (paired with its inverse, used by
// gbuffer_resolve.fsh to decode gAlbedo) so the two halves cannot drift apart.
#moj_import <fornax_runtime:color.glsl>

// --- Options ---------------------------------------------------------------------------------------
// Declared HERE rather than in tonemap.fsh: the include that USES an option also DECLARES it, so a
// second caller inherits it by importing. Runtime options resolve through u_PackOptions BY NAME, so
// declaration site only decides std140 offset, never visibility.
//
// Operator 1 is the default: the pack's own filmic curve (Lottes 2016 parametric family plus three
// readability aids), constants fitted by tools/fit_tonemap_parity.py against the committed fixture.
#define TONEMAP_OPERATOR 1 //[0 1 2 3] compile "Tonemap" {0="None (clip)" 1="Filmic" 2="ACES" 3="Reinhard"}

// GLOBAL brightness compensation. Whenever a pipeline change makes the whole frame genuinely
// brighter or darker, the correction lands HERE rather than being smeared back through every colour
// constant in light_and_ambient_colors.glsl.
//
// Current derivation (tools/verify_albedo_linear_space.py, re-run on every invocation): the albedo
// linear-space fix made shaded/AO'd surfaces genuinely brighter, so this absorbs the difference so
// the fix costs no net brightness. Solved against a captured vanilla frame using real material
// textures (dirt/podzol/cobblestone); the honest band is 0.87-1.51 depending on assumed texture
// range, landing at 1.11 as the centre. The question this constant answers is always "what did the
// change brighten the pipeline by", never "how bright is vanilla" — Plague is deliberately brighter
// than flat vanilla lighting by design, and vanilla's mean luminance has never been a calibration
// target here.
//
// A stored value overrides this: anyone with u_Exposure already in their Plague.txt keeps their old
// number. Returns to 1.0 when metering lands (PORTING-PLAN step 3), the number auto-exposure is
// meant to replace.
//
// Past mistake, do not repeat: retargeting this to vanilla's mean luminance shipped once and made
// orange terracotta read as olive/khaki in game. tools/verify_color_decode.py's hue/saturation
// check exists specifically to catch that regression again.
#define u_Exposure 0.90 //[0.10..3.00 step 0.05] runtime "Exposure"
#define u_TmContrast 1.05 //[0.50..2.00 step 0.05] runtime "Tonemap Contrast"
#define u_TmWhitePath 1.00 //[0.10..1.90 step 0.05] runtime "Highlight Fade"
#define u_TmDarkDesaturation 0.25 //[0.00..1.00 step 0.05] runtime "Dark Desaturation"
#define u_Saturation 1.25 //[0.00..2.00 step 0.05] runtime "Saturation"
#define u_Contrast 1.05 //[0.50..2.00 step 0.05] runtime "Contrast"

// Rec. 709 luminance weights, the same primaries the rest of the pipeline assumes.
float luminance(vec3 colour) {
    return dot(colour, vec3(0.2126, 0.7152, 0.0722));
}

#if TONEMAP_OPERATOR == 1
// Filmic operator: Lottes parametric curve (Timothy Lottes, "Advanced Techniques and Optimization
// of HDR Color Pipelines", GDC 2016), y = x^(a*d) / (x^a * b + c), roll-off exponent d pinned at 1
// for a closed-form inverse. plagueLottesCoefficients() derives b, c from the contrast slider so
// the curve pins mid-grey and the declared max input to 1.0; tonemapFilmic() then layers a shadow
// lift, a highlight-to-white path and a low-light desaturation.
//
// Verified by tools/fit_tonemap_parity.py against tools/fixtures/tonemap-behavior-e5a2c24.json:
// RMS/max error under 4e-7 display codes across 3744 rows at the shipped defaults.

// --- base curve ----------------------------------------------------------------------------------
const float PLAGUE_TM_MID_GREY_IN  = 0.25;  // linear input pinned to PLAGUE_TM_MID_GREY_OUT
const float PLAGUE_TM_MID_GREY_OUT = 0.25;  // curve's own (pre-encode) output at MID_GREY_IN
const float PLAGUE_TM_HDR_MAX      = 8.0;   // linear input pinned to 1.0

// --- dark lift -----------------------------------------------------------------------------------
// Blends toward a gamma encode at low luminance: a film curve's toe crushes shadow detail, correct
// for a photograph but wrong for a game where the player needs to see in a cave.
const float PLAGUE_TM_DARK_LIFT_GAMMA    = 2.2;   // pow(colour, 1/gamma) lift target
const float PLAGUE_TM_DARK_LIFT_EDGE     = 0.1;   // scene-luminance ceiling of the lift ramp
const float PLAGUE_TM_DARK_LIFT_WINDOW   = 0.55;  // contrast-slider half-width of the fade
const float PLAGUE_TM_DARK_LIFT_STRENGTH = 0.75;  // peak blend weight

// --- path to white -------------------------------------------------------------------------------
// Intense colours converge on white instead of a saturated primary (a per-channel curve alone
// leaves tinting). u_TmWhitePath drives the shape exponent of pow(luminance/SCALE, shape); at the
// slider's default the exponent is 1.0 and the aid is a plain linear-luminance smoothstep.
const float PLAGUE_TM_WHITE_PATH_SCALE   = 16.0;  // "maximum input" reference for the ramp
const float PLAGUE_TM_WHITE_PATH_SHAPE_A = 2.0;
const float PLAGUE_TM_WHITE_PATH_SHAPE_B = -1.0;

// --- dark desaturation ---------------------------------------------------------------------------
// Chroma drains toward luminance below this edge (scotopic vision is near-achromatic); without it a
// dim scene keeps full saturation and reads as artificially tinted rather than dark.
const float PLAGUE_TM_DARK_DESAT_EDGE = 0.1;

// Derives b/c so PLAGUE_TM_MID_GREY_IN -> MID_GREY_OUT and PLAGUE_TM_HDR_MAX -> 1.0. Shared by the
// forward curve and plagueUntonemapApprox's inverse.
//
// y = x^a / (x^a * b + c). Solving y(midIn) = midOut, y(hdrMax) = 1 for b, c:
//   P = midIn^a, Q = hdrMax^a
//   b = (P - Q * midOut) / (midOut * (P - Q))
//   c = Q * (1 - b)
void plagueLottesCoefficients(out vec3 a, out vec3 b, out vec3 c) {
    a = vec3(u_TmContrast);

    float p = pow(PLAGUE_TM_MID_GREY_IN, u_TmContrast);
    float q = pow(PLAGUE_TM_HDR_MAX, u_TmContrast);
    float bb = (p - q * PLAGUE_TM_MID_GREY_OUT) / (PLAGUE_TM_MID_GREY_OUT * (p - q));
    float cc = q * (1.0 - bb);

    b = vec3(bb);
    c = vec3(cc);
}

vec3 tonemapFilmic(vec3 colour) {
    float initialLuminance = luminance(colour);

    vec3 a, b, c;
    plagueLottesCoefficients(a, b, c);
    vec3 z = pow(colour, a);
    vec3 curved = z / (z * b + c);
    vec3 mapped = plagueLinearToSrgb(curved);

    // Dark lift. 1.05 is u_TmContrast's declared default; the lift fades out as the slider departs
    // it in either direction.
    vec3 lifted = pow(colour, vec3(1.0 / PLAGUE_TM_DARK_LIFT_GAMMA));
    float liftLumFactor = 1.0 - smoothstep(0.0, PLAGUE_TM_DARK_LIFT_EDGE, initialLuminance);
    float liftContrastFactor =
        clamp(1.0 - abs(u_TmContrast - 1.05) / PLAGUE_TM_DARK_LIFT_WINDOW, 0.0, 1.0);
    float liftWeight =
        clamp(PLAGUE_TM_DARK_LIFT_STRENGTH * liftLumFactor * liftContrastFactor, 0.0, 1.0);
    mapped = mix(mapped, lifted, liftWeight);

    // Path to white. The slider's declared ceiling (1.90) keeps the shape exponent strictly
    // positive, so pow(0.0, shape) is defined and a pure-black pixel takes no pull toward white.
    float whitePathShape = PLAGUE_TM_WHITE_PATH_SHAPE_A + PLAGUE_TM_WHITE_PATH_SHAPE_B * u_TmWhitePath;
    float whitePathShaped = pow(max(initialLuminance, 0.0) / PLAGUE_TM_WHITE_PATH_SCALE, whitePathShape);
    float whitePathT = smoothstep(0.0, 1.0, whitePathShaped);
    mapped = mix(mapped, vec3(1.0), whitePathT);

    // Dark desaturation.
    float desatRamp = 1.0 - smoothstep(0.0, PLAGUE_TM_DARK_DESAT_EDGE, initialLuminance);
    float desatWeight = clamp(u_TmDarkDesaturation * desatRamp, 0.0, 1.0);
    mapped = mix(mapped, vec3(luminance(mapped)), desatWeight);

    return clamp(mapped, 0.0, 1.0);
}
#endif

#if TONEMAP_OPERATOR == 2
// ACES, Narkowicz's fit. Cheaper than the full Academy transform and close enough for a game; the
// real one wants colour-space conversions this pipeline does not carry yet.
vec3 tonemapAces(vec3 colour) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    vec3 mapped = clamp((colour * (a * colour + b)) / (colour * (c * colour + d) + e), 0.0, 1.0);
    return plagueLinearToSrgb(mapped);
}
#endif

#if TONEMAP_OPERATOR == 3
// Reinhard, extended so that a chosen white maps exactly to 1.0 rather than approaching it forever.
vec3 tonemapReinhard(vec3 colour) {
    const float white = 4.0;
    vec3 mapped = colour * (1.0 + colour / (white * white)) / (1.0 + colour);
    return plagueLinearToSrgb(clamp(mapped, 0.0, 1.0));
}
#endif

// Post-tonemap grading, applied to display-referred values rather than scene light: saturating
// before the curve pushes colours into the region the curve compresses hardest, cancelling the
// effect. Both default near neutral — a tonemap should not invent a look on its own.
vec3 grade(vec3 colour) {
    // Saturation around luminance, so a fully desaturated image is the correct greyscale, not a
    // channel average.
    float luma = luminance(colour);
    colour = mix(vec3(luma), colour, u_Saturation);

    // Contrast pivots on middle grey. Pivoting on zero would just darken everything, which is what
    // makes a naive contrast control read as an exposure control.
    const float midGrey = 0.5;
    colour = (colour - midGrey) * u_Contrast + midGrey;

    return clamp(colour, 0.0, 1.0);
}

/**
 * The whole display transform, exposure through grade, as ONE call, so a second caller cannot write
 * a second, divergent copy of the chain's order.
 *
 * Bloom is deliberately excluded: tonemap.fsh mixes it into hdr before calling here, since a forward
 * caller has no bloom texture bound and nothing to mix.
 */
vec3 plagueTonemapAndGrade(vec3 hdr) {
    hdr *= u_Exposure;

#if TONEMAP_OPERATOR == 1
    vec3 ldr = tonemapFilmic(hdr);
#elif TONEMAP_OPERATOR == 2
    vec3 ldr = tonemapAces(hdr);
#elif TONEMAP_OPERATOR == 3
    vec3 ldr = tonemapReinhard(hdr);
#else
    // No operator: clip, and apply the display transform so the image is still in the right space.
    // Kept as a real option because it is the honest reference for judging what the others do.
    vec3 ldr = plagueLinearToSrgb(clamp(hdr, 0.0, 1.0));
#endif

    return grade(ldr);
}

/**
 * Undoes the grade, EXACTLY: the contrast pivot is affine and inverts directly, and since
 * `luminance` is affine with weights summing to 1, the saturation step preserves luminance, so the
 * pivot can be read straight back off the result.
 *
 * Undefined at u_Saturation == 0, where chroma is genuinely destroyed; guarded rather than
 * pretending otherwise.
 */
vec3 plagueUngrade(vec3 display) {
    vec3 c = (clamp(display, 0.0, 1.0) - 0.5) / max(u_Contrast, 1e-3) + 0.5;
    float luma = luminance(c);
    return vec3(luma) + (c - vec3(luma)) / max(u_Saturation, 1e-3);
}

/**
 * An APPROXIMATE inverse of plagueTonemapAndGrade: display-referred sRGB back to linear scene light.
 *
 * A forward draw needs to blend a scene-referred quantity (fog) into an already-tonemapped frame;
 * blending in display space instead is wrong by up to 138/255 codes mid-curve (verified in
 * tools/verify_fog.py), since the operator compresses a bright sky by an enormous factor.
 *
 * The grade and the operator's main curve invert exactly. The three luminance-coupled readability
 * aids (dark lift, path to white, dark desaturation) have no closed-form inverse and are left
 * un-inverted: worst measured round-trip error 3.34/255 codes, median 0.20. That residual is
 * cancelled, not tolerated — see plagueCompositeLinearOverDisplay, the only caller.
 */
vec3 plagueUntonemapApprox(vec3 display) {
    vec3 ungraded = clamp(plagueUngrade(display), 0.0, 1.0);
    // The display encode is the last thing the operator does, so it is the first thing to undo. Exact
    // inverse, from the shared pair in color.glsl.
    vec3 y = clamp(plagueSrgbToLinear(ungraded), 0.0, 1.0);

#if TONEMAP_OPERATOR == 1
    // y = x^a / (x^a * b + c)  =>  x^a = y*c / (1 - y*b)  =>  x = (y*c / max(1 - y*b, eps))^(1/a)
    vec3 a, b, c;
    plagueLottesCoefficients(a, b, c);
    vec3 denom = max(vec3(1.0) - y * b, vec3(1e-6));
    vec3 x = pow(max(y * c, 0.0) / denom, 1.0 / a);
#elif TONEMAP_OPERATOR == 2
    // Narkowicz's ACES fit is a ratio of quadratics, so its inverse is the positive root of
    //   (A - y*C) x^2 + (B - y*D) x - y*E = 0
    const float A = 2.51, B = 0.03, C = 2.43, D = 0.59, E = 0.14;
    vec3 qa = vec3(A) - y * C;
    vec3 qb = vec3(B) - y * D;
    vec3 qc = -y * E;
    vec3 disc = sqrt(max(qb * qb - 4.0 * qa * qc, vec3(0.0)));
    // The linear fallback is for the degenerate qa ~ 0, which is a single y and never a range.
    vec3 x = mix((-qc) / max(abs(qb), vec3(1e-9)),
                 (-qb + disc) / (2.0 * qa),
                 step(vec3(1e-6), abs(qa)));
#elif TONEMAP_OPERATOR == 3
    // y = x(1 + x/W^2) / (1 + x) with W = 4  =>  x^2 + 16(1-y)x - 16y = 0
    vec3 x = 8.0 * (y - vec3(1.0)) + 4.0 * sqrt(max(4.0 * (vec3(1.0) - y) * (vec3(1.0) - y) + y,
                                                    vec3(0.0)));
#else
    // No operator: the clip arm's only nonlinearity is the display encode, already undone above.
    vec3 x = y;
#endif

    return max(x, vec3(0.0)) / max(u_Exposure, 1e-3);
}

/**
 * Blends a LINEAR scene-referred colour over a DISPLAY-referred one, in LINEAR space, and lands
 * exactly on both endpoints.
 *
 * A forward draw's surface colour is already display-referred (vanilla composited it, this pack
 * does not relight it), while the fog it dissolves into is scene light. Mixing in display space is
 * wrong by up to 138/255 codes mid-curve; decoding the surface and tonemapping the result is wrong
 * at both ends since the inverse is approximate. This instead blends the recovered linear estimate
 * and adds back the residual the inverse left, faded out with the blend, landing exactly on both
 * endpoints. Measured against a true linear-space blend: worst 2.81/255 codes, median 0.05
 * (tools/verify_fog.py re-measures on every run).
 *
 * @param surfaceDisplay the fragment's own colour, display-referred sRGB, with no fog at all
 * @param overLinear     the colour to blend toward, linear scene-referred HDR
 * @param f              blend factor, 0 = untouched surface, 1 = pure overLinear, per channel
 */
vec3 plagueCompositeLinearOverDisplay(vec3 surfaceDisplay, vec3 overLinear, vec3 f) {
    vec3 surfaceLinear = plagueUntonemapApprox(surfaceDisplay);
    // What the inverse could not recover. Zero if it were exact; a couple of display codes in practice.
    vec3 residual = surfaceDisplay - plagueTonemapAndGrade(surfaceLinear);
    vec3 blended = plagueTonemapAndGrade(mix(surfaceLinear, overLinear, f));
    return clamp(blended + (vec3(1.0) - f) * residual, 0.0, 1.0);
}


#endif // PLAGUE_TONEMAP_INCLUDE
