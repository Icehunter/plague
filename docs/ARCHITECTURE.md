# Architecture

How Plague draws a frame. `graph.toml` is the authority: if the two disagree, the TOML is right and
this file is stale.

## What the pack is responsible for

Fornax owns the pipeline: it reads `graph.toml`, allocates the render targets, compiles the shaders
and dispatches the passes in declaration order. It draws nothing of its own. How the world looks is
all in this repository.

That split shapes the design. The pack cannot ask for a pass to run "sometimes": a pass either runs
or it does not, decided by its `enabled_if` over compile options at pack build. There is no branch
to take at frame time, so quality tiers are separate passes rather than `if` statements, and a
feature that is off costs nothing because its passes are not in the graph at all.

## The frame, in order

`graph.toml` declares **109 passes** writing **135 targets**. They run in file order. Grouped by job:

### 0. Atmosphere: 4 compute passes

`atmo_transmittance` → `atmo_multiscatter` → `atmo_skyview` → `atmo_aerial`, first in the file
because nothing before them needs the sky and the resolve does. The first four each write one small fixed-size
table (256 × 64, 32 × 32, 192 × 108, 1088 × 32, all rgba16f): how much light gets
through from a point in the air to space, what arrives there after more than one bounce, the dome as
the camera sees it from its own height, and the same march stopped at each screen froxel's depth
(32 × 32 froxels, 32 depth slices out to twice the render distance, plus a slice of the sky along
each froxel and one of the frame's transmittance chroma). All lit by the true sun and the moon
opposite it; the aerial pass adds the fog drive's mist as a shallow layer. The mappings live in
`shaders/include/atmo_lut.glsl`, one function per writer/reader pair; a compute reader loads the
tables as storage images, a fullscreen one samples them. Those four writers and targets are unconditional.
The first two passes declare `reuse_when_unchanged`: their output depends only on density, haze,
ozone, rain and thunder. Fornax skips their kernels when those inputs and resources stay the same,
but still updates descriptors and keeps sync correct. A shader reload or a new target forces a
rerun. Sky-view and aerial still run every frame. Sky-view has each workgroup column march its two
horizon rays once and share them; the pole case and above-horizon rays are unaffected.
The opaque `resolve` pass writes `sceneHdrUnfogged`. Right after it, the fullscreen `resolve_hdr`
pass (`fog_composite.fsh`) reads the depth again, adds up light along the path from camera to
surface, and mixes in fog, edge fade and underwater effects to make `sceneHdr`. Color and light
loss are worked out together, in the same shader step: no separate compute pass or lookup table
stands in for this.
The fog pass copies its input straight through on sky pixels, when fog is off, and for debug
views that don't need it. It shares its air, light source and shadow math with `atmo_aerial`
through `atmo_transport.glsl`; `atmo_transport_compute.glsl` holds only the code that binds and
reads compute textures. Light along the path is added up from far to near.
Near the camera, the ray is split at world-grid lines every eight blocks, and the last piece is
cut short at the solid surface. Each piece uses one smooth reading of air and haze, averaged from
eight light-visibility checks. Each grid cell always gets the same fixed set of checks, so a
longer path adds more cells rather than more checks per cell; the far sky march keeps its old,
wider spacing. `atmo_mist.glsl` adds a test-stage patch of still mist tied to world position,
turned on by the Local Mist Amount setting. It sits on a smooth 128-block grid and fades with
height above sea level, adding the same amount to both light loss and haze scatter. It needs no
extra pass, texture, or history from past frames. The sky tables (planetary light loss and
multi-bounce light) leave this thin local patch out. The color of light lost through the solid
surface path stays correct when the patch mixes with colored air, and needs no extra storage. The
new full-size unfogged color target costs eight bytes per pixel and one extra read and write; the
new fog step proves the math is right, but its speed has not yet been measured.
The aerial table still feeds light-loss data to water, reflections and cave detection.
`fog_aerial.glsl` mixes this with the sky along the ray and the fade at the render edge. Its guard
against wrong sky light at cave mouths still works, and still misses a lit gap between two
sheltered points. This new fog step shares no cache and reuses nothing between frames; its speed
and look still need to be checked on the owner's own machine before tuning it further.

`sky.glsl` retains the shared palette estimates used for surface ambient, water illumination,
reflection-probe clouds and forward particle/banner fog, plus the scattering sky's warmth and
weather grading. Their controls remain live; removing the alternate dome does not retire them.

### 1. Geometry: 7 passes

`terrain`, `entities`, `block_entities`, `particles`, `particles_translucent`, `banner_patterns`,
`shadow_entities`.

Each is a `program` stem under `shaders/blocks/` with a `.vsh` and a `.fsh` beside each other. These
run as Minecraft draws the world, and they fill the G-buffer: albedo in linear space, normals, and
the labPBR material channels. Lighting is deliberately *not* done here: the two forward-lit arms
inside `terrain.fsh` are the exception, and they exist because those draws cannot reach the deferred
resolve.

`shadow_entities` writes the shadow map, which is depth-only.

The terrain position decoder matches Fornax's fixed-point vertex codes: 2048 steps per block,
offset by -8. It recovers the integer from UNORM before scaling, so adjacent section origins
preserve shared edges. Encoder and decoder updates require rebuilding meshes and shaders together.

Terrain material reads use exact texels at whole mip levels inside the owning sprite. Bounds follow
Fornax's integer sidecar rectangles; misaligned leading edges are excluded where neighbouring sprites
can overlap during mip reduction. This keeps emission and metal codes from crossing sprite boundaries.
Missing bounds use level zero; missing overflow material pages use the engine's neutral layer.

### 2. Screen-space occlusion and reflection: 9 passes

`ssao_raw` → `ssao_blur`, then `hiz` (a mip chain over depth), then the reflection tier:
`ssr_trace_fancy` **or** `ssr_trace_fast`, each followed by its own blur, with `ssr_upsample` for the
half-resolution tier and `ssr_prefilter` building a roughness pyramid.

The AO blur evaluates a five-by-five box using nine weighted bilinear samples. Its `ssaoRaw`
input is R8 with linear clamp sampling; changing that sampler changes the kernel. The R8 output
contains only the current frame's AO.

The tier split is the pattern to notice: `ssr_trace_fancy` and `ssr_trace_fast` are two passes with
mutually exclusive `enabled_if` guards, not one pass with a quality branch. The blur is one shader
file compiled as two passes at two sizes, because every size-dependent value comes from
`textureSize()`.

### 3. The deferred resolve: 2 passes

`resolve` is where the frame is lit: it reads the G-buffer, samples the sky from the sky-view table,
evaluates the sun, filters shadows, applies ambient and
blocklight, composites reflections in, and lays fog over the result. It is by far the largest shader
in the pack.

`resolve_hdr_rt_shadow` runs before `resolve` and applies the shared world-position handoff in
`shadow_handoff.glsl`, followed by `shadow_filter.glsl`. `rtShadowComposite` holds direct and wide
ambient visibility in red/green, the seabed caustic query in blue, and actual selected RT coverage
in alpha (averaged over the direct filter taps). `resolve` reads input 18; input 19 remains reserved.
Its RT shadow coverage debug tints selected RT cyan and raster fallback gray; brightness follows
applied visibility with a display-only floor so shadowed coverage remains visible.

The graph's `[ray_traced_shadows]` table declares `SHADOWS && RT_SHADOWS`, runtime
`distance_option = "u_RtShadowDistance"`, and `blocks_per_unit = 16`. The control is an integer
one-to-sixteen chunks, default two (32 blocks), measured horizontally from camera to receiving
point. The engine caps effective RT distance at overall Shadow Distance and publishes its square
in `u_ShadowMapParams.y`; zero means inactive. The fixed two-block transition lies inside that
boundary. Increasing coverage does not change already-covered nearby shadow queries.

RT caster selection is distinct: relevant blockers can be distant or elevated, anywhere along the
light ray through the receiving volume. `rtTerrainShadowDepth.r` is forward light depth (miss one),
and alpha is current validity. Per tap, the pack unions valid RT terrain depth with independent
`sunEntityShadowMapRaw` depth before comparison. Invalid RT texels and distant receivers use the
complete `sunShadowMapRaw`. Manual bilinear comparison preserves the comparison-sampler filter;
it never multiplies two complete visibility fields or interpolates raw depths before comparison.

The same handoff serves primary surfaces, caustics, water shafts, reflected surfaces and fog sample
positions. Softness, Samples, rain widening, Strength and ambient darkening retain their existing
places. The engine receives a conservative filter guard of 148.371472 texels: maximum softness 6,
disk radius 2.046826, rain factor 3 and ambient multiplier 4, plus one bilinear texel. Every other
consumer uses one bilinear tap and needs no larger guard. Cloud transmission remains separate.

The complete raster map remains available for distant receivers and incomplete RT coverage. This
implementation therefore adds tracing and mesh maintenance; it does not promise zero raster cost.
Offline depth fixtures verify selection and filtering, while actual caster coverage, appearance and
frame time require engine tests and the owner's client session.

### 4. Clouds

`clouds_candidates` → `clouds_march_volume` → `clouds_merge_layers` → `clouds_composite`, with
quarter, half and three-quarter resolution variants. The compute march
samples the pack's 3D shape volumes against the same sky model the dome uses, so the clouds and the
light they cast agree. Global Minecraft rain and thunder strengths drive weather shape, while the
camera precipitation type picks rain or snow. Each march writes seven pairs of full-float targets:
premultiplied colour and first density-bearing ray distance, one pair per genus. The merge sorts
these layers and writes `cloudsVolumeCompute` plus the contribution-weighted mean of their sampled
front distances to `cloudsVolumeDistance`. Existing history and composite passes consume these
merged outputs.
Weather, cloud decks, lighting and hemisphere sampling run once per 16 × 16 workgroup. Each
invocation keeps its own view direction, noise phase and ray samples; a barrier shares the setup
before any invocation can exit at the edge of the image.
The dispatch has seven Z workgroup planes, one per genus. Each invocation retains only its current
layer while marching, preserving the independent dither phases, convective weather fade and sample
budgets. Moving sorting to a separate pass removes the seven-result private arrays from the long
density loop. Every missed or disabled genus writes zero so the merge cannot read a stale layer.
The fourteen intermediate images use the same scale as the merged output; separate targets avoid
atlas tile rounding errors at odd viewport sizes. Their float32 storage avoids an extra half-float
quantization before merging, at a transient cost of 140 bytes per cloud pixel (about 141 MiB at
1296 × 813). Only the selected resolution allocates these targets, and clouds Off allocates none.

Before marching, `clouds_candidates` builds conservative membership masks for seven decks in a
512 × 3585 R32F atlas. Each of the 512 × 512 deck tiles stores nine candidate bits; one extra row
stores frame stamps. Ellipse/lobe bounds omit nonnegative patch and vertical penalties, retaining
every candidate that could produce visible density anywhere in the tile. The march visits retained
bits in the original order. An empty mask returns the sheet value and its erosion owner before
evaluating unused patch noise. Rank and support checks run procedurally on cache misses; other cloud
callers keep that original path. Both passes import the same frame/deck setup.

Masks encode as 1 to 512, reserving zero for cleared/unavailable data. Wrong dimensions, malformed
entries or a mismatched frame stamp fall back to the original field. The frame stamp uses the
engine's wrapped frame counter, not a globally unique generation identifier. The atlas is rebuilt
in graph order with compute write/read synchronization and has no temporal history. Candidate
culling changes work, not march resolution, sample counts, lighting, density or winning ownership.
Offline GPU parity and dispatch measurements do not establish live FPS or stability in motion.

The composite step works out how far the land and water are at each screen pixel, then reconstructs
cloud colour from sixteen source pixels with positive cubic B-spline weights. The separable kernel
is the convolution of four unit-area boxes; it smooths the source sampling grid while preserving
constant colour and opacity. Each tap reads colour and front distance from the same source pixel.
A tap contributes only when it sits in front of the destination land and water. Rejected taps
contribute zero without renormalizing the remaining weights, avoiding inflated opacity at terrain
edges. Premultiplied colour and opacity are filtered together, then converted to the straight colour
format the next pass needs. The wider kernel softens silhouettes and does not resolve temporal
aliasing already present in the density march.

Cloud placement has two separate coordinate systems. The density volumes keep their fixed
57.6-block world X/Z lobe frame, shear, wind and drift. A separate unwarped 230.4-block allocation
grid searches a fixed 3x3 neighbourhood of deterministically jittered sites. Each active site adds
an owner-local potential made from a tall core, lower side boil and raised crown. That potential
biases the cutoff of the sampled 3D density; it is never multiplied into final density, so it cannot
become a visible circle, ring or Voronoi edge. Overlaps take the strongest potential without showing
the Cartesian allocation cells. `Cloud Amount` changes only the immutable-rank activation threshold.
Zero amount is exactly empty, and the dry maximum is capped below full population so the whole
lattice can never become visible. Rain and snow keep that candidate membership fixed, so a weather
fade cannot cross a hard rank, pop in a whole cloud, and only then grow it. They change deck depth,
optical depth, horizontal footprint and profile smoothly instead; thunder may also add storm
candidates while keeping the accepted full-thunder population endpoint. No weather state moves the
candidate sites. Each site also owns a small stable base-height offset, so single cumulus keep
locally flat bases without the whole deck sharing one plane.

Before evaluating a candidate's ellipse, lobes and vertical profile, the density query rejects
sites outside a conservative support circle derived from its existing empty-density cutoff.
The bound includes every lobe, ellipse stretch and floating-point slack; nearly zero orientation
seeds bypass it because their normalization floor can collapse the frame. Sampling, lighting,
cloud resolution and visible winning potentials are unchanged.

`Cloud Size = 0.30` is the physical reference. Size changes physical depth and the isosurface bias
inside each fixed owner potential; it never scales a radius, offset or noise coordinate. So the real
3D sampled field owns the growing silhouette around a stable centre. Base and detail volume
coordinates keep the reference 76.8-block Y period and fixed X/Z frame, and the base blend stays 20%
local to 80% organizational. The broad organization lookup uses a derived 5.3333 X/Z scale, giving
it the same 307.2-block period up and sideways instead of a pancake-biased field. Rain broadens the
owners into a seven-okta, low-family stratiform/congestus layer; snow picks a slightly shallower,
flatter endpoint. Thunder widens the deck further and reaches the spreading-top storm family, rather
than putting the calm cumulus footprint under a taller slab. Amount never reaches the per-cloud
cutoff. The rain/snow cover lane also closes the cloud-lighting ambient aperture from its clear
estimate toward 0.875, so the cloudy sky does not keep a mostly-sunny fill while its visible bodies
overlap.

The coarse density path takes exactly two base-shape volume samples, and the full path adds two
detail samples. The nine owner-site tests are ALU-only: no sampler, target, pass, history, ray step
or sun tap is added. At the reference setting the dry deck resolves to 76.8 blocks, Balanced
advances six slab steps, and grazing rays are capped at 64 steps. These contracts aim at detached,
flat-based cumulus groups with rounded vertical crowns rather than one continuous rolling layer. The
shape and the control response are subject to owner live acceptance.

Each step of the cloud ray march stays inside its own piece of the ray, even as later steps grow
longer. Distance and the deck's step scale reduce its tier budget to a fixed four-sample slab floor
and eight-step grazing cap floor. Those floors never rise with tier or morphology: doing so cancels
the distance reduction. The low-detail mode halves the budget before these safety floors apply.
The step count is always capped at the loop limit, even when rounding pushes it one step over.
Sampling changes between frames only when engine temporal AA or cloud temporal smoothing is
enabled. With both off, spatial dither stays fixed; movement can still reveal sampling aliasing.
This uses the engine's `FX_TAA` compute preamble. Older engines that omit that fact retain the
previous animated sequence until updated.

Cloud lighting treats the density as a medium light passes through rather than a normal-mapped
surface. Each quality tier keeps its coarse direct-light fan. The fan's accumulated optical depth is
extended toward the light-side slab exit with a bounded same-budget remainder estimate made from the
density and fan mean already in registers. Ambient sky fill keeps its sky colour and
height/coverage response. The strongly forward raw phase is mixed 10% toward an even response
without losing energy, which cuts the two-octave lit forward/backward ratio from about 385:1 to
7.79:1. Powder and ambient overburden are gated by how much direct light gets through, so lit crowns
stay white while shadowed interiors keep cool optical-depth separation. A bounded direct-crown
exposure applies only high in the parcel when the light path is open and the camera views the
light-facing crown; lower, blocked and near-sun samples keep the established response. That
clear-noon-only closure fades out with rain, so its artificial +100% cap cannot punch a sunny crown
through the already-overcast light palette, while the accepted clear look is unchanged. Terrain,
water and LabPBR normal maps take no part in cloud transport. These add no density lookup, light
tap, pass or history resource and are subject to owner live acceptance.

`plagueCloudActiveDeck` is the pack-owned contributor-selection seam shared by the direct compute
march, cloud-shadow query, and reflected-sky probe. All three read the same global rain, thunder,
wetness, and camera rain/snow classification so their cloud shape agrees.

### 5. Water: 13 passes, the deepest part of the graph

After `scene_hdr_copy` snapshots the lit scene:

- `water_environment_seed` → `water_environment_mips` build what water reflects.
- `ssr_trace_water` → `ssr_blur_water` trace reflections off the surface itself.
- `glint_occlusion` handles sun glitter visibility.
- `water_volume_interval` → `water_volume_march` → `water_volume_scatter_history` are the water
  column: where a ray enters and leaves the water, what it scatters along the way, and a history
  that keeps the result steady rather than noisy.
- `water_composite` puts the surface together: reflection, refraction, foam, caustics, depth.

### 6. Temporal: 1 pass

`temporal_accumulate` runs **before** bloom, deliberately. Accumulating a bloomed frame let a bright
mover's halo hold the anti-ghost clamp open along its own path, and every star dragged a permanent
comet tail. Under any anti-aliasing mode other than TAA the engine drops this to an identity copy,
so the chain stays valid.

### 7. Underwater: 5 passes

`underwater_refraction` (or `underwater_refraction_shafts`, the same shader wired to a different
output when volumetrics are on), `water_volume_composite_submerged`, then a separated blur:
`underwater_blur_h` → `underwater_blur_v`.

The submerged shaft resolver accepts only interval-compatible half-resolution donors. When a valid
full-resolution ray has none, it runs the same 8/12-cell integrator as the raw shaft pass on that ray.
This covers thin surfaces and gaps absent from the half-resolution field without borrowing light
across depth boundaries. A compatible donor with zero radiance remains zero. Shadow and noise
inputs are appended to the resolver; its sparse integration keeps the half-resolution footprint.

### 8. Surface simulation: 8 compute passes

`water_prepare`, then `water_step_a`/`water_step_b` and `water_shore` in a quality or performance
variant, then `water_commit`. This is a fluid simulation on the water surface, kept in compute
because it carries state between frames. Shoreline work uses 16×16 workgroups: 32×32 groups cover
the 512² Quality grid, and 16×16 groups cover the 256² Performance grid.

### 9. Output: 10 passes

`exposure_measure` reads scene luminance; `bloom_blur1..7` build the pyramid and `bloom_combine`
folds it back; `tonemap` maps HDR to display and applies grading. `depth_copyback` restores depth for
anything drawn afterwards.

`tonemap` also owns the world outline, which is why it reads `builtin.gAo`, appended at input 8. The
detector runs there rather than in its own pass because it must sit after `temporal_accumulate` (a
one-pixel line is the outlier a neighbourhood clamp rejects) and needs the finished colour to
composite against. `tonemap` is the only pass after the accumulator holding both. The outline adds
proportional contrast to that finished colour, with no additive floor, so unlit surfaces stay unlit.

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
never names a file. So an option can move between shaders freely.

Two kinds, and the difference is not cosmetic:

- **`compile`** options are baked at pack build. They can gate a whole pass through `enabled_if`, so
  turning one off removes work from the graph entirely.
- **`runtime`** options arrive as `float` uniforms in a `u_PackOptions` block the engine prepends to
  every shader. They can be dragged in game with no rebuild. A runtime boolean is therefore tested
  `> 0.5`, never against an integer.

A runtime option draws as a **slider** only if its name appears in `screens.toml`'s top-level
`sliders` list as well as on its screen; listed only on the screen, it is a cycle button.

## Constants

Tables are generated, not typed. `tools/derive_fog.py`, `derive_sky.py`, `derive_atmosphere.py`,
`derive_cloud_types.py` and `generate_foam.py` emit the numbers the shaders use, and the shaders cite
them. Rerun one and you get what ships: the script is the record that the table belongs to this
pack.

A constant that is not generated carries a comment saying why it has the value it has: a paper, a
measurement, or the render it was tuned against.

### Voxel water reflection recovery

`voxel_water_reflection_pass.glsl` holds the shared fullscreen implementation. The Debug option
`PLAGUE_VOXEL_PROFILE` adds five timing draws: primary trace including alpha, surface
decode, direct lighting including shadows, the full reflection without segment fog, and the full
reflection again. Their half-size `voxelReflectionProbe` scratch target is never consumed by water
composition. Off removes the target and all five draws. The normal draw's shader body is unchanged
by this option.
Prefix outputs retain intermediate fields to prevent unused-result elimination; their timing
differences include those output sinks, compiler choices and cache/order effects. Full minus
no-fog estimates segment fog cost; no-fog minus direct estimates secondary reflection cost. Both
are marginal draw differences, not exact timings inside the normal shader, and enabled-mode FPS
is not a gameplay benchmark.

`PLAGUE_VOXEL_REFLECTIONS` defaults On under Reflections and runs `voxel_water_reflection` between
the water SSR trace and the blur, at half size. It needs reflective water and SSR on. Screen-space
geometry stays the detailed source; this fills in where SSR found nothing. With the option on, SSR
flags its sky guesses with negative confidence so the voxel pass can tell sky from a real hit.
The blur preserves sky confidence magnitude and smoothly maps positive geometry confidence to one
at the producer's existing 0.5 tracing cutoff. This narrows the geometry fade while keeping the
voxel work budget and avoiding a confidence jump where the producer stops. Fractional voxel
coverage blends confidence and premultiplied colour continuously; complete coverage retains the
geometry-priority handoff. Underwater bypasses this mapping and voxel recovery.
The target is allocated next to water SSR so the blur's appended input binds even with the option Off,
which draws and reads nothing.

A hit carries the shape crossing, face normal, local position and material entry. Mapped faces read
colour, tint, normals and the labPBR maps; anything else uses the harvested average. Cutouts test
alpha. The walk keeps each section summary and occupancy word until the address changes. An empty
section skips ahead to its far edge, adding the same float steps as the walk so a tied crossing
still lands the same way. A pending section still stops the ray. Off underwater.

Both buffers are optional and allocated only when the option is on:

- `voxelLightmap` (input 11): real block and sky light per cell, block4/sky4, four cells per word,
  1024 words per section, same wrapped slot and Y/Z/X order as the geometry. Full cube faces read
  the light outside the block; partial shapes and crossed planes read their own cell. Shape bits,
  not material flags, pick the side.
- `voxelFaceTexture` (input 10): six baked face mappings per entry, atlas UVs plus layer-zero tint,
  single-quad full cube faces only. Each face is seven words: one holds RGB and flags, the other six
  hold the UV values as float32. 168 bytes per palette entry, about 75.6 MiB at eight chunks.

`surface_lighting.glsl` supplies the frame light colours; `main_lighting.glsl` and the shared BRDF
shade the bounce. Palette word15 is a block's own glow; block light landing on it is not glow. Four
GGX directions give one rough second bounce. Missing or unloaded coverage never claims sky.

Fog on the reflected ray covers water to hit only. The border comes from the engine's terrain
radius around the camera, whatever the ray's length; PassParams carries that radius and the sun.

`glint_occlusion_voxel` traces one blocker ray inside the glitter lobe and zeroes the active lane
only on a confirmed hit, so the glitter source stops showing through when on-screen blockers leave
the frame. Needs the engine's `glint_occlusion*` PassParams routing.

`PLAGUE_VOXEL_COVERAGE` is a separate switch showing first-surface and behind-cutout tests from the
same walk. Voxel Reach is a slider under Reflections, 1 to 16 chunks in one-chunk steps, default
4; render distance and detail caps still apply.

Limits: finite grid, stand-in leaf shapes, no vertex shading, SSAO, POM, weather layering or Nether
noise, nothing past the second bounce. Cost is unmeasured; no compile check or fixture says how it
looks or how fast it runs.

### Source inventory diagnostic

`PLAGUE_SOURCE_DIAGNOSTIC` is a Debug test control, default Off. Sources marks which sections hold
a light source or a supported glowing material; Freshness shows whether a section's GPU copy
matches the current window and material set. Counts include hidden faces and say nothing about how
much light is given off. Materials the pack cannot read stay unknown. Neither view changes normal
lighting or adds light bounces.

Turning it on adds two GPU buffers, `voxelSectionState` and `voxelSourceSummary`, even with water
reflections off. Each section takes 32 bytes in each buffer; the source buffer also has a 32-byte
header. A compute pass, `voxel_source_status`, checks these records and writes a 256×256 RGBA16F
status image. A final pass, `voxel_source_diagnostic`, draws that image over the normal scene
depth. Graphics code never reads the raw buffers; Fornax's compute/graphics sync hands off the
image instead. A stored alpha of zero marks an image not yet written. Off removes both passes and
their targets, except section state when local coloured lighting also uses it.

At a 25-section window, this adds about 1.45 MiB of GPU memory, including the 512 KiB status image,
on top of the existing voxel grid. Material data is read once, at load and section-build time; each
diagnostic frame only reads the small per-section summary. The overlay, the F10 counters, the
shader compile check and the offline address checks do not prove how much light a source gives off,
prove the GPU output is correct, or measure cost.

Face Colours adds a bounded `voxelEmitterPool` buffer (64-byte header plus 4096 64-byte records)
and a 256×256 RGBA16F thumbnail image, another 768 KiB plus 64 bytes. Fornax admits faces from
committed section snapshots with resumable, bounded CPU enumeration; it republishes the compact pool
only when changed. This is an admission subset, not a complete or nearest-source list. Deferred and
unsupported face counts remain separate; lightmap-only refreshes preserve the geometry keys.

`voxel_source_faces` checks section ownership, geometry/storage revisions and atlas generation,
then evaluates sixteen texture samples per admitted face using raw intrinsic emission, labPBR alpha
and unshaded albedo/tint. Known missing material maps use the unprovided-alpha sentinel. Cutout gaps
emit zero. Overflow atlas pages remain unsupported until this path can address their real textures.
The samples are sparse radiance, not integrated face energy; small glowing texels can be missed.
`voxel_source_faces_overlay` displays them in a corner panel after the other diagnostics. Grey means
unused, magenta means rejected, and black means a valid non-emitting sample. No transport or normal
lighting changes. Both extra passes and targets exist only in Face Colours mode. The panel enters
the engine's final-image history, as other diagnostic overlays do, so it can appear in reflections.

### Source colour preview

`PLAGUE_SOURCE_RADIANCE`, default Off under Debug, compares emitted colour before local-light
transport is added. Source Colour uses unshaded texture and biome tint with intrinsic and authored
emission. Compare Emission shows the existing terrain rule on the left and that candidate on the
right. The existing rule includes baked shade/AO and excludes coal's authored emission; normal
terrain and voxel shading retain their respective policies.

While enabled, deferred terrain stores the two colours in `gAlbedo.rgb` and `gMaterial.rgb`, using
the same fixed `Le/(1+Le)` compression and sRGB transfer. The normal intermediate lighting is then
unsuitable for display. The fullscreen pass `source_radiance_preview` reads exact texels from
`consolidatedGbuf` and depth and replaces the image; sky and nonterrain classes are black. Forward
surfaces and held items can still draw afterward. This uses no extra target and runs no preview
pass when Off. The display encoding is diagnostic only, not a source-energy storage format.

### Experimental local coloured lighting

`PLAGUE_LOCAL_LIGHTING`, default Off under Debug, replaces vanilla placed block light on every
surface. Missing source data and unsupported lamps have no vanilla fallback. Sun/sky, held light
and visible emission remain separate. The shared block-light curve returns zero; forward geometry
samples the zero-block-light column of the vanilla LUT. Raw light values remain available as world
data. A merged lightmap cannot subtract one selected lamp, so replacement is global.

`blocks.toml` opts casting sources in with root `[lighting] voxel = false` and per-category
`lighting.voxel = true`. The engine resolves membership at harvest. Unselected blocks remain
occluders and retain visible self-emission. Reloading source policy rebuilds publications. Opting
in a shape does not manufacture missing face mappings: currently only mapped full unit source
faces are sampled, so partial lamps such as torches and lanterns remain unsupported.

The engine's `voxelSourceWindow` ABI2 is a sparse inventory over committed voxel sections, with
per-section ranges and capacity for 4096 emitting cells. Admitted world identities persist as the
eye moves; capacity overflow withholds new cells instead of dropping admitted lamps. Pending
sections hide their own records while retaining admission. Unknown cells are counted separately.
The header's published/overflow/unknown counts describe committed data, not unloaded world space.
A source's validity is checked against its section owner, storage and geometry revision. A pending
or unsupported source contributes nothing; it does not cancel other known sources.

Static source sprites on overflow pages retain their existing seven-word face mapping, with the
engine's 1-based page encoded in header bits 27..28. `voxel_local_sources` and the face-colour
diagnostic append `builtin.blockAtlasPages` and `builtin.materialAtlasPages` as array samplers;
shared page sampling remaps ghost UVs to the original layer before fetching either lane. The
1x1x1 retirement fallback and missing layers are unavailable sources. Animated ghosts without a
full-copy layer remain unsupported. Material alpha still distinguishes authored zero from the
unprovided sentinel on every page; neither source eligibility nor emission changes with resolution.

`voxel_local_sources` evaluates sixteen midpoint atlas samples per eligible face and reduces them
to four quarter-face radiances. `voxel_local_direct` integrates those area samples from the actual
visible surface, using emitter cosine, inverse-square transport and the material BRDF. Candidate
section ranges come from the receiver's 27 neighbouring sections. The authored finite domain is
12 blocks from each source, with a smooth taper only from 9 to 12 blocks. There is no camera-range
fade and no limit of three contributing faces. Adding known lamps adds their contributions.

Full opaque cubes beside a source's forward cell clip its visible face area analytically when
the receiver lies within the other tangent slab. A full cube is the engine's boxCount-0 palette
entry, with neither the cutout nor the cross bit set. The clipping uses the same snapped and
biased endpoints as shadow traversal. Each quarter keeps its radiance, weights by its surviving
area, and traces from a point inside that area that shifts a little per pixel and per frame. The
shift is interleaved gradient noise stepped by the golden-ratio fraction each frame, so the
engine's temporal reconstruction settles the result over a few frames instead of leaving a fixed
step at each quarter edge. This avoids whole-quarter visibility steps at certified alcove side
walls without adding rays. Unknown, partial, cutout and unsupported silhouettes retain ordinary
quadrature. Every surviving sample still traces the complete shadow segment.

`PLAGUE_LOCAL_EMITTER_SIZE`, default Quarter block, sets the size of the square that gives off
light, centred on the face: the whole face (Full face), half its side (Half block) or a quarter of
its side (Quarter block). The four quarters are cut from that square first and only then clipped
by the aperture, so a certified side wall still clips smoothly instead of switching a whole
quarter on or off. Each quarter's weight divides by the square's area, so a smaller square gives
off the same total light as the full face. Only the spot the light comes from gets smaller, which
lets a thin block fully shadow a face instead of hiding only a sliver of it.

Visibility follows finite voxel segments from source toward receiver, rejecting nearby source-side
blockers early, with opaque blocks, partial boxes, atlas-alpha cutouts, and the engine's published
nearby-body bounds. Each segment is tested against every published body's axis-aligned box, so a
player, a mob or a dropped item inside a light's range casts a shadow the same way a wall does.
The shadow is the plain box; which way the body faces and how it moves do not shape it. An item's
box is first shrunk about its centre to half its width and depth, so it matches the drawn sprite
and not the wider collision box; height stays as published. It asks whether
geometry blocks the segment, independently of whether a hit has a usable reflection colour.
Missing or pending segment data fails closed for that sample. Rendered opaque
backing is a separate face-metadata bit from a usable atlas mapping; grass overlays therefore
cannot turn their opaque cube backing transparent. Terrain carries the primitive's geometric
normal in `gNormal.a`, encoded for the target's actual SNORM16 format; exact axis codes preserve
cube faces. Normal maps affect the BRDF, not which side the shadow ray starts on. Geometry stages
without this payload use their shading normal as a fallback.

Grass and foliage use actual visible points rather than a cube-face receiver cache. Known thin
cutouts with labPBR subsurface response split diffuse energy between reflection and transmission,
up to half in each hemisphere. This is an authored thin-sheet approximation, not volume scattering;
opaque-backed grass faces do not transmit. Cutout occluders use the harvested model's approximation:
two crossed planes for CROSS, the unit cube for a full cutout cell, and each stored box's own faces
for a partial cutout (a door, trapdoor, pane or iron bars). The sprite rect is stretched across
that box, and a box thinner than a quarter block reads as solid. Outside the certified aperture
case, four area samples can leave visible steps in a penumbra; the per-quarter shift turns those
steps into noise that temporal reconstruction settles over a few frames. Quarter radiance and
shifted-sample integration do not resolve arbitrarily small emissive details or exact specular
area-light response.

Primary lighting has a separate HDR target so its cost and output can be measured. RGB holds local
radiance; alpha carries the cloud-shadow mask. Resolve reads both through its existing input 15,
keeping the Metal sampler budget the same. With local lighting Off,
`voxel_local_off` copies only the cloud mask into the same target. The source producer does not run.
Secondary voxel surfaces use the same direct-light transport, without a primary screen cache.
This is direct lighting, not bounced GI; reflected hits have no per-hit fluid classification and
the local transport does not integrate water absorption along a segment.

Visible emission and received source radiance share the scale derived by
`tools/derive_local_emission.py`: a white unit face one block from a neutral rough wall matches the
legacy block-14 reference luminance at the documented fixed settings. This establishes relative
scene units, not measured lumens. Off keeps the legacy emission scale.

The radiance buffer occupies 1,991,496 bytes and remains allocated for fixed bindings while Off.
The engine sparse source inventory adds 418,632 bytes while enabled. Section state adds 32 bytes
per voxel section when not already allocated. The full-resolution RGBA16F direct target consumes
8 bytes per pixel. Geometry buffers are shared with reflection tracing. Fornax synchronizes compute
writes before graphics reads, and previous graphics reads before subsequent compute writes.
Native shader fixtures verify transport and ABI cases; they do not establish the installed resource
pack's appearance or live Vulkan frame cost. Owner validation remains required.
