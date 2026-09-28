# Plague: feature set

What is **currently working**, checked against `graph.toml`, `screens.toml` and the shader tree.
Anything experimental, opt-in or unfinished is marked as such.

Plague is a shaderpack for the Fornax engine (see `README.md` for what that split means); this file
covers what the pack does, not the engine under it.

---

## Sky

- Procedural sky dome from scattering through the air:
  Rayleigh, aerosol and ozone with multiple scattering, from the camera's own height, into three
  small tables rebuilt every frame. Sunset, twilight blue and the sun's glow around it all fall out
  of that maths, with a gain on the sun's light through twilight standing in for the light metering
  the pack does not have yet. Water reflections and screen-space misses sample the same dome. The haze
  on distant terrain, water and glass is marched too: added light and how much light gets through,
  per screen froxel, with the fog drive's morning, night, after-rain and snow mist as a shallow
  layer. Aerial Perspective on the Atmosphere screen multiplies that air along the view ray alone,
  since at true scale a 32-chunk view is under 3 km of air and fades nothing; the dome, the sun's
  path and the camera's height stay at true scale. The render-edge veil fades into the sky along the same
  ray. The night-sky gate follows the scattering dome. Shared palette estimates still supply surface ambient, water illumination,
  cloud direct lighting, smoke and banner fog; their controls remain active.
- Stars, with amount, size, roundness and softness controls.
- Night nebula (intensity, zoom, amount).
- Shooting stars (count, speed, frequency).
- Aurora borealis: a marched curtain with Smooth and Blocky styles, an every-clear-night or
  full-moon-only condition, and detail/size/intensity/quality controls.
- Sun and moon discs drawn from vanilla's celestials atlas, with their own shading.
- Ambient light optionally follows the shared sky colour estimate and its sunset controls.

## Clouds and fog

- Local mist banks, turned on by Local Mist Amount on the Fog screen. Density changes along all
  three world axes within the Fog Height range, and shapes the normal morning and after-rain
  mist too. Banks are 32 blocks wide and 16 blocks tall, giving shape and range you can see over
  close paths. Solid objects and the aerial table read the mist directly; direct sunlight through
  it uses the normal terrain shadow check. Mist blocking its own light, and matching fog on
  particles, are not done yet.

- Volumetric cloud march composited in linear HDR **before** the tonemap, so sunlit cloud tops go
  past display white and bloom. Fast / Fancy (half-res) and Ultra (full-res) tiers, with altitude,
  amount and speed controls. *Opt-in, default off: it is the most costly per-pixel effect here.*
- Distance fog, on by default, doing two jobs: haze that pools in valleys and thins with height, and
  a border veil that reaches full strength right at the render limit so chunks fade out instead of
  popping. Both take the sky's own colour along the view ray, so fogged terrain matches the sky
  beside it instead of turning grey against it.

## Lighting

- *Experiment, on by default:* Debug → Local Coloured Light replaces vanilla placed block light
  on every surface with voxel direct lighting. There is no vanilla fallback for missing data or
  unsupported lamps. Sun/sky, held light and self-emission remain. Sources opt in through
  `lighting.voxel` in `blocks.toml`; their emission and textures determine colour and intensity.
  Mapped full source faces light actual visible surfaces, including grass and foliage. Visibility
  uses geometry and cutout alpha. The 12-block source range is independent of camera distance;
  adding lamps does not invalidate the existing lights. Known thin subsurface cutouts can transmit
  light; opaque grass backing cannot. This is not bounced GI, and partial lamps remain unsupported.
  Full opaque alcove walls clip the visible source area continuously. Other silhouettes retain
  four shadow samples per face. Static light textures work on overflow atlas pages as well as
  the base page; animated overflow sprites remain unsupported.
  Visible emission and received light share the calibrated scale in either local-light mode;
  switching both modes off keeps legacy lighting.
  The owner has checked the direct-light appearance in game; its GPU cost remains high.
- *Experiment, off by default:* Ray Tracing → Traced Block Light sends one hardware ray per active
  cell of a 512x512 grid toward a glowing block. Source selection follows its RGB material
  contribution, with a fresh point sampled on its face each frame.
  With Local Coloured Light enabled, RT handles nearby receivers and voxel probes handle distant
  ones. Traced Block Light Distance defaults to two chunks, with a one-chunk transition; covered
  nearby pixels skip the voxel probes. Both estimators use the same sources and material response.
  Missing current RT answers use voxel coverage when available, without restoring vanilla block
  light. The grid averages RGB estimates over up to 24 frames. RT-only mode can keep a held
  estimate while waiting for a current answer. Needs a ray-tracing tier; without one RT-only
  direct light is unavailable. Switching traced shadows does not change visible lamp emission.
  The distance handoff's appearance and frame cost still need a client check.
- *Experiment, off by default, not yet checked in game:* Ray Tracing → Bounce Light works with any
  lighting setup and adds one bounce on top: one ray per grid cell, and at the hit a sun ray and a
  lamp ray, so a lit wall lights the floor in front of it and a lamp's light reaches a second
  surface. Averaged over up to 24 frames per cell against last frame's once-spread light, with
  the luminance's first two moments kept beside it, then spread by four variance-guided steps
  (one, two, four and eight cells) that stop on facing, on distance from the cell's plane and
  on a brightness gap measured in the cell's own standard deviations. History is kept when the
  point seen at the old spot lies in the cell's plane, so walls at a grazing angle hold it while
  walking. Stationary views also retain four separate surface estimates per cell through changing
  cutout coverage; these expire after 24 unobserved frames and clear when the camera changes.
  Commanded time jumps discard stale bounce light and exposure history immediately.
  Longer AA cycles or more than four recurring surfaces can still exhaust that cache. Bounce
  Light Strength scales the lamp share of the bounce only. There is no emission
  term at the hit and no second bounce.
- *Experiment, default Quarter block:* Debug → Local Light Source Size sets how much of each lit
  face casts light: Quarter block, Half block or Full face. Smaller gives sharper shadows from
  thin blocks such as a fence post or a hopper; Full face is the softest. The light's total energy
  is the same at every setting.
- *Test feature, default Off:* Test Views → Test View: Light Sources shows which sections hold a light
  source and whether each section's data is current. F10 records the counts. This is a first step
  toward coloured local lighting; it adds no light and still needs checking in game.
- *Test feature, default Off:* Debug → Source Colour Preview shows terrain emission alone, or
  compares existing emission on the left with a material-only source rule on the right. Both use
  the same fixed display mapping. It adds no surrounding light; the candidate needs owner review
  before it becomes a normal lighting rule.
- Two light models to pick from. **Physical** works sunlight colour out from air mass and torchlight
  from blackbody temperature; **Custom** is a hand-written day/sunset/night colour table, editable
  per arm. Physical is the default, picked in game knowing a physical sunset is the dimmer of the
  two.
- Day, night and sunset colour tables decoded out of display space into the linear pipeline, so
  midnight is truly dark rather than a dimmed noon.
- Emissive blocks glow from vanilla's own light emission level; labPBR painted emission is handled
  on its own, with its own strength control, so ores glint without rescaling glowstone or lava.
- Block light colour temperature control; a screen-brightness lift that raises night and rain only,
  leaving clear daylight alone.
- Deferred lighting shades terrain, entities, solid particles and entity shadows through one resolve.
  Translucent particles and banner patterns take a forward path instead, so their blending survives
  and they still get the pack's fog.

## Shadows

- PCF shadow filtering. Resolution 1024/2048/4096, 2-16 taps per side, distance
  16-512 blocks in chunk steps, plus softness and strength.
- Shadows fade out over the last quarter of their distance rather than ending at a hard edge.
- Ray-traced sun and moon shadows: a toggle plus an RT Shadow Distance slider, in chunks. Default
  2 chunks (32 blocks), range 1 to 16. This sets how far from you shadows use ray tracing, capped
  by the normal Shadow Distance. A block far away or high up can still cast a shadow onto ground
  close to you.
- Past that range, or where ray data is missing, shadows fall back to the normal shadow map.
  Shadows from mobs and players still combine with the ray-traced ground shadows. Softness,
  Samples, rain spread, Strength and ambient darkening apply to ray-traced shadows too.
- Ray tracing covers ground, water light shafts, caustics, reflections and fog through one shared
  step. In the shadow debug view, cyan means ray-traced, gray means the normal shadow map, and
  brightness shows how much light gets through. Cloud shadows are handled on their own.
- The normal shadow map still runs everywhere, as a backup and for far-away ground. Ray tracing is
  extra work on top of it, not a free swap for it.
- The offline tests check the numbers only. Seeing how it looks and runs needs a real game session.
- Optional suppression of vanilla's blob shadows and vanilla's rain-splash particles.

## Ambient occlusion

- Screen-space AO from the depth buffer, with 4/8/16 taps, radius and strength, a per-pixel rotated
  sample pattern and build-up across frames.
- Multiplies with labPBR texture-baked AO, which has its own control.

## Reflections

- Screen-space reflections: one mirror ray per pixel marched through a Hi-Z depth pyramid, blurred by
  roughness, built up across frames, blended so it adds no light that was not there, with a
  procedural-sky fallback for rays that leave the screen. The mirror direction does not vary with
  screen-pixel noise; roughness stays in the reflection filtering.
- Two real tiers: Fancy at full resolution and Fast at half resolution with a joint-bilateral
  upsample. Fast is a quarter of the rays, not a coarser ray. Controls for strength, distance and
  step budget.
- World Reflections fills missing opaque and water reflections from nearby world geometry, on by
  default while the view is above water. Needs SSR on; water also needs Reflective mode. Positive
  opaque screen hits keep their existing image and confidence. Opaque recovery uses one sample per
  8x8 SSR pixels and rejects incompatible neighbouring surfaces; mirror detail can look coarse and
  thin or sharply bumped reflections can remain unresolved. Its cost
  rises with visible reflective area and nearby lights. Voxel Reach sets its window: 1 to 16 chunks in
  one-chunk steps, default 4. Both controls sit under Reflections; the coverage overlay is on
  Debug.
- The player shows up in reflections: in water, on shiny floors and on shiny walls, whenever
  Reflections are on. Three `player_mirror` passes draw the player, three `player_mirror_resolve`
  passes light that picture with sun and shadow, and the reflection passes use it before falling
  back to the screen or the sky. Normal maps are not used on the reflected player.

## Water

- Four modes: off, forward highlights, traced, and high. The upper two hand water to a deferred chain
  with its own surface capture, wave normals, reflection trace and HDR composite.
- Multi-octave wave field (2-6 octaves) where shorter waves travel slower, scaled so detail changes
  without changing total steepness; separate wave strength control.
- One medium for every view of the water (`shaders/include/water_medium.glsl`): absorption from
  Pope & Fry, a small flat scattering term, and the depth fall-off of sky light after Kirk. The
  surface seen from the shore, the veil seen from under it, the light shafts and the light left on a
  sunken block all read the same numbers, so a lantern on the bottom keeps its colour across the
  surface.
  Per channel: red goes in the first few blocks, blue lasts tens. One control, Water Clarity, scales
  the lot.
- The surface reads the scene behind it and writes the composed pixel whole, so the bed is absorbed
  per channel rather than dimmed by one grey alpha.
- Shoreline foam placed by water depth, so it hugs every coast and sandbar without edge detection.
- Its own reflection trace and temporal blur, reprojected by a motion vector taken from the water
  surface itself rather than the seabed behind it.

## Underwater: *in active tuning*

- The underwater veil is the medium's own scattered light: sky light at the eye's depth,
  scattered along the view ray, brighter looking up toward the surface and dimmer looking down,
  fading with the same per-channel loss the surface uses. A ray that meets nothing ends in the
  same closed volume the render edge seals on. No colour, distance or darkness sliders: the water
  decides.
- Depth-graded blur of the sunken scene.
- Texture-driven caustics thrown onto the seabed, from a commissioned tileable pattern sampled as
  two rotated flowing layers. Scale, speed and strength controls.
- Snell-window underside: looking up from below, the world squeezes into the window and the rest of
  the surface mirrors the scene below (exact dielectric Fresnel, true TIR past ~48.6 degrees).
- The window itself has real moving structure: the wave normal bends which sky direction it shows,
  and a single sun/moon glint tracks the true celestial direction through that same bending. A
  richer version (slope-driven shimmer plus a drawn sun disc) is deliberately left out: at usable
  gain the wave field's mean tilt saturated over a third of the surface into a flat "white marble"
  wash whatever the view, so the underside is this narrower, calmer pair rather than a broad shimmer
  effect.

## Materials

- labPBR support: normal, AO, roughness, metalness, porosity, subsurface, painted emission.
  **No IPBR:** Plague is labPBR or vanilla, decided day one.
- Parallax occlusion mapping with self-shadowing, a distance fade rather than a cutoff line, an
  opt-in cutout-block arm, and three diagnostic views. Quality, depth and distance controls.
  Deferred motion follows the virtual height hit on orthogonal UV charts whose sprite axes each
  span one block. Other mappings retain polygon motion. Physical depth and light-ray origins stay
  on the model surface.
- Surface wetness scaled by labPBR porosity; wet surfaces darken and slick up.
- Puddles that form where rain collects and dry slowly after it stops.
- Puddle ripples keyed off rain actually falling, held to the deeper middle of each puddle.
- Separate rain-splash rings on water and puddles, each on its own grid cell with its own timing,
  working by tilting the surface so they catch light and reflections.
- Metals reflect with their own colour; grazing angles get their sheen.
- Experimental glass transport in voxel and traced lighting: certified box unions, including
  supported connected panes, have entry and exit refraction, Fresnel reflection and
  thickness-dependent RGB absorption. Photon paths illuminate
  their receiving surfaces at full pixel resolution, preserving albedo, normal and roughness detail.
  Source-anchored photon samples retain RGB energy and incoming directions across camera motion.
  The current material and view are shaded afresh, without a caustic colour-history settling window.
  Geometry and source changes rebuild the local photon set before shading. Finite sampling can
  leave spatial error. Camera paths sum the first interface's Fresnel reflection and transmission,
  with later boundaries still sampled stochastically. Unsupported models or unresolved paths retain
  their vanilla-lit material tint and screen-space effect, which does not transport light through
  their volume. The sampling and material changes have offline checks; their GPU appearance and
  performance require a client check.

## Snow: *opt-in, default off*

- Static snow dusting on open upward-facing surfaces, placed by world-space noise so it is nailed to
  the world and never swims. Which biomes get it comes from vanilla's own per-block precipitation
  type; what counts as sheltered comes from vanilla's sky light, so canopies and doorways stay bare.
- A separate foliage arm that puts snow only on leaf planes tilted toward the sky.

## Post

- Seven-level HDR bloom pyramid, no threshold, blending toward the blurred image rather than adding
  a clipped highlight pass on top.
- Four tonemap operators, named as the settings screen names them: **None (clip)**, kept as an
  honest baseline; **Filmic**, a parametric curve with dark lift, path-to-white and dark
  desaturation; **ACES**; and **Reinhard**.
- Exposure applied before the curve; saturation and contrast applied after, on display values.

## Focus blur

- A camera-lens depth of field: focal length and f-stop set the blur through the thin-lens
  law, autofocus follows the middle of the screen with a smoothed pull, and bright lights
  grow into round discs through a half-resolution golden-angle gather over a four-level
  pyramid. Bloom is folded into the picture before the blur, so glow takes the disc shape
  too. A close object's blur spreads over what is behind it; light from behind a surface
  never bleeds forward through it.
- A by-distance mode with no focus tracking: everything past a set number of chunks goes
  gently soft. This mode ships ON, tuned to a whisper of far haze.
- A Photo quality choice doubles the gather samples, and a Highlight Boost slider keeps
  small bright spots shining inside the blur.
- **True Camera Stills, experimental and off by default**: stand perfectly still and the
  engine looks through a different part of the lens each frame; the picture converges to a
  real exposure with nothing faked. Known to shimmer with ray traced lighting on.

## World outline

- Lines along the world's geometric edges, from a centred second difference of the depth buffer. It
  answers to a jump in distance (a silhouette) and a kink in the depth field (a block corner), and to
  nothing else. A flat surface at any angle and distance answers with algebraic zero, so a floor seen
  at a grazing angle stays clean by construction rather than by a tuned threshold.
- Convex and concave edges have separate strengths, both swinging through zero, so either channel
  brightens or darkens the surface's own colour. The lift scales with the lit surface down to black;
  no neutral brightness floor reveals unlit edges. Thickness only widens: what counts as an edge is an angle,
  free of tap radius, resolution and field of view.
- Leaves, grass and fences are skipped by default, read off the G-buffer surface class. Every leaf
  gap is a real depth break, so foliage otherwise draws as a mass of lines.
- It outlines geometry, not blocks. A flat wall of a hundred stone blocks gets one outline around the
  wall, not a grid. Water, glass and the held item are never outlined; they draw after the graph.
- Nothing is outlined under water, seen through a surface or with the camera under water. A stepped
  bed at a grazing angle puts a huge number of real one-block edges in frame at once, over an image
  refraction has already softened.
- Lines fade over the last quarter of Outline Distance, which also makes the effect cheaper: nothing
  past the fade is computed.

## Verification tooling

Sixteen offline Python verifiers redo shader maths (noise, marches, wave fields, colour decode,
parallax, fog, caustics) and draw PNGs for numeric comparison, so behaviour is checked without
launching the game. A pre-commit hook flattens imports and runs `glslangValidator` over every pass
and refuses commits whose shaders do not compile.

---

## Known gaps

- **Light shafts / god rays are not shipped.** No implementation, render option or pass wiring for
  them is in the tree.
- **Underwater is in active tuning.** The chain works end to end but constants are still moving.
- Reflected sky has no clouds in it: reflection rays that leave the screen fall back to the procedural
  sky function, which the cloud march runs after.
- Vanilla draws rain and snow. Plague's weather lives on the ground (wetness, puddles, ripples,
  splashes) because vanilla's precipitation is per-column and a camera-centred pass cannot be.
- Moving night-sky content (shooting stars) leaves a temporal trail until the camera moves.
- The nebula reads more like cloud than like a nebula. Whether to diverge is still an open decision.
