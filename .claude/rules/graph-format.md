---
paths: "*.toml"
---

# Pack Manifest Standards

Four manifests, all read by Fornax at load: `pack.toml` (identity), `graph.toml` (the render graph,
54 passes), `screens.toml` (the settings UI, 1634 lines), `blocks.toml` (material categories).

## Rules

1. **Pass `inputs` are POSITIONAL.** They arrive in the shader as `u_GeomInput0`, `u_GeomInput1`,
   `u_GeomInput2`… so inserting an entry renumbers every later sampler with no error anywhere — the
   shader simply samples a different texture. `terrain`'s own comment says it: `builtin.noise` is
   THIRD and every puddle, ripple, splash and snow-dusting call reads it as `u_GeomInput2`.
   **Append, never insert.**
2. **Passes execute in declaration order.** Position in the file is semantics, not tidiness.
3. **A blend-only pass must not name the target it blends into as an input.** That is a same-frame
   read-write hazard; `clouds_composite` and `water_composite` both document the convention.
4. **Only COMPILE options may appear in `enabled_if`.** A runtime option has no value at graph-build
   time.
5. **A pass name and its target name are independent identifiers.** Fornax indexes passes by name for
   execution and targets by name for resource resolution. Never rely on the two strings matching
   accidentally.
6. **Declaring a pass is half the fix; the engine hook is the other half.** Particles are the worked
   example: Fornax's deferred variant resolves only when a pack claims the slot, so with no pass here
   the hook declines every group and particles stay invisible. The two land together.
7. **`screens.toml` has three silent failures**, all named at the top of the file: an option not
   listed on a screen is invisible though fully working; a ranged runtime option is a cycle button
   unless named in the top-level `sliders` array; a page not listed under `[yacl]` is unreachable.
8. **`blocks.toml` holds exactly one category and that is deliberate.** No IPBR: material properties
   come from labPBR channels or the albedo, never a per-block table. Water is the sole exception
   because no labPBR channel means "I am water" and the water pre-pass must discard every non-water
   translucent fragment. A second category must re-argue that case from scratch.

## Patterns

```toml
[[pass]]
name  = "clouds_march"
type  = "fullscreen"                 # or "geometry" (with slot =) / "compute"
shader = "shaders/post/clouds_march.fsh"   # geometry passes use program = (stem, no extension)
enabled_if = "CLOUDS_VOLUMETRIC && CLOUD_QUALITY != 2"
inputs  = ["builtin.depth", "builtin.noise"]
outputs = ["cloudsRaw"]

[targets.waterVolumeInterval]
format = "rgba16f"
scale  = 0.5                          # fraction of screen; independent of resource-pack resolution
filter = "linear"
history = true                        # exposes <name>.history for temporal ping-pong
enabled_if = "PLAGUE_UNDERWATER != 0 && WATER_SCATTERING_QUALITY != 0"

[textures.foamTexture]                # a committed PNG under shaders/textures/, needs an ASSETS.md row
```

- **Fixed target dimensions are independent of resource-pack texture resolution.** Never route
  `width`/`height` validation through the atlas override; 256x packs and future 512x support depend
  on that separation.
- **Persistent GPU simulation uses explicit storage targets and temporal ping-pong**: graphics samples
  the completed `.history` image while compute writes its partner.
- **Comment the reasoning, at length.** `blocks.toml`'s single category and `graph.toml`'s particle
  pass each carry the full argument for why they exist. That is the standard here.

## Anti-Patterns

- Inserting an input in the middle of a list "to keep it grouped".
- A pass gated on an `enabled_if` whose option is runtime, not compile.
- Adding a category to `blocks.toml` for convenience. Identity buys nothing unless the alternative is
  genuinely impossible.
- Assuming a mipchain pass name and its declared target name are the same string.

## Checklist

- [ ] New inputs appended, never inserted; shader `u_GeomInput*` indices still line up
- [ ] Blend-only writes do not list their own target as an input
- [ ] `enabled_if` references compile options only
- [ ] New option reachable: listed on a screen, and in `sliders` if ranged
- [ ] New texture has an `ASSETS.md` row and real PNG bytes (see `.claude/rules/assets.md`)
- [ ] `tools/check_shaders.sh` run — the pre-commit gate watches `graph.toml` and `screens.toml` too
