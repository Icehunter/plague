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
  layer. The render-edge veil fades into the sky along the same ray. The night-sky gate follows the
  scattering dome. Shared palette estimates still supply surface ambient, water illumination,
  cloud direct lighting, reflection-probe clouds, smoke and banner fog; their controls remain active.
- Stars, with amount, size, roundness and softness controls.
- Night nebula (intensity, zoom, amount).
- Shooting stars (count, speed, frequency).
- Aurora borealis: a marched curtain with Smooth and Blocky styles, an every-clear-night or
  full-moon-only condition, and detail/size/intensity/quality controls.
- Sun and moon discs drawn from vanilla's celestials atlas, with their own shading.
- Ambient light optionally follows the shared sky colour estimate and its sunset controls.

## Clouds and fog

- Volumetric cloud march composited in linear HDR **before** the tonemap, so sunlit cloud tops go
  past display white and bloom. Fast / Fancy (half-res) and Ultra (full-res) tiers, with altitude,
  amount and speed controls. *Opt-in, default off: it is the most costly per-pixel effect here.*
- Distance fog, on by default, doing two jobs: haze that pools in valleys and thins with height, and
  a border veil that reaches full strength right at the render limit so chunks fade out instead of
  popping. Both take the sky's own colour along the view ray, so fogged terrain matches the sky
  beside it instead of turning grey against it.

## Lighting

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
- Optional suppression of vanilla's blob shadows and vanilla's rain-splash particles.

## Ambient occlusion

- Screen-space AO from the depth buffer, with 4/8/16 taps, radius and strength, a per-pixel rotated
  sample pattern and build-up across frames.
- Multiplies with labPBR texture-baked AO, which has its own control.

## Reflections

- Screen-space reflections: one mirror ray per pixel marched through a Hi-Z depth pyramid, blurred by
  roughness, built up across frames, blended so it adds no light that was not there, with a
  procedural-sky fallback for rays that leave the screen.
- Two real tiers: Fancy at full resolution and Fast at half resolution with a joint-bilateral
  upsample. Fast is a quarter of the rays, not a coarser ray. Controls for strength, distance and
  step budget.
- Voxel SSR Recovery fills missing above-water reflections from nearby world geometry, on by
  default. Needs reflective water and SSR on. Voxel Reach sets its window: 1 to 16 chunks in
  one-chunk steps, default 4. Both controls sit under Reflections; the coverage overlay is on
  Debug.

## Water

- Four modes: off, forward highlights, traced, and high. The upper two hand water to a deferred chain
  with its own surface capture, wave normals, reflection trace and HDR composite.
- Multi-octave wave field (2-6 octaves) where shorter waves travel slower, scaled so detail changes
  without changing total steepness; separate wave strength control.
- Per-channel absorption, so deep water goes blue-green then dark rather than only dim; clarity
  control.
- Shoreline foam placed by water depth, so it hugs every coast and sandbar without edge detection.
- Its own reflection trace and temporal blur, reprojected by a motion vector taken from the water
  surface itself rather than the seabed behind it.

## Underwater: *in active tuning*

- Depth-graded underwater veil, with an ocean depth floor.
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
- Surface wetness scaled by labPBR porosity; wet surfaces darken and slick up.
- Puddles that form where rain collects and dry slowly after it stops.
- Puddle ripples keyed off rain actually falling, held to the deeper middle of each puddle.
- Separate rain-splash rings on water and puddles, each on its own grid cell with its own timing,
  working by tilting the surface so they catch light and reflections.
- Metals reflect with their own colour; grazing angles get their sheen.
- Refraction through glass, ice and stained panes, bent by each pane's own labPBR F0. Packs that
  paint no material map fall back to the format's glass entry rather than bending nothing.

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

## World outline

- Lines along the world's geometric edges, from a centred second difference of the depth buffer. It
  answers to a jump in distance (a silhouette) and a kink in the depth field (a block corner), and to
  nothing else. A flat surface at any angle and distance answers with algebraic zero, so a floor seen
  at a grazing angle stays clean by construction rather than by a tuned threshold.
- Convex and concave edges have separate strengths, both swinging through zero, so either channel
  draws a white line or an ink one. Thickness only widens: what counts as an edge is an angle,
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
