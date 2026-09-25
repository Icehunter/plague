// Plague DOF shared math: circle of confusion from the thin-lens camera model (Potmesil and
// Chakravarty 1981, "A lens and aperture camera model for synthetic image generation"), sampled
// with a golden-angle spiral disc (Vogel 1979 model of the sunflower head).
#ifndef PLAGUE_DOF
#define PLAGUE_DOF

// Real lens controls, no extra gain: the blur is whatever the thin lens says. One block is one
// metre. The circle of confusion follows 1/focus - 1/dist, so a far focus keeps the whole
// world near sharp and a close focus melts the background, as a real lens does.

// How zoomed-in the pretend lens is; longer lenses melt the background more.
#define u_DofFocalLength 50.0 //[15.0..135.0 step 5.0] runtime "Focal Length"
// How wide the lens opens; lower numbers let in more light and blur more. Default f/2.0 picked
// against live captures: f/2.8 at 50 mm reads too subtle at 1080p half resolution.
#define u_DofFStop 2.0 //[0.95..16.0 step 0.05] runtime "F-Stop"
// Hard cap on disc radius in half-resolution pixels: a safety rail for the near field, which
// grows without bound as objects approach the lens. 20 from the tools/verify_dof.py renders,
// where larger discs at 64 taps start to grain.
#define u_DofMaxBlur 20.0 //[4.0..32.0 step 1.0] runtime "Blur Size Limit"
// Per-frame blend toward the newly measured focus distance; frame-rate dependent by choice,
// matching the exposure adaptation in this pack.
#define u_DofFocusSpeed 0.10 //[0.02..0.50 step 0.02] runtime "Focus Speed"

// Distance mode: no focus tracking, the world past a set distance goes soft. The lens and
// focus sliders above do nothing while it is on; Distance Blur Size below sets the far
// softness, still under Blur Size Limit.
#define u_DofDistanceMode 0 //[0 1] runtime "Blur By Distance" {0="Off" 1="On"}
// Where the softness begins, in chunks. Default 6: close to 100 blocks, so a build the
// player stands in stays sharp while the horizon softens.
#define u_DofDistanceStart 6.0 //[1.0..16.0 step 1.0] runtime "Distance Blur Start"
// Chunks from the start to full size. Default 4 spreads the onset over 64 blocks so no
// sharp ring shows where the blur begins.
#define u_DofDistanceFade 4.0 //[1.0..16.0 step 1.0] runtime "Distance Blur Fade"
// Far softness in half-res pixels: a haze, not a photo-mode disc. 5 keeps far builds
// readable and sits near what the f/2 lens gives the far field; Blur Size Limit still caps
// it. Ramping to the cap reads as a wall of fog on a hillside.
#define u_DofDistanceBlur 5.0 //[1.0..12.0 step 1.0] runtime "Distance Blur Size"

// How strongly small bright spots keep their shine inside the blur. 0.4 picked off the
// offline disc render: glints still read as discs while flat fields stay an exact average.
#define u_DofHighlightBoost 0.4 //[0.0..1.0 step 0.05] runtime "Highlight Boost"

// Photo doubles the gather taps so each pyramid footprint can shrink by the square root of
// two at the same disc solidity; small glints then survive one level finer and the blur
// carries the texture of the lens references it was tuned against.
#define DOF_QUALITY 0 //[0 1] compile "Focus Blur Quality" {0="Fast" 1="Photo"}

#if DOF_QUALITY == 0
// Fast: 64 taps; switch points 4/9/18 picked off the tools/verify_dof.py lantern render,
// the last radii at which the 2, 4 and 8 px footprints keep a 2x2 source solid.
const int PLAGUE_DOF_TAPS = 64;
const float PLAGUE_DOF_LEVEL_T0 = 4.0;
const float PLAGUE_DOF_LEVEL_T1 = 9.0;
const float PLAGUE_DOF_LEVEL_T2 = 18.0;
#else
// Photo: twice the taps; the same solidity rule moves each switch point up by the square
// root of two.
const int PLAGUE_DOF_TAPS = 128;
const float PLAGUE_DOF_LEVEL_T0 = 6.0;
const float PLAGUE_DOF_LEVEL_T1 = 13.0;
const float PLAGUE_DOF_LEVEL_T2 = 25.0;
#endif

// pi times (3 minus sqrt 5), the golden angle; Vogel 1979.
const float PLAGUE_DOF_GOLDEN_ANGLE = 2.39996322972865332;

// Width of a full-frame stills sensor in millimetres, the reference that converts millimetres
// of confusion into pixels: the pretend camera exposes a 36 mm frame onto the output width.
const float PLAGUE_DOF_SENSOR_MM = 36.0;

// Signed circle-of-confusion RADIUS in half-res pixels; negative is nearer than focus.
// Thin lens: c = f^2 (d - s) / (N d (s - f)) millimetres of confusion diameter on the sensor,
// f focal length, N the f-number, s focus distance, d subject distance, all in millimetres
// (Potmesil and Chakravarty 1981). pxPerMm is the caller's half-res pixels per sensor
// millimetre, so the same lens blurs the same angle at any output resolution.
float plagueDofCoc(float dist, float focus, float pxPerMm) {
    // Distance mode: a far-field-only ramp in pixels. Never negative, so nothing
    // classifies as near field and the focus distance drops out entirely.
    if (u_DofDistanceMode > 0.5) {
        float startBlocks = u_DofDistanceStart * 16.0;
        float fadeBlocks = max(u_DofDistanceFade, 0.25) * 16.0;
        float t = clamp((dist - startBlocks) / fadeBlocks, 0.0, 1.0);
        // Eased at both ends so neither the onset nor the saturation draws a line.
        t = t * t * (3.0 - 2.0 * t);
        return min(u_DofDistanceBlur, u_DofMaxBlur) * t;
    }
    float d = max(dist, 0.1) * 1000.0;
    float s = max(focus, 0.1) * 1000.0;
    float f = u_DofFocalLength;
    float cocMm = f * f * (d - s) / (max(u_DofFStop, 0.1) * d * max(s - f, 1.0));
    return clamp(0.5 * cocMm * pxPerMm, -u_DofMaxBlur, u_DofMaxBlur);
}

// i-th unit-disc point of a PLAGUE_DOF_TAPS-point Vogel spiral, rotated by phi radians.
vec2 plagueDofVogel(int i, float phi) {
    float r = sqrt((float(i) + 0.5) / float(PLAGUE_DOF_TAPS));
    float a = float(i) * PLAGUE_DOF_GOLDEN_ANGLE + phi;
    return r * vec2(cos(a), sin(a));
}

#endif
