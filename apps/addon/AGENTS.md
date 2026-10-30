# Addon (apps/addon)

The WoW Forever addon itself. The repo root's CLAUDE.md has the file table,
the Forever client facts and the release steps; this file is the short list
of what bites when you change the addon.

## Layout

- `RoadToSixty/` is the addon folder WoW loads. Its name must match the toc,
  so it never moves or gets renamed.
- `tests/*_test.lua` are the offline tests; `tests/fixtures/` holds
  hand-made saved files with made-up names.
- `scripts/` holds the release build (`package.ps1`), the changelog and
  CurseForge helpers, the data generators (`zone-overlays.py`, `seed-gear.py` and the
  texture scripts, such as `gear-bar-textures.py` for the gear screen's bars) and `sync-folder.lua`, which makes a sync folder by hand.
- `check.ps1` runs every check CI runs.

## Commands (from apps/addon)

```
bun run test              # every test under LuaJIT, and under Lua 5.1 if installed
./check.ps1               # syntax, LuaLS diagnostics, tests (the old warnings are listed in the root CLAUDE.md)
./scripts/package.ps1     # release build plus a load test in toc order
```

## Rules that bite

- Files load in toc order and share the addon table `ns`. Handlers for one
  event run in the order their files load.
- Read a file's header comment before changing it: it says what the module
  does and, for saved data, its exact format.
- `Packed.lua`, `Tidy.lua`, `Parse.lua`, `Tally.lua` and `Merge.lua` make no
  game calls: the sync server runs them under plain Lua 5.1.
  `tests/pure_test.lua` fails if one does.
- `Merge.Windows` and `Merge.Strip` serve restores on the sync server: the
  sessions a restore took out, and taking them out of an upload made before
  the restore reached its PC. `tests/restore_test.lua` covers them.
- Any change to what is saved, or what it means, bumps `DATA_VERSION` in
  Core.lua, gets listed there, and brings older files up in `Upgrade`.
  A new event kind, or a new optional field older code ignores (an extra
  event field, a new key in a snapshot), is the exception: it changes
  nothing already saved, and Merge matches kinds it does not know on time
  and kind alone and copies fields it does not know. A bump would stop
  syncing until the server is redeployed, as the server's merge refuses
  a newer layout than it knows. List a new kind in Merge's `ABOUT` and
  the sync spec instead.
- Counts kept per PC (Tally.lua) go under the PC that started the thing:
  an open dungeon run and group carry `pc`, so two PCs finishing the same
  one from their copies count it once after the merge.
- The character file keeps its own `class` (set at each login) because
  the sync server reads only that file, never the account-wide one.
- Each character file carries `journeyId`, the journey's stamp
  (`<GUID>:<start>`, Core.lua). The login writes it, a GUID that differs
  starts the file fresh (a deleted namesake's), Erase gives a new start,
  and `Sync.Apply` and `Merge.Merge` never join two different stamps. The
  sync server reads it from uploads to keep journeys of one name apart.
- Saved times use `ns.Now()`, never `time()` (a test fails on `time()` in
  shipped files).
- Map.lua is near Lua's 200-local limit: new map features go in their own file.
- Developer-only code sits between `--@debug@` and `--@end-debug@`; release
  builds strip it.
- An icon shown in our own windows goes in the game's item button art, as
  the bags have it: `ns.Screens.ItemButton(parent, size)` with
  `SetItemButtonTexture` (and `SetItemButtonQuality` for items), never a
  bare texture or a border drawn from colour squares. Jordan's call on the
  Stats screen's records (#83).
- Real SavedVariables files hold other players' names and GUIDs. They never
  go into a test, a fixture or an issue.
