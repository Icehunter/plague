// Plague DOF shared math: circle of confusion from the thin-lens camera model (Potmesil and
// Chakravarty 1981, "A lens and aperture camera model for synthetic image generation"), sampled
// with a golden-angle spiral disc (Vogel 1979 model of the sunflower head).
#ifndef PLAGUE_DOF
#define PLAGUE_DOF

// Real lens controls, no extra gain: the blur is whatever the thin lens says. One block is one
// metre. A single strength slider in place of these hides a factor of the focus distance, so
// far focus over-blurs the whole world; the lens form keeps far focus sharp.

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

// Tap count for the gather spiral: at the 20 px default cap each tap covers about 20 square
// half-res pixels, the density where the verify_dof.py disc render still reads as solid.
const int PLAGUE_DOF_TAPS = 64;

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
