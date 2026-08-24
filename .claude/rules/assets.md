---
paths: "{ASSETS.md,THIRD-PARTY-NOTICES.md,shaders/textures/**,tools/generate_*.py,tools/captures_dir.py,tools/resource_packs.py}"
---

# Asset Standards

## Rules

1. **Nothing enters the tree without a row.** A binary needs a row in `ASSETS.md`; third-party code
   needs one in `THIRD-PARTY-NOTICES.md`. Each names a source and a licence that permits
   redistribution under MIT. A file whose provenance cannot be stated does not go in: it gets
   regenerated, replaced, or resolved at run time from something the user already has.
2. **Block textures and captures are deliberately not committed.** They are not ours to
   redistribute, and they are large. Both resolve at run time — textures from the installed resource
   pack, captures from `$PLAGUE_CAPTURES` (default `~/plague-captures`). See
   `tools/captures_dir.py`. A tool that needs one skips its comparison and says so when it is
   absent; it never crashes and never silently passes.
3. **Pack-declared textures must contain real PNG bytes.** Minecraft's `NativeImage` decodes them;
   renaming a JPEG to `.png` fails with `bad png signature`. Convert properly.
4. **Generate authored tables with a committed script.** The generator is the provenance:
   `tools/generate_foam.py` builds `water_foam.png`, `_n` and `_h` from what foam physically is, with
   every lattice periodic so the tile is seamless by construction. Rerun it and you get the file.
5. **Machine-generated assets get a row in `ASSETS.md`** like anything else. Check the
   distribution rules of wherever the pack is being listed before publishing — storefronts differ on
   what they accept, and an icon or banner is the usual sticking point.

## Patterns

An `ASSETS.md` row carries more than a licence. Write down what someone would need later and
cannot reconstruct from the file itself: how it was produced, what a regenerating script is called,
which channel carries the signal.

`tools/resource_packs.py` and `tools/captures_dir.py` are the two run-time resolvers. A tool that
needs external artwork goes through them rather than reaching into a path directly.

## Anti-Patterns

- Committing a capture, a block texture, or anything under `tools/textures/` or `tools/captures/`.
  Both are gitignored for a reason.
- Adding a binary and filing its `ASSETS.md` row "later".
- Hand-editing a generated texture instead of the generator that produced it. The next rerun silently
  reverts the edit and the provenance claim becomes false.

## Checklist

- [ ] Every new binary has an `ASSETS.md` row naming source and licence
- [ ] Every new third-party code file has a `THIRD-PARTY-NOTICES.md` row with its full licence
      text reproduced inline (there is no `licenses/` directory; the notices file carries the text)
- [ ] Generated assets have their generator committed alongside them
- [ ] No capture or resource-pack artwork added to the tree
