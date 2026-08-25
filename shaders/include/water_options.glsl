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
#define u_WaterClarity 1.0 //[0.25..3.0 step 0.05] runtime "Water Clarity"
#define u_WaterTintSaturation 0.45 //[0.0..1.0 step 0.05] runtime "Surface Water Saturation"
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
#define u_FoamTextureScale 0.25 //[0.02..0.30 step 0.01] runtime "Foam Texture Scale"
// World blocks, converted to foam-UV units at the call site so the slider stays intuitive regardless
// of texture scale.
#define u_FoamPomDepth 0.15 //[0.0..0.5 step 0.02] runtime "Foam Relief Depth"

// --- Light shafts through the water column -----------------------------------------------------------
#define u_WaterShaftDistance 3 //[1..6 step 1] runtime "Light Shaft Distance (Chunks)"
#define u_WaterShaftStrength 1.0 //[0.0..3.0 step 0.05] runtime "Light Shaft Strength"
#define u_WaterShaftFocus 1.0 //[0.0..2.0 step 0.05] runtime "Light Shaft Focus"
#define u_WaterShaftSpread 0.75 //[0.0..1.0 step 0.05] runtime "Light Shaft Spread"
#define u_WaterShaftPersistence 0.70 //[0.0..0.9 step 0.05] runtime "Light Shaft Persistence"

// --- Under the surface: colour and darkness ----------------------------------------------------------
// Declared here since underwater.glsl (its consumer) is transitively reachable from terrain.fsh and
// so cannot declare runtime options itself. u_DepthDarkness: the darkening floor at depth, 1.0
// disables it. Raised from 0.10 to 0.60 — 0.10 shipped-on crushed shallow water at noon; 0.60 still
// lets the near-black deep-water look through at night and in storms.
#define u_DepthDarkness 0.60 //[0.0..1.0 step 0.05] runtime "Deep Water Darkness"
#define u_WaterTintR 0.50 //[0.0..1.0 step 0.01] runtime "Water Tint Red"
#define u_WaterTintG 0.80 //[0.0..1.0 step 0.01] runtime "Water Tint Green"
#define u_WaterTintB 1.00 //[0.0..1.0 step 0.01] runtime "Water Tint Blue"
#define u_WaterDistanceDarkness 0.55 //[0.0..1.0 step 0.05] runtime "Water Darkness (Distance)"
#define u_WaterDepthDarkness 0.10 //[0.0..1.0 step 0.05] runtime "Water Darkness (Depth)"
#define u_WaterDarknessDepth 1 //[0..12 step 1] runtime "Water Darkness Depth"

// --- Under the surface: how far you can see ----------------------------------------------------------
// Byte-identical to underwater_refraction.fsh's own declaration (option scanner merge rule).
#define u_UnderwaterFogStart 1 //[0..12 step 1] runtime "Water Fog Start"
// Chunks, not blocks, matching vanilla's own render-distance slider unit. Bare integer value list
// (not a `min..max` range) so the settings UI displays the literal token rather than a raw double —
// checked against Fornax's OptionAnnotation.java. Converted to blocks in exactly one place,
// underwater.glsl's plagueChunksToBlocks.
#define u_WaterDistanceFog 4 //[0..12 step 1] runtime "Water Fog End (Distance)"
#define u_WaterDepthFog 2 //[0..12 step 1] runtime "Water Fog End (Depth)"

// --- Under the surface: defocus blur -----------------------------------------------------------------
#define u_UwBlurStart 1 //[0..12 step 1] runtime "Underwater Blur Start"
// Deliberately decoupled from u_WaterDistanceFog above: sharing one number meant Water Fog End and
// blur distance fought over a single slider.
#define u_UwBlurEnd 3 //[1..12 step 1] runtime "Underwater Blur End"
// Byte-identical to tonemap.fsh's own declaration (option scanner merge rule).
#define u_UwBlurRadius 28.0 //[0.0..80.0 step 2.0] runtime "Underwater Blur Radius"
// Kept separate from radius (how far scattering reaches) so strength alone controls contrast loss.
#define u_UwBlurStrength 0.65 //[0.0..1.0 step 0.05] runtime "Underwater Blur Strength"

// --- Under the surface: distortion and glitter -------------------------------------------------------
// Absolute authored units (pixels, reciprocal world scale), not multipliers. Fresh option keys: Fornax
// persists by key, so reusing a former key after a meaning change reinterprets old saved values.
#define u_UnderwaterFlowPixels 1.65 //[0.0..3.0 step 0.05] runtime "Underwater Distortion"
#define u_UnderwaterFlowScale 0.035 //[0.001..0.120 step 0.001] runtime "Distortion Scale"
#define u_UnderwaterViewWarpPixels 5.2 //[0.0..8.0 step 0.1] runtime "Underwater View Warp"
#define u_UnderwaterWarpBends 6.75 //[0.5..8.0 step 0.25] runtime "Underwater Warp Bends"
#define u_UnderwaterSunGlitterStrength 1.0 //[0.0..2.0 step 0.05] runtime "Underwater Sun Glitter"
// Blurs the Snell-window disc sample itself (signal prefilter), not the wave-normal wobble, which is
// real refraction and stays untunable — an earlier cut exposed it as a preference and was reverted.
#define u_UnderwaterDiscSoftness 0.50 //[0.0..1.0 step 0.05] runtime "Underwater Disc Softness"

#endif // PLAGUE_WATER_OPTIONS
