# Forever Journey

A World of Warcraft addon for WoW Forever that records your road from level 1
to 60 and replays it on a zoomable world map: level-coloured paths, hearths,
teleports, boats, deaths, dungeons, loot, and a History and Stats panel.

The addon folder is `ForeverMod/` (its saved variables are `ForeverModDB` and
`ForeverModCharDB`); the name players see is "Forever Journey".

## Development

Needs [LuaJIT](https://luajit.org/) on the path. [Lua Language Server](https://luals.github.io/)
is optional; when installed, `check.ps1` also reports its diagnostics.

```powershell
./check.ps1                      # syntax check, diagnostics, offline tests
```

To play with the source in game, link or copy `ForeverMod/` into
`World of Warcraft/_classic_beta_/Interface/AddOns/`. The source includes the
developer tools (`/fm seed`, `/fm swatch`, `/fm icons`, `/fm probe`,
`/fm terrain`, `/fm levelart`, `/fm tiles`, `/fm perf`).

### Developer-only code

Release builds leave out anything marked like this (the BigWigs packager
convention):

```
# in ForeverMod.toc            -- in Lua
#@debug@                       --@debug@
Seed.lua                       ns.Command("perf", ...)
#@end-debug@                   --@end-debug@
```

Files the stripped toc no longer lists are dropped from the build.

## Release builds

```powershell
./scripts/package.ps1                       # version from git describe
./scripts/package.ps1 -Version 0.9.0-beta   # or explicit
```

This writes `build/ForeverMod/` and `dist/ForeverMod-<version>.zip`, after
checking that every toc file exists, no debug markers remain, every file
compiles, and the build loads in toc order (`tests/release_load.lua`).

### CI

- **CI** (`.github/workflows/ci.yml`): every push to `main` and every pull
  request runs the checks and uploads the release build as an artifact.
- **Release** (`.github/workflows/release.yml`): pushing a tag such as
  `v0.9.0-beta` builds the zip and creates a GitHub release (tags with
  `alpha` or `beta` are pre-releases). It also uploads to CurseForge once
  `CF_API_TOKEN`, `CF_PROJECT_ID` and `CF_GAME_VERSIONS` are set; see the
  comments at the top of the workflow.

```powershell
git tag v0.9.0-beta
git push origin v0.9.0-beta
```

## Branding

`branding/` holds the icon and header art as SVG/HTML sources plus rendered
PNGs. Rebuild the CurseForge header with `branding/build-header.ps1`.
