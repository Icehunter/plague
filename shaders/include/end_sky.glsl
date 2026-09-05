#ifndef PLAGUE_END_SKY
#define PLAGUE_END_SKY

// Named for PLAGUE_ATMO_SKY_GAIN, which the light below is divided by so both skies arrive at the
// scale the one shared exposure expects.
#moj_import <fornax_runtime:atmo_lut.glsl>

// How much light the End gives off. The place has no sun, so this is the only thing setting how
// bright it is.
//
// 1.0 sits where the colour below, divided by the same gain the Overworld dome is multiplied by,
// lands at the brightness the pack's fixed exposure was approved against. Picked off a render
// rather than solved, so it moves when exposure metering arrives.
#define u_EndSkyBrightness 1.0 //[0.00..3.00 step 0.05] runtime "End Sky Brightness"

// The End's sky. There is no sun, no air and no clock, so none of the Overworld's model applies:
// the scattering tables assume an overhead sun and a Rayleigh atmosphere and paint blue daylight
// with a sun in it when they are read here.
//
// What the End has instead is a thin medium that gives off its own light. With no light source to
// scatter, the brightness along a ray is just how much of the medium the ray crosses, so the sky is
// pure geometry: no time of day, no weather, no direction to the light. Three things follow, and
// they are the whole look.
//
//   Straight up is DIMMEST. The medium is a slab, so looking up crosses it by the short way.
//   Eye level is BRIGHTEST, in a wide soft band, because the ray runs along the slab instead of
//     across it. The band is soft rather than a hard line because the medium also stops at a
//     radius, which caps the path before it can run away.
//   Looking down goes dark fast. Below the islands only a thin trace of it is left, so the
//     further down you look the less there is. That is what makes the drop read as depth and not
//     as a hole in the render.
//
// Colour comes from vanilla's own End, not from taste: the_end.json gives sky_light_color #AC60CD,
// which is the colour the game itself lights the place with. Anchoring here means the pack and
// vanilla agree about what colour the End is.
//
// Path length does not change the colour, only the brightness. An air path reddens because the
// short waves are scattered out along the way; a medium giving off its own light has nothing to
// scatter out, so every direction is the same colour and only the brightness moves. That is the
// clearest difference between standing in the End and standing in the Overworld, and it is free.

// Vanilla's sky_light_color #AC60CD as linear sRGB. Derived, not authored: read from the game's own
// data/minecraft/dimension_type/the_end.json.
const vec3 PLAGUE_END_SKY_COLOUR = vec3(0.4147, 0.1144, 0.6104);

// Half-thickness of the slab, in blocks. AUTHORED. Sets how flat the sky reads: too thin and the
// band at eye level pinches into a line, too thick and the whole sky flattens to one tone. Tune
// against a render from the main island at Y 64, where the band should sit about 1.6 times the
// brightness of straight up.
const float PLAGUE_END_SLAB_HALF = 320.0;

// Where the medium stops, in blocks. Derived: twice vanilla's own central-island radius, which
// TheEndBiomeSource puts at 1024 blocks. This is what caps the eye-level band instead of letting
// it run away to a hard bright line.
const float PLAGUE_END_REACH = 2048.0;

// How fast the light dies below the islands: the drop over which it fades to a third. AUTHORED.
// Tune against
// stepping off the edge: the drop should read as bottomless within about three seconds of falling,
// rather than as a floor at a distance you can judge.
const float PLAGUE_END_VOID_FALL = 96.0;

// The share of the sky's own light that reaches even a surface facing away from all of it. Derived:
// vanilla's the_end.json sets ambient_light 0.25, which is its promise that nothing in the End is
// ever fully dark.
const float PLAGUE_END_AMBIENT_FLOOR = 0.25;

// How far you can see before things fade into the sky, in chunks. AUTHORED, and the first thing to
// move if the place reads either too clear or too soupy.
#define u_EndAirReach 12.0 //[1.0..64.0 step 1.0] runtime "End Air Distance"

// The End's own cloud dials. Separate from the Sky page's set on purpose: the two clouds share a
// field and nothing else, and a value that suits a night sky rarely suits this place.
#define u_EndNebulaIntensity 1.0 //[0.00..2.00 step 0.05] runtime "End Nebula Strength"
#define u_EndNebulaZoom 3.0 //[1.00..5.00 step 0.05] runtime "End Nebula Size"
#define u_EndNebulaAmount 0.55 //[0.15..0.70 step 0.01] runtime "End Nebula Amount"
#define u_EndNebulaCoreOnset 0.06 //[0.00..0.60 step 0.01] runtime "End Nebula Core Onset"
#define u_EndNebulaCoreWidth 0.34 //[0.05..0.90 step 0.01] runtime "End Nebula Core Blend"
#define u_EndNebulaDrift 1.0 //[0.00..4.00 step 0.05] runtime "End Nebula Drift Speed"
#define u_EndNebulaStarGlow 7.0 //[0.00..20.00 step 0.5] runtime "End Nebula Star Glow"

// The storm. Sheets of the same medium, seen edge-on: a sheet is brightest where your line of
// sight runs along it and invisible where it runs through it square, which is why they read as
// curtains without needing anything to hold them up. Not an aurora: the End has no magnetic field
// and nothing streaming into it, so calling it one would claim physics that is not there. What
// they are is shock fronts in the gas, and shock fronts sweep, swell and pass, which is what the
// surge below is for.
#define u_EndStormIntensity 1.0 //[0.00..2.00 step 0.05] runtime "Ion Storm Strength"
#define u_EndStormSize 1.2 //[0.50..2.00 step 0.05] runtime "Ion Storm Size"
#define u_EndStormSurge 0.6 //[0.00..1.00 step 0.05] runtime "Ion Storm Surge"
#define u_EndStormReach 0.55 //[0.10..1.00 step 0.05] runtime "Ion Storm Reach"


// The lines a shock front burns. Hotter than the quiet gas: the fronts run Hydrogen-alpha hard, so
// their bodies go magenta where the still cloud stays violet. Same analytic CIE fit and the same
// pull toward white as the nebula's lines (nebula.glsl).
const vec3 PLAGUE_END_STORM_LOW  = vec3(0.49, 0.38, 1.00);   // H-gamma 434.0 nm, the cold fringe
const vec3 PLAGUE_END_STORM_BODY = vec3(0.86, 0.30, 0.86);   // H-alpha over H-gamma, shock-heated
const vec3 PLAGUE_END_STORM_HIGH = vec3(0.90, 0.38, 0.62);   // H-alpha, the hottest crests


/**
 * How much of a ray's light survives a distance through the End's medium.
 *
 * The same for all three colours on purpose: air turns things red over distance because the short
 * waves are scattered out along the way, and a medium giving off its own light has nothing to lose
 * that way. So distance changes how much you see, never what colour it is.
 */
float plagueEndTransmittance(float distanceBlocks) {
    // 16 blocks to a chunk. Converted here rather than through plagueChunksToBlocks, which lives in
    // underwater.glsl and would drag the whole underwater chain in behind it.
    float reachBlocks = max(u_EndAirReach, 1.0) * 16.0;
    return exp(-max(distanceBlocks, 0.0) / reachBlocks);
}

/**
 * How much medium a ray crosses, as a share of the straight-up amount. 1.0 looking straight up,
 * rising toward eye level, falling away below.
 *
 * @param rayUp  the view ray's vertical part, sin of its angle above eye level
 */
float plagueEndPathLength(float rayUp) {
    float steep = max(abs(rayUp), PLAGUE_END_SLAB_HALF / PLAGUE_END_REACH);
    float path = min(1.0 / steep, PLAGUE_END_REACH / PLAGUE_END_SLAB_HALF);
    if (rayUp >= 0.0) {
        return path;
    }
    // Below eye level only a trace is left, and it thins the further down the ray goes.
    return path * exp(rayUp * PLAGUE_END_SLAB_HALF / PLAGUE_END_VOID_FALL);
}

/** How much light the End's sky sends back along a view ray. */
vec3 plagueEndSky(vec3 viewRay, float brightness) {
    float path = plagueEndPathLength(clamp(viewRay.y, -1.0, 1.0));
    // Divided by the same gain the Overworld dome is multiplied by, so both domes reach the HDR
    // buffer at the scale the one shared exposure expects. Without it the End arrives a full gain
    // too hot and the slider spends its whole range undoing that.
    return PLAGUE_END_SKY_COLOUR * (path * max(brightness, 0.0) / PLAGUE_ATMO_SKY_GAIN);
}

#endif // PLAGUE_END_SKY
