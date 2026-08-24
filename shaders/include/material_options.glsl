// Materials, Parallax and Snow settings pages in source form.
//
// terrain.fsh must NEVER import this file: it's the pack's only deferred geometry program (no
// u_PackOptions block), so it reads these names instead through a hand-written u_PbrSettings
// block kept in positional lockstep with Fornax's PbrSettingsLayout.MEMBERS. Only fullscreen
// passes import this file; terrain reads it through the bridge.
#ifndef PLAGUE_MATERIAL_OPTIONS
#define PLAGUE_MATERIAL_OPTIONS

#define u_BumpStrength 1.45 //[0.0..2.0 step 0.05] runtime "Normal Map Strength"
// Defaults match terrain.fsh's plaguePomDistanceFade: 32 steps put the 0.75x/1.5x fade band at
// 24..48 blocks.
#define u_PomDepth 0.18 //[0.0..2.0 step 0.01] runtime "3D Texture Depth"
#define u_PomQuality 32.0 //[0.0..256.0 step 8.0] runtime "3D Texture Quality"
#define u_PomDistance 32.0 //[16.0..512.0 step 8.0] runtime "3D Texture Distance"
#define u_PomAllowCutout 1 //[0 1] runtime "3D Texture on Cutout Blocks" {0="Off" 1="On"}
#define u_PomShadowStrength 0.6 //[0.00..1.00 step 0.05] runtime "3D Texture Shadows"
#define u_PomDebug 0 //[0 1 2 3] runtime "3D Texture Debug View" {0="Off" 1="Height" 2="Shadow" 3="Travel"}
// Debug instrument: repaints gAlbedoOut with the raw atlas sample and tint instead of composited
// albedo, readable via the engine's DBG_ALBEDO_IDENTITY_INPUTS (29) in gbuffer_resolve.fsh. A
// second toggle rather than gating on debugView alone, because terrain.fsh can't see u_Param3.
// Needs BOTH this ON and debugView set to 29 — otherwise 29 misreads real gAlbedo bytes as the
// four diagnostic floats.
#define u_AlbedoIdentityDebug 0 //[0 1] runtime "Raw Texture View" {0="Off" 1="On"}
// Scales the AUTHORED emission lane (labPBR `_s` alpha), not the block lane vanilla's light level
// drives. 1.0 is the DERIVED no-attenuation value, fit against the blown-out-texel fraction on
// four ore captures; it shipped at 0.35 only to compensate for a since-fixed atlas resample bug
// (LabPbrEmissionSentinel averaged the "no emission" code into painted magnitudes) — see
// delete-compensations-after-finding-root-cause.
#define u_AuthoredEmission 1.0 //[0.0..1.0 step 0.05] runtime "Glowing Texture Strength"
#define u_AOStrength 1.0 //[0.0..1.0 step 0.05] runtime "Texture AO Strength"

#define u_SnowAmount 1.0 //[0.25..2.0 step 0.05] runtime "Snow Amount"
#define u_SplashDensity 0.6 //[0.2..1.0 step 0.05] runtime "Splash Density"

#endif // PLAGUE_MATERIAL_OPTIONS
