---
paths: "**/*"
---

# Clean-Room Provenance Standards

The provenance protocol for this repository. This is the whole of it; there is no second copy under
`docs/`.

## The one rule everything follows from

**Copyright protects expression, not ideas.** Plague ships under MIT, which is a *grant* — you
cannot grant what you do not own. The bar is not "does it look different", it is "did this come out
of my own reasoning".

Reading other shaderpacks is how you learn what is possible, and it is not off limits. The reading
and the writing have to be separated, and that separation is what this file is.

Free to use, always:

- That a technique exists and roughly how it works. *"Cloud coverage is a noise field thresholded
  and lit by a two-lobe phase function"* is a fact about the world.
- Published mathematics, cited. Lottes' tonemap curve, Hammon's diffuse model, Cornette–Shanks, GGX,
  Rayleigh and Mie coefficients, Pope & Fry's absorption spectrum, the Keys cubic kernel, Pascal's
  binomial row, Jimenez's interleaved gradient noise, Roberts' R1 sequence. Cite the paper and
  implement it.
- Which API calls a thing requires, and which vanilla behaviour has to be worked around. There is
  usually one way to call an API, and that is not authorship.
- Measurements you take yourself, including measurements *of* another pack's output. Observing that
  one renderer draws a brick face flat where yours draws it rounded is your observation.

Never free:

- The specific sequence of statements, the identifiers, the structure, the comment text.
- **Authored constants** — numbers encoding taste rather than physics: a colour table, a damping
  rate, an octave count, a threshold, a slider range.
- **A deviation from published physics.** The sharpest tell there is. Where a scattering or
  absorption coefficient differs from the value in the literature it cites, that difference is a
  *choice*, not a measurement, and there is no innocent route to arriving at it. Take the number
  from the paper; then any divergence is theirs, not yours.
- Option names, defaults and value ranges. Those are authored too.

## The two-context rule — NON-NEGOTIABLE

**A context that has read another pack may not write the implementation.**

| | Reader | Writer |
|---|---|---|
| May open another pack | **Yes** | **No — never** |
| Produces | A behavioural spec, in prose | The implementation |
| May carry numbers from what it read | **No** | n/a |
| Compares the result against what it read | **No** | n/a |

With agents: one subagent reads and returns a prose spec; a **separate** subagent implements from
that spec and is given no path to the source. Never do both in one context, and never paste the
source into the writing context "just to check" — checking is how statement order gets reproduced.

The reader's output is the airlock. If a fact cannot survive being written in prose, it is
expression and it does not cross.

A good spec describes mechanism and carries no expression:

> Stars are a hash lattice on the sky sphere. Tile the direction into cells, hash each cell, and
> draw a star where the hash clears a cutoff, with a soft edge so it does not alias. Several cutoffs
> at different densities mix many faint stars with a few bright ones.

The writer picks the hash, the cell resolution, the cutoffs, the edge softness, the tint, the gain.
Those choices are then the writer's.

A bad spec is a translation with the syntax filed off — one that pins a specific hash function, a
specific cell resolution, a specific ordered set of thresholds. That is a defect even when it names
no numbers, because a writer handed it goes and looks them up.

## Constants

Every constant is one of two kinds:

- **Physically derived** — keep, but cite the paper, measurement or standard in the comment. The
  labPBR decode thresholds qualify: the format spec dictates them.
- **Authored** — must be your own. Pick it off a render, tune it in game, or derive it from a
  property you can state. Then write down *why*. `// 0.58 because the trough weight makes the
  ripple volume-neutral over the radial measure` is a defence; the same number bare is a liability.

**When you cannot tell which kind it is, it is authored.** Assume the stricter rule.

A rename is not a re-derivation. Changing what a value is called, or re-spelling it as an arithmetic
expression that evaluates to the same thing, hides it from a text search while preserving exactly
the thing that mattered. Derive it forwards from a stated criterion, and let it land where it lands.

## Comments and commit messages

**Never name another pack or renderer as a source**, in code or in a commit message. Not a "ported
from" note, not a "matches their default" note, not a line-number citation into another tree. <!-- NOTICE-OK: forbidden phrasings, described as examples -->
Describe the mechanism on its own terms instead. `// warm torch tint, picked against the dusk
capture` says more to the next reader than a pointer at somebody else's variable ever did.

**One hard sequencing rule.** A comment describing where code came from is only ever removed in the
same change that replaces the code beneath it — never ahead of it. Removing the note while keeping
the code changes nothing about the code and looks like concealment.

Interoperability naming is fine and is not what this is about: `heldBlockLightValue`,
`isEyeInWater`, the `gbuffers_*` program names and the labPBR channel layout are a published
interface this pack implements. Naming an interface in order to speak to it has never been
infringement.

## Provenance records

Two ledgers, both root-level, both "no row, no entry into the tree":

- **`THIRD-PARTY-NOTICES.md`** — every piece of *code* in the pack that someone else wrote, with its
  licence text reproduced in full.
- **`ASSETS.md`** — every *binary* in the repository, with its source and a licence permitting MIT
  redistribution. A file whose provenance cannot be stated gets regenerated or replaced, not
  grandfathered.

`tools/verify_notices.py` is the attribution lint and `tools/pre-commit` runs it before the compile
gate. It catches a project *name*; it cannot catch a euphemism or a transcribed statement order, so
it is a backstop and not the protocol.

## What to record as you go

The derivation trail is the affirmative half of this. Absence of a bad comment proves nothing;
presence of a good one proves a lot.

Generate authored tables — start positions, palettes, sample kernels — with a committed script
rather than pasting numbers. The script is the record that the table is yours, and it re-runs.

Where a look must be preserved across a rewrite, measure the accepted build's **output** into a
numbers-only fixture under `tools/fixtures/` and fit to that. Measurement of output is data, not
expression. Measure the sub-field a viewer actually tracks, not just an aggregate — an aggregate
statistic can be satisfied by the wrong term while the thing you care about does not move.

## The convergence test

After a rewrite, compare against the old build:

- **Close but not identical** — correct. You solved the same problem and made your own choices.
- **Identical** — the rewrite failed. Do it again.
- **Wildly different** — probably a bug, not freedom. Check the mechanism before celebrating.

A pack that looks the same is not the goal, and a pack that looks worse is not the price. The goal
is a look you chose.

## Checklist

- [ ] The context that wrote this never opened another pack's source
- [ ] Every authored constant has a provenance comment
- [ ] Every cited formula names its paper
- [ ] No comment or commit message names another project as a source
- [ ] Any new bundled code has a row in `THIRD-PARTY-NOTICES.md` with its full licence text
- [ ] Any new binary asset has a row in `ASSETS.md` naming a source and an MIT-redistributable
      licence
