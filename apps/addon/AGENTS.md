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
  `tests/pure_test.lua` fails if one does. The server goes live with them
  when they merge to `main` (Dokploy deploys it from there), long before
  players update the addon, so a change to them must still merge journeys
  from the released addon.
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
  starts the file fresh (a deleted namesake's, or a transfer's copied by
  hand) with the old journey kept in the roster, Erase gives a new start,
  a file with nothing in it gets its journey back from the roster's copy
  stamped with its GUID (`Recover`: a rename, as WoW keeps files by name,
  or a lost file), and `Sync.Apply` and `Merge.Merge` never join two
  different stamps. The
  sync server reads it from uploads to keep journeys of one name apart.
- Saved times use `ns.Now()`, never `time()` (a test fails on `time()` in
  shipped files). `ns.PCTime()` is the PC's clock, for comparing with times
  the client gives by it (the death recap's), and is never saved.
- Map.lua is near Lua's 200-local limit: new map features go in their own file.
- Developer-only code sits between `--@debug@` and `--@end-debug@`; release
  builds strip it.
- An icon shown in our own windows goes in the game's item button art, as
  the bags have it: `ns.Screens.ItemButton(parent, size)` with
  `SetItemButtonTexture` (and `SetItemButtonQuality` for items), never a
  bare texture or a border drawn from colour squares. Jordan's call on the
  Stats screen's records (#83). In a row or list smaller than the bags'
  37 px, use `ns.Screens.IconButton(parent, size)` and
  `ns.Screens.SetIcon(button, icon, quality)`: the button scaled to fit,
  the row keeping the mouse, an item's loot-toast quality border over the
  icon. The History list's rows use it for every entry with game icon art
  (#131). `tests/style_test.lua` fails on any shipped file that makes its
  own item button, item button frame or quality border.
- A map marker drawn from game icon art (a spell or item icon, not an
  atlas) goes in the item button frame through `Style.Frame(m, icon,
  size)`, at `Style.MARKER_ICON` (16), or `Style.NODE_ICON` (12) for a
  gathering node; `Style.Unframe` takes it off a reused marker. Never a
  frame of its own. Jordan's call (#110).
- Friends' journeys (Friends.lua) arrive by addon whisper from other
  players, so treat them as untrusted. `Apply` checks the shape of every
  field, nested ones too, before it keeps anything. A new journey field or
  event field the panels read needs a check there, or one bad friend can
  break the Characters list or the Stats screen. A number a screen loops up
  to needs a bound too: a far-future time or a huge level hangs the client
  (`Time`, `Level`, `PackedTimes`), and a field in capitals in `EVENT_FIELDS`
  is required, so one an older version didn't always save mustn't be one: a
  refused event refuses the friend's whole batch. They live in the
  account-wide `ns.db.friends`, never in the character file, so the sync
  server and the app never see them.
- `Roster:Entries` lists friends too (`e.friend`). Anything that saves
  over, deletes or uploads an entry must skip them.
- Real SavedVariables files hold other players' names and GUIDs. They never
  go into a test, a fixture or an issue.
- CHANGELOG.md is also the in-game changelog (WhatsNew.lua, #132): after
  an update, every player sees the new versions' sections in a window. So
  every release needs its `## X.Y.Z` section, written for players, and
  nothing else is updated by hand for it.
  `RoadToSixty/WhatsNewData.lua`, the notes the addon carries, is
  generated and not committed: the release build writes it from
  CHANGELOG.md (`scripts/whatsnew-data.lua`, run by `package.ps1`), and
  fails when the version's section is missing. The toc lists it, so a
  test that reads every toc file must allow it to be absent
  (`tests/clock_test.lua`).
