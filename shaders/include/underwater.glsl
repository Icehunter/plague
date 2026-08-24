// Underwater colour/opacity/darkening supplier.
//
// SCOPE: owns the eye-in-water veil (opacity + colour), the scene-wide darkening ramps, the
// closed-volume (no-hit) radiance, and a dead speculative caustic hook. Does NOT own the caustic
// PATTERN (a texture-driven system elsewhere) or the Snell-window surface optics (owned by the
// water-compositing consumer) — this file only supplies colour to both.
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
// exact neutral identity when dry (opacity 0, added colour 0, tint 1), so a consumer can call
// these unconditionally on every fragment with no separate dry-path branch.

#ifndef PLAGUE_UNDERWATER_INCLUDE
#define PLAGUE_UNDERWATER_INCLUDE

#moj_import <fornax_runtime:color.glsl>

// =================================================================================================
// Compile-time options, all declared here, all default on. Each gates ONLY its own named
// behavior: flipping one must reproduce exactly what existed before that behavior was added.
//
// Four related switches are GONE (reflection fallback, surface-seen-from-below, underwater cloud
// suppression, forward-draw rejection): each existed only to bisect a rendering fault, not as a
// taste setting, and their behaviour now runs unconditionally. Two of the remaining switches are
// gated INSIDE this file (WATER_VEIL on the opacity ramp only; WATER_ABSORPTION_TINT on the
// per-channel absorption term in plagueUnderwaterMult). The rest are declared here but gated at
// their owning call site — this file only owns their names so the option scanner has one source
// of truth to redeclare against.
#define PLAGUE_UNDERWATER 1 //[0 1] compile "Underwater Effects" {0="Off" 1="On"}
#define WATER_SCATTERING_QUALITY 1 //[0 1 2] compile "Underwater Light Shafts" {0="Off" 1="Balanced" 2="High"}
#define WATER_CAUSTICS 1 //[0 1] compile "Underwater Caustics" {0="Off" 1="On"}
#define WATER_VEIL 1 //[0 1] compile "Underwater Veil" {0="Off" 1="On"}
#define WATER_ABSORPTION_TINT 1 //[0 1] compile "Underwater Tint" {0="Off" 1="On"}
#define WATER_SUN_TINT 1 //[0 1] compile "Underwater Sun Recolour" {0="Off" 1="On"}
#define WATER_AMBIENT_FLOOR 1 //[0 1] compile "Underwater Ambient Floor" {0="Off" 1="On"}
#define WATER_HELD_LIGHT_FILTER 1 //[0 1] compile "Underwater Held Light Filter" {0="Off" 1="On"}
#define WATER_BLUR 1 //[0 1] compile "Underwater Defocus Blur" {0="Off" 1="On"}

// The render-edge closure handoff and the suppression of aerial/border fog underwater are retired
// as options (§1/§3.7 of the behavioral spec this file implements): neither is a legitimate "off"
// state any more, so neither gets a #define. Consumers apply both unconditionally.

// =================================================================================================
// Constants. Every one below is either read off a cited published source or authored; no in-game
// render pass ran during this rewrite, so authored constants are reasoned choices, not photometric
// fits, and are candidates for an in-game tuning pass.

// Minecraft's own chunk width. Every distance-flavored option in this pack is authored in chunks
// and funnels through this one conversion.
const float PLAGUE_UW_BLOCKS_PER_CHUNK = 16.0;

// Fallback fog reach for the one caller with no option access (plagueGetWaterFog's single-arg
// overload). Authored: 4 chunks reads as moderately fogged rather than nearly clear or opaque.
const float PLAGUE_UW_DEFAULT_FOG_REACH_BLOCKS = 4.0 * PLAGUE_UW_BLOCKS_PER_CHUNK;

// Pure-water absorption coefficients, Pope & Fry 1997 ("Absorption spectrum (380-700 nm) of pure
// water. II. Integrating cavity measurements", Appl. Opt. 36, 8710-8723), sampled near this pack's
// display primaries and converted from published cm^-1 to m^-1, read as per-block extinction under
// this pack's blocks-as-metres convention:
//   630.0 nm (red)   -> 0.2916 m^-1  (attenuation length ~3.4 blocks)
//   532.5 nm (green) -> 0.0447 m^-1  (attenuation length ~22.4 blocks)
//   465.0 nm (blue)  -> 0.01011 m^-1 (attenuation length ~98.9 blocks)
// Used as a per-channel Beer-Lambert extinction on the whole-scene tint (plagueUnderwaterMult),
// gated independently by WATER_ABSORPTION_TINT.
const vec3 PLAGUE_UW_ABSORPTION_PER_BLOCK = vec3(0.2916, 0.0447, 0.01011);

// Camera-depth reach for the whole-scene multiplier's Beer-Lambert ramp (plagueUnderwaterMult,
// §2B.1). Authored, deliberately NOT tied to renderDistance: camera depth is vertical, render
// distance is an unrelated horizontal setting. 24 blocks is roughly the depth of vanilla's deeper
// ocean floors, so the floor is reached on a genuine dive rather than a few blocks under.
const float PLAGUE_UW_CAMERA_DEPTH_REACH_BLOCKS = 24.0;

// Clear-noon brightening target for the depth-darkening floor (§3.2, this pack's own addition).
// Authored: high enough that a clear noon dive reads distinctly less murky than an overcast one,
// low enough that depth still reads as depth.
const float PLAGUE_UW_NOON_FLOOR_TARGET = 0.42;

// Local light falloff, shared by the additive lamp glow (plagueWaterLampGlow) and the multiplier's
// own local lift: both describe the same fact, how far a point light's influence reaches through
// the medium. Authored: a several-block bubble, well inside render distance.
const float PLAGUE_UW_LOCAL_LIGHT_FALLOFF_BLOCKS = 8.0;

// Gain on the MULTIPLIER's local-light lift. Authored so the immediate murk around a held light
// reads several times brighter than the unlit floor before clamping back to 1.0 (never brighter
// than un-darkened).
const float PLAGUE_UW_LOCAL_LIGHT_LIFT_GAIN = 6.0;

// Gain on the separate ADDITIVE lamp glow (§3.4, decoupled from sky brightness so a lamp cannot
// interact with how much sun penetrated the column). Authored, kept modest.
const float PLAGUE_UW_LAMP_GLOW_GAIN = 0.8;

// Night floor for the veil's brightness (§2C): low but non-zero on a clear night, lower under
// heavily-overcast + night. Authored judgment calls, not physical constants — the extreme floor
// sits at roughly a quarter of the clear one.
const float PLAGUE_UW_NIGHT_FLOOR_CLEAR = 0.05;
const float PLAGUE_UW_NIGHT_FLOOR_EXTREME = 0.012;

// Maximum lift the accessibility brightness slider may add to the night floor above. Fixed
// design decision: an accessibility control only ever touches how dark "dark" gets and never
// scales daytime veil brightness (see plagueWaterFogColor).
const float PLAGUE_UW_VSBRIGHTNESS_NIGHT_LIFT = 0.05;

// Closed-volume directional anchoring (§3.8): brighter looking up, dimmer looking down,
// re-anchored so upness == 0 (a level ray) reproduces the veil's own full-opacity colour EXACTLY
// (see plagueUnderwaterClosedRadiance). All three authored; no offline measurement of "how much
// brighter is up" is available.
const float PLAGUE_UW_ZENITH_LIFT = 0.9;
const float PLAGUE_UW_NADIR_DROP = 0.35;
const float PLAGUE_UW_CLOSED_RADIANCE_FLOOR = 0.5;

// Reference reach past which the closed-volume radiance's directional lift is considered "clear
// water" rather than murk (short-visibility water should wash out directional structure). Authored,
// between the single-chunk fog reach and the default four-chunk one.
const float PLAGUE_UW_CLOSED_CLARITY_REF_BLOCKS = 40.0;

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

float plagueGetWaterFog(float lViewPos, float scaleBlocks) {
    if (!plagueUwIsSubmerged()) return 0.0;
    // Standard Beer-Lambert opacity: 1 - exp(-distance/scale). Never reaches a literal 1.0, but
    // the residual is negligible within a few multiples of scale.
    return 1.0 - exp(-max(lViewPos, 0.0) / max(scaleBlocks, 1e-4));
}

float plagueGetWaterFog(float lViewPos) {
    return plagueGetWaterFog(lViewPos, PLAGUE_UW_DEFAULT_FOG_REACH_BLOCKS);
}

float plagueGetWaterFogAniso(vec3 worldPos, float startBlocks, float distanceEndBlocks,
                             float depthEndBlocks) {
    if (!plagueUwIsSubmerged()) return 0.0;
#if WATER_VEIL
    float dist = length(worldPos);
    if (dist <= 1e-5) return 0.0;
    vec3 dir = worldPos / dist;
    float lateralEnd = max(distanceEndBlocks, 1e-3);
    float depthEnd = max(depthEndBlocks, 1e-3);
    // Anisotropic ramp: measure the fragment's true 3D distance against where the configured
    // end-surface (an axisymmetric ellipsoid, lateral semi-axis lateralEnd, vertical semi-axis
    // depthEnd) lies along THIS SAME ray direction — not where the ray's horizontal and vertical
    // components separately land against their own ends, which under-fogs a point moderately far
    // in both directions at once. Implicit-ellipsoid ray length for normalized direction d:
    // r = 1 / sqrt((1 - d.y^2) / lateralEnd^2 + d.y^2 / depthEnd^2); collapses to r == lateralEnd
    // (isotropic) when lateralEnd == depthEnd.
    float horizWeight = (1.0 - dir.y * dir.y) / (lateralEnd * lateralEnd);
    float vertWeight = (dir.y * dir.y) / (depthEnd * depthEnd);
    float endAlongRay = inversesqrt(max(horizWeight + vertWeight, 1e-12));
    float start = min(max(startBlocks, 0.0), endAlongRay - 1e-3);
    return clamp((dist - start) / max(endAlongRay - start, 1e-4), 0.0, 1.0);
#else
    return 0.0;
#endif
}

vec3 plagueWaterFogColor(PlagueLighting lighting) {
    if (!plagueUwIsSubmerged()) return vec3(0.0);
    // §2C: brightness is a pure function of lighting state — no position, no depth (positional
    // darkening is layered on afterward by the ramps below). sunVisibility is the engine's
    // clear-noon-normalized day/night ramp, used directly as "how bright is the sky right now
    // relative to clear noon".
    float skyRatio = clamp(lighting.sunVisibility, 0.0, 1.0);

    // Night floor: low but non-zero on a clear night, lower under overcast+night, liftable
    // (floor only) by the accessibility brightness slider — vsBrightness may lift how dark "dark"
    // gets but must never scale the daytime ratio, which is why it appears only here.
    float clearNightFloor = mix(PLAGUE_UW_NIGHT_FLOOR_EXTREME, PLAGUE_UW_NIGHT_FLOOR_CLEAR,
                                clamp(1.0 - lighting.rainFactor, 0.0, 1.0));
    float floorValue = clearNightFloor + lighting.vsBrightness * PLAGUE_UW_VSBRIGHTNESS_NIGHT_LIFT;
    float brightness = max(skyRatio, floorValue);

    // The one authored hue (§2C: fixed, never recomputed per-frame or per-biome). Cool blue,
    // chosen with Pope & Fry's channel-survival shape as directional guidance (red gone first,
    // blue surviving longest), not a literal encoding of the coefficients.
    const vec3 PLAGUE_UW_HUE_DISPLAY = vec3(0.05, 0.22, 0.42);
    return plagueAuthoredToLinear(PLAGUE_UW_HUE_DISPLAY) * brightness;
}

vec3 plagueWaterLampGlow(PlagueLighting lighting, float lViewPos) {
    if (!plagueUwIsSubmerged()) return vec3(0.0);
    // §3.4: a separate, additive, distance-local glow — same hue family as the ambient veil,
    // scaled by whichever local light is strongest, never multiplied against the sky-brightness
    // transmission term above.
    float lightStrength = clamp(max(max(u_HeldLight.x, u_HeldLight.y), u_FrameState.y), 0.0, 1.0);
    float falloff = exp(-max(lViewPos, 0.0) / PLAGUE_UW_LOCAL_LIGHT_FALLOFF_BLOCKS);
    const vec3 PLAGUE_UW_HUE_DISPLAY = vec3(0.05, 0.22, 0.42);
    return plagueAuthoredToLinear(PLAGUE_UW_HUE_DISPLAY) * lightStrength * falloff
         * PLAGUE_UW_LAMP_GLOW_GAIN;
}

vec3 plagueUnderwaterClosedRadiance(vec3 rayDirection, vec3 closedVeil, float downwellingVisibility,
                                    float uwVisibility) {
    // No submersion gate: a pure, homogeneous function of closedVeil (a scalar gain times
    // closedVeil, nothing additive), so an already-zeroed dry closedVeil propagates to zero here
    // automatically.
    float upness = clamp(rayDirection.y, -1.0, 1.0);
    float clarity = clamp(uwVisibility / (uwVisibility + PLAGUE_UW_CLOSED_CLARITY_REF_BLOCKS),
                          0.0, 1.0);
    float sunGain = clamp(downwellingVisibility, 0.0, 1.0);
    // §3.8: re-anchored so upness == 0 (a level ray) reproduces closedVeil EXACTLY — both lift and
    // drop terms vanish at upness == 0 by construction, avoiding the "dark patches shaped like
    // unloaded chunks" artifact a naive brighter-zenith-only anchor produces.
    float directionalGain = 1.0
        + max(upness, 0.0) * PLAGUE_UW_ZENITH_LIFT * clarity * sunGain
        - max(-upness, 0.0) * PLAGUE_UW_NADIR_DROP * clarity;
    return closedVeil * max(directionalGain, PLAGUE_UW_CLOSED_RADIANCE_FLOOR);
}

float plagueWaterDepthDim(vec3 worldPos, float darknessDepthBlocks, float depthDark) {
    if (!plagueUwIsSubmerged()) return 1.0;
    // §2B.2: keyed on the FRAGMENT's own absolute depth, never the camera's — worldPos is
    // camera-relative, so u_CameraAbs.y + worldPos.y recovers the same absolute Y (and so the same
    // darkness) regardless of where the camera is floating.
    float fragAbsY = u_CameraAbs.y + worldPos.y;
    float depth = max(u_WaterState.z - fragAbsY, 0.0);
    float ramp = 1.0 - exp(-depth / max(darknessDepthBlocks, 1e-3));
    return mix(1.0, clamp(depthDark, 0.0, 1.0), ramp);
}

float plagueWaterVeilDarkness(vec3 worldPos, float distanceEndBlocks, float darknessDepthBlocks,
                              float distanceDark, float depthDark) {
    if (!plagueUwIsSubmerged()) return 1.0;
    // §2B.3: additional lateral darkening on top of the fragment-depth ramp, for the veil colour —
    // opacity alone can't read as depth if the fogged-in colour is one flat shade. Reuses
    // distanceEndBlocks so darkness and opacity close out over the same span.
    float lateralDist = length(worldPos.xz);
    float lateralRamp = 1.0 - exp(-lateralDist / max(distanceEndBlocks, 1e-3));
    float lateralMult = mix(1.0, clamp(distanceDark, 0.0, 1.0), lateralRamp);
    return lateralMult * plagueWaterDepthDim(worldPos, darknessDepthBlocks, depthDark);
}

vec3 plagueUnderwaterMultCore(float lViewPos, float renderDistance, float depthFloor,
                              PlagueLighting lighting, vec3 tintBase) {
    if (!plagueUwIsSubmerged()) return vec3(1.0);

    // §2B.1: whole-scene multiplier keyed on the CAMERA's own depth (how much water above the
    // camera has already filtered the light), distinct from the fragment-keyed ramps above.
    // Clamped to renderDistance as a numerical safety bound, not a physical scale.
    float camDepth = max(u_WaterState.z - u_CameraAbs.y, 0.0);
    camDepth = min(camDepth, max(renderDistance, 0.0));
    float camRamp = 1.0 - exp(-camDepth / PLAGUE_UW_CAMERA_DEPTH_REACH_BLOCKS);

    // §3.2: clear-noon floor brightening — only a sunny, rain-free, near-noon moment reaches the
    // brighter minimum. max(depthFloor, target) guarantees a disabled floor (1.0) is never lifted
    // past 1.0 by this term.
    float clearNoon = clamp(lighting.noonFactor * (1.0 - lighting.rainFactor), 0.0, 1.0);
    float liftedFloor = max(depthFloor, PLAGUE_UW_NOON_FLOOR_TARGET);
    float effectiveFloor = mix(depthFloor, liftedFloor, clearNoon);

    float base = mix(1.0, effectiveFloor, camRamp);

    // Local light lift on the MULTIPLIER itself (distinct from plagueWaterLampGlow's additive
    // term), clamped to 1.0 so it can never brighten past "undarkened".
    float lightStrength = clamp(max(max(u_HeldLight.x, u_HeldLight.y), u_FrameState.y), 0.0, 1.0);
    float lightFalloff = exp(-max(lViewPos, 0.0) / PLAGUE_UW_LOCAL_LIGHT_FALLOFF_BLOCKS);
    float lift = lightStrength * lightFalloff * PLAGUE_UW_LOCAL_LIGHT_LIFT_GAIN;
    float lifted = min(base * (1.0 + lift), 1.0);

    // §3.1: independent toggle from the veil (WATER_VEIL above) — turning either off must not
    // disable the other. Applied over the SAME camera depth the multiplier itself uses.
    vec3 absorb = vec3(1.0);
#if WATER_ABSORPTION_TINT
    absorb = exp(-camDepth * PLAGUE_UW_ABSORPTION_PER_BLOCK);
#endif

    return lifted * tintBase * absorb;
}

vec3 plagueUnderwaterMult(float lViewPos, float renderDistance, float depthFloor,
                          PlagueLighting lighting, vec3 tintBase) {
    return plagueUnderwaterMultCore(lViewPos, renderDistance, depthFloor, lighting, tintBase);
}

vec3 plagueUnderwaterMult(float lViewPos, float renderDistance, float depthFloor,
                          PlagueLighting lighting) {
    return plagueUnderwaterMultCore(lViewPos, renderDistance, depthFloor, lighting, vec3(1.0));
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
