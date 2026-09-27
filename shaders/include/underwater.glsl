// Underwater colour supplier: what the water between the eye and a point lets through, what it
// adds, and what the sky light is worth at a depth. Every number comes from water_medium.glsl, the
// same medium the surface composite and the shaft march read, so a lantern keeps its colour when
// the camera crosses the surface.
//
// SCOPE: owns the eye-in-water leg of a view ray (its transmittance and its scattered light), the
// closed-volume radiance of a ray that meets nothing, the lamp glow around a local light, and the
// sky light left at a depth for the resolve's submerged terrain. Does NOT own the caustic pattern
// (a texture-driven system elsewhere) or the Snell-window surface optics (owned by the water
// compositing consumer).
//
// Reachable from a deferred geometry pass with no runtime-options buffer: every tunable is a
// function PARAMETER, never a locally-declared option. The compile-time switches below are
// preprocessor #defines, resolved before the options buffer exists, so they're fine to declare here.
//
// Assumes on entry: PlagueLighting and the engine's u_Globals block (u_CameraAbs, u_WaterState,
// u_HeldLight, u_FrameState.y) are already in scope, imported by the consumer.
//
// WET/DRY AUTHORITY: u_WaterState.x (1.0 iff the camera's eye is in water) is the SOLE signal this
// file trusts; see plagueUwIsSubmerged(). Every public function checks it first and returns an
// exact neutral identity when dry (transmittance 1, added light 0), so a consumer can call these
// unconditionally on every fragment with no separate dry-path branch.

#ifndef PLAGUE_UNDERWATER_INCLUDE
#define PLAGUE_UNDERWATER_INCLUDE

#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:water_medium.glsl>

// =================================================================================================
// Compile-time options, all declared here, all default on. Each gates ONLY its own named
// behavior: flipping one must reproduce exactly what existed before that behavior was added.
//
// Two of the switches are gated INSIDE this file (WATER_VEIL on the scattered light,
// WATER_ABSORPTION_TINT on the per-channel shape of the absorption). The rest are declared here
// but gated at their owning call site; this file only owns their names so the option scanner has
// one source of truth to redeclare against.
#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="High" 2="Epic"}
#define WATER_CAUSTICS 1 //[0 1] compile "Underwater Caustics" {0="Off" 1="On"}
#define WATER_VEIL 1 //[0 1] compile "Underwater Haze" {0="Off" 1="On"}
#define WATER_ABSORPTION_TINT 1 //[0 1] compile "Underwater Tint" {0="Off" 1="On"}
#define WATER_SUN_TINT 1 //[0 1] compile "Underwater Sun Recolour" {0="Off" 1="On"}
#define WATER_AMBIENT_FLOOR 1 //[0 1] compile "Underwater Minimum Light" {0="Off" 1="On"}
#define WATER_HELD_LIGHT_FILTER 1 //[0 1] compile "Underwater Held Light Colour" {0="Off" 1="On"}
#define WATER_BLUR 1 //[0 1] compile "Underwater Blur" {0="Off" 1="On"}

// =================================================================================================
// Constants.

// Minecraft's own chunk width. Every distance-flavored option in this pack is authored in chunks
// and funnels through this one conversion.
const float PLAGUE_UW_BLOCKS_PER_CHUNK = 16.0;

// A leg longer than any render distance. exp() of the medium's extinction over it underflows to
// a clean zero, which is the closed volume's own answer: nothing comes back from that far.
const float PLAGUE_WATER_CLOSED_LEG_BLOCKS = 4096.0;

// How far a held torch or a lit block reaches into the water around the eye. Authored: a
// several-block bubble, well inside render distance.
const float PLAGUE_WATER_LAMP_REACH_BLOCKS = 8.0;
// The scattered light of a full-strength lamp at the lamp, before the water's own colour
// (plagueWaterAlbedo) filters it. Derived from the accepted build's output: its glow reached 0.118
// linear in blue at the lamp, and 0.118 over the medium's blue albedo of 0.60 is 0.2.
const float PLAGUE_WATER_LAMP_GLOW = 0.2;

// Dead-hook caustic constants (§0/§2D): inert unless PLAGUE_UNDERWATER_WAVE_CAUSTIC_HOOK is
// defined, which nothing in the shipped tree does. Kept minimal, matching the described
// construction (two differently-scaled, oppositely-drifting samples of the same field the water
// surface animates from), not tuned against anything.
const float PLAGUE_UW_CAUSTIC_SCALE_A = 0.05;
const float PLAGUE_UW_CAUSTIC_SCALE_B = 0.037;
const float PLAGUE_UW_CAUSTIC_DRIFT = 0.015;
const float PLAGUE_UW_CAUSTIC_GAIN = 3.0;
const float PLAGUE_UW_CAUSTIC_CONTRAST = 1.6;

// =================================================================================================
// Private helpers (not part of this file's interop surface).

// The one submersion signal this file trusts: the engine's per-frame eye-in-water flag. See the
// WET/DRY AUTHORITY note at the top of this file.
bool plagueUwIsSubmerged() {
    return u_WaterState.x > 0.5;
}

// =================================================================================================
// Public ABI. Names and signatures below are this pack's own interop surface; every consumer calls
// them by these names.

float plagueChunksToBlocks(float chunks) {
    return chunks * PLAGUE_UW_BLOCKS_PER_CHUNK;
}

// How deep the eye sits. Zero when dry.
float plagueWaterCameraDepth() {
    return plagueUwIsSubmerged() ? max(u_WaterState.z - u_CameraAbs.y, 0.0) : 0.0;
}

// The sky light left at a depth, in the units a white diffuse surface shows under the same sky.
// The dome fill is the sky light the terrain itself is lit by, so the water and the ground under
// it agree about how bright the day is.
vec3 plagueWaterLightAtDepth(PlagueLighting lighting, float depthBlocks, float clarity) {
    return max(lighting.ambient, vec3(0.0)) * plagueWaterDownwelling(depthBlocks, clarity);
}

// The water's own glow around a point at a depth: what a level ray through endless water would
// carry there. The resolve adds this to a sunken block's ambient, since the lightmap's sky level
// drops a whole step per water block and reads nearly nothing a few blocks down.
vec3 plagueWaterGlowAtDepth(PlagueLighting lighting, float depthBlocks, float clarity) {
    return plagueWaterInScatter(plagueWaterLightAtDepth(lighting, depthBlocks, clarity), 0.0,
                                PLAGUE_WATER_CLOSED_LEG_BLOCKS, clarity);
}

// The in-water part of a view ray. viewRay is the unit direction from the eye, rayLength the
// distance to the point; an upward ray leaves the water at the surface and the leg stops there.
float plagueWaterLegBlocks(vec3 viewRay, float rayLength) {
    float toSurface = viewRay.y > 1e-4 ? plagueWaterCameraDepth() / viewRay.y : rayLength;
    return min(max(rayLength, 0.0), max(toSurface, 0.0));
}

// What the eye-to-point leg lets through, per channel. Exactly 1 when dry.
vec3 plagueWaterViewTransmittance(vec3 viewRay, float rayLength, float clarity) {
    if (!plagueUwIsSubmerged()) return vec3(1.0);
    vec3 through = plagueWaterVolumeTransmittance(plagueWaterLegBlocks(viewRay, rayLength), clarity);
#if WATER_ABSORPTION_TINT
    return through;
#else
    // The switch keeps the loss and drops the colour of it: one grey figure for all three.
    return vec3(dot(through, vec3(1.0 / 3.0)));
#endif
}

// The light the eye-to-point leg adds. Exactly 0 when dry, and 0 with the haze switched off.
vec3 plagueWaterViewInScatter(vec3 viewRay, float rayLength, PlagueLighting lighting,
                              float clarity) {
#if WATER_VEIL
    if (!plagueUwIsSubmerged()) return vec3(0.0);
    return plagueWaterInScatter(plagueWaterLightAtDepth(lighting, plagueWaterCameraDepth(), clarity),
                                viewRay.y, plagueWaterLegBlocks(viewRay, rayLength), clarity);
#else
    return vec3(0.0);
#endif
}

// A ray that meets nothing: water to the end of the world, or to the surface if it climbs. The
// leg length makes the sum converge on its own; no closure curve is needed on top. Exactly 0 when
// dry.
vec3 plagueWaterClosedRadiance(vec3 viewRay, PlagueLighting lighting, float clarity) {
    return plagueWaterViewInScatter(viewRay, PLAGUE_WATER_CLOSED_LEG_BLOCKS, lighting, clarity);
}

// A held torch or a lit block lights the water around the eye. Added, with its own reach, on top
// of the sky's share: a local source, not a scale on the day. White light scattered by water takes
// the water's own colour (the albedo), which is why a torch glow under water is not orange. Scaled
// by what the leg stops, so a point at arm's length gets none of it.
vec3 plagueWaterLampGlow(float rayLength, float clarity) {
    if (!plagueUwIsSubmerged()) return vec3(0.0);
    float strength = clamp(max(max(u_HeldLight.x, u_HeldLight.y), u_FrameState.y), 0.0, 1.0);
    float reach = exp(-max(rayLength, 0.0) / PLAGUE_WATER_LAMP_REACH_BLOCKS);
    return plagueWaterAlbedo() * PLAGUE_WATER_LAMP_GLOW * strength * reach
         * (vec3(1.0) - plagueWaterVolumeTransmittance(rayLength, clarity));
}

// Dead (§0): no shipped file defines this hook, so the body below never reaches a compiler. A
// future caustic system using this should sample the SAME field the water surface animates from,
// passed in as noiseTex — not an independent noise source.
#ifdef PLAGUE_UNDERWATER_WAVE_CAUSTIC_HOOK
float plagueCaustic(sampler2D noiseTex, vec3 worldAbs, float time, float distFalloff,
                    float strength) {
    // Two differently-scaled, oppositely-drifting samples of the field, differenced to approximate
    // a focusing/gradient effect, then contrast-shaped so the result reads as a bright, connected,
    // dancing web over a darker floor rather than isolated sparkle points or a flat wash (§2D).
    vec2 drift = vec2(time, -time) * PLAGUE_UW_CAUSTIC_DRIFT;
    vec2 uvA = worldAbs.xz * PLAGUE_UW_CAUSTIC_SCALE_A + drift;
    vec2 uvB = worldAbs.xz * PLAGUE_UW_CAUSTIC_SCALE_B - drift;
    float web = abs(texture(noiseTex, uvA).r - texture(noiseTex, uvB).r);
    web = pow(clamp(web * PLAGUE_UW_CAUSTIC_GAIN, 0.0, 1.0), PLAGUE_UW_CAUSTIC_CONTRAST);
    return web * exp(-length(worldAbs) * distFalloff) * strength;
}
#endif
#endif // PLAGUE_UNDERWATER_INCLUDE
