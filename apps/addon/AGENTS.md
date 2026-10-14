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
  CurseForge helpers, the data generators (`zone-overlays.py` and the
  texture scripts) and `sync-folder.lua`, which makes a sync folder by hand.
- `check.ps1` runs every check CI runs.

## Commands (from apps/addon)

```
bun run test              # every test under LuaJIT, and under Lua 5.1 if installed
./check.ps1               # syntax, LuaLS diagnostics, tests (three old warnings are known)
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
- Counts kept per PC (Tally.lua) go under the PC that started the thing:
  an open dungeon run and group carry `pc`, so two PCs finishing the same
  one from their copies count it once after the merge.
- The character file keeps its own `class` (set at each login) because
  the sync server reads only that file, never the account-wide one.
- Saved times use `ns.Now()`, never `time()` (a test fails on `time()` in
  shipped files).
- Map.lua is near Lua's 200-local limit: new map features go in their own file.
- Developer-only code sits between `--@debug@` and `--@end-debug@`; release
  builds strip it.
- Real SavedVariables files hold other players' names and GUIDs. They never
  go into a test, a fixture or an issue.
