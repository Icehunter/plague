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
- **The resolve sits close to Metal's ceiling of 16 live samplers per fragment function**, at 14
  under the scattering sky and 12 under Palette (`tools/check_metal_pipelines.py` measures the
  count). The `gbuf_consolidate` pass (`graph.toml`, see `docs/PACK-FORMAT.md`) already buys back
  three slots; the motion and raw-shadow-map debug views (`PLAGUE_DEBUG_VIEWS`) stay compiled out
  regardless, and the ceiling itself is not raisable from this engine's integration surface:
  Blaze3D's bind-group API has no path to the separate-sampler descriptors Metal argument buffers
  would need.
- **Under the scattering sky, a cloud's DIRECT sun/moon light still comes from the palette**
  (`lighting.light` / `plagueMoonColor` in `shaders/include/clouds.glsl`), so a cloud's lit side can
  disagree with the air under it at dusk. A table-lit direct term was tried and rejected by eye:
  clouds under a low deck's horizon went grey where the palette keeps them warm. Open. (A cloud's
  ambient and its distance fade-to-sky DO read the scattering tables under
  `PLAGUE_SKY_MODEL == 1`, via the `plagueGetClouds` overload `clouds_march_volume.comp` calls,
  with the pack's own sunset-band warmth on the fade; only the direct term is still palette-only.
  `clouds_march.fsh`, the non-live fullscreen fallback, still calls the palette overload
  unconditionally.)
- **The sun disc's own brightness is not on the dome's exposure ladder** (`PLAGUE_ATMO_SKY_GAIN`,
  the twilight adaptation): it is gated off at sunset (`sunSetGate` in `gbuffer_resolve.fsh`) so
  it does not sit bright on a dark sky, but while it is up its brightness is still
  `plagueSunColor`'s own analytic calibration, independent of the table gain. Not attempted: doing
  so unconditionally overexposed the disc at noon, where the un-gained disc is already the
  accepted look.
- **The scattering march does not apply atmospheric refraction.** A real sun is visible about
  0.833 degrees (34 arcmin refraction plus its own 16 arcmin radius) past where its geometric
  position would predict, which is why the disc's own set gate is offset by exactly that much; the
  dome and aerial marches still use the un-refracted direction, so the sky's own colour continues
  to shift about that much earlier than the disc vanishes. Measured as a minor effect on the
  sunset's warmth, not attempted here.
- **A far hill dissolved by the render-edge veil still hides the clouds behind it**, leaving a
  sky-coloured cutout with no cloud in it (`shaders/post/clouds_composite.fsh` tests cloud depth
  against terrain depth). A see-through weight on the veil was tried and rejected: at partial veil
  it painted horizon cloud over terrain still in view.
- **Smoke and banner fog use the palette haze under the scattering sky.** Those slots draw through
  vanilla pipelines that receive no pack inputs, so they cannot read the aerial table; an engine
  change. The smoke-fog mismatch below is the same seam.
- **The scattering sky's twilight ends about five degrees earlier than the palette's.** Through
  civil twilight the adaptation gain (`PLAGUE_ATMO_TWILIGHT_GAIN`) keeps the sun-side glow at the
  palette's level; past six degrees below the horizon the sun reaches only the air above 15 km
  and the glow is a fifth of the palette's by eight. Real skies keep more from high aerosol the
  model does not carry. About twenty seconds of game time.
- **The aerial table stores one transmittance channel** and readers reconstruct the other two
  with an exponent taken at the camera's altitude (`plagueAtmoTransmittanceChroma`), exact for
  one medium and within 3% at sea level for the mixed air. A second table would need a sampler
  the resolve does not have.

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

## World outline

- **Bare uneven terrain draws densely.** A cliff or open hillside is thousands of one-block steps,
  every one a real 90 degree edge, so it reads as a lattice rather than outlined shapes. No per-pixel
  discriminator separates that from architecture: the edge-magnitude distributions overlap. Lowering
  Outline Distance is the only lever today. A regional density filter over a much wider neighbourhood
  is the untried fix. `shaders/include/outline.glsl`.
- **Lines shimmer by up to half a pixel under temporal accumulation.** The projection is jittered, so
  the depth read is sub-pixel offset each frame while the colour was resolved unjittered. Worst at
  thickness 1. A fix needs an unjittered depth buffer, which the G-buffer does not carry.
- **A band at the frame edge, as wide as the tap radius, draws no lines.** The border early-out in
  `plagueOutlineFold`. Every alternative breaks stencil symmetry and makes it respond to slant.
- **Terrain seen through a leaf gap can draw a faint line on the wall behind.** A leaf close in front
  of a surface occludes the surface, not the leaf.

## Performance

- **Water scenes run around 55 FPS** against 75–110 elsewhere. A long-standing cost rather than a
  recent regression, and not yet measured per-feature.
