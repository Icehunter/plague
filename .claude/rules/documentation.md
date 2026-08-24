---
paths: "**/*.md"
---

# Documentation Standards

## Rules

1. **Never name another pack as a source**, in a doc, a comment or a commit message. There is no
   exception and no document that is allowed one.
2. **State what was measured, not what it was measured against** (`91ad2db`). A finding is
   "the wall reads 1.07 degrees of mean tilt", not "closer to the reference than before".
3. **Record the decision and its trail, not only the outcome.** A decision without its measurement
   gets re-litigated in three weeks. Close-out records and investigation notes live in `docs/local/`,
   which is on disk and deliberately outside git; only the permanent documents below are tracked.
4. **A green lint is not a clearance** (`d200196`). Say what a check can and cannot establish
   whenever you report it.
5. **`docs/KNOWN-ISSUES.md` is one line per open defect**, pointing at the code. An issue states
   what is seen and what would resolve it. The long diagnostic write-up behind it belongs in
   `docs/local/`, not in the shipped document.

## Patterns

Which document owns what:

| File | Owns |
|---|---|
| `AGENTS.md` | The working rules. `CLAUDE.md` is a one-line import of it |
| `.claude/rules/clean-room.md` | The provenance protocol — the authority, not a summary |
| `README.md` | What Plague is, what it needs, how to install it |
| `docs/ARCHITECTURE.md` | The render graph as `graph.toml` declares it: passes, targets, ordering |
| `docs/FEATURES.md` | What currently works, verified against the graph and the shader tree |
| `docs/KNOWN-ISSUES.md` | Open defects, one line each |
| `docs/RELEASING.md` | How a release is cut |
| `docs/local/` | Working notes and investigation records. On disk, never tracked |

**Commit messages are lowercase imperative sentences describing the effect**: "move the underwater
view warp to the final frame, on the owner's own field"; "record why a green notices lint is not a
clearance"; "correct the refraction pass's documentation and remove its dead code". No ticket
prefixes — this repository's numbered work is a local roadmap, not a Jira board.

## Anti-Patterns

- A comment that explains why a constant was chosen *in place of* stating where it came from. The
  provenance is the paper, the measurement, or the render — not the rationale.
- Deleting a source-naming comment on its own. It must go in the same change as the code beneath it.
- Documenting an intended behaviour as a current one. `docs/FEATURES.md` marks anything
  experimental, opt-in or unfinished as such.

## Checklist

- [ ] No external project named in the doc, the comment, or the commit message
- [ ] Findings state the measurement, with units
- [ ] Any check reported alongside what it cannot establish
- [ ] The right document updated: features to `FEATURES.md`, open defects to `KNOWN-ISSUES.md`
- [ ] Commit message is a lowercase imperative sentence describing the effect
