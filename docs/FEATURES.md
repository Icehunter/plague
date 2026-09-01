# Plague: feature set

What is **currently working**, verified against `graph.toml`, `screens.toml` and the shader tree.
Anything experimental, opt-in or unfinished is marked as such.

Plague is a shaderpack for the Fornax engine (see `README.md` for what that split means); this file
covers what the pack itself does, not the engine underneath it.

---

## Sky

- Procedural sky dome: a nine-colour day/night gradient, a separate sunset horizon band, horizon
  scattering, and sun and moon glare.
- Stars, with amount, size, roundness and softness controls.
- Night nebula (intensity, zoom, amount).
- Shooting stars (count, speed, frequency).
- Aurora borealis: a marched curtain with Smooth and Blocky styles, an every-clear-night or
  full-moon-only condition, and detail/size/intensity/quality controls.
- Sun and moon discs drawn from vanilla's celestials atlas, with their own shading.
- Ambient light optionally read off the rendered dome, so the sky and what it lights agree by
  construction as the sky reddens.

## Clouds and fog

- Volumetric cloud march composited in linear HDR **before** the tonemap, so sunlit cloud tops exceed
  display white and actually bloom. Fast / Fancy (half-res) and Ultra (full-res) tiers, with altitude,
  amount and speed controls. *Opt-in, default off: it is the most expensive per-pixel effect here.*
- Distance fog, on by default, doing two jobs: aerial perspective that pools in valleys and thins with
  altitude, and a border veil that reaches full strength exactly at the render limit so chunks dissolve
  instead of popping. Both take the sky's own colour along the view ray, so fogged terrain becomes
  indistinguishable from the sky beside it rather than turning grey against it.

## Lighting

- Two selectable light models. **Physical** derives sunlight colour from air mass and torchlight
  from blackbody temperature; **Custom** is an authored day/sunset/night colour table you can edit
  per arm. Physical is the default, chosen in game knowing a physical sunset is the dimmer of the
  two.
- Day, night and sunset colour tables decoded out of display space into the linear pipeline, so
  midnight is genuinely dark rather than a dimmed noon.
- Emissive blocks glow from vanilla's own light emission level; labPBR painted emission handled
  separately with its own strength control, so ores glint without rescaling glowstone or lava.
- Block light colour temperature control; a screen-brightness lift that raises night and rain only,
  leaving clear daylight untouched.
- Deferred lighting shades terrain, entities, solid particles and entity shadows through one resolve.
  Translucent particles and banner patterns ride a forward path instead, so their blending survives and
  they still receive the pack's fog.

## Shadows

- PCF shadow filtering. Resolution 1024/2048/4096, 2-16 taps per side, distance
  16-512 blocks in chunk increments, plus softness and strength.
- Shadows fade out over the last quarter of their distance rather than ending at a hard edge.
- Optional suppression of vanilla's blob shadows and vanilla's rain-splash particles.

## Ambient occlusion

- Screen-space AO from the depth buffer, with 4/8/16 taps, radius and strength, a per-pixel rotated
  sample pattern and temporal accumulation across frames.
- Multiplies with labPBR texture-baked AO, which has its own control.

## Reflections

- Screen-space reflections: one mirror ray per pixel marched through a Hi-Z depth pyramid, blurred by
  roughness, accumulated temporally, blended energy-conservingly, with a procedural-sky fallback for
  rays that leave the screen.
- Two real tiers: Fancy at full resolution and Fast at half resolution with a joint-bilateral upsample.
  Fast is a quarter of the rays, not a coarser ray. Controls for strength, distance and step budget.

## Water

- Four modes: off, forward highlights, traced, and high. The upper two hand water to a deferred chain
  with its own surface capture, wave normals, reflection trace and HDR composite.
- Multi-octave wave field (2-6 octaves) where shorter waves genuinely travel slower, normalised so
  detail changes without changing total steepness; separate wave strength control.
- Per-channel absorption, so deep water goes blue-green then dark rather than merely dim; clarity control.
- Shoreline foam placed by water depth, so it hugs every coast and sandbar without edge detection.
- Its own reflection trace and temporal blur, reprojected by a motion vector derived from the water
  surface itself rather than the seabed behind it.

## Underwater: *in active tuning*

- Depth-graded underwater veil, with an ocean depth floor.
- Depth-graded blur of the submerged scene.
- Texture-driven caustics projected onto the seabed, from a commissioned tileable pattern sampled as
  two rotated flowing layers. Scale, speed and strength controls.
- Snell-window underside: looking up from below, the world compresses into the window and the rest of
  the surface mirrors the scene below (exact dielectric Fresnel, true TIR past ~48.6 degrees).
- The window itself has real moving structure: the wave normal refracts which sky direction it
  shows, and a single sun/moon glint tracks the true celestial direction through that same
  refraction. A richer version (slope-driven shimmer plus a rendered sun disc) was tried and
  deliberately removed: at usable gain the wave field's mean tilt saturated over a third of the
  surface into a flat "white marble" wash regardless of view, so today's underside is intentionally
  this narrower, calmer pair rather than a broad shimmer effect.

## Materials

- labPBR support: normal, AO, roughness, metalness, porosity, subsurface, painted emission.
  **No IPBR:** Plague is labPBR or vanilla, decided day one.
- Parallax occlusion mapping with self-shadowing, distance fade rather than a
  cutoff line, an opt-in cutout-block arm, and three diagnostic views. Quality, depth and distance
  controls.
- Surface wetness scaled by labPBR porosity; wet surfaces darken and slick up.
- Puddles that form where rain collects and dry slowly after it stops.
- Puddle ripples keyed off rain actually falling, confined to the deeper middle of each puddle.
- Discrete rain-splash rings on water and puddles, each on its own grid cell with its own timing,
  working by tilting the surface so they catch light and reflections.
- Metals reflect with their own colour; grazing angles get their sheen.
- Refraction through glass, ice and stained panes, bent by each pane's own labPBR F0. Packs that
  paint no material map fall back to the format's glass entry rather than refracting nothing.

## Snow: *opt-in, default off*

- Static snow dusting on exposed upward-facing surfaces, placed by world-space noise so it is nailed to
  the world and never swims. Which biomes get it comes from vanilla's own per-block precipitation type;
  what counts as sheltered comes from vanilla's sky light, so canopies and doorways stay bare.
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
  responds to a jump in distance (a silhouette) and a kink in the depth field (a block corner), and
  to nothing else. A flat surface at any orientation and distance responds with algebraic zero, so a
  floor seen at a grazing angle stays clean by construction rather than by a tuned threshold.
- Convex and concave edges have separate strengths, both swinging through zero, so either channel
  draws a white line or an ink one. Thickness only widens: what counts as an edge is an angle,
  independent of tap radius, resolution and field of view.
- Leaves, grass and fences are skipped by default, read off the G-buffer surface class. Every leaf
  gap is a real depth discontinuity, so foliage otherwise draws as a mass of lines.
- It outlines geometry, not blocks. A flat wall of a hundred stone blocks gets one outline around the
  wall, not a grid. Water, glass and the held item are never outlined; they draw after the graph.
- Nothing is outlined under water, seen through a surface or with the camera submerged. A stepped bed
  at a grazing angle puts a huge number of real one-block edges in frame at once, over an image
  refraction has already softened.
- Lines fade over the last quarter of Outline Distance, which also makes the effect cheaper: nothing
  past the fade is computed.

## Verification tooling

Sixteen offline Python verifiers reproduce shader maths (noise, marches, wave fields, colour decode,
parallax, fog, caustics) and render PNGs for numeric comparison, so behaviour is checked without
launching the game. A pre-commit hook flattens imports and runs `glslangValidator` over every pass and
refuses commits whose shaders do not compile.

---

## Known gaps

- **Light shafts / god rays are not shipped.** The discarded implementations, render options, and
  pass wiring have been removed.
- **Underwater is in active tuning.** The chain works end to end but constants are still moving.
- Reflected sky has no clouds in it: reflection rays that leave the screen fall back to the procedural
  sky function, which the cloud march runs after.
- Vanilla draws rain and snow. Plague's weather lives on the ground (wetness, puddles, ripples,
  splashes) because vanilla's precipitation is per-column and a camera-centred pass cannot be.
- Moving night-sky content (shooting stars) leaves a temporal trail until the camera moves.
- The nebula reads more like cloud than like a nebula. A divergence is
  still an open decision.
