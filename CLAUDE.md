# Road to Sixty

WoW Forever addon: records a character's road from level 1 to 60 (path,
events, gear, stats) and replays it on a zoomable world map, in the spirit of
Zelda's Hero's Path. Forever launches 2026-11-04 (cap 60); until then it is in
beta (client folder `_classic_beta_`, interface 16001). The recorder matters
most: journey data lost at launch cannot be recreated.

Public repo, all rights reserved (LICENSE). Never commit secrets, personal
paths or email addresses. User-facing name is "Road to Sixty", command `/rts`.

## Layout

`RoadToSixty/` is the addon; files load in toc order and share the addon
table `ns`. Each file starts with a comment describing what it does and,
for data, its exact format; read that before changing a module.

| File | Role |
|---|---|
| Core.lua | saved variable defaults, `ns.On` (event bus), `ns.Command` (slash commands), `ns.SafeCall`, `ns.Print` |
| Recorder.lua | path segments (delta-packed world yards); segment format in its header |
| Journal.lua | events, kills (packed), level snapshots; event kinds in its header |
| Crafts.lua | professions and recipes (`prof`, `rec` events), `/rts craftprobe` |
| Roster.lua | account-wide character list with a copy of each journey; `ns.view`, the journey the map shows |
| Health.lua | `/rts check` |
| Routes.lua | boat and zeppelin docks (`ns.Dock`, `ns.BoatRoute`) and boat sea courses (`ns.SeaCourse`, `ns.CourseCurve`) |
| Map.lua | journey map window, layers, replay, markers |
| ZoneArt.lua | zone map art: overlays, outline and edge masks, `ZoneView` |
| Islands.lua | maps the world map leaves out (Zephras Isle, continent 2991), drawn in the sea at a chosen spot, on a layer above the zone art |
| Portals.lua | hearthstone and teleport portals and the replay's dive through them (`ns.Portals`) |
| PathCurve.lua | walked and flown lines curved through their points when zoomed in (`ns.CurveLines`) |
| MarkerPiles.lua | markers piling up on screen: merged with a count, spread apart, fanned out on hover |
| Panel.lua, GearCard.lua, QuestPop.lua, GuildPop.lua, LevelPop.lua, KillPop.lua, KillMarks.lua | map side panel and replay effects |
| MinimapTiles.lua, ZoneOverlays.lua, ZoneMasks/ | generated data, do not edit by hand |
| Probe.lua, Seed.lua, Swatch.lua, IconBrowser.lua, GuildProbe.lua, PartyProbe.lua, LevelProbe.lua | developer tools, left out of releases |

Saved variables: `RoadToSixtyDB` (account) and `RoadToSixtyCharDB`
(per character, `version` field; bump it when the layout changes).

## Commands

```powershell
./check.ps1                         # LuaJIT syntax check, LuaLS diagnostics, offline tests (tests/*_test.lua)
./scripts/package.ps1               # release build to build/ and dist/, plus a load test in toc order
./scripts/sync-version.ps1          # set the toc Interface from the installed client after a patch
python scripts/zone-overlays.py <build>   # regenerate ZoneOverlays.lua and ZoneMasks/ (needs Pillow)
```

Run `check.ps1` from the repo root. It currently reports two old type
warnings (Probe.lua:52, Recorder.lua:281); anything new is ours to fix.

## Release

1. Add the version's section to CHANGELOG.md as features land: `## X.Y.Z`
   with `### New` and `### Fixed`, non-technical, written for players.
   `bash scripts/changelog.sh X.Y.Z` prints what the release will use.
2. Run `check.ps1` and `scripts/package.ps1`, commit, and push `main`.
3. Push an annotated tag: `git tag -a vX.Y.Z -m "Road to Sixty X.Y.Z"`, then
   `git push origin vX.Y.Z`. The version comes from the tag; tags containing
   `beta` or `alpha` become pre-releases.
4. The Release workflow fails at once if the changelog section is missing,
   then checks, builds, makes the GitHub release with the zip and the notes,
   and uploads to CurseForge. Watch it to the end (`gh run watch <id>
   --exit-status`): the GitHub release can succeed while the upload fails.
5. If only the CurseForge upload failed, fix the cause on `main`, then run
   `gh workflow run curseforge-check.yml -f tag=vX.Y.Z`. It uploads the
   existing GitHub release's zip with its notes. Never move or re-push a
   tag. Without a tag, that workflow only checks the token and game version.
6. Sweep the issues (see below).

The CurseForge description and screenshots are not synced; they are
edited on CurseForge by hand.

## Work tracking: GitHub issues

Features, bugs and their context live in GitHub issues on this repo (`gh`).
Treat them as the shared memory of what is planned, decided and done.

- Before starting a feature or fix, look for its issue (`gh issue list`,
  `gh issue view <n>`) and read it with its comments. If there is none and
  the work is more than a quick fix, open one.
- While working, comment on the issue when something worth keeping happens:
  a decision and why, an API verified or found blocked on Forever, a design
  change, what Jordan picked from a screenshot, what is left.
- Keep the issue body's plan current if the design changes; the body is the
  summary, the comments are the history.
- Reference the issue in commits (`Guilds: record joining (#5)`). Close it
  with a short summary comment of what shipped and in which version once
  the work is released (tagged and published), not when it is committed.
  Open follow-up issues for anything deferred.
- After each release, sweep: `git log vPREV..vX.Y.Z --oneline` lists the
  issues with work in it. Read each one with its comments. Close the
  finished ones with a summary. Move anything left over, or marked "left
  out", into a follow-up issue, and link it from the closing comment.
  Issues without commits in the release stay open.
- Anything that can only be checked once Forever is live goes on the
  launch day checklist, issue #23, with a link to its own issue.
- Issues are public: no secrets, personal paths or email addresses.

## Conventions

- Developer-only code sits between `#@debug@` / `#@end-debug@` in the toc and
  `--@debug@` / `--@end-debug@` in Lua; release builds strip it and drop
  files the toc no longer lists.
- Map.lua is at Lua's limit of 200 locals in one chunk. New map features go
  in their own file (as ZoneArt.lua did) or into a table, not new top-level
  locals in Map.lua.
- Comments are plain sentences that explain why; match the density of the
  surrounding code. British spelling (colour, centre).
- Commit subjects: `Area: what changed` (e.g. "Kills: record each one and pop
  them up during the replay"), with a body for anything non-trivial.
- Wrap handlers in `ns.SafeCall` (via `ns.On`) so one error cannot stop the
  recorder.

## Forever client facts

Verified in game; trust these over web guides, and re-check after patches.

- Combat log is blocked for addons; kills come from `CHAT_MSG_COMBAT_XP_GAIN`.
- One copy of a dungeon cannot be told from another: `GetInstanceInfo`
  gives only the map ID, 5-man dungeons have no saved lockout, and creature
  GUIDs (target, nameplates) are secret values (`issecretvalue`), so their
  copy part cannot be read. Loot source GUIDs are believed secret too (not
  probed). Runs are joined by time and group instead (Journal.lua).
  Other players' GUIDs, names and guilds are readable.
- SavedVariables are written only on logout, quit, disconnect or `/reload`.
  `ReloadUI()` needs a hardware event (a click or key), never a timer.
- Some UI values are retail-style "secret values"; reading their rects or
  comparing them errors, so wrap such reads in `pcall`.
- Textures by path from game data often fail; use file IDs (from the wowdev
  listfile or wago.tools). `SetTexture` returns true even for missing files,
  so only a screenshot proves a texture works. Addon TGA files load, even
  ones added while the game runs.
- Zone map art has fog of war; full overlay data comes from wago.tools
  (`https://wago.tools/db2/<Table>/csv?build=<build>`; Forever builds are
  listed under `wow_classic_beta`). Raw files: `https://wago.tools/api/casc/<fileID>?version=<build>`.
- Zone highlight textures hold their shape in colour only, so they cannot be
  used as masks; ZoneMasks/ are alpha masks made from them. A texture can
  take several mask textures and they multiply. Cities have no highlight.
- Professions and recipes use the modern APIs: `GetProfessions` /
  `GetProfessionInfo` (secondary skills included) and `C_TradeSkillUI`
  (window open). Classic `GetSkillLineInfo` and `GetTradeSkillInfo` do not exist.
- Reputation uses the modern `C_Reputation` (`GetNumFactions`,
  `GetFactionDataByIndex`, `GetFactionDataByID`, expand and collapse);
  classic `GetFactionInfo` and friends do not exist.
- Riding is modern: the trainer teaches Apprentice Riding (33388, level 40)
  and Journeyman Riding (33391, level 60), skill line "Riding". Mounts are
  learned into a collection (`C_MountJournal`, listing the classic mounts;
  Brown Horse is mount 6). Mount vendors will not open without riding, so
  buying one was not seen on the beta.
- Continents: Eastern Kingdoms is continent 0 / uiMap 1415, Kalimdor is 1 / 1414.
- Models of other characters: `DressUpModel:SetCustomRace` does not exist.
  `SetDisplayInfo` with a saved `C_PlayerInfo.GetDisplayID()` gives the right
  race shape but an untextured white body (weapons still show; armour shows
  as white shapes only, also on a `ModelScene` actor with
  `SetModelByCreatureDisplayID`), so only the logged-in character can be
  shown properly. `SetPlayerModelFromGlues` draws nothing in game.
- Textures zoomed far in draw as hard blocks because of pixel snapping, not
  filtering: `SetSnapToPixelGrid(false)` and `SetTexelSnappingBias(0)` make
  them smooth (the filter argument of `SetTexture` alone does nothing).
- `ModelScene` actors draw black until the scene's fog is cleared
  (`scene:ClearFog()`); light type 1 keeps them black.

## Testing in game

The dev install is a junction from the client's `Interface/AddOns/RoadToSixty`
to this repo's `RoadToSixty/` (the CurseForge app may replace it with a
release; check it is still a link before testing). `/reload` picks up
changes. Developer tools: `/rts probe`, `/rts zoneprobe`, `/rts terrain`,
`/rts swatch`, `/rts icons`, `/rts seed`, `/rts perf`, `/rts tiles`.

Jordan tests in game and sends screenshots. For visual choices (icons, line
styles, effects), build candidates into `/rts swatch` or a probe window
first and let Jordan pick from a screenshot before integrating.
