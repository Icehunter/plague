#ifndef PLAGUE_END_SKY
#define PLAGUE_END_SKY

// Named for PLAGUE_ATMO_SKY_GAIN, which the light below is divided by so both skies arrive at the
// scale the one shared exposure expects.
//
// The globals are NOT imported here, though the helpers below read u_CameraAbs, u_SkyState and
// u_CameraSkyLight. The compute passes set their own binding and layout before importing them, so
// a second import inside this file declares u_Globals twice and the pass fails to build. Every
// file that includes this one imports the globals first.
#moj_import <fornax_runtime:atmo_lut.glsl>

// How much light the End gives off. The place has no sun, so this is the only thing setting how
// bright it is.
//
// 1.0 sits where the colour below, divided by the same gain the Overworld dome is multiplied by,
// lands at the brightness the pack's fixed exposure was approved against. Picked off a render
// rather than solved, so it moves when exposure metering arrives.
#define u_EndSkyBrightness 0.35 //[0.00..3.00 step 0.05] runtime "End Sky Brightness"

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

// How far you can see, as a share of how far the game is drawing. A share and not a fixed number
// of chunks: fog set in blocks is soup at a short view distance and a hard edge at a long one, and
// the hard edge is the whole problem, since it lets an island stay sharp right up to the point the
// game stops drawing it and then blink out. At 0.30 an island at the edge is down to about
// 4 percent, so it is gone before it can pop. AUTHORED, and the first thing to move if the End
// reads either too clear or too soupy.
#define u_EndAirReach 0.30 //[0.05..0.60 step 0.01] runtime "End View Reach"

// The End's own cloud dials. Separate from the Sky page's set on purpose: the two clouds share a
// field and nothing else, and a value that suits a night sky rarely suits this place.
#define u_EndNebulaIntensity 0.85 //[0.00..2.00 step 0.05] runtime "End Nebula Strength"
#define u_EndNebulaZoom 4.30 //[1.00..5.00 step 0.05] runtime "End Nebula Size"
#define u_EndNebulaAmount 0.65 //[0.15..0.70 step 0.01] runtime "End Nebula Amount"
#define u_EndNebulaCoreOnset 0.18 //[0.00..0.60 step 0.01] runtime "End Nebula Core Onset"
#define u_EndNebulaCoreWidth 0.50 //[0.05..0.90 step 0.01] runtime "End Nebula Core Blend"
#define u_EndNebulaDrift 1.85 //[0.00..4.00 step 0.05] runtime "End Nebula Drift Speed"
#define u_EndNebulaStarGlow 13.5 //[0.00..20.00 step 0.5] runtime "End Nebula Star Glow"

// The storm. Sheets of the same medium, seen edge-on: a sheet is brightest where your line of
// sight runs along it and invisible where it runs through it square, which is why they read as
// curtains without needing anything to hold them up. Not an aurora: the End has no magnetic field
// and nothing streaming into it, so calling it one would claim physics that is not there. What
// they are is shock fronts in the gas, and shock fronts sweep, swell and pass, which is what the
// surge below is for.
#define u_EndStormIntensity 1.40 //[0.00..2.00 step 0.05] runtime "Ion Storm Strength"
#define u_EndStormSize 1.75 //[0.50..2.00 step 0.05] runtime "Ion Storm Size"
#define u_EndStormSurge 0.6 //[0.00..1.00 step 0.05] runtime "Ion Storm Surge"
#define u_EndStormReach 0.55 //[0.10..1.00 step 0.05] runtime "Ion Storm Reach"


// The lines a shock front burns. Hotter than the quiet gas: the fronts run Hydrogen-alpha hard, so
// their bodies go magenta where the still cloud stays violet. Same analytic CIE fit and the same
// pull toward white as the nebula's lines (nebula.glsl).
const vec3 PLAGUE_END_STORM_LOW  = vec3(0.49, 0.38, 1.00);   // H-gamma 434.0 nm, the cold fringe
const vec3 PLAGUE_END_STORM_BODY = vec3(0.86, 0.30, 0.86);   // H-alpha over H-gamma, shock-heated
const vec3 PLAGUE_END_STORM_HIGH = vec3(0.90, 0.38, 0.62);   // H-alpha, the hottest crests

// Motes: specks of the same medium close enough to see one at a time, drifting past. They are what
// makes the End feel like somewhere you are standing rather than a picture you are looking at,
// because they are real points in the world and slide against the far field as you move.
#define u_EndMoteAmount 2.25 //[0.00..3.00 step 0.05] runtime "Floating Motes"
#define u_EndMoteDrift 0.35 //[0.00..2.00 step 0.05] runtime "Mote Drift Speed"

// How much bigger to draw each speck. Only grows them: the size they start at is already the
// smallest one that holds still, since a speck under a pixel wide flickers as you turn and nothing
// after this point catches it.
#define u_EndMoteSize 1.75 //[1.00..8.00 step 0.25] runtime "Mote Size"

// The two Ends. Vanilla splits the place in half: one central island, then a ring of void, then the
// outer islands. TheEndBiomeSource puts that edge at 1024 blocks out, which is 64 chunks. Standing
// on the middle island you are inside the thick of the gas, with the storm right over your head.
// Fly out and the gas thins, the storm falls behind you, and the sky opens up. That change is the
// only thing in the End that tells you how far you have gone, since everything else out there
// looks the same in every direction.
#define u_EndOuterReach 64.0 //[8.0..256.0 step 8.0] runtime "Outer Islands Distance"
#define u_EndOuterDim 0.45 //[0.00..1.00 step 0.05] runtime "Outer Islands Dimming"
#define u_EndOuterStormFade 0.65 //[0.00..1.00 step 0.05] runtime "Outer Islands Storm Fade"

// The slow turn. The whole cloud creeps around you, one full circle in about eight minutes at 1.0.
// Slow enough that you never catch it moving, fast enough that the sky is not where you left it
// when you look back. The stars do not turn with it, so the two pull apart over time.
#define u_EndTurn 1.95 //[0.00..4.00 step 0.05] runtime "Sky Turn Speed"

// Breathing. The whole place swells and falls on about a forty second cycle. Reads as something
// large and alive rather than as a light being turned up and down, because it moves the storm and
// the cloud with it instead of only the brightness.
#define u_EndBreath 0.35 //[0.00..0.50 step 0.01] runtime "Sky Breathing"

// How much of the world outline is kept in the End, on top of its surface-lighting response.
#define u_EndOutline 0.35 //[0.00..1.00 step 0.05] runtime "End Outline Strength"

// How strong the fill light is in the End. The place has no sun, so this is the only thing lighting
// a surface that faces away from everything.
#define u_EndAmbient 1.00 //[0.00..3.00 step 0.05] runtime "End Fill Light"

// How many directions the fill light is averaged over. Eight lands within about 2 percent of the
// exact answer and costs nothing, since the result is the same for every pixel on screen.
const int PLAGUE_END_AMBIENT_RAYS = 8;

// How much of the light already at a pixel a mote picks up. A speck in front of a bright front
// flares with it; one out over the void stays nearly dark. That link is what stops them
// reading as dirt on the screen. AUTHORED.
const float PLAGUE_END_MOTE_PICKUP = 0.55;
const float PLAGUE_END_MOTE_FLOOR = 0.010;

// How wide the change from the middle island to the outer ones is, as a share of the distance out.
// AUTHORED. Wide on purpose: a sharp edge would read as a wall you fly through.
const float PLAGUE_END_OUTER_BLEND = 0.55;
// Seconds for one full turn at 1.0, and for one breath. AUTHORED.
const float PLAGUE_END_TURN_PERIOD = 480.0;
const float PLAGUE_END_BREATH_PERIOD = 40.0;


/**
 * How much of a ray's light survives a distance through the End's medium.
 *
 * The same for all three colours on purpose: air turns things red over distance because the short
 * waves are scattered out along the way, and a medium giving off its own light has nothing to lose
 * that way. So distance changes how much you see, never what colour it is.
 */
float plagueEndTransmittance(float distanceBlocks) {
    // Same render-distance anchor every other pass reads, so the tables, the dome and the terrain
    // all agree about where the world ends.
    float renderDistance = u_CameraSkyLight.z > 1.0 ? u_CameraSkyLight.z : max(u_RenderFog.y, 32.0);
    float reachBlocks = max(u_EndAirReach, 0.01) * renderDistance;
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

/** Seconds since the world started. u_SkyState.w counts ticks and never stops in the End. */
float plagueEndSeconds() {
    return u_SkyState.w / 20.0;
}

/**
 * Where you are, across the End's two halves. 0 on the middle island, 1 well out among the outer
 * ones. Read straight off the camera so every pass that draws this sky agrees, including the
 * tables, which are built before anything knows which way you are looking.
 */
float plagueEndOuterFactor() {
    float edge = max(u_EndOuterReach, 1.0) * 16.0;
    float outHere = length(u_CameraAbs.xz);
    return smoothstep(edge * (1.0 - PLAGUE_END_OUTER_BLEND * 0.5),
                      edge * (1.0 + PLAGUE_END_OUTER_BLEND * 0.5), outHere);
}

/** The swell, around 1.0. */
float plagueEndBreath() {
    return 1.0 + u_EndBreath * sin(plagueEndSeconds() * 6.2831853 / PLAGUE_END_BREATH_PERIOD);
}

/**
 * How bright the End is at the camera this frame: the slider, dimmed by how far out you are,
 * times the breath. Everything that draws this sky reads it from here so no two passes can disagree.
 */
float plagueEndSkyLevel() {
    float place = mix(1.0, 1.0 - clamp(u_EndOuterDim, 0.0, 1.0), plagueEndOuterFactor());
    return max(u_EndSkyBrightness * place * plagueEndBreath(), 0.0);
}

/**
 * Turns a view ray about the up axis by the slow creep. Only the cloud and the storm ride it: the
 * dome itself is the same all the way round, so turning it would change nothing.
 */
vec3 plagueEndTurn(vec3 viewRay) {
    float angle = plagueEndSeconds() * 6.2831853 * u_EndTurn / PLAGUE_END_TURN_PERIOD;
    float s = sin(angle);
    float c = cos(angle);
    return vec3(viewRay.x * c - viewRay.z * s, viewRay.y, viewRay.x * s + viewRay.z * c);
}

/**
 * The fill light in the End: the whole sky averaged over every direction.
 *
 * Every direction, not just the upper half. In the Overworld a surface sits on the ground and sees
 * sky above and dirt below, so only the top half lights it. In the End there is no ground: the
 * medium runs on under your feet and lights a surface from below as well, which is why an island's
 * underside is lit at all rather than being a black slab.
 *
 * Averaged in the shader rather than written down as a number, so it follows the slab settings
 * above instead of quietly disagreeing with them the moment one is retuned.
 */
vec3 plagueEndAmbient() {
    float pathSum = 0.0;
    for (int i = 0; i < PLAGUE_END_AMBIENT_RAYS; ++i) {
        float rayUp = -1.0 + 2.0 * (float(i) + 0.5) / float(PLAGUE_END_AMBIENT_RAYS);
        pathSum += plagueEndPathLength(rayUp);
    }
    float meanPath = pathSum / float(PLAGUE_END_AMBIENT_RAYS);
    return PLAGUE_END_SKY_COLOUR
            * (meanPath * plagueEndSkyLevel() * max(u_EndAmbient, 0.0) / PLAGUE_ATMO_SKY_GAIN);
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
