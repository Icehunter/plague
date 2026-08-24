# Releasing

A release of Plague is the pack folder, zipped, with nothing else in it.

## Cutting a release

1. Bump `version` in `pack.toml`. That field is the pack's identity to the engine and to the
   settings screen; nothing else carries a version number.
2. Run the gates. `tools/check_shaders.sh` must be green: it compiles every pass under every arm
   its `variants_for()` declares, then runs the water verifiers. A pass that compiles is not a pass
   that works, so a release also needs the pack loaded in a client and looked at.
3. Update `docs/FEATURES.md` if the feature set moved, and `docs/KNOWN-ISSUES.md` if anything was
   fixed. A fixed issue is deleted from that file, not struck through.
4. Tag `v<version>`. `.github/workflows/release.yml` checks the tag against `pack.toml`, refuses
   the release if they disagree, builds the zip and publishes it. Running the workflow by hand from
   the Actions tab does everything except publish, which is the dry run.

## What goes in the zip

Everything the engine reads, and nothing else:

```
pack.toml  graph.toml  screens.toml  blocks.toml
shaders/
```

`docs/`, `tools/`, `.claude/` and the notices files are repository material, not pack material. The
engine never reads them and a player never needs them. The release workflow copies only the four
TOMLs and `shaders/`, so this cannot drift by someone forgetting to trim a directory.

## Checking the zip

Fornax loads a pack from a folder or a zip identically, so the check is to drop the zip in
`shaderpacks/`, select it, and confirm the settings screens populate. A pack that fails to load says
why: a missing `#moj_import` names the file it could not resolve, and a malformed option annotation
names the line.

## Assets

Every binary in the release has a row in `ASSETS.md`, and every piece of third-party code has a row
in `THIRD-PARTY-NOTICES.md` with its licence text. Both files are the gate: no row, no entry into
the tree, and therefore no entry into a release.

Check the distribution rules of wherever the pack is being listed before publishing: storefronts
differ on what they accept, and icons and banners are the usual sticking point.
