# Rules Directory

Modular standards for Plague. Each file covers ONE concern and names the files it applies to.

**The `paths:` frontmatter is documentation, not a mechanism.** Nothing loads these files by path
glob — they are in context because `AGENTS.md` links them from its "Modular Rules" table, which
means they are all always on or all always off. The key records the intended scope for a reader; it
does not scope anything. Keep that table and the list below in sync, and do not rely on a rule
"only applying" to its glob.

`CLAUDE.md` is a one-line import of `AGENTS.md`, so there is only one entry point to edit.

| File | Applies to |
|---|---|
| `clean-room.md` | everything — provenance protocol, reader/writer split, constants |
| `shaders.md` | `shaders/**` — GLSL conventions, option grammar, arm coverage, includes |
| `graph-format.md` | `graph.toml`, `screens.toml`, `blocks.toml`, `pack.toml` |
| `verification.md` | `tools/**` — the compile gate, the offline models, what proves a change |
| `assets.md` | binaries, `ASSETS.md`, `THIRD-PARTY-NOTICES.md`, captures, resource packs |
| `documentation.md` | `**/*.md` — comment provenance, commit messages, which doc owns what |

## Writing a new rule file

Keep the shape the existing ones use:

```markdown
---
paths: "<glob>"
---

# [Concern] Standards

## Rules            <!-- non-negotiable requirements, with the reason -->
## Patterns         <!-- preferred approaches, with real examples from this tree -->
## Anti-Patterns    <!-- what to avoid and the failure it causes -->
## Checklist        <!-- - [ ] items an agent can verify before finishing -->
```

Two house rules for rule files themselves:

1. **Only document what is observably true in this tree.** Every count, path and constant in these
   files came from reading the code. If you add a claim, verify it first.
2. **State the failure, not just the rule.** "Register the option on a screen" is forgettable; "an
   option not listed on a screen is fully working and completely invisible" is not.
