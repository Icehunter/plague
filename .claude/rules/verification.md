---
paths: "tools/**"
---

# Verification Standards

There is no CI and no test framework in this repository. Verification is an offline apparatus under
`tools/`: one compile check, per-subsystem offline models, parity fits against measured fixtures,
table generators, and a renderer for eyeballing a look change.

**Most of it is local-only and deliberately not tracked.** Only the table generators ship, because
shaders cite them as the provenance of their constant tables. Everything else exists on disk, works
exactly as described below, and is no use to someone installing a shaderpack. If a path in this file
is not in the repository, that is why — not because it is missing.

## Rules

1. **`tools/check_shaders.sh` is the compile gate.** It flattens `#moj_import`, then
   compiles every pass under the arms listed in its own `variants_for()`, and finishes by running
   four water verifiers — 46 source files, 153 compile invocations and 565 checks green as of
   2026-08-23.
   `tools/pre-commit` runs it — and the attribution lint first — whenever a
   commit touches `shaders/`, `graph.toml`, `screens.toml` or the notices files. Install with
   `tools/install-hooks.sh`; it symlinks the tracked hook so updates take effect without reinstalling.
2. **A default arm compiling is not a check.** An option that is default-off preprocesses its whole
   feature away and the script reports `ok` on code that never met a compiler. This is the most
   repeated failure in the repository's history; add the variant in the same change.
3. **A harness must reproduce a real defect before it is trusted.** A model that cannot show the
   photographed bug is testing assumptions, not the shader. If a verifier goes green while the game
   shows the bug, the verifier is wrong.
4. **Never launch Minecraft.** Live verification comes from the user's own sessions: they launch,
   they report. If a task needs in-game evidence, say so and stop.
5. **A missing capture SKIPS and says so.** `tools/captures_dir.py::require()` returns `None` when a
   reference frame is absent; callers treat that as "this check did not run" and report it. Never
   crash, and never silently pass.
6. **Do not create a commit until the owner has run the change locally.**

## Patterns

```bash
tools/check_shaders.sh              # compile every pass under every declared arm
tools/install-hooks.sh              # symlink tools/pre-commit into .git/hooks (idempotent)
python3 tools/verify_<subsystem>.py # one offline model; prints ok/FAIL per check, exits non-zero
python3 tools/verify_notices.py --report    # per-file table of the text lint
python3 tools/render_look.py <mode>         # PNGs into tools/out/ for eyeballing
python3 tools/derive_<subsystem>.py         # regenerate a constant table (tracked: it IS the
                                            #   provenance of the numbers it emits)
```

`glslangValidator` is required by the compile gate (`brew install glslang`); the pre-commit hook
skips cleanly when it is absent so a machine without Vulkan tooling can still commit.

**A verifier parses the live GLSL rather than restating its constants.** `verify_water_waves.py`
opens `shaders/include/water_waves.glsl` and `shaders/post/water_composite.fsh` and reads the numbers
out of them, so the model cannot drift away from the shader. Follow that: `check(name, condition,
detail)` printing `ok`/`FAIL`, a failure list, and a non-zero exit.

**A verifier states its own limits.** `verify_water_waves.py` says what it can reject and what
"remains an in-game launch check". Write that down; it is what stops a green run being read as a
clearance.

**`tools/fixtures/*.json` pin behaviour at a named commit** (`caustics-behavior-0804193.json`). A
parity fit compares against the fixture, not against a memory.

**Render before shipping a look change.** The offline renderer exists because sixteen
constant-tweak launches failed to converge on the caustics: nobody had rendered the thing being
tuned. Render the
user's actual scene at the user's actual option values, then pick the constant off the picture.

## Anti-Patterns

- Reporting a change verified because `check_shaders.sh` said `ok`, when the new code sits behind a
  default-off option with no variant.
- Reading option defaults out of a shader instead of the user's live `Plague.txt`. A `#if` means the
  shader you read may not be the one running.
- A verifier that hardcodes a constant the shader also declares. It will pass forever after the
  shader changes.
- Treating a green `verify_notices.py` as a provenance clearance. It gates names, not expression.
- Adding a compensation constant while guessing. Delete it once the root cause is found, or the real
  fix will look broken.

## Checklist

- [ ] `tools/check_shaders.sh` green, with a variant covering the new or newly-gated arm
- [ ] The relevant `verify_*.py` run, and its stated limits repeated when reporting the result
- [ ] The harness demonstrably reproduces the defect being fixed
- [ ] Look changes rendered — the user's own scene, the user's own option values — and looked at
- [ ] Minecraft was never launched
- [ ] No commit created before the owner ran it
