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

- **The climate signal snaps at biome borders**, so fog character can change sharply across a line.
- **Thunder is not its own fog driver.** Heavy weather reads as ordinary rain.
- **The resolve sits close to Metal's ceiling of 16 live samplers per fragment function**, at 14
  (`tools/check_metal_pipelines.py` counts them). The
  `gbuf_consolidate` pass (`graph.toml`, see `docs/PACK-FORMAT.md`) already buys back three slots;
  the motion and raw-shadow-map debug views (`PLAGUE_DEBUG_VIEWS`) are left out of the build either
  way, and the ceiling itself cannot be raised from where this engine plugs in: Blaze3D's bind-group
  API has no route to the separate-sampler descriptors Metal argument buffers would need.
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
- **The aerial table stores one transmittance channel** and readers rebuild the other two
  with an exponent taken at the camera's height (`plagueAtmoTransmittanceChroma`), exact for
  one medium and within 3% at sea level for the mixed air. A second table would need a sampler
  the resolve does not have.

## Clouds

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
  most for anything at eye level, so it must be understood before the march is reused for ground fog
  or mist, which are viewed edge-on constantly.
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

- **Water scenes run around 55 FPS** against 75 to 110 elsewhere. A long-standing cost rather than a
  recent regression, and not yet measured per-feature.
