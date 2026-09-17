// Every light/ambient-colour option, declared once: gbuffer_resolve.fsh, water_composite.fsh,
// water_volume_march.fsh and clouds_march_volume.comp all import this rather than each carrying its own
// copy, since the option scanner requires every declaration of a name to be byte-identical across
// files. Same arrangement, and the same reason, as fog_options.glsl.
//
// Not declared in light_and_ambient_colors.glsl, the file that actually consumes them: terrain.fsh
// imports that (via color.glsl) above its hand-written u_PbrSettings block, and a runtime `#define`
// seen before that block gets rewritten instead of becoming a real option. This file is imported by
// fullscreen passes only, so terrain never reaches it.
//
// DefineRewriter swaps every runtime `#define` below for a comment at load time; the real values
// arrive through the u_PackOptions block, spliced into the pass file, never an include — so a pass
// reaching these names must import this file at the point its own block used to sit.
#ifndef PLAGUE_LIGHT_OPTIONS
#define PLAGUE_LIGHT_OPTIONS

// Off (default) = Physical: Rayleigh/Mie/ozone extinction integrated along the light's actual
// path, so sunset colour emerges rather than being chosen (see atmosphere.glsl). On = Custom:
// player-tunable colours per time of day (see light_and_ambient_colors.glsl). Ambient uses the
// Custom palette in BOTH modes until the sky LUT lands (M1 phase 2) — Physical's ambient would
// need a rendered atmosphere this pack doesn't have yet.
#define CUSTOM_LIGHT_COLORS 0 //[0 1] compile "Light Colours" {0="Natural" 1="Custom"}

// Defaults mirror light_and_ambient_colors.glsl's own PLAGUE_*_DEFAULT constants; see each one's
// derivation comment there.
#define u_LightPaletteNoonR 1.3998 //[0.00..3.00 step 0.02] runtime "Custom Noon Light: Red"
#define u_LightPaletteNoonG 1.1976 //[0.00..3.00 step 0.02] runtime "Custom Noon Light: Green"
#define u_LightPaletteNoonB 1.0075 //[0.00..3.00 step 0.02] runtime "Custom Noon Light: Blue"
#define u_LightPaletteSunsetR 0.6782 //[0.00..3.00 step 0.02] runtime "Custom Sunset Light: Red"
#define u_LightPaletteSunsetG 0.4953 //[0.00..3.00 step 0.02] runtime "Custom Sunset Light: Green"
#define u_LightPaletteSunsetB 0.2458 //[0.00..3.00 step 0.02] runtime "Custom Sunset Light: Blue"
#define u_LightPaletteSunsetWarmth 0.00 //[0.00..2.00 step 0.05] runtime "Custom Sunset Light Warmth"
#define u_LightPaletteNightR 0.0321 //[0.00..2.00 step 0.01] runtime "Custom Night Light: Red"
#define u_LightPaletteNightG 0.0462 //[0.00..2.00 step 0.01] runtime "Custom Night Light: Green"
#define u_LightPaletteNightB 0.0777 //[0.00..2.00 step 0.01] runtime "Custom Night Light: Blue"
#define u_LightPaletteRainDayR 0.3598 //[0.00..2.00 step 0.01] runtime "Custom Rainy Day Light: Red"
#define u_LightPaletteRainDayG 0.3268 //[0.00..2.00 step 0.01] runtime "Custom Rainy Day Light: Green"
#define u_LightPaletteRainDayB 0.4920 //[0.00..2.00 step 0.01] runtime "Custom Rainy Day Light: Blue"
#define u_LightPaletteRainNightR 0.4699 //[0.00..2.00 step 0.01] runtime "Custom Rainy Night Light: Red"
#define u_LightPaletteRainNightG 0.7939 //[0.00..2.00 step 0.01] runtime "Custom Rainy Night Light: Green"
#define u_LightPaletteRainNightB 1.2417 //[0.00..2.00 step 0.01] runtime "Custom Rainy Night Light: Blue"
#define u_LightPaletteRainMagnitude 1.00 //[0.00..2.00 step 0.05] runtime "Custom Rain Light Strength"
#define u_AtmPaletteNoonExponent 1.2294 //[0.20..4.00 step 0.05] runtime "Custom Noon Sky Shaping"
#define u_AtmPaletteNoonBrightness 1.3615 //[0.00..3.00 step 0.05] runtime "Custom Noon Sky Brightness"
#define u_AtmPaletteSunsetTintR 1.5868 //[0.00..3.00 step 0.02] runtime "Custom Sunset Sky: Red"
#define u_AtmPaletteSunsetTintG 0.6909 //[0.00..3.00 step 0.02] runtime "Custom Sunset Sky: Green"
#define u_AtmPaletteSunsetTintB 0.5900 //[0.00..3.00 step 0.02] runtime "Custom Sunset Sky: Blue"
#define u_AtmPaletteNightR 0.0589 //[0.00..2.00 step 0.01] runtime "Custom Night Sky: Red"
#define u_AtmPaletteNightG 0.0289 //[0.00..2.00 step 0.01] runtime "Custom Night Sky: Green"
#define u_AtmPaletteNightB 0.0609 //[0.00..2.00 step 0.01] runtime "Custom Night Sky: Blue"
#define u_AtmPaletteRainDayR 0.4650 //[0.00..2.00 step 0.01] runtime "Custom Rainy Day Sky: Red"
#define u_AtmPaletteRainDayG 0.4341 //[0.00..2.00 step 0.01] runtime "Custom Rainy Day Sky: Green"
#define u_AtmPaletteRainDayB 0.6637 //[0.00..2.00 step 0.01] runtime "Custom Rainy Day Sky: Blue"
#define u_AtmPaletteRainNightR 0.0280 //[0.00..2.00 step 0.01] runtime "Custom Rainy Night Sky: Red"
#define u_AtmPaletteRainNightG 0.0445 //[0.00..2.00 step 0.01] runtime "Custom Rainy Night Sky: Green"
#define u_AtmPaletteRainNightB 0.1532 //[0.00..2.00 step 0.01] runtime "Custom Rainy Night Sky: Blue"

// --- Colour multipliers (M0) ------------------------------------------------------------------
//
// A user grading layer: four time-of-day arms times R/G/B/Intensity, for light and atmosphere
// colour independently. Every constant defaults to 1.00 (identity), confirmed in
// tools/verify_color_mults.py. The two NIGHT_I sliders open to 0.01 rather than 0.50 since a night
// grade wanting near-total darkening is the one arm that needs it.
//
// Master toggles default ON: this costs nothing at neutral defaults (a few mix()/dot() ops), so
// there's no reason to make a user find a second switch before the sliders they can see do anything.
//#define LIGHT_COLOR_MULTS //[] compile "Light Colour Adjustments"
#define u_LightMorningR 1.00 //[0.50..2.00 step 0.05] runtime "Morning Light Tint: Red"
#define u_LightMorningG 1.00 //[0.50..2.00 step 0.05] runtime "Morning Light Tint: Green"
#define u_LightMorningB 1.00 //[0.50..2.00 step 0.05] runtime "Morning Light Tint: Blue"
#define u_LightMorningI 1.00 //[0.50..2.00 step 0.05] runtime "Morning Light Tint: Brightness"
#define u_LightNoonR 1.00 //[0.50..2.00 step 0.05] runtime "Noon Light Tint: Red"
#define u_LightNoonG 1.00 //[0.50..2.00 step 0.05] runtime "Noon Light Tint: Green"
#define u_LightNoonB 1.00 //[0.50..2.00 step 0.05] runtime "Noon Light Tint: Blue"
#define u_LightNoonI 1.00 //[0.50..2.00 step 0.05] runtime "Noon Light Tint: Brightness"
#define u_LightNightR 1.00 //[0.50..2.00 step 0.05] runtime "Night Light Tint: Red"
#define u_LightNightG 1.00 //[0.50..2.00 step 0.05] runtime "Night Light Tint: Green"
#define u_LightNightB 1.00 //[0.50..2.00 step 0.05] runtime "Night Light Tint: Blue"
#define u_LightNightI 1.00 //[0.01..2.00 step 0.05] runtime "Night Light Tint: Brightness"
#define u_LightRainR 1.00 //[0.50..2.00 step 0.05] runtime "Rain Light Tint: Red"
#define u_LightRainG 1.00 //[0.50..2.00 step 0.05] runtime "Rain Light Tint: Green"
#define u_LightRainB 1.00 //[0.50..2.00 step 0.05] runtime "Rain Light Tint: Blue"
#define u_LightRainI 1.00 //[0.50..2.00 step 0.05] runtime "Rain Light Tint: Brightness"
#define ATM_COLOR_MULTS //[] compile "Sky Colour Adjustments"
#define u_AtmMorningR 1.00 //[0.50..2.00 step 0.05] runtime "Morning Sky Tint: Red"
#define u_AtmMorningG 1.00 //[0.50..2.00 step 0.05] runtime "Morning Sky Tint: Green"
#define u_AtmMorningB 1.00 //[0.50..2.00 step 0.05] runtime "Morning Sky Tint: Blue"
#define u_AtmMorningI 1.00 //[0.50..2.00 step 0.05] runtime "Morning Sky Tint: Brightness"
#define u_AtmNoonR 1.00 //[0.50..2.00 step 0.05] runtime "Noon Sky Tint: Red"
#define u_AtmNoonG 1.00 //[0.50..2.00 step 0.05] runtime "Noon Sky Tint: Green"
#define u_AtmNoonB 1.00 //[0.50..2.00 step 0.05] runtime "Noon Sky Tint: Blue"
#define u_AtmNoonI 1.00 //[0.50..2.00 step 0.05] runtime "Noon Sky Tint: Brightness"
#define u_AtmNightR 1.00 //[0.50..2.00 step 0.05] runtime "Night Sky Tint: Red"
#define u_AtmNightG 1.00 //[0.50..2.00 step 0.05] runtime "Night Sky Tint: Green"
#define u_AtmNightB 1.00 //[0.50..2.00 step 0.05] runtime "Night Sky Tint: Blue"
#define u_AtmNightI 1.00 //[0.01..2.00 step 0.05] runtime "Night Sky Tint: Brightness"
#define u_AtmRainR 1.00 //[0.50..2.00 step 0.05] runtime "Rain Sky Tint: Red"
#define u_AtmRainG 1.00 //[0.50..2.00 step 0.05] runtime "Rain Sky Tint: Green"
#define u_AtmRainB 1.00 //[0.50..2.00 step 0.05] runtime "Rain Sky Tint: Blue"
#define u_AtmRainI 1.00 //[0.50..2.00 step 0.05] runtime "Rain Sky Tint: Brightness"


// Stands in for vanilla's own brightness slider (Fornax exposes no equivalent uniform), folded
// into the NIGHT and RAIN intensities only, so raising it lightens the dark end without washing
// out daylight. 0.5 matches vanilla's own default.
#define u_ScreenBrightness 0.5 //[0.0..1.0 step 0.05] runtime "Screen Brightness"

#endif // PLAGUE_LIGHT_OPTIONS
