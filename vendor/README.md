# Vendored third-party dependencies

This directory contains pinned copies of third-party SourceMod plugin binaries
that would otherwise be downloaded at install time from GitHub releases.

Vendoring them here:
- Guarantees **reproducible installs** regardless of upstream release history
- Enables **offline installation** (no GitHub connectivity required)
- Ties the binary to a known-good version **verified by SHA256 checksum**

The installer (`installer/steps/06_sourcemod.sh`) copies these files first and
only falls back to a live download if the file is missing.

---

## Plugins

### `sourcemod/plugins/levels_ranks.smx`

| Property | Value |
|---|---|
| Plugin | Levels Ranks Core |
| Version | `3.1.6` |
| Source | https://github.com/levelsranks/pawn-levels_ranks-core/releases/tag/v3.1.6 |
| SHA256 | `a17155442448f5ff757a50677bb7035c7ab6badf542680293ef858669eaeaa7c` |
| Installer var | `LR_VERSION` / `LR_SHA256` in `installer/globals.sh` |

### `sourcemod/plugins/serverredirect.smx`

| Property | Value |
|---|---|
| Plugin | ServerRedirect |
| Version | `1.3.1` |
| Source | https://github.com/GAMMACASE/ServerRedirect/releases/tag/v1.3.1 |
| SHA256 | `8947e3028ae2762a580044ce5412c5d8201f005ff4702b65e5dd8065a5054839` |
| Installer var | `SR_VERSION` / `SR_SHA256` in `installer/globals.sh` |

---

## Updating a plugin

1. Download the new `.smx` from the GitHub release page
2. Compute its SHA256: `sha256sum <file.smx>`
3. Copy the `.smx` to the appropriate path under `vendor/sourcemod/plugins/`
4. Update the corresponding `*_VERSION` and `*_SHA256` constants in
   `installer/globals.sh`
5. Commit both the binary and the `globals.sh` change together

> The `.gitignore` contains a `!vendor/**/*.smx` exception so these committed
> binaries are not excluded by the global `*.smx` rule.
