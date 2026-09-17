#ifndef PLAGUE_CLOUD_DECK_OPTIONS
#define PLAGUE_CLOUD_DECK_OPTIONS

// Per-deck reach and opacity. Runtime options declared in an include: they reach the compute march
// through u_PackOptions, the same way the tier options next to them do, and reach the fade pass by
// the same route. Never import this from a geometry pass, which has no u_PackOptions block.
//
// Fade: chunks past the terrain render distance over which this deck fades to nothing.
// Opacity: this deck's optical depth as a percentage of its genus row's own value; 100 is authored.
#define u_CloudFadeCumulus 256.0 //[1.0..512.0 step 1.0] runtime "Cumulus Fade Distance"
#define u_CloudFadeStratus 64.0 //[1.0..512.0 step 1.0] runtime "Stratus Fade Distance"
#define u_CloudFadeStratocumulus 256.0 //[1.0..512.0 step 1.0] runtime "Stratocumulus Fade Distance"
#define u_CloudFadeNimbostratus 128.0 //[1.0..512.0 step 1.0] runtime "Nimbostratus Fade Distance"
#define u_CloudFadeAltocumulus 256.0 //[1.0..512.0 step 1.0] runtime "Altocumulus Fade Distance"
#define u_CloudFadeCirrocumulus 256.0 //[1.0..512.0 step 1.0] runtime "Cirrocumulus Fade Distance"
#define u_CloudFadeCirrus 256.0 //[1.0..512.0 step 1.0] runtime "Cirrus Fade Distance"

#define u_CloudOpacityCumulus 100.0 //[0.0..200.0 step 5.0] runtime "Cumulus Thickness"
#define u_CloudOpacityStratus 45.0 //[0.0..200.0 step 5.0] runtime "Stratus Thickness"
#define u_CloudOpacityStratocumulus 100.0 //[0.0..200.0 step 5.0] runtime "Stratocumulus Thickness"
#define u_CloudOpacityNimbostratus 100.0 //[0.0..200.0 step 5.0] runtime "Nimbostratus Thickness"
#define u_CloudOpacityAltocumulus 100.0 //[0.0..200.0 step 5.0] runtime "Altocumulus Thickness"
#define u_CloudOpacityCirrocumulus 100.0 //[0.0..200.0 step 5.0] runtime "Cirrocumulus Thickness"
#define u_CloudOpacityCirrus 100.0 //[0.0..200.0 step 5.0] runtime "Cirrus Thickness"

#endif // PLAGUE_CLOUD_DECK_OPTIONS
