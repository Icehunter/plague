// Every fog option, declared once: fog.glsl (dispatcher), clouds.glsl (deck air fade) and
// water_environment.fsh (reflection probe's cloud imposter) all import this rather than each
// carrying its own copy, since the option scanner requires every declaration of a name to be
// byte-identical across files.
//
// DefineRewriter swaps every runtime `#define` below for a comment at load time; the real values
// arrive through the u_PackOptions block, spliced into the pass file, never an include. A pass
// reaching these names must declare a runtime option of its own, or — for terrain.fsh, which has
// no u_PackOptions — carry every name in its hand-written u_PbrSettings block, appended in
// lockstep with Fornax's PbrSettingsLayout.MEMBERS. tools/verify_fog.py checks both.
#ifndef PLAGUE_FOG_OPTIONS
#define PLAGUE_FOG_OPTIONS

// Compile-time so "off" costs nothing; the per-feature toggles below are runtime.
#define PLAGUE_FOG 1 //[0 1] compile "Fog" {0="Off" 1="On"}

// -------------------------------------------------------------------------------------------------
// Feature toggles
// -------------------------------------------------------------------------------------------------

#define u_FogEnableDistance 1.0 //[0.0..1.0 step 1.0] runtime "Distance Fog"
#define u_FogEnableEdge 1.0 //[0.0..1.0 step 1.0] runtime "Edge Fog"
#define u_FogEnableMorning 1.0 //[0.0..1.0 step 1.0] runtime "Morning Mist"
#define u_FogEnableNight 1.0 //[0.0..1.0 step 1.0] runtime "Night Fog"
#define u_FogEnableWet 1.0 //[0.0..1.0 step 1.0] runtime "After-Rain Mist"
#define u_FogEnableCold 1.0 //[0.0..1.0 step 1.0] runtime "Snow Mist"
#define u_FogEnableDry 1.0 //[0.0..1.0 step 1.0] runtime "Desert Air"

// Gates the per-type override sliders and the fine-tuning group below. Off, those sliders keep
// their stored value but have no effect; on, they apply.
#define u_FogAdvanced 1.0 //[0.0..1.0 step 1.0] runtime "Advanced Overrides"

// -------------------------------------------------------------------------------------------------
// Main settings
// -------------------------------------------------------------------------------------------------

// Deliberately NOT applied to the cloud fade: clouds must keep melting into the sky where the
// terrain does, or they read as pasted on.
#define u_FogDensity 1.0 //[0.0..2.0 step 0.05] runtime "Fog Amount"

// The edge itself is always fully hidden at every setting; this only moves where the fade starts.
#define u_FogBorderDensity 0.85 //[0.0..1.0 step 0.05] runtime "Edge Fog Reach"

// fit: tools/derive_fog.py (1.0 is the fitted curve exactly)
#define u_FogDistance 1.0 //[0.30..2.50 step 0.05] runtime "Fog Distance"

#define u_FogSharpness 1.0 //[0.50..2.00 step 0.05] runtime "Fog Sharpness"

// fit: tools/derive_fog.py
#define u_FogHeight 26.0 //[6.0..96.0 step 1.0] runtime "Fog Height"

// Faint haze left on far peaks above the fog layer, so high terrain reads as distant air rather
// than cut-out shapes. fit: tools/derive_fog.py
#define u_FogHighAltitude 0.073 //[0.000..0.300 step 0.001] runtime "Mountain Haze"

#define u_FogMistReach 1.0 //[0.00..2.00 step 0.05] runtime "Mist Closeness"

// -------------------------------------------------------------------------------------------------
// Time of day
// -------------------------------------------------------------------------------------------------

// Evenings are never misty; builds before sunrise and burns off through the morning.
#define u_FogMorningMist 1.0 //[0.00..2.00 step 0.05] runtime "Morning Mist Amount"

#define u_FogNight 1.0 //[0.00..2.00 step 0.05] runtime "Night Fog Amount"

#define u_FogDayVariance 0.5 //[0.00..1.00 step 0.05] runtime "Random Mornings"

// -------------------------------------------------------------------------------------------------
// Weather
// -------------------------------------------------------------------------------------------------

#define u_FogRainResponse 1.0 //[0.00..2.00 step 0.05] runtime "Rain Fog"

// fit: tools/derive_fog.py
#define u_FogRainDepth 0.98 //[0.00..2.00 step 0.02] runtime "Rain Fog Height"

// Fades out as the ground dries rather than vanishing with the weather.
#define u_FogWetMist 1.0 //[0.00..2.00 step 0.05] runtime "After-Rain Mist Amount"

// -------------------------------------------------------------------------------------------------
// Climate
// -------------------------------------------------------------------------------------------------

#define u_FogColdMist 1.0 //[0.00..2.00 step 0.05] runtime "Snow Mist Amount"

// Edge fog is not affected; the world's edge stays hidden regardless.
#define u_FogDryClear 0.5 //[0.00..1.00 step 0.05] runtime "Desert Clearness"

// -------------------------------------------------------------------------------------------------
// Advanced overrides. Each fog type gets its own Amount/Distance/Sharpness, starting at the main
// settings' defaults and ignored entirely (values kept, no effect) while Advanced Overrides is off.
// -------------------------------------------------------------------------------------------------

#define u_FogMorningDensity 1.0 //[0.00..2.00 step 0.05] runtime "Morning: Fog Amount"
#define u_FogMorningDistance 1.0 //[0.30..2.50 step 0.05] runtime "Morning: Fog Distance"
#define u_FogMorningSharpness 1.0 //[0.50..2.00 step 0.05] runtime "Morning: Fog Sharpness"

#define u_FogNightDensity 1.0 //[0.00..2.00 step 0.05] runtime "Night: Fog Amount"
#define u_FogNightDistance 1.0 //[0.30..2.50 step 0.05] runtime "Night: Fog Distance"
#define u_FogNightSharpness 1.0 //[0.50..2.00 step 0.05] runtime "Night: Fog Sharpness"

#define u_FogWetDensity 1.0 //[0.00..2.00 step 0.05] runtime "After-Rain: Fog Amount"
#define u_FogWetDistance 1.0 //[0.30..2.50 step 0.05] runtime "After-Rain: Fog Distance"
#define u_FogWetSharpness 1.0 //[0.50..2.00 step 0.05] runtime "After-Rain: Fog Sharpness"

#define u_FogColdDensity 1.0 //[0.00..2.00 step 0.05] runtime "Snow: Fog Amount"
#define u_FogColdDistance 1.0 //[0.30..2.50 step 0.05] runtime "Snow: Fog Distance"
#define u_FogColdSharpness 1.0 //[0.50..2.00 step 0.05] runtime "Snow: Fog Sharpness"

#define u_FogDryDensity 1.0 //[0.00..2.00 step 0.05] runtime "Desert: Fog Amount"
#define u_FogDryDistance 1.0 //[0.30..2.50 step 0.05] runtime "Desert: Fog Distance"
#define u_FogDrySharpness 1.0 //[0.50..2.00 step 0.05] runtime "Desert: Fog Sharpness"

// -------------------------------------------------------------------------------------------------
// Fine tuning. Also gated behind "Advanced Overrides"; off, the shipped defaults hold.
// -------------------------------------------------------------------------------------------------

// fit: tools/derive_fog.py
#define u_FogClimbRise 0.44 //[0.00..1.00 step 0.02] runtime "Fog Seen From Above"

// Below Min sky light a nearby surface counts as underground and gets no fog; above Max it fogs
// normally. Kept low so forests and doorways still fog.
#define u_FogCaveGuardLo 0.05 //[0.00..1.00 step 0.01] runtime "Cave Fog Guard Min"
#define u_FogCaveGuardHi 0.35 //[0.00..1.00 step 0.01] runtime "Cave Fog Guard Max"

// How far out (as a share of render distance) the edge fog stops caring whether a surface is
// underground. Only changes what sealed caves see; never the horizon.
#define u_FogBorderGateNear 0.55 //[0.00..1.00 step 0.05] runtime "Edge Fog Guard Near"
#define u_FogBorderGateFar 0.80 //[0.00..1.00 step 0.05] runtime "Edge Fog Guard Far"

// -------------------------------------------------------------------------------------------------
// The drive, built from the options above plus the engine's own signals
// -------------------------------------------------------------------------------------------------
//
// A macro, not a function: this file is imported before fog_model.glsl (which defines
// plagueFogDrive), and the option identifiers only resolve inside the program carrying the
// u_PackOptions or u_PbrSettings block, so both have to defer to the use site.
//
// u_CameraSkyLight.y carries vanilla's own precipitation type (0 none, 1 rain, 2 snow) — the only
// climate signal that exists. u_SkyState.y is the sun angle in radians, noon-zero over the full
// day cycle, so it distinguishes dawn from dusk where elevation alone can't. u_FrameState.w is
// accumulated surface wetness, which lags rain in both directions (the after-rain mist's clock).
// lighting.rainFactor and lighting.nightFactor come from the caller's own lighting model, not a
// separate read; u_SkyState.w is the raw tick clock morning mist keys its own fade window on.
//
// One line, no backslash continuations: glslangValidator rejects line continuation under this
// pack's #version (see CLAUDE.md).
#define PLAGUE_FOG_DRIVE(lighting) plagueFogDrive((lighting).rainFactor, clamp(u_FrameState.w, 0.0, 1.0), u_CameraSkyLight.y, (lighting).nightFactor, plagueFogDayFrac(u_SkyState.y), u_SkyState.w, u_FogDistance, u_FogSharpness, u_FogHeight, u_FogHighAltitude, u_FogMorningMist, u_FogNight, u_FogDayVariance, u_FogRainResponse, u_FogRainDepth, u_FogWetMist, u_FogMistReach, u_FogColdMist, u_FogDryClear, u_FogClimbRise, vec4(u_FogEnableMorning, u_FogEnableNight, u_FogEnableWet, u_FogEnableCold), vec2(u_FogEnableDry, u_FogAdvanced), vec3(u_FogMorningDensity, u_FogMorningDistance, u_FogMorningSharpness), vec3(u_FogNightDensity, u_FogNightDistance, u_FogNightSharpness), vec3(u_FogWetDensity, u_FogWetDistance, u_FogWetSharpness), vec3(u_FogColdDensity, u_FogColdDistance, u_FogColdSharpness), vec3(u_FogDryDensity, u_FogDryDistance, u_FogDrySharpness))

#endif // PLAGUE_FOG_OPTIONS
