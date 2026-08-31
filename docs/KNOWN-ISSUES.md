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
- **Cloud shadows only see one deck.** `shaders/post/gbuffer_resolve.fsh`'s shadow block resolves a
  single deck through `plagueCloudActiveDeck` and takes three samples through it, so the low
  stratiform layer casts nothing. Rain shadows correctly, because the precipitating deck is the one
  the seam returns. The transmittances multiply, so the fix is a per-deck three-tap and a product,
  not a redesign.
- **A stratiform layer shows a flat horizontal seam where it thins.** Visible as a straight
  light-toned line through the layer rather than a cloud edge. Suspected to be the slab's own top or
  bottom plane appearing once the vertical profile saturates before it reaches the boundary. Matters
  most for anything at eye level, so it must be understood before the march is reused for ground fog
  or mist, which are viewed edge-on constantly.
- **A cloud brightens and appears to swell as the sun passes behind it.** The sun's disc reads
  through the cloud as a hard-edged bright circle rather than being attenuated by the cloud it sits
  behind, and its aureole spreads into the surrounding cloud. `plagueCelestialDiscs` writes into the
  sky before the cloud composite, so the cloud's alpha thins the disc but the disc keeps its own
  shape and edge; nothing tests the cloud's optical depth along the sun ray. Most visible against a
  small isolated cumulus.

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
