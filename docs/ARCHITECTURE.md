# Architecture

How Plague draws a frame. This document is a reading of `graph.toml`, which is the authority: if
the two disagree, the TOML is right and this file is stale.

## What the pack is responsible for

Fornax owns the pipeline: it reads `graph.toml`, allocates the render targets, compiles the shaders
and dispatches the passes in declaration order. It has no rendering of its own. Everything about how
the world looks is in this repository.

That split shapes the whole design. The pack cannot ask for a pass to run "sometimes" in code: a
pass either runs or it does not, decided by its `enabled_if` expression over compile options at pack
build. There is no branch to take at frame time, so quality tiers are separate passes rather than
`if` statements, and a feature that is off costs nothing because its passes are not in the graph at
all.

## The frame, in order

`graph.toml` declares **57 passes** writing **44 targets**. They run in the order they appear in the
file. Grouped by what they are for:

### 0. Atmosphere: 3 compute passes

`atmo_transmittance` → `atmo_multiscatter` → `atmo_skyview`, first in the file because nothing
before them needs the sky and the resolve does. Each writes one small fixed-size table
(256 × 64, 32 × 32, 192 × 108, all rgba16f) every frame: what survives from a point in the air to
space, what arrives there after more than one bounce, and the dome as the camera sees it from its
own altitude, marched per texel and lit by the true sun and the moon opposite it. The mappings
live in `shaders/include/atmo_lut.glsl`, one function per writer/reader pair. The passes are gated
on `PLAGUE_SKY_MODEL == 1`; the tables are not, because `resolve` and `water_environment_seed`
list `atmoSkyView` as an input under either setting and the gate-consistency check refuses a pass
that can run while a target it reads does not exist. Under `Palette` the tables stay zero and
unread and the five-key palette in `sky.glsl` paints the dome.

### 1. Geometry: 7 passes

`terrain`, `entities`, `block_entities`, `particles`, `particles_translucent`, `banner_patterns`,
`shadow_entities`.

Each is a `program` stem under `shaders/blocks/` with a `.vsh` and a `.fsh` beside each other. These
run as Minecraft draws the world, and their job is to fill the G-buffer: albedo in linear space,
normals, and the labPBR material channels. Lighting is deliberately *not* done here: the two
forward-lit arms inside `terrain.fsh` are the exception, and they exist because those draws cannot
reach the deferred resolve.

`shadow_entities` writes the shadow map, which is depth-only.

### 2. Screen-space occlusion and reflection: 9 passes

`ssao_raw` → `ssao_blur`, then `hiz` (a mip chain over depth), then the reflection tier:
`ssr_trace_fancy` **or** `ssr_trace_fast`, each followed by its own blur, with `ssr_upsample` for the
half-resolution tier and `ssr_prefilter` building a roughness pyramid.

The tier split is the pattern to notice: `ssr_trace_fancy` and `ssr_trace_fast` are two passes with
mutually exclusive `enabled_if` guards, not one pass with a quality branch. The blur is one shader
file compiled as two passes at two resolutions, because every size-dependent quantity comes from
`textureSize()`.

### 3. The deferred resolve: 1 pass

`resolve` is where the frame is lit: the G-buffer is read, the sky is sampled from the
sky-view table (or the palette, per `PLAGUE_SKY_MODEL`) and the sun is evaluated,
shadows are filtered, ambient and blocklight are applied, reflections are composited in, and fog is
laid over the result. It is by far the largest shader in the pack.

### 4. Clouds: 4 passes

`clouds_march_volume` → `clouds_composite`, with
`clouds_march_volume_full` / `clouds_composite_full` as the higher-quality pair. The compute march
samples the pack's 3D shape volumes against the same sky model the dome uses, so the clouds and the
light they cast agree. Global Minecraft rain and thunder strengths drive weather morphology, while
the camera precipitation type selects rain versus snow. Each march writes paired targets:
premultiplied colour in
`cloudsVolumeCompute` and the first density-bearing ray distance in `cloudsVolumeDistance`, with
full-resolution equivalents for the highest quality tier.

The composite samples the destination pixel's reversed-Z terrain depth, reconstructs its terrain
distance, and resolves the colour from four fixed diagonal cloud taps. Each tap fetches colour and
front distance from the same exact source texel, because filtering the discontinuous zero-sentinel
distance would break their depth ordering. A non-empty tap contributes only when its cloud front is
in front of that destination geometry (or the destination is sky), and the sum is always divided by
four. The resolve therefore neither borrows clouds from a neighbouring depth class nor expands them
by renormalising the surviving taps at a silhouette.

Cloud placement has two independent coordinate systems. The density volumes retain their fixed
57.6-block world X/Z lobe frame, shear, wind and drift. A separate unwarped 230.4-block allocation
grid searches a fixed 3x3 neighbourhood of deterministically jittered sites. Each active site
contributes an owner-local potential made from a tall core, lower side boil and raised crown. That
potential biases the cutoff of the sampled 3D density; it is never multiplied into final density
and therefore cannot become a visible circle, ring or Voronoi boundary. Overlaps take the strongest
potential without exposing the Cartesian allocation cells. `Cloud Amount` changes only the immutable-rank activation
threshold. Zero amount is exactly empty, while the dry maximum is capped below full population so
the complete lattice can never become visible. Rain and snow keep that candidate membership fixed,
so a weather fade cannot cross a hard rank, pop in a complete cloud, and only then grow it. They
continuously change deck depth, optical depth, horizontal footprint and profile instead; thunder may
also add storm candidates while retaining the accepted full-thunder population endpoint. No weather
state moves the candidate sites. Each site also
owns a small stable base-height offset, so individual cumulus retain locally flat bases without the
whole deck sharing one plane.

`Cloud Size = 0.30` is the physical reference. Size changes physical depth and the isosurface bias
inside each fixed owner potential; it never scales a radius, offset or noise coordinate. The real
3D sampled field therefore owns the growing silhouette around a stable centre. Base and detail
volume coordinates retain the reference 76.8-block Y period and fixed X/Z
frame, and the base blend remains 20% local to 80% organizational. The broad organization lookup
uses a derived 5.3333 X/Z scale, giving it the same 307.2-block period vertically and horizontally
instead of a pancake-biased field. Rain broadens the existing owners into a seven-okta, low-family
stratiform/congestus layer; snow selects a slightly shallower, flatter endpoint. Thunder widens the
deck further and reaches the spreading-top storm family, rather than putting the calm cumulus
footprint under a taller slab. Amount never reaches the per-cloud cutoff. The rain/snow cover lane
also closes the cloud-lighting ambient aperture from its clear estimate toward 0.875, so the cloudy
sky does not retain a mostly-sunny fill even while its visible bodies overlap.

The coarse density path still takes exactly two base-shape volume samples, and the full path adds
the same two detail samples as before. The nine owner-site tests are ALU-only: no sampler, target,
pass, history, ray step or sun tap is added. At the reference setting the dry deck resolves to 76.8
blocks, Balanced advances six slab steps, and grazing rays remain capped at 64 steps. These
contracts target detached, flat-based cumulus groups with rounded vertical crowns rather than a
continuous rolling layer. The morphology and control response remain subject to owner live
acceptance.

Cloud lighting treats the density as a participating medium rather than a normal-mapped surface.
Each quality tier keeps its existing coarse direct-light fan. The fan's accumulated optical depth
is extended toward the light-side slab exit with a bounded same-budget remainder estimate made from
the current density and fan mean already in registers. Ambient sky fill keeps its established sky
colour and height/coverage response. The strongly forward raw phase is energy-preservingly mixed
10% away from isotropic response, reducing the two-octave lit forward/backward ratio from roughly
385:1 to 7.79:1. Powder and ambient overburden are gated by direct-light transmittance, so lit crowns
remain white while shadowed interiors retain cool optical-depth separation. A bounded direct-crown
exposure applies only high in the parcel when the light path is open and the camera views the
light-facing crown; lower, occluded and near-sun samples retain the established response. That
clear-noon-only closure fades out with rain, preventing its artificial +100% cap from punching a
sunny crown through the already-overcast light palette while leaving the accepted clear expression
unchanged. Terrain,
water and LabPBR normal maps do not participate in cloud transport. These changes add no density
lookup, light tap, pass or history resource and remain subject to owner live acceptance.

`plagueCloudActiveDeck` is the pack-owned contributor-selection seam shared by the direct compute
march, cloud-shadow query, and reflected-sky probe. All three consume the same global rain,
thunder, wetness, and camera rain/snow classification so their cloud morphology agrees.

### 5. Water: 13 passes, the deepest part of the graph

After `scene_hdr_copy` snapshots the lit scene:

- `water_environment_seed` → `water_environment_mips` build what water reflects.
- `ssr_trace_water` → `ssr_blur_water` trace reflections off the surface specifically.
- `glint_occlusion` handles sun glitter visibility.
- `water_volume_interval` → `water_volume_march` → `water_volume_scatter_history` are the volumetric
  water column: where a ray enters and leaves the water, what it scatters along the way, and a
  temporal history so the result is stable rather than noisy.
- `water_composite` puts the surface together: reflection, refraction, foam, caustics, depth.

### 6. Temporal: 1 pass

`temporal_accumulate` runs **before** bloom, deliberately. Accumulating a bloomed frame let a bright
mover's halo hold the anti-ghost clamp open along its own path, and every star dragged a permanent
comet tail. Under any anti-aliasing mode other than TAA the engine degrades this to an identity copy,
so the chain stays valid.

### 7. Underwater: 5 passes

`underwater_refraction` (or `underwater_refraction_shafts`, the same shader wired to a different
output when volumetrics are on), `water_volume_composite_submerged`, then a separated blur:
`underwater_blur_h` → `underwater_blur_v`.

### 8. Surface simulation: 6 compute passes

`water_prepare`, then `water_step_a`/`water_step_b` in a quality or performance variant, then
`water_commit`. This is a fluid simulation on the water surface, kept in compute because it carries
state between frames.

### 9. Output: 10 passes

`exposure_measure` reads scene luminance; `bloom_blur1..7` build the pyramid and `bloom_combine`
folds it back; `tonemap` maps HDR to display and applies grading. `depth_copyback` restores depth for
anything drawn afterwards.

`tonemap` also owns the world outline, which is why it reads `builtin.gAo`, appended at input 8. The
detector runs there rather than in its own pass because it must sit after `temporal_accumulate` (a
one-pixel line is the outlier a neighbourhood clamp rejects) and needs the finished colour to
composite against. `tonemap` is the only pass after the accumulator holding both.

## Where the shaders live

```
shaders/
├── blocks/    7 geometry stages, 14 files (.vsh + .fsh each)
├── post/      28 fullscreen passes
├── compute/   5 compute stages
├── include/   32 shared includes
└── textures/  6 pack-owned textures
```

Two engine rules constrain this and cannot be worked around:

- **An include must be under `shaders/include/`.** `#moj_import <fornax_runtime:x.glsl>` resolves
  there and nowhere else. Subdirectories under it are fine: `<fornax_runtime:water/waves.glsl>`
  works.
- **A geometry program is a stem.** The engine appends `.vsh` and `.fsh`, so both stages must sit
  together with the same name.

## Options

Options are declared as annotated `#define`s in whichever shader is natural, and the engine's scanner
merges them across every source **by name**. `screens.toml` then binds them by name onto screens; it
never references a file. That means an option can move between shaders freely.

Two kinds, and the difference is not cosmetic:

- **`compile`** options are baked at pack build. They can gate a whole pass through `enabled_if`, so
  turning one off removes work from the graph entirely.
- **`runtime`** options arrive as `float` uniforms in a `u_PackOptions` block the engine prepends to
  every shader. They can be dragged in game with no rebuild. A runtime boolean is therefore tested
  `> 0.5`, never against an integer.

A runtime option renders as a **slider** only if its name appears in `screens.toml`'s top-level
`sliders` list as well as on its screen; listed only on the screen, it becomes a cycle button.

## Constants

Tables are generated, not typed. `tools/derive_fog.py`, `derive_sky.py`, `derive_atmosphere.py`,
`derive_cloud_types.py` and `generate_foam.py` emit the numbers the shaders use, and the shaders cite
them. Rerun one and you get what ships: the script is the record that the table belongs to this
pack.

Constants that are not generated carry a comment saying why they have the value they have: a paper, a
measurement, or the render they were tuned against.
