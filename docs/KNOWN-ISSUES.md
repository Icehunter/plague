# Known issues

Open defects, one line each, with where the fix would go. Anything not listed here is either working
or not yet noticed; this file is not a wish list, and a fixed issue is deleted rather than struck
through.

The long diagnostic write-up behind each of these lives outside the repository with the rest of the
working notes; what is here is what a reader needs to know the limitation exists.

## Water

- **Near-silhouette SSR substitutes the wrong reflection** where a water edge meets geometry.
- **The underwater shaft ray does not follow the shaft angle**, so shafts and their light disagree
  at low sun.
- **Floor caustics are a texture, not the focused image of the wave surface.** They repeat, and the
  pattern does not correspond to the crests above it. The machinery to derive it properly already
  exists in `shaders/include/water_volume.glsl`.

## Atmosphere

- **The climate signal snaps at biome borders**, so fog character can change abruptly across a line.
- **Thunder is not its own fog driver.** Heavy weather reads as ordinary rain.

## Clouds

- **A distant cloud can render in front of a nearer one.** An opacity/transparency issue, not the
  separately tracked boxy/grid allocation-lattice shape issue. Root cause not found; likely
  grazing-angle step undersampling in `shaders/include/clouds.glsl`'s march.
- **A stratiform layer shows a flat horizontal seam where it thins.** Visible as a straight
  light-toned line through the layer rather than a cloud edge. Suspected to be the slab's own top or
  bottom plane appearing once the vertical profile saturates before it reaches the boundary. Matters
  most for anything at eye level, so it must be understood before the march is reused for ground fog
  or mist, which are viewed edge-on constantly.
- **A cloud grows and gains density as the sun passes behind it.** The silhouette widens, not just
  the glow around it. Most visible against a small isolated cumulus. The moon behind the same cloud
  does nothing, which fits the march lighting from the sun alone: the moon is no directional source
  for it. The lead is the forward-scattering lobe in `shaders/include/clouds.glsl`. Looking toward
  the sun puts cosLight near 1, the phase peak brightens the thin margins, and material that sat
  below visibility crosses it, so the cloud reads both larger and thicker. Forward scatter belongs
  there; the open question is its magnitude, and whether the growth tracks
  PLAGUE_CLOUD_PHASE_FORWARD or the multiple-scattering octaves. Not measured.
- **A water surface renders over a cloud in front of it.** Looking down from above the deck, ground
  is correctly hidden but lakes and ocean punch through. `water_composite` runs after
  `clouds_composite` in graph.toml, so water blends over the already-composited cloud.
  `clouds_composite` binds `builtin.waterDepth` as input 2 and never reads it, which is the test
  this needs. Compositing clouds after water instead costs the reflections nothing:
  Reordering is ruled out: `ssr_trace_water` reads `sceneHdr` and its sky probe samples the
  on-screen sky pixel to stay consistent with the direct view, so clouds have to be in `sceneHdr`
  before SSR, and SSR runs before water. Clouds cannot be both before SSR and after water with one
  composite. The fix is for `water_composite` to scale its own alpha by the cloud's transmittance
  where `cloudFrontDistance` is nearer than the water surface, which needs the cloud distance in
  that pass: its targets are tiered on `CLOUD_QUALITY` and the pass is not, so it needs either tier
  variants or a single ungated distance target.
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
  after the real fog pass finishes, and the approximation diverges from the real fog enough that
  smoke reads as floating in front of it rather than sitting inside it.

## Materials

- **`u_PomShadowStrength` has no visible effect.** The slider moves and nothing changes.
- **The normal-atlas magnification filter shapes the POM read**, so parallax depth depends on a
  texture filter setting rather than only on the material.

## Performance

- **Water scenes run around 55 FPS** against 75–110 elsewhere. A long-standing cost rather than a
  recent regression, and not yet measured per-feature.
