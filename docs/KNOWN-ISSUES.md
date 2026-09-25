# Known issues

Open defects, one line each, with where the fix would go. Anything not listed here is either working
or not yet noticed; this file is not a wish list, and a fixed issue is deleted rather than struck
through.

The long write-up behind each of these lives outside the repository with the rest of the working
notes; what is here is what a reader needs to know the limit exists.

## Water

- **Near-silhouette SSR puts the wrong reflection in** where a water edge meets geometry.
- **The underwater shaft ray does not follow the shaft angle**, so shafts and their light disagree
  at low sun.
- **Floor caustics are a texture, not the focused image of the wave surface.** They repeat, and the
  pattern does not match the crests above it. The machinery to work it out properly is already in
  `shaders/include/water_volume.glsl`.

## Atmosphere

- **Camera rotation can shift opaque fog when anti-aliasing is off.** `shaders/post/fog_composite.fsh` reads current depth and adds fog in one step; whether this holds up during motion is not yet checked in game.
- **The climate signal snaps at biome borders**, so fog character can change sharply across a line.
- **Thunder is not its own fog driver.** Heavy weather reads as ordinary rain.
- **The sun's glow bleeds into fog through terrain farther than the shadow distance.** The fog
  march's sun gate (`shaders/include/atmo_shadow.glsl`) can only see casters inside the shadow
  map; a heightfield sun-horizon fed from the engine's coarse weather clipmap is the planned fix.
- **Ray traced light flashes under the Off and TAAU anti-aliasing modes.** The pack's temporal
  pass only runs under TAA (engine `TemporalPassRunner.accumulationLive`), so nothing integrates
  the trace noise in the other modes.
- **Metal allows only 16 live samplers per fragment shader.** The material resolve and fog composite each use 13 with ray-traced shadows on (`tools/check_surface_metal_compat.py` checks the normal and debug builds); adding more inputs needs a fresh count on real hardware.
- **A lit patch of fog between two sheltered points can lose its direct light** (`shaders/include/fog_aerial.glsl`). Fixing the sky-light guard at cave mouths needs a way to measure enclosed spaces that still keeps caves dark.
- **Sharp shadow edges in fog stay blurry from some angles** (`shaders/include/atmo_lut.glsl`). A test with a hard-edged shape still shows 17.42% error in total light, even though the same-ray extension is stable; shadow sampling needs an accuracy check across angles, not just motion.
- **Under the scattering sky, a cloud's DIRECT sun/moon light still comes from the palette**
  (`lighting.light` / `plagueMoonColor` in `shaders/include/clouds.glsl`), so a cloud's lit side can
  disagree with the air under it at dusk. A table-lit direct term was tried and turned down by eye:
  clouds under a low deck's horizon went grey where the palette keeps them warm. Open. (A cloud's
  ambient and its distance fade-to-sky DO read the scattering tables through
  `clouds_march_volume.comp`, with the pack's own sunset-band warmth on the fade;
  only the direct term is still palette-based.)
- **The sun disc's own brightness is not on the dome's exposure ladder** (`PLAGUE_ATMO_SKY_GAIN`,
  the twilight adaptation): it is gated off at sunset (`sunSetGate` in `gbuffer_resolve.fsh`) so
  it does not sit bright on a dark sky, but while it is up its brightness is still
  `plagueSunColor`'s own analytic calibration, free of the table gain. Not attempted: doing so with
  no gate blew out the disc at noon, where the un-gained disc is the accepted look.
- **The scattering march does not apply atmospheric refraction.** A real sun is visible about
  0.833 degrees (34 arcmin refraction plus its own 16 arcmin radius) past where its geometric
  position would predict, which is why the disc's own set gate is offset by exactly that much; the
  dome and aerial marches still use the un-bent direction, so the sky's own colour keeps shifting
  about that much earlier than the disc vanishes. Measured as a small effect on the sunset's warmth,
  not attempted here.
- **A far hill dissolved by the render-edge veil still hides the clouds behind it**, leaving a
  sky-coloured cutout with no cloud in it (`shaders/post/clouds_composite.fsh` tests cloud depth
  against terrain depth). A see-through weight on the veil was tried and turned down: at partial veil
  it painted horizon cloud over terrain still in view.
- **Smoke and banner fog use the palette haze under the scattering sky.** Those slots draw through
  vanilla pipelines that get no pack inputs, so they cannot read the aerial table; an engine change.
  The smoke-fog mismatch below is the same seam.
- **The scattering sky's twilight ends about five degrees earlier than the palette's.** Through
  civil twilight the adaptation gain (`PLAGUE_ATMO_TWILIGHT_GAIN`) keeps the sun-side glow at the
  palette's level; past six degrees below the horizon the sun reaches only the air above 15 km
  and the glow is a fifth of the palette's by eight. Real skies keep more from high aerosol the
  model does not carry. About twenty seconds of game time.
- **Water and reflection code rebuild full-color light loss from one stored channel** (`plagueAtmoTransmittanceChroma` in `shaders/include/atmo_lut.glsl`). Matching areas where mist mixes unevenly with air needs full-color light-loss data, the same as the solid-surface path uses.

## Clouds

- **Distant cloud detail still shimmers under temporal AA.** `shaders/include/clouds.glsl` reduces march samples with distance while `shaders/include/cloud_density.glsl` retains fine density detail; no pixel footprint reaches that density evaluation. Cloud history also rejects many moving or overlapping contributors. Close this after the owner's camera-motion comparison stays stable without changing cloud coverage or losing body; phase and motion-vector checks alone do not establish that.
  The 2026-09-13 composite change uses positive cubic reconstruction to reduce spatial stippling.
  Saved-input checks establish filtering and visibility; some pattern remains in the reconstructed
  capture, and camera-motion stability is still unverified.
- **Square cloud borders remain under investigation.** The 2026-09-13 saved weather buffer
  reproduced a derivative crease at the square edge of the precipitation sampling region.
  `shaders/include/precip_field.glsl` joins the interior coordinates to the bounded extension
  smoothly over one existing interpolation cell. GPU probes confirm the join and unchanged inner
  region; they do not establish that every photographed border comes from this field. Allocation
  shapes and the nighttime seam remain separate open possibilities.
- **A distant cloud can draw in front of a nearer one.** An opacity/transparency issue, not the
  separately tracked boxy/grid allocation-lattice shape issue. Root cause: the decks overlap in
  space. `shaders/compute/clouds_march_volume.comp` marches each deck on its own and blends the
  results in the order of one distance per deck, but nimbostratus encloses the cumulus slab and
  stratocumulus overlaps its lower half, so no per-deck order is right. Measured with the clouds
  held still (`u_CloudSpeed = 0`) and the camera fixed: the wrong order sits steady instead of
  flickering, which rules out the step and dither pattern and leaves the overlap. The fix is to
  march the live decks together across the whole span they cover and blend front to back in one
  pass, not to order seven separate results better.
- **A stratiform layer shows a flat horizontal seam where it thins.** Seen as a straight
  light-toned line through the layer rather than a cloud edge. Suspected to be the slab's own top or
  bottom plane showing once the vertical profile saturates before it reaches the boundary. Matters
  most for anything at eye level, so fix this before the march runs for ground fog or mist, which
  show it edge-on all the time. A later capture also shows a straight seam in the night sky near
  the crosshair; it may be the same cause. Check `shaders/compute/clouds_march_volume.comp`,
  `shaders/compute/atmo_skyview.comp`, and `shaders/post/clouds_composite.fsh`. Close this once the
  sky stays smooth in game, including camera movement. A 2026-09-13 probe of all seven decks using
  the saved daytime state found zero density at and outside the nominal slab faces. That probe
  did not support slab clipping as the cause in that state and does not settle the nighttime report.
- **A cloud grows and gains density as the sun passes behind it.** The silhouette widens, not just
  the glow around it. Most visible against a small isolated cumulus. The moon behind the same cloud
  does nothing, which fits the march lighting from the sun alone: the moon is no directional source
  for it. The lead is the forward-scattering lobe in `shaders/include/clouds.glsl`. Looking toward
  the sun puts cosLight near 1, the phase peak brightens the thin margins, and material that sat
  below visibility crosses it, so the cloud reads both larger and thicker. Forward scatter belongs
  there; the open question is its size, and whether the growth tracks
  PLAGUE_CLOUD_PHASE_FORWARD or the multiple-scattering octaves. Not measured.
- **Distant cloud loses structure when seen from above.** The deck reads as a flat blurred sheet
  toward the horizon. The march spends a fixed step budget over the whole span, so a long grazing
  ray stretches its steps (`PLAGUE_CLOUD_STEP_RANGE` grows them geometrically once the budget stops
  covering the span), and the composite is half resolution below the Ultra tier. Which of the two
  dominates is not measured.

## Particles

- **Forward-translucent draws (particles, banner patterns) do not warp with the water-entry/exit
  camera distortion.** They draw after `GraphRunner.finishDeferred()` (fornax's
  `FeatureSolidFeaturesGraphMixin`), which is where tonemap's remap runs; nothing after that point
  in the frame can be reached by it. Moving that boundary later breaks banner patterns and other
  blended geometry, so this is a structural limit, not a quick fix.
- **Campfire/torch smoke's fog does not match the deferred fog behind it.**
  `shaders/blocks/particles_translucent.fsh` hand-rolls its own `plagueFogTerms` call since it draws
  after the real fog pass finishes, and the approximation drifts from the real fog enough that
  smoke reads as floating in front of it rather than sitting inside it.

## Materials

- **`u_PomShadowStrength` has no visible effect.** The slider moves and nothing changes.
- **The normal-atlas magnification filter shapes the POM read**, so parallax depth depends on a
  texture filter setting rather than only on the material.

## World outline

- **Bare uneven terrain draws densely.** A cliff or open hillside is thousands of one-block steps,
  every one a real 90 degree edge, so it reads as a lattice rather than outlined shapes. No per-pixel
  test separates that from architecture: the edge-magnitude spreads overlap. Lowering
  Outline Distance is the only lever today. A regional density filter over a much wider neighbourhood
  is the untried fix. `shaders/include/outline.glsl`.
- **Lines shimmer by up to half a pixel as frames build up.** The projection is jittered, so
  the depth read is sub-pixel offset each frame while the colour was resolved unjittered. Worst at
  thickness 1. A fix needs an unjittered depth buffer, which the G-buffer does not carry.
- **A band at the frame edge, as wide as the tap radius, draws no lines.** The border early-out in
  `plagueOutlineFold`. Every alternative breaks stencil symmetry and makes it answer to slant.
- **Terrain seen through a leaf gap can draw a faint line on the wall behind.** A leaf close in front
  of a surface hides the surface, not the leaf.

## Performance

- **The test local-air fog step is slower than the speed target** (`shaders/include/atmo_lut.glsl`). A test at 1728 × 1084 measured about 7.6 ms with the compute-based version, against 4.0 ms without local fog. This does not show the cost of the new one-pass graphics version; sharing light data between frames is future work, once the math is confirmed correct.

- **Water scenes run around 55 FPS** against 75 to 110 elsewhere. A long-standing cost rather than a
  recent regression, and not yet measured per-feature.

- Experimental local lighting supports mapped full source faces, not partial lamps. It has a finite
  12-block source range, four area samples per face and a 4096-cell admitted-source capacity;
  pending/unknown data contributes no light. Thin-sheet transmission and harvested cutout geometry
  are approximations. A full cube clips a light's face smoothly; a door, trapdoor, pane or iron
  bars shadows through its own opening. A fence or hopper, which is made of several boxes, still
  uses four area samples, not the smooth clip. Debug → Local Light Source Size, Quarter block by
  default, sets how much of a lit face casts light: smaller gives thin blocks (a fence post, a
  hopper) a crisp shadow instead of a wide soft one, at the same light energy. Nearby players,
  mobs and items shadow local light through the engine's published body boxes; an item's box is
  shrunk to half its width and depth first to match its drawn sprite. Which way a body faces and
  how it moves do not shape its shadow. The owner accepted the direct-light appearance but
  reported high cost: supplied overlays show roughly 4.8 to 7.1 ms in the earlier outdoor scenes
  and 40 to 42 ms in the later multi-light corridor. Those samples are not a controlled benchmark.
  Source-side traversal and certified full-cube aperture clipping reduced native synthetic alcove
  dispatch time by 27.6%; this does not predict live frame time. Other silhouettes still use four
  area samples; a per-pixel, per-frame shift turns the stepped penumbra into noise that temporal
  reconstruction settles, rather than removing the steps. Static overflow source pages are
  supported; animated sprites without a full-copy page remain unsupported. Cost scales with
  receivers and sources
  (`shaders/include/voxel_local_light.glsl`, `shaders/post/voxel_local_direct.fsh`).

## Focus blur

- **Fire and smoke particles, glass and the held item stay sharp over the blur.** The engine
  draws them after the render graph (`graph.toml`, `depth_copyback`), so no post pass ever sees
  them; the fix is claiming those draws into the graph, engine-side.
- **True Camera Stills can jitter with ray traced lighting on.** Experimental and off by
  default (`shaders/post/dof_accumulate.fsh`, engine `ApertureJitter`); the diagnostic plan is
  in the working notes.
