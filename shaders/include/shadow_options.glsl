// Every shadow option, declared once, so gbuffer_resolve.fsh and water_volume_march.fsh (both need
// SHADOWS) stay byte-identical without hand-syncing two declarations.
//
// Imported by fullscreen passes only: terrain.fsh has no u_PackOptions block, so a runtime #define
// reaching it would rewrite a member of its hand-written u_PbrSettings block instead.
#ifndef PLAGUE_SHADOW_OPTIONS
#define PLAGUE_SHADOW_OPTIONS

// With this off, the engine never renders the shadow map and it stays a 64x64 placeholder.
#define SHADOWS //[] compile "Shadows"
// Default off: a new per-fragment cost on the full-res shading pass, on top of needing
// CLOUDS_VOLUMETRIC (also default off). Its own toggle so enabling volumetric clouds doesn't
// silently also enable this separately-costed feature.
#define CLOUD_SHADOWS 1 //[0 1] compile "Cloud Shadows" {0="Off" 1="On"}

#define SHADOW_RESOLUTION 2048 //[1024 2048 4096] compile "Shadow Resolution" {1024="1024" 2048="2048" 4096="4096"}

// Vanilla's blob shadow reads as a smudge under a real cast shadow, so the engine suppresses it
// when this is on. Absent counts as off (keeps vanilla's behaviour).
#define HIDE_VANILLA_BLOB_SHADOWS //[] compile "Hide Vanilla Blob Shadows"

// Taps per side (real count is double, +/- pairs). Powers of two so each tier doubles the cost.
#define SHADOW_SAMPLES 8 //[2 4 8 16] compile "Shadow Samples" {2="Low" 4="Medium" 8="High" 16="Ultra"}

#define u_ShadowSoftness 1.5 //[0.0..6.0 step 0.5] runtime "Shadow Softness"
// Past 1.0 also darkens ambient fill inside shadow, keyed on a broadened occlusion query
// (PLAGUE_SHADOW_AMBIENT_BROADEN) rather than the noisy sharp signal, capped by
// PLAGUE_AMBIENT_SHADOW_MAX so shadowed ground never reaches black.
#define u_ShadowStrength 1.50 //[0.00..2.00 step 0.05] runtime "Shadow Strength"
// The engine reads this exact name to size the shadow frustum, so it must stay in blocks.
#define u_ShadowDistance 128.0 //[16.0..512.0 step 16.0] runtime "Shadow Distance"

#endif // PLAGUE_SHADOW_OPTIONS
