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

`graph.toml` declares **54 passes** writing **39 targets**. They run in the order they appear in the
file. Grouped by what they are for:

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

`resolve` is where the frame is actually lit: the G-buffer is read, the sky and sun are evaluated,
shadows are filtered, ambient and blocklight are applied, reflections are composited in, and fog is
laid over the result. It is by far the largest shader in the pack.

### 4. Clouds: 4 passes

`clouds_march` → `clouds_composite`, with `clouds_march_full` / `clouds_composite_full` as the
higher-quality pair. Marched volumetrically against the same sky model the dome uses, so the clouds
and the light they cast agree.

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

## Where the shaders live

```
shaders/
├── blocks/    7 geometry stages, 14 files (.vsh + .fsh each)
├── post/      28 fullscreen passes
├── compute/   4 compute stages
├── include/   32 shared includes
└── textures/  4 pack-owned textures
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
