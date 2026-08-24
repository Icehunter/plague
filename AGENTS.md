# Plague: AI Assistant Rules

## Project Overview

Plague is a shaderpack, a player-supplied bundle of shader programs and settings that replaces how
a Minecraft world is lit and drawn, written for the **Fornax** engine, a Vulkan deferred renderer
that ships as a Fabric client mod. Fornax hardcodes no pipeline: this pack declares its render
passes, render targets and player-facing options in TOML, and the engine's graph interpreter walks
them. Everything visible in game is authored here; the engine only routes.

The pack ships under MIT (`Copyright (c) 2026 Ryan Wilson`, see `LICENSE`). Fornax lives in the
sibling repository `../fornax` and is the only side of the pair that needs a build.

**The visual north star**: physically-motivated light, time of day, real sources, bounces, at the
best framerate that allows.

## Before you write shader code, read `.claude/rules/clean-room.md`

That document is the working protocol for this repository, not background reading. The licence
landscape it sits in, and what each position allows:

| Neighbour | Licence | What you may do |
|---|---|---|
| **Fornax** | MIT | Read it freely. Same owner, and the ABI this pack speaks to. Dependencies run one way, pack to engine, never the reverse. |
| **Any other shaderpack** | mostly all-rights-reserved | Read to learn what is possible. Take nothing: not code, not constants, not option names. Reader and writer must be separate contexts. |
| **The labPBR spec** | a published format spec | Implement it. Its decode thresholds and channel meanings are dictated by the format and are yours to use. **A pack's data authored to spec IS the default look**: roughness controls *what* a metal reflects, never *whether*. |
| **Published literature** | papers | Cite the paper and implement it. Lottes, Hammon, Cornette–Shanks, GGX, Pope & Fry, Jimenez, Roberts. |

The two rules that bite most often:

1. **A context that has read another shaderpack may not write the implementation.** Reader produces
   a prose spec with no code, no identifiers and no constants; a separate writer implements from the
   spec and never opens the reference. Doing both in one context is how statement order gets
   reproduced.
2. **Never name another pack as a source** in code or in a commit message. Not a "ported from"
   note, not a "matches their default" note, not a line-number citation into another tree. Describe
   the mechanism on its own terms instead.

Naming a shader ABI to interoperate with it (`heldBlockLightValue`, `isEyeInWater`, `gbuffers_*`,
Fornax's `builtin.*` inputs) is fine and is not what rule 2 is about.

`.claude/rules/clean-room.md` is the protocol in full. It is the authority, not a summary.

## Mandatory Workflow

**Follow these steps for EVERY change. No exceptions.**

1. **Check the licence position first.** If the task involves reading any other pack, split reader
   and writer contexts before a single line is written.
2. **Read the user's actual option values, not the shader's defaults.** A `#if` means the file you
   are reading may not describe the shader that is running.
3. **Implement the smallest correct change**, and give every authored constant a provenance comment.
4. **Register what needs registering.** A new option is invisible until it is on a screen in
   `screens.toml`. A new pass file is never executed until a `[[pass]]` names it. A new preprocessor
   arm is never compiled until `tools/check_shaders.sh` has a variant for it.
5. **Verify**: `tools/check_shaders.sh` plus the relevant offline verifier. A look change is not
   verified by a compile; it needs a picture, and ultimately the owner's own eyes in a client.
6. **Say explicitly when the edit set is complete.** This pack is live in the user's profile
   (below). Only then is it fair to ask for an in-game reading.

### Commands

```bash
tools/check_shaders.sh              # Compile every pass under every declared arm, then the water verifiers
tools/install-hooks.sh              # Symlink tools/pre-commit into .git/hooks (idempotent)
python3 tools/verify_<subsystem>.py # One offline model; ok/FAIL per check, non-zero on failure
python3 tools/derive_<subsystem>.py # Regenerate a constant table; the script IS the table's provenance
```

**Only the generators are tracked.** `derive_*.py`, `generate_foam.py` and the `plague_*` modules
they import are in the repository because shaders cite them as the origin of their constant tables:
rerun one and you get the shipped numbers. The rest of `tools/` is local: an offline verification
apparatus that is no use to anyone installing a shaderpack. It is on disk and fully working; it is
just not part of what this repository publishes.

There is no CI and no test framework here. `tools/pre-commit` is the gate: it runs the lint, then the
compile check, whenever a commit touches `shaders/`, `graph.toml`, `screens.toml` or the notices
files. `glslangValidator` is required (`brew install glslang`); the hook skips cleanly without it.
Python tooling needs `numpy` (and `Pillow` for renders).

**Never launch Minecraft.** Live verification comes from the user's own sessions: they launch, they
report. If a task needs in-game evidence, say so and stop rather than launching. **And do not create
a commit until the owner has run the change locally.**

## This pack is symlinked into the Minecraft profile

Edits to `shaders/`, `graph.toml` and `screens.toml` are live the moment they are written. Batch your
edits and say explicitly when a set is complete and safe to load. Never ask for an in-game reading
while a change is half-written: a "broken shader" report taken mid-edit is a false signal.

## Assets

Nothing enters the tree without a row in `ASSETS.md` (binaries) or `THIRD-PARTY-NOTICES.md` (code)
naming a source and a licence that permits MIT redistribution. Block textures and reference captures
are deliberately **not committed**: they resolve at run time from the installed resource pack and
from `$PLAGUE_CAPTURES` (default `~/plague-captures`). See `tools/captures_dir.py`, and
`.claude/rules/assets.md` for the rest.

## Core Principles

### The look belongs to the pack; the plumbing belongs to the engine

Fornax routes geometry, declares targets and uploads matrices. Plague picks projection, filtering,
curves and colour. If a change needs new *data* to make a look possible, that is an engine change;
if it needs a different *decision* about existing data, it belongs here. Never ask the engine to
carry block identity into the fragment stage on the pack's behalf: **no IPBR**. Material properties
come from labPBR channels or from the albedo. `blocks.toml` declares exactly one category, water,
and the full argument for why is written at the top of that file.

### A green check is not a clearance

Every gate here has a stated blind spot, and reporting a result means repeating it. The compile gate
proves the arms it was told about compile, not that the feature works, and not that an arm it was
never told about exists. A lint that matches text catches the text it matches and nothing adjacent
to it. A verifier that cannot reproduce the photographed bug is testing assumptions, not the shader.

### Measure, then pick

Sixteen constant-tweak launches failed to converge on the caustics because nobody had rendered the
thing being tuned. Render it at the user's own live option values and *pick the constant off the
picture* rather than guessing and shipping. When a fix is guessed, the
compensation constants added along the way must be deleted once the root cause is found, otherwise
the real fix looks broken.

### Fail loudly, and know where it fails silently

Most of this pack's historical bugs are silent: an uncompiled arm, an unregistered option, a
renumbered positional input, an unreferenced include. `.claude/rules/` lists them by file. When you
add a mechanism, ask what its silent-failure mode is and write it into the file's own comment:
one or two lines, stating the failure a reader could not otherwise predict.

## Modular Rules

Detailed standards in `.claude/rules/`:

| File | Applies To | Content |
|---|---|---|
| `clean-room.md` | everything | Reader/writer split, authored vs derived constants, comment and commit rules |
| `shaders.md` | `shaders/**` | GLSL conventions, option grammar, arm coverage, includes, live-edit protocol |
| `graph-format.md` | `*.toml` | Positional inputs, targets, `enabled_if`, screen registration, no-IPBR |
| `verification.md` | `tools/**` | Compile gate, offline models, what proves a change and what does not |
| `assets.md` | binaries, notices | `ASSETS.md`/`THIRD-PARTY-NOTICES.md` rows, captures, generated textures |
| `documentation.md` | `**/*.md` | Which doc owns what, comment provenance, commit messages |

---

## Reference Information

### Stack

- **Shaders**: GLSL `#version 330 core`, compiled by Fornax through shaderc for Vulkan. Includes use
  Mojang's `#moj_import`: `<fornax_runtime:foo.glsl>` for this pack's `shaders/include/`,
  `<fornax:foo.glsl>` for engine-shipped ones. `materials.glsl` is *generated* by the engine from
  `blocks.toml`.
- **Manifests**: TOML: `pack.toml`, `graph.toml` (54 passes), `screens.toml` (the YACL settings UI),
  `blocks.toml` (one material category).
- **Tooling**: Python 3 with `numpy`, plus `Pillow` for renders; `glslangValidator` for the compile
  gate.
- **Engine**: Fornax at `../fornax`. Java 25, Gradle, Fabric, Minecraft 26.2, alongside Sodium.
- **Options**: `#define NAME <default> //[<values>] compile "Label" {0="Off" 1="Fancy"}`. `compile`
  marks a compile-time option; only those may appear in an `enabled_if`. Omit it for a runtime
  option, which reaches the shader through `u_PackOptions`, and which therefore cannot be declared
  in a geometry pass at all.

### Code Organization

```text
plague/
├── shaders/
│   ├── blocks/     # 7 geometry stages (14 files, .vsh/.fsh each): terrain, entities,
│   │               #   block_entities, particles, particles_translucent, banner_patterns,
│   │               #   shadow_entities
│   ├── post/       # 28 fullscreen passes: gbuffer_resolve, ssao*, ssr*, hiz_downsample, bloom*,
│   │               #   clouds_*, water_*, underwater_*, exposure_measure, tonemap, glint_occlusion
│   ├── compute/    # 4 stages: the water simulation (prepare, step_a, step_b, commit)
│   ├── include/    # 32 shared .glsl: sky, atmosphere, clouds, brdf, tonemap, fog, water_*, snow,
│   │               #   puddles, emission, celestials, stars, nebula, aurora, ocean_caustics
│   └── textures/   # 4 committed PNGs (caustics + foam trio). Every one has an ASSETS.md row
├── graph.toml      # The render graph: passes in execution order, [targets.*], [textures.*]
├── screens.toml    # The settings UI. An option not listed here is invisible
├── blocks.toml     # Material categories. Exactly one, deliberately
├── pack.toml       # Pack identity
├── tools/          # Tracked: derive_*.py + generate_foam.py + the plague_* modules they import,
│                   #   cited by shaders as the provenance of their constant tables. The rest is
│                   #   local-only: the compile gate, the offline verifiers and their fixtures
├── docs/           # ARCHITECTURE.md, FEATURES.md, KNOWN-ISSUES.md, RELEASING.md
│                   #   docs/local/ is working notes and records: on disk, never tracked
├── ASSETS.md       # Every binary in the tree, with source and licence
└── THIRD-PARTY-NOTICES.md
```

Gitignored working dirs you may see and should not commit: `tools/out/`, `tools/textures/`,
`tools/captures/`, `__pycache__/`. Reference captures live outside the tree entirely, at
`$PLAGUE_CAPTURES` (default `~/plague-captures`); see `tools/captures_dir.py`.

### The silent failures, in one list

- **An uncompiled arm.** An option that is default-off preprocesses its whole feature away;
  `check_shaders.sh` reports `ok` on code that never met a compiler. `PLAGUE_SNOW` shipped this way,
  and `terrain.fsh`'s deferred arm (every opaque block in the world) went unchecked for the pack's
  whole life. Add a `variants_for()` entry in the same change.
- **A positional input, renumbered.** Pass `inputs` arrive as `u_GeomInput0/1/2…`. Inserting one
  hands every later sampler a different texture with no error anywhere. **Append, never insert.**
- **An unregistered option.** Fully working, completely invisible, until it is listed on a screen in
  `screens.toml`, and it is a cycle button, not a slider, until its name is in that file's
  top-level `sliders` array.
- **A mismatched `#define`.** The option scanner merges same-name declarations across files and
  rejects any mismatch as a load error. `SSR_QUALITY` is declared in seven files; change one, change
  all of them character for character.
- **A runtime option in a geometry pass.** No `u_PackOptions` block there; the `#define` is stripped
  and the identifier is left undefined, a hard crash at the first terrain draw.
- **An unclaimed slot.** Fornax's deferred variants resolve only when a pack claims the slot, so a
  pass declaration and the engine hook must land together. Particles were invisible for exactly this
  reason.
- **A dead file.** An include nothing `#moj_import`s, or a pass file no `[[pass]]` names, is text.

### Cross-repo

Fornax is at `../fornax`. Its test suite loads this pack when present, so **a red test over there
can be about this pack's content rather than engine code**: check the failing assertion before
touching engine source. Dependencies run one way, pack to engine. Nothing in the engine should
depend on this pack's option labels.

---

## Code Review Checklist

- [ ] No other pack's source was open in the context that wrote this
- [ ] Every authored constant carries a provenance comment (paper, measurement, or the render it was
      tuned against)
- [ ] No comment or commit message names another project as a source
- [ ] New binary has an `ASSETS.md` row; new third-party code has a `THIRD-PARTY-NOTICES.md` row
- [ ] The look belongs to the pack: no engine change asked for that carries block identity (no IPBR)
- [ ] New or newly-gated arm has a `variants_for()` entry in `tools/check_shaders.sh`
- [ ] Pass `inputs` appended, never inserted; `u_GeomInput*` indices still line up
- [ ] New option listed on a screen in `screens.toml`, and in `sliders` if it has a range
- [ ] Same-name `#define`s updated byte-identically in every file that declares them
      (`grep -rl 'define <NAME>' shaders/`)
- [ ] `tools/check_shaders.sh` green, and the relevant `verify_*.py` run
- [ ] Look changes rendered at the user's own option values and actually looked at
- [ ] Reported results repeat what the check cannot establish
- [ ] Minecraft was never launched
- [ ] No commit created before the owner ran it
