// Every water and underwater option, declared once: the option scanner requires byte-identical
// declarations across files, and several of these were previously duplicated in up to five files.
//
// Not imported by terrain.fsh: the one deferred geometry program has no u_PackOptions block and
// carries its options in a hand-written u_PbrSettings block instead — a runtime `#define` seen above
// that block would rewrite the member declaration underneath it offline (no DefineRewriter there).
//
// The seven caustic options live in ocean_caustics.glsl instead, since only one pass reads them.
#ifndef PLAGUE_WATER_OPTIONS
#define PLAGUE_WATER_OPTIONS

// --- The surface, seen from above --------------------------------------------------------------------
// Consumed by terrain.fsh but declared here and bridged in by name, for the u_PbrSettings-ordering
// reason above. Defaults reproduce the old compile-time 100%/60% stops exactly.
#define u_WaveStrength 1.0 //[0.0..2.0 step 0.1] runtime "Wave Strength"
#define u_WaveSpeed 1.0 //[0.0..4.0 step 0.05] runtime "Wave Speed"
// Scales the whole water medium (water_medium.glsl), above and below the surface alike: absorption,
// scattering and the depth fall-off of sky light move together, so the water stays one water.
#define u_WaterClarity 1.0 //[0.25..3.0 step 0.05] runtime "Water Clarity"
#define u_WaterReflectionStrength 1.0 //[0.0..1.5 step 0.05] runtime "Water Reflection Strength"
#define u_WaterSunGlitterStrength 1.0 //[0.0..2.0 step 0.05] runtime "Surface Sun Glitter"
// The lens-splash warp when the camera crosses the surface (tonemap.fsh's plagueWaterCameraUv).
// 0.75 picked live by the owner over the original hardcoded 0.3; 1.0 is a full-strength splash,
// 0.0 turns the crossing distortion off entirely without touching the underwater look itself.
#define u_WaterSplashStrength 0.75 //[0.0..1.0 step 0.05] runtime "Water Splash Strength"

// --- Shoreline foam ----------------------------------------------------------------------------------
#define u_WaterFoamAmount 1.0 //[0.0..2.0 step 0.05] runtime "Foam Amount"
// 0.25, not the shipped 0.09: the old value was a tiling-parity guess against a retired noise
// pattern and read too fine to show this texture's strand/cell structure.
#define u_FoamTextureScale 0.25 //[0.02..0.30 step 0.01] runtime "Foam Pattern Size"
// World blocks, converted to foam-UV units at the call site so the slider stays intuitive regardless
// of texture scale.
#define u_FoamPomDepth 0.15 //[0.0..0.5 step 0.02] runtime "Foam Parallax Depth"

// --- Light shafts through the water column -----------------------------------------------------------
#define u_WaterShaftDistance 3 //[1..6 step 1] runtime "Light Shaft Distance (Chunks)"
#define u_WaterShaftStrength 1.0 //[0.0..3.0 step 0.05] runtime "Light Shaft Strength"
#define u_WaterShaftFocus 2.0 //[0.0..2.0 step 0.05] runtime "Light Shaft Focus"
#define u_WaterShaftSpread 0.75 //[0.0..1.0 step 0.05] runtime "Light Shaft Spread"
#define u_WaterShaftPersistence 0.70 //[0.0..0.9 step 0.05] runtime "Light Shaft Persistence"
// Suspended particulate rising with depth (water_volume.glsl's plagueWaterTurbidityLoad). Raises
// SCATTERING only, never absorption, so deep beams densify instead of the water closing in. Drives
// the shaft march alone; underwater fog and darkness run their own depth model. 0.0 reproduces the
// flat-medium march exactly, the property verify_water_turbidity.py asserts. Default 0.20 is +45%
// shaft radiance at 20 blocks down, on a range useful to 1.00 (+161%).
#define u_WaterTurbidityDepth 0.20 //[0.0..1.0 step 0.05] runtime "Water Murkiness By Depth"
// Discrete drifting particles (water_motes.glsl). A different mechanism from the turbidity slider
// above, not a stronger version of it: turbidity is a continuous medium and can only give veil and
// glow, this draws separable specks anchored to world positions.
//
// 1.2 is picked against a dark seabed, where 2.0 reads as too busy. Each speck is lit by the
// radiance already at its pixel, so this number scales a field that is dim in shadow and bright
// in open water on its own.
#define u_WaterMoteAmount 2.0 //[0.0..2.0 step 0.05] runtime "Floating Water Specks"

// --- Under the surface: colour, darkness and reach -----------------------------------------------------
// No sliders. The colour, the loss with distance and depth, and how far a view ray carries are all
// the medium's own (water_medium.glsl); Water Clarity above scales the lot.
// --- Under the surface: defocus blur -----------------------------------------------------------------
#define u_UwBlurStart 1 //[0..12 step 1] runtime "Underwater Blur Start"
// Its own number rather than a share of the water's reach: a blur distance tied to visibility left
// one slider doing two jobs.
#define u_UwBlurEnd 3 //[1..12 step 1] runtime "Underwater Blur End"
// Byte-identical to tonemap.fsh's own declaration (option scanner merge rule).
#define u_UwBlurRadius 28.0 //[0.0..80.0 step 2.0] runtime "Underwater Blur Size"
// Kept separate from radius (how far scattering reaches) so strength alone controls contrast loss.
#define u_UwBlurStrength 0.65 //[0.0..1.0 step 0.05] runtime "Underwater Blur Strength"

// --- Under the surface: distortion and glitter -------------------------------------------------------
// Absolute authored units (pixels, reciprocal world scale), not multipliers. Fresh option keys: Fornax
// persists by key, so reusing a former key after a meaning change reinterprets old saved values.
#define u_UnderwaterFlowPixels 1.65 //[0.0..3.0 step 0.05] runtime "Underwater Distortion"
#define u_UnderwaterFlowScale 0.035 //[0.001..0.120 step 0.001] runtime "Underwater Distortion Scale"
#define u_UnderwaterViewWarpPixels 5.2 //[0.0..8.0 step 0.1] runtime "Underwater View Warp"
#define u_UnderwaterWarpBends 6.75 //[0.5..8.0 step 0.25] runtime "Underwater Warp Bends"
#define u_UnderwaterSunGlitterStrength 1.0 //[0.0..2.0 step 0.05] runtime "Underwater Sun Glitter"
// Blurs the Snell-window disc sample itself (signal prefilter), not the wave-normal wobble, which is
// real refraction and stays untunable — an earlier cut exposed it as a preference and was reverted.
#define u_UnderwaterDiscSoftness 0.50 //[0.0..1.0 step 0.05] runtime "Underwater Sparkle Softness"

#endif // PLAGUE_WATER_OPTIONS
