# Account API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the server everything the app's account screens need (characters with class, history, restore, PCs, export, delete everything), make restores safe with a restore id, and rebuild the link page so the player types the code and sees the PC's name over the animated fog.

**Architecture:** New PC-token routes live in `apps/server/src/account.ts`, sharing the token check with `sync.ts` through `src/pc.ts`. The character's class comes from the addon's own file (a new `class` field in layout 3) through the merge runner. Restores travel as a restore id from the server through the app's sync folder to `Sync.lua`. The PC's name rides in Better Auth's device code `scope`, so the link page can show it. The fog animation lives in `packages/ui/src/dots.ts`, used by `Fog.tsx` now and by the website later, and by the link page through a script the server builds once.

**Tech Stack:** Bun 1.4.2, Elysia 1.4, Drizzle 0.45 on Postgres, Bun's S3 client (SeaweedFS locally, R2 live), Better Auth 1.7.7 device authorization, Rust (engine, `ureq`, `serde`), Lua 5.1 (addon), React 19 (`packages/ui`).

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md` ("Account API", "Restore", "Storage", "Deleting an account", "The website"). Picks from the mockups are on issue #39; the restore id fix is item 7 of issue #40.

This is plan 1 of 2. Plan 2 is the app: its screens (Characters with class icons and history, the one-tab Account screen, the PC name box at first run, the start-at-login switch), unlinking from the app through the server, automatic updates, the window anchored under the menu bar icon, and fetching other PCs' sessions when the game starts. None of that goes in here.

## Global Constraints

- Branch `account-api` from `dev`; merged into `dev` locally at the end. Never push `main`.
- Commits: `Area: what changed (#N)`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- British spelling in code comments and docs. Comments are plain sentences that say why, never what the next line does.
- Every app and package's `AGENTS.md` changes in the same commit as the change it describes.
- Request and response shapes live in `packages/api/src/index.ts`; the engine's Rust mirrors them in `apps/desktop/engine/src/api.rs`. Change them together.
- Migrations come from `bun run db:generate` in `apps/server`, never by hand; commit the SQL and the `drizzle/meta` snapshot.
- Test journeys and names are made up (`test/helpers.ts`, `tests/` in the addon). Never a real saved file.
- App 0.1.1 is installed on testers' PCs: `CheckEntry.replace` stays in the server's answer (0.1.1's `api.rs` has `pub replace: bool` with no default, so dropping it breaks every check), and `Sync.lua` still honours `replace` in a sync folder 0.1.1 wrote.
- `Packed.lua`, `Tidy.lua`, `Parse.lua`, `Tally.lua` and `Merge.lua` make no game calls.
- A PC name is at most 40 characters, after collapsing whitespace and dropping control characters (`pcName` in `src/devices.ts`, used by linking and renaming).

Commands, each from its folder:

- Server: `cd apps/server && docker compose up -d && bun test`. If `lua5.1` isn't on the path, set `LUA51` to a standard Lua 5.1 (not LuaJIT: the limit tests need its count hook).
- Server types: `cd apps/server && bun run typecheck`.
- UI package: `cd packages/ui && bun test && bun run typecheck`.
- Engine: `cd apps/desktop && cargo test -p rts-sync` (run `. ~/.cargo/env` first if `cargo` isn't found).
- Addon: `cd apps/addon && bun run test` (LuaJIT, and Lua 5.1 when `lua5.1` is on the path).

## Rulings made while planning

- **Class joins layout 3 without a bump.** Layout 3 has not shipped: `main` writes layout 2 and the latest addon release is older still. So `class` is added to layout 3's line in `Core.lua`'s comment and `DATA_VERSION` stays 3. Files written by dev builds before this change simply have no class until the next login. Class is optional everywhere: `-` from the runner, `null` in the API.
- **The PC's name travels in the device code's `scope`.** Better Auth 1.7.7 stores `scope` as free text with no validation, and `GET /api/auth/device?user_code=` returns it only to the signed-in player who has claimed the code (`routes.mjs`, `canReviewRequest`). The app sends `scope` as JSON, `{"pc":"Desk","platform":"darwin"}`. No new table or route. App 0.1.1 sends no scope, so the page says "a PC".
- **History lists merged and restored versions, not raw uploads,** newest first, at most 100. Each merged version names the PC whose upload made it; each restore names the version it restored.
- **The characters list holds characters with a merged version,** like `/v1/check`; the app adds what it knows locally.
- **Export is a zip of deflated files,** written by a small `src/zip.ts`, since Bun has no zip writer. Each file is the character's newest journey as a SavedVariables file (`RoadToSixtyCharDB = …`), so it could be put back in the game.
- **Delete everything runs in this order:** revoke the user's PCs (no more uploads), delete their jobs, delete their files from the bucket, then delete their rows in one transaction. Files go before rows, so a failure part way can be retried and never leaves files belonging to no one.

## Review Focus

1. A restore picked while another PC's upload is waiting to be merged: the upload must be set aside, not merged on top of the restore. (Test in Task 4.)
2. Renaming a PC to nothing, to spaces, to a name with a newline, or to 200 characters: refused or trimmed to 40, never stored as is. (Test in Task 5.)
3. Delete everything while a merge job is queued: the job goes too, and no file is left in the bucket. (Test in Task 7.)
4. A journey with no level snapshots: `level` is `null` in the characters list and the history, not 0 or a crash. (Test in Task 3.)
5. A character on a realm with an accent (`Azjol-Nérub`) in the export: the zip's file name keeps the accent and `unzip -t` passes. (Test in Task 6.)

---

### Task 1: The class in the journey, and a level for each version

**Files:**
- Modify: `apps/addon/RoadToSixty/Roster.lua:140` (set `ns.char.class`)
- Modify: `apps/addon/RoadToSixty/Core.lua:53-61` (layout 3's line)
- Modify: `apps/addon/tests/roster_test.lua:100`
- Modify: `apps/server/src/runner.lua` (header and the `ok` line)
- Modify: `apps/server/src/lua.ts` (`class` in `MergeResult`)
- Modify: `apps/server/src/schema.ts` (`versions.level`)
- Create: `apps/server/drizzle/0003_*.sql` and its `drizzle/meta` snapshot (generated)
- Modify: `apps/server/src/worker.ts` (store class and level)
- Test: `apps/server/test/lua.test.ts`, `apps/server/test/sync.test.ts`
- Modify: `apps/addon/AGENTS.md`, `apps/server/AGENTS.md`

**Interfaces:**
- Produces: `ns.char.class` (the class file name, `"WARRIOR"`), saved in the character file. `MergeResult` (ok) gains `class: string | null`. `versions.level: number | null`, set on merged versions (Task 4 copies it onto restores). `characters.class` filled by the worker.

- [ ] **Step 1: Write the failing addon test**

In `apps/addon/tests/roster_test.lua`, change the check at line 100 to:

```lua
check(e.class == "MAGE" and e.level == 12 and e.zone == 1436, "entry has class, level and zone")
check(ns.char.class == "MAGE", "the character's own file keeps its class, for the sync server")
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/addon && luajit tests/roster_test.lua`
Expected: `FAIL: the character's own file keeps its class, for the sync server`

- [ ] **Step 3: Save the class at login**

In `apps/addon/RoadToSixty/Roster.lua`, in the `PLAYER_LOGIN` handler, after `entry.class = select(2, UnitClass("player"))`:

```lua
    ns.char.class = entry.class
```

In `apps/addon/RoadToSixty/Core.lua`, extend layout 3's line in the comment above `DATA_VERSION` (no bump, see the rulings):

```lua
--   3  the counts the merge can't rebuild are tallies by PC (Tally.lua):
--      people[guid] groups, seconds, raids, raidSeconds, dungeons and
--      raidRuns, and rares[key][1]. Older counts become this PC's. class,
--      the character's class (UnitClass's file name), set at each login.
```

- [ ] **Step 4: Run the addon tests**

Run: `cd apps/addon && bun run test`
Expected: every test passes, `roster_test` included.

- [ ] **Step 5: Write the failing server tests**

In `apps/server/test/lua.test.ts`, first test: add `class: "MAGE",` to the `journey({ ... })` fields and change the expectation to:

```ts
  expect(r).toMatchObject({ from: 2, layout: 3, level: 6, played: 3600, lastSeen: 1120, class: "MAGE" });
```

In the second test ("an upload merges into the current journey"), add after `expect(r.lastSeen).toBe(5120);`:

```ts
  expect(r.class).toBeNull(); // neither copy was saved by an addon that records it
```

In `apps/server/test/sync.test.ts`, test "the first upload becomes the character's journey…": make the file `savedFile(journey({ events: session(1000), levels: { 4: { t: 900 } }, played: 600, class: "PRIEST" }))` and replace the characters check with:

```ts
  const [c] = await db.select().from(characters);
  expect(c).toMatchObject({ level: 4, played: 600, class: "PRIEST", headVersionId: entry!.version });
  const [merged] = await db.select().from(versions).where(eq(versions.id, entry!.version!));
  expect(merged!.level).toBe(4);
```

- [ ] **Step 6: Run them to see them fail**

Run: `cd apps/server && bun test test/lua.test.ts test/sync.test.ts`
Expected: FAIL. `class` is missing from the merge result, and `versions` has no `level` column (a TypeScript error from `merged!.level` shows when typechecking; at runtime `undefined` isn't `4`).

- [ ] **Step 7: Add the column and generate the migration**

In `apps/server/src/schema.ts`, in `versions` after `dataVersion`:

```ts
  // The character's level in this version, for the history the app shows.
  level: integer("level"),
```

Run: `cd apps/server && bun run db:generate --name version_level`
Expected: `drizzle/0003_version_level.sql` holding `ALTER TABLE "versions" ADD COLUMN "level" integer;`, plus `drizzle/meta/0003_snapshot.json` and an updated `_journal.json`.

- [ ] **Step 8: Report the class from the runner**

In `apps/server/src/runner.lua`, change the header's `ok` line to:

```lua
--   ok <layout uploaded> <layout> <level> <played> <last seen> <class>
```

and the end of `Run` to:

```lua
    -- The class is a file name like WARRIOR; anything else is left out, so
    -- it can't break the line lua.ts reads.
    local class = type(out.class) == "string" and out.class:match("^%u+$")
    return ("ok %s %d %s %s %s %s"):format(from, out.version, tostring(level or "-"),
        tostring(tonumber(out.played) or "-"), tostring(last or "-"), class or "-")
```

In `apps/server/src/lua.ts`, add to the ok branch of `MergeResult`:

```ts
      class: string | null; // the class file name, such as WARRIOR
```

and read it:

```ts
      const [layout, level, played, lastSeen, cls] = rest;
      return {
        ok: true,
        from: num(from),
        layout: Number(layout),
        level: num(level),
        played: num(played),
        lastSeen: num(lastSeen),
        class: cls === undefined || cls === "-" ? null : cls,
        journey: new Uint8Array(await Bun.file(outPath).arrayBuffer()),
      };
```

- [ ] **Step 9: Store them in the worker**

In `apps/server/src/worker.ts`, in the merged version's `.values({ ... })` add `level: result.level,`. In `tx.update(characters).set({ ... })` add, after `level: result.level,`:

```ts
        // A file from before the addon recorded the class doesn't forget it.
        ...(result.class ? { class: result.class } : {}),
```

- [ ] **Step 10: Run the server tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass, no type errors.

- [ ] **Step 11: Update AGENTS.md**

`apps/addon/AGENTS.md`, under "Rules that bite", add:

```markdown
- The character file keeps its own `class` (set at each login) because
  the sync server reads only that file, never the account-wide one.
```

`apps/server/AGENTS.md`, in the layout line for `src/worker.ts`, add after "one at a time per character;": "it fills each character's level, class and time played, and each merged version's level, from the runner's `ok` line;".

- [ ] **Step 12: Commit**

```bash
git add apps/addon apps/server
git commit -m "Server: keep each character's class and each version's level (#1)

The addon now saves the class in the character's own file (layout 3, which
hasn't shipped, so no bump), and the merge runner reports it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Restores travel as a restore id

**Files:**
- Modify: `packages/api/src/index.ts` (`CheckEntry.restore`)
- Modify: `apps/server/src/sync.ts` (`/check`)
- Modify: `apps/desktop/engine/src/api.rs` (`CheckEntry`)
- Modify: `apps/desktop/engine/src/inbox.rs` (`Delivery`, `data_lua`, its tests)
- Modify: `apps/desktop/engine/src/sync.rs:205` and its test at `:428`
- Modify: `apps/addon/RoadToSixty/Sync.lua` (header and `Sync.Apply`)
- Test: `apps/server/test/sync.test.ts`, `apps/addon/tests/sync_test.lua`, the engine's tests
- Modify: `apps/desktop/AGENTS.md`, `packages/api/AGENTS.md`

**Interfaces:**
- Produces: `CheckEntry.restore: number | null` (TypeScript), `CheckEntry.restore: Option<i64>` with `#[serde(default)]` (Rust), `Delivery.restore: Option<i64>` (Rust, replacing `replace: bool`), sync folder entry field `restore = <id>` (Lua, left out when there is none).
- Keeps: `CheckEntry.replace: boolean` in TypeScript and in the server's answer, equal to `restore !== null`, for app 0.1.1.

- [ ] **Step 1: Write the failing addon tests**

In `apps/addon/tests/sync_test.lua`, replace section 2 ("Replaced") with:

```lua
-- 2. Replaced: a restore takes the incoming journey whole, unless this PC
-- already took that restore in, so its play since then merges instead.
what, out = Sync.Apply(Journey({ events = Both(here, there) }), { version = 6, restore = 6, journey = Write(Journey({ events = Session(1000) })) })
check(what == "replaced" and Same(out.events, here), "a restore replaces: " .. tostring(what))
local tookIt = Journey({ events = Both(here, there), syncedVersion = 6 })
what, out = Sync.Apply(tookIt, { version = 9, restore = 6, journey = Write(Journey({ events = Session(1000) })) })
check(what == "merged" and #out.events == 6, "a restore this PC already took in merges, keeping its play since: " .. tostring(what))
what, out = Sync.Apply(Journey({ events = Both(here, there) }), { version = 6, replace = true, journey = Write(Journey({ events = Session(1000) })) })
check(what == "replaced", "a sync folder from app 0.1.1 still replaces on its flag: " .. tostring(what))
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/addon && luajit tests/sync_test.lua`
Expected: `FAIL: a restore replaces: merged` (the new `restore` field isn't read yet).

- [ ] **Step 3: Read the restore id in Sync.lua**

In `apps/addon/RoadToSixty/Sync.lua`, change the header's entry to:

```lua
--           ["Name-Realm"] = {     -- Roster:Key()
--               version = 42,      -- the server's version number; higher is newer
--               restore = 40,      -- optional: the restore this PC hasn't taken in yet
--               journey = "...",   -- the journey as Parse.Write text
--           },
```

and in the first paragraph change "for a restore picked on the website" to "for a restore picked in the app". In `Sync.Apply`, replace `if entry.replace then return "replaced", journey end` with:

```lua
    -- A restore replaces only a copy older than it. A PC that already took
    -- the restore in has play since then that a replace would throw away.
    -- replace is what app 0.1.1 writes instead of restore.
    local restore = tonumber(entry.restore)
    if (restore and (char.syncedVersion or 0) < restore) or (not restore and entry.replace) then
        return "replaced", journey
    end
```

- [ ] **Step 4: Run the addon tests**

Run: `cd apps/addon && bun run test`
Expected: all pass.

- [ ] **Step 5: Write the failing server test**

In `apps/server/test/sync.test.ts`, test "a restore is delivered as a replace…": change the expectation after the restore is made to:

```ts
  expect((await check(token)).characters[0]).toMatchObject({ version: restore!.id, restore: restore!.id, replace: true });
```

and in the same test, after the PC's upload that names the restore in `received` has been merged, add:

```ts
  expect((await check(token)).characters[0]).toMatchObject({ restore: null, replace: false });
```

(If that test has no such upload, add one: `await upload(token, savedFile(journey({ events: session(9000) })), { received: String(restore!.id) }); await workAll();` before the new expectation.)

- [ ] **Step 6: Run it to see it fail**

Run: `cd apps/server && bun test test/sync.test.ts`
Expected: FAIL, `restore` is missing from the entry.

- [ ] **Step 7: Send the restore id**

In `packages/api/src/index.ts`, in `CheckEntry`, replace the `replace` line with:

```ts
  // The newest restore, while this PC hasn't shown (by an upload's received)
  // that its addon took it in. The addon replaces its copy only when the
  // version it last brought in is older than this, so play since stays.
  restore: number | null;
  replace: boolean; // restore !== null; read by app 0.1.1
```

In `apps/server/src/sync.ts`, in `/check`'s map, before the `return {`:

```ts
          const lastRestoreId = lastRestore.get(c.id) ?? 0;
          const restore = head !== null && (applied.get(c.id) ?? 0) < lastRestoreId ? lastRestoreId : null;
```

and in the returned object replace the `replace:` line with:

```ts
            restore,
            replace: restore !== null,
```

- [ ] **Step 8: Run the server tests**

Run: `cd apps/server && bun test`
Expected: all pass.

- [ ] **Step 9: Write the failing engine test**

In `apps/desktop/engine/src/inbox.rs` tests: every `replace: false` becomes `restore: None` and every `replace: true` becomes `restore: Some(6)`. In the Lua round-trip test's script, change `tostring(e.replace)` to `tostring(e.restore)`, and its expected outputs from `false` to `nil` and from `true` to `6`. In `apps/desktop/engine/src/sync.rs`'s test at line 428, change the expected text to:

```rust
            data.contains(r#"["Ann-Test Realm"] = { version = 9, journey = "{[\"version\"]=3,}" }"#),
```

- [ ] **Step 10: Run them to see them fail to build**

Run: `cd apps/desktop && cargo test -p rts-sync`
Expected: FAIL to compile, `Delivery` has no field `restore`.

- [ ] **Step 11: Carry the restore id through the engine**

`apps/desktop/engine/src/api.rs`, in `CheckEntry`, replace `pub replace: bool,` and its comment with:

```rust
    /// The restore this PC hasn't taken in yet; the addon replaces its copy
    /// only if the version it last brought in is older.
    #[serde(default)]
    pub restore: Option<i64>,
```

`apps/desktop/engine/src/inbox.rs`, in `Delivery`, replace `replace` with:

```rust
    /// The restore this PC hasn't taken in yet (Sync.lua's header).
    pub restore: Option<i64>,
```

and in `data_lua` replace the `push_str` with:

```rust
        let restore = d.restore.map(|id| format!("restore = {id}, ")).unwrap_or_default();
        out.push_str(&format!(
            "        [{}] = {{ version = {}, {}journey = {} }},\n",
            lua_quote(&d.key),
            d.version,
            restore,
            lua_quote(&d.journey)
        ));
```

`apps/desktop/engine/src/sync.rs:205`: `replace: entry.replace,` becomes `restore: entry.restore,`.

- [ ] **Step 12: Run the engine tests**

Run: `cd apps/desktop && cargo test -p rts-sync`
Expected: all pass (the Lua round trip needs `luajit` on the path).

- [ ] **Step 13: Update AGENTS.md**

`apps/desktop/AGENTS.md`, after the `inbox.rs` line, add: "A restore reaches the addon as `restore = <id>`, never as a yes or no: the addon replaces only a copy older than that restore (`Sync.lua`)." `packages/api/AGENTS.md`, under its rules, add: "`CheckEntry.replace` stays until no tester runs app 0.1.1: its `api.rs` needs the field."

- [ ] **Step 14: Commit**

```bash
git add packages/api apps/server apps/desktop apps/addon
git commit -m "Sync: a restore is sent as its id, so a PC that already took it in merges instead of losing play (#40)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The characters list and a character's history

**Files:**
- Create: `apps/server/src/pc.ts` (the token check shared by every PC route)
- Modify: `apps/server/src/sync.ts` (start from `pcRoutes()`)
- Create: `apps/server/src/account.ts`
- Modify: `apps/server/src/app.ts` (`.use(account)`)
- Modify: `packages/api/src/index.ts` (`CharacterInfo`, `VersionInfo`)
- Modify: `apps/server/test/helpers.ts` (move `CHAR`, `call`, `upload`, `check`, `workAll`, `newDevice` here)
- Modify: `apps/server/test/sync.test.ts` (import them)
- Create: `apps/server/test/account.test.ts`
- Modify: `apps/server/AGENTS.md`, `packages/api/AGENTS.md`

**Interfaces:**
- Consumes: `characters.class`, `versions.level` (Task 1).
- Produces: `pcRoutes(): Elysia` (prefix `/v1`, `device` in context, 401 without a live token, notes `lastSeenAt`, `addonVersion` from `?addon=`, `appVersion` from `?app=`). `own(device: Device, id: string): Promise<Character | null>` in `account.ts`. Routes `GET /v1/characters` → `CharacterInfo[]`, `GET /v1/characters/:id/versions` → `VersionInfo[]`. Test helpers `CHAR`, `call(token, path, init?)`, `upload(token, file, extra?)`, `check(token)`, `workAll()`, `newDevice(userId, name)`.

- [ ] **Step 1: Move the shared test helpers**

Move these from the top of `apps/server/test/sync.test.ts` into `apps/server/test/helpers.ts`, exported, unchanged in behaviour: `CHAR`, `call`, `upload`, `check`, `workAll`, and `newDevice` (the wrapper that adds the user). `helpers.ts` gains the imports they need (`app`, `pack`, `work`, `newDevice as linkDevice`, `CheckResponse`). `sync.test.ts` imports them from `./helpers`.

Run: `cd apps/server && bun test test/sync.test.ts`
Expected: all pass, as before.

- [ ] **Step 2: Write the failing tests**

Create `apps/server/test/account.test.ts`:

```ts
import type { CharacterInfo, VersionInfo } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { CHAR, call, journey, newDevice, reset, savedFile, session, upload, workAll } from "./helpers";

beforeEach(reset);

const json = async <T>(r: Response | Promise<Response>) => (await (await r).json()) as T;

test("the characters list says class, level, time played and which PC last synced each", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000), levels: { 7: { t: 900 } }, played: 4000, class: "WARRIOR" })));
  await workAll();
  const list = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  expect(list).toEqual([
    expect.objectContaining({ ...CHAR, class: "WARRIOR", level: 7, played: 4000, syncedFrom: "Desk" }),
  ]);
  expect(Date.parse(list[0]!.syncedAt)).toBeGreaterThan(0);
  expect(list[0]!.lastPlayedAt).toBe(new Date(1120 * 1000).toISOString());
});

test("a journey with no level snapshots lists its level as unknown", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  expect(c!.level).toBeNull();
  const [v] = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  expect(v!.level).toBeNull();
});

test("a character's history lists each merged version, newest first, with the PC that made it", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, savedFile(journey({ events: session(1000), levels: { 3: { t: 900 } } })));
  await workAll();
  await upload(laptop.token, savedFile(journey({ events: session(5000), levels: { 4: { t: 4900 } } })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const history = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  expect(history.map((v) => [v.kind, v.from, v.level, v.current])).toEqual([
    ["merged", "Laptop", 4, true],
    ["merged", "Desk", 3, false],
  ]);
  expect(history[0]!.restoredFrom).toBeNull();
});

test("another player's character is not found", async () => {
  const desk = await newDevice("user-1", "Desk");
  const other = await newDevice("user-2", "Elsewhere");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  expect(await json<CharacterInfo[]>(call(other.token, "/v1/characters"))).toEqual([]);
  expect((await call(other.token, `/v1/characters/${c!.id}/versions`)).status).toBe(404);
  expect((await call(other.token, "/v1/characters/nonsense/versions")).status).toBe(404);
});

test("the account routes need a live PC token", async () => {
  expect((await call("nope", "/v1/characters")).status).toBe(401);
});
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd apps/server && bun test test/account.test.ts`
Expected: FAIL, `CharacterInfo` isn't exported and `/v1/characters` answers 404.

- [ ] **Step 4: Add the shared types**

Append to `packages/api/src/index.ts`:

```ts
// The account API: the app's window, with the PC token. Times are ISO 8601.

// GET /v1/characters: each character with a merged journey.
export type CharacterInfo = {
  id: number;
  game: string;
  realm: string;
  name: string;
  class: string | null; // the class file name, such as WARRIOR
  level: number | null;
  played: number | null; // seconds
  lastPlayedAt: string | null;
  syncedAt: string; // when its current version was made
  syncedFrom: string | null; // the PC whose upload made it; null for a restore
};

// GET /v1/characters/:id/versions: newest first, at most 100.
export type VersionInfo = {
  id: number;
  kind: "merged" | "restore";
  createdAt: string;
  level: number | null;
  from: string | null; // the PC whose upload made a merged version
  restoredFrom: { id: number; createdAt: string } | null;
  current: boolean;
};
```

- [ ] **Step 5: Share the token check**

Create `apps/server/src/pc.ts`:

```ts
import { eq } from "drizzle-orm";
import { Elysia } from "elysia";
import { db } from "./db";
import { deviceFor } from "./devices";
import { devices } from "./schema";

// Every route the app calls with its PC token starts from this: an unknown
// or unlinked PC is refused, and the PC's last visit and versions noted.
export const pcRoutes = () =>
  new Elysia({ prefix: "/v1" })
    .resolve(async ({ headers }) => ({ device: await deviceFor(headers.authorization) }))
    .onBeforeHandle(({ device, set }) => {
      if (!device) {
        set.status = 401;
        return { error: "unknown or unlinked PC" };
      }
    })
    .onBeforeHandle(async ({ device, query }) => {
      await db
        .update(devices)
        .set({
          lastSeenAt: new Date(),
          ...(query.addon ? { addonVersion: String(query.addon).slice(0, 20) } : {}),
          ...(query.app ? { appVersion: String(query.app).slice(0, 20) } : {}),
        })
        .where(eq(devices.id, device!.id));
    });
```

In `apps/server/src/sync.ts`, replace `new Elysia({ prefix: "/v1" })` and the `.resolve` and both `.onBeforeHandle` calls with `pcRoutes()`, import it from `./pc`, and drop the imports that are no longer used (`Elysia`, `deviceFor`).

- [ ] **Step 6: Write the routes**

Create `apps/server/src/account.ts`:

```ts
import type { CharacterInfo, VersionInfo } from "@road-to-sixty/api";
import { and, desc, eq, inArray } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { db } from "./db";
import type { Device } from "./devices";
import { pcRoutes } from "./pc";
import { characters, devices, versionParents, versions } from "./schema";

const HISTORY = 100;

export type Character = typeof characters.$inferSelect;

// The character with this id, if it belongs to the PC's player.
export async function own(device: Device, id: string): Promise<Character | null> {
  if (!/^\d+$/.test(id)) return null;
  const [c] = await db
    .select()
    .from(characters)
    .where(and(eq(characters.id, Number(id)), eq(characters.userId, device.userId)));
  return c ?? null;
}

// The name of the PC whose upload made each of these merged versions.
async function madeBy(ids: number[]): Promise<Map<number, string>> {
  if (ids.length === 0) return new Map();
  const upload = alias(versions, "upload");
  const rows = await db
    .select({ id: versionParents.versionId, name: devices.name })
    .from(versionParents)
    .innerJoin(upload, and(eq(upload.id, versionParents.parentId), eq(upload.kind, "upload")))
    .innerJoin(devices, eq(devices.id, upload.deviceId))
    .where(inArray(versionParents.versionId, ids));
  return new Map(rows.map((r) => [r.id, r.name]));
}

// The version each of these restores brought back.
async function restoredFrom(ids: number[]): Promise<Map<number, { id: number; createdAt: string }>> {
  if (ids.length === 0) return new Map();
  const source = alias(versions, "source");
  const rows = await db
    .select({ id: versionParents.versionId, sourceId: source.id, createdAt: source.createdAt })
    .from(versionParents)
    .innerJoin(source, eq(source.id, versionParents.parentId))
    .where(inArray(versionParents.versionId, ids));
  return new Map(rows.map((r) => [r.id, { id: r.sourceId, createdAt: r.createdAt.toISOString() }]));
}

// The account API (spec, "Account API"), for the app's window.
export const account = pcRoutes()
  .get("/characters", async ({ device }): Promise<CharacterInfo[]> => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .innerJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    const from = await madeBy(rows.map((r) => r.head.id));
    return rows.map(({ c, head }) => ({
      id: c.id,
      game: c.game,
      realm: c.realm,
      name: c.name,
      class: c.class,
      level: c.level,
      played: c.played,
      lastPlayedAt: c.lastPlayedAt?.toISOString() ?? null,
      syncedAt: head.createdAt.toISOString(),
      syncedFrom: from.get(head.id) ?? null,
    }));
  })

  .get("/characters/:id/versions", async ({ device, params, set }): Promise<VersionInfo[] | { error: string }> => {
    const c = await own(device!, params.id);
    if (!c) {
      set.status = 404;
      return { error: "no such character" };
    }
    const rows = await db
      .select()
      .from(versions)
      .where(and(eq(versions.characterId, c.id), inArray(versions.kind, ["merged", "restore"])))
      .orderBy(desc(versions.id))
      .limit(HISTORY);
    const from = await madeBy(rows.filter((v) => v.kind === "merged").map((v) => v.id));
    const restored = await restoredFrom(rows.filter((v) => v.kind === "restore").map((v) => v.id));
    return rows.map((v) => ({
      id: v.id,
      kind: v.kind as "merged" | "restore",
      createdAt: v.createdAt.toISOString(),
      level: v.level,
      from: from.get(v.id) ?? null,
      restoredFrom: restored.get(v.id) ?? null,
      current: v.id === c.headVersionId,
    }));
  });
```

In `apps/server/src/app.ts`, import `account` and add `.use(account)` after `.use(sync)`.

- [ ] **Step 7: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass, no type errors.

- [ ] **Step 8: Update AGENTS.md and commit**

`apps/server/AGENTS.md` layout: add "- `src/pc.ts` is the PC token check every app route starts from; `src/account.ts` is the account API the app's window calls (characters, history, restore, PCs, export, delete everything)." `packages/api/AGENTS.md`: mention the account API types live beside the sync API's.

```bash
git add packages/api apps/server
git commit -m "Server: list characters and a character's history for the app (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Restore a version

**Files:**
- Modify: `apps/server/src/account.ts`
- Modify: `packages/api/src/index.ts` (`RestoreResponse`)
- Test: `apps/server/test/account.test.ts`; `apps/server/test/sync.test.ts` (its `restoreHead()` helper calls the route)

**Interfaces:**
- Consumes: `own`, `madeBy` (Task 3), `versions.level` (Task 1), `CheckEntry.restore` (Task 2).
- Produces: `POST /v1/characters/:id/restore` with JSON body `{ version: number }` → `RestoreResponse = { version: number }` (the new restore version's id). 404 for another player's character or version, 400 for the current version, 409 when the journey changed during the restore.

- [ ] **Step 1: Write the failing tests**

Append to `apps/server/test/account.test.ts` (add `RestoreResponse`, `CheckResponse` to the type import, and `check` to the helpers import):

```ts
async function twoVersions() {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000), levels: { 3: { t: 900 } } })));
  await workAll();
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000)], levels: { 3: { t: 900 }, 4: { t: 4900 } } })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const [newest, older] = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  return { desk, c: c!, newest: newest!, older: older! };
}

const restore = (token: string, id: number, version: number) =>
  call(token, `/v1/characters/${id}/restore`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ version }),
  });

test("restoring a version makes it current again, keeps the old one in history, and is sent as a restore", async () => {
  const { desk, c, newest, older } = await twoVersions();
  const { version } = await json<RestoreResponse>(restore(desk.token, c.id, older.id));
  const history = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c.id}/versions`));
  expect(history[0]).toMatchObject({ id: version, kind: "restore", level: 3, current: true, restoredFrom: { id: older.id } });
  expect(history.map((v) => v.id)).toContain(newest.id);
  const [entry] = (await check(desk.token)).characters;
  expect(entry).toMatchObject({ version, restore: version, replace: true });
});

test("a restore can't pick the current version, or another player's", async () => {
  const { desk, c, newest, older } = await twoVersions();
  expect((await restore(desk.token, c.id, newest.id)).status).toBe(400);
  const other = await newDevice("user-2", "Elsewhere");
  expect((await restore(other.token, c.id, older.id)).status).toBe(404);
  expect((await restore(desk.token, c.id, 999999)).status).toBe(404);
});

test("an upload waiting to be merged when a restore is picked is set aside, not merged on top", async () => {
  const { desk, c, older } = await twoVersions();
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000), ...session(9000)] })));
  const { version } = await json<RestoreResponse>(restore(desk.token, c.id, older.id));
  await workAll();
  const [after] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const [head] = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c.id}/versions`));
  expect(head).toMatchObject({ id: version, current: true });
  expect(after!.level).toBe(3);
});
```

In `apps/server/test/sync.test.ts`, make `restoreHead()` call the route instead of writing rows: find the character and the version before the head with `/v1/characters` and `/v1/characters/:id/versions`, `POST` the restore, and return its `version`. Delete the hand-written restore in the test "a restore is delivered as a replace…" the same way. Remove the comments that say "the website's restore (a later step)".

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && bun test test/account.test.ts`
Expected: FAIL, the restore route answers 404.

- [ ] **Step 3: Add the type and the route**

`packages/api/src/index.ts`:

```ts
// POST /v1/characters/:id/restore, body { version }: the version becomes
// current again as a new restore version; every PC replaces its copy with
// it at its next login, unless it already took the restore in.
export type RestoreResponse = { version: number };
```

`apps/server/src/account.ts`: import `sql` from `drizzle-orm` and `RestoreResponse`, then chain:

```ts
  .post("/characters/:id/restore", async ({ device, params, body, set }): Promise<RestoreResponse | { error: string }> => {
    const c = await own(device!, params.id);
    const id = Number((body as { version?: unknown } | null)?.version);
    const [source] = c
      ? await db
          .select()
          .from(versions)
          .where(and(eq(versions.id, id), eq(versions.characterId, c.id), inArray(versions.kind, ["merged", "restore"])))
      : [];
    if (!c || !source) {
      set.status = 404;
      return { error: "no such version" };
    }
    if (source.id === c.headVersionId) {
      set.status = 400;
      return { error: "that is already the current version" };
    }
    // The restore, its parent and the head move are one change: a merge
    // finishing in between must either see all of it or none.
    const version = await db.transaction(async (tx) => {
      const [made] = await tx
        .insert(versions)
        .values({
          characterId: c.id,
          deviceId: device!.id,
          kind: "restore",
          fingerprint: source.fingerprint,
          rawSize: source.rawSize,
          dataVersion: source.dataVersion,
          level: source.level,
          status: "accepted",
        })
        .returning({ id: versions.id });
      await tx.insert(versionParents).values({ versionId: made!.id, parentId: source.id });
      const moved = await tx
        .update(characters)
        .set({ headVersionId: made!.id, level: source.level, updatedAt: new Date() })
        .where(and(eq(characters.id, c.id), sql`${characters.headVersionId} IS NOT DISTINCT FROM ${c.headVersionId}::bigint`))
        .returning({ id: characters.id });
      if (moved.length === 0) tx.rollback();
      return made!.id;
    }).catch(() => null);
    if (version === null) {
      set.status = 409;
      return { error: "the journey changed just now; try again" };
    }
    return { version };
  })
```

- [ ] **Step 4: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass. The worker's existing rule ("made before the restore reached this PC") sets the waiting upload aside.

- [ ] **Step 5: Commit**

```bash
git add packages/api apps/server
git commit -m "Server: restore a character's version from the app (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: List, rename and unlink PCs

**Files:**
- Modify: `apps/server/src/devices.ts` (`PC_NAME_MAX`, `pcName`)
- Modify: `apps/server/src/link.ts` (use `pcName`)
- Modify: `apps/server/src/account.ts`
- Modify: `packages/api/src/index.ts` (`DeviceInfo`)
- Test: `apps/server/test/account.test.ts`

**Interfaces:**
- Produces: `pcName(v: unknown): string | null`, `PC_NAME_MAX = 40`. Routes `GET /v1/devices` → `DeviceInfo[]` (linked PCs, most recently seen first), `PATCH /v1/devices/:id` with `{ name }` → `DeviceInfo`, `DELETE /v1/devices/:id` → `{ ok: true }` (the PC's token stops working at once; a PC may unlink itself).

- [ ] **Step 1: Write the failing tests**

Append to `apps/server/test/account.test.ts` (add `DeviceInfo` to the type import):

```ts
test("the PC list shows each linked PC with its versions and when it was last seen", async () => {
  const desk = await newDevice("user-1", "Desk");
  await newDevice("user-1", "Laptop");
  await newDevice("user-2", "Elsewhere");
  await call(desk.token, "/v1/check?addon=1.9.0&app=0.1.2");
  const list = await json<DeviceInfo[]>(call(desk.token, "/v1/devices"));
  expect(list.map((d) => d.name)).toEqual(["Desk", "Laptop"]);
  expect(list[0]).toMatchObject({ id: desk.device.id, addonVersion: "1.9.0", appVersion: "0.1.2" });
});

test("a PC can be renamed; a name is trimmed to 40 characters and can't be empty", async () => {
  const desk = await newDevice("user-1", "Desk");
  const rename = (name: unknown) =>
    call(desk.token, `/v1/devices/${desk.device.id}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name }),
    });
  expect(await json<DeviceInfo>(rename("  ROG   Ally\n"))).toMatchObject({ name: "ROG Ally" });
  expect((await json<DeviceInfo>(rename("x".repeat(200)))).name).toHaveLength(40);
  expect((await rename("   ")).status).toBe(400);
  expect((await rename(12)).status).toBe(400);
});

test("unlinking a PC stops its token at once, from itself or another PC, but not another player's", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  const other = await newDevice("user-2", "Elsewhere");
  expect((await call(other.token, `/v1/devices/${laptop.device.id}`, { method: "DELETE" })).status).toBe(404);
  expect((await call(desk.token, `/v1/devices/${laptop.device.id}`, { method: "DELETE" })).status).toBe(200);
  expect((await call(laptop.token, "/v1/check")).status).toBe(401);
  expect((await json<DeviceInfo[]>(call(desk.token, "/v1/devices"))).map((d) => d.name)).toEqual(["Desk"]);
  expect((await call(desk.token, `/v1/devices/${desk.device.id}`, { method: "DELETE" })).status).toBe(200);
  expect((await call(desk.token, "/v1/check")).status).toBe(401);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && bun test test/account.test.ts`
Expected: FAIL, `/v1/devices` answers 404.

- [ ] **Step 3: Add the name rule, the type and the routes**

`apps/server/src/devices.ts`:

```ts
export const PC_NAME_MAX = 40;

// A PC's name as the player typed it, on one line and at most PC_NAME_MAX
// characters; null when nothing is left.
export function pcName(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const name = v.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, PC_NAME_MAX).trim();
  return name || null;
}
```

`apps/server/src/link.ts`: `const name = pcName(query.name) ?? "PC";` (import `pcName`).

`packages/api/src/index.ts`:

```ts
// GET /v1/devices: the player's linked PCs, most recently seen first.
// PATCH /v1/devices/:id, body { name }, renames one; DELETE unlinks it.
export type DeviceInfo = {
  id: string; // the app compares it with its own pc to mark "This PC"
  name: string;
  platform: string | null; // darwin, windows or linux
  appVersion: string | null;
  addonVersion: string | null;
  lastSeenAt: string | null;
};
```

`apps/server/src/account.ts` (import `isNull`, `sql` and `pcName`, `DeviceInfo`):

```ts
const info = (d: typeof devices.$inferSelect): DeviceInfo => ({
  id: d.id,
  name: d.name,
  platform: d.platform,
  appVersion: d.appVersion,
  addonVersion: d.addonVersion,
  lastSeenAt: d.lastSeenAt?.toISOString() ?? null,
});

const mine = (device: Device, id: string) =>
  and(eq(devices.id, id), eq(devices.userId, device.userId), isNull(devices.revokedAt));
```

and chain:

```ts
  .get("/devices", async ({ device }): Promise<DeviceInfo[]> =>
    (
      await db
        .select()
        .from(devices)
        .where(and(eq(devices.userId, device!.userId), isNull(devices.revokedAt)))
        .orderBy(sql`${devices.lastSeenAt} DESC NULLS LAST`, devices.name)
    ).map(info),
  )

  .patch("/devices/:id", async ({ device, params, body, set }): Promise<DeviceInfo | { error: string }> => {
    const name = pcName((body as { name?: unknown } | null)?.name);
    if (!name) {
      set.status = 400;
      return { error: "a PC needs a name" };
    }
    const [renamed] = await db.update(devices).set({ name }).where(mine(device!, params.id)).returning();
    if (!renamed) {
      set.status = 404;
      return { error: "no such PC" };
    }
    return info(renamed);
  })

  // The token stops working at once; the PC's journeys stay where they are.
  .delete("/devices/:id", async ({ device, params, set }) => {
    const [gone] = await db.update(devices).set({ revokedAt: new Date() }).where(mine(device!, params.id)).returning({ id: devices.id });
    if (!gone) {
      set.status = 404;
      return { error: "no such PC" };
    }
    return { ok: true };
  })
```

- [ ] **Step 4: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass. (The PC list test expects "Desk" first because it was just seen and "Laptop" never was.)

- [ ] **Step 5: Commit**

```bash
git add packages/api apps/server
git commit -m "Server: list, rename and unlink PCs; unlinking stops the PC's token at once (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Download all my data

**Files:**
- Create: `apps/server/src/zip.ts`
- Modify: `apps/server/src/account.ts` (`GET /v1/export`)
- Test: `apps/server/test/account.test.ts`

**Interfaces:**
- Consumes: `get(userId, fingerprint)` from `src/storage.ts`.
- Produces: `zip(files: { name: string; data: Uint8Array }[]): Uint8Array`. Route `GET /v1/export` → `application/zip`, one `<game>/<realm>/<name>.lua` per character with a merged journey, holding `RoadToSixtyCharDB = <journey>`.

- [ ] **Step 1: Write the failing test**

Append to `apps/server/test/account.test.ts` (imports: `mkdtemp`, `rm` from `node:fs/promises`, `tmpdir` from `node:os`, `join` from `node:path`):

```ts
test("the export is a zip of each character's journey that unzip accepts, accents and all", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await upload(desk.token, savedFile(journey({ events: session(2000) })), { realm: "Azjol-Nérub", name: "Zoë" });
  await workAll();
  const r = await call(desk.token, "/v1/export");
  expect(r.headers.get("content-type")).toBe("application/zip");
  const dir = await mkdtemp(join(tmpdir(), "rts-export-"));
  try {
    const path = join(dir, "export.zip");
    await Bun.write(path, await r.arrayBuffer());
    const tested = Bun.spawnSync(["unzip", "-t", path]);
    expect(tested.exitCode).toBe(0);
    const listed = Bun.spawnSync(["unzip", "-Z1", path]).stdout.toString().trim().split("\n").sort();
    expect(listed).toEqual(["_classic_beta_/Azjol-Nérub/Zoë.lua", "_classic_beta_/Test Realm/Ann.lua"]);
    const text = Bun.spawnSync(["unzip", "-p", path, "_classic_beta_/Test Realm/Ann.lua"]).stdout.toString();
    expect(text.startsWith("RoadToSixtyCharDB = ")).toBe(true);
    expect(sessions(text)).toBe(1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
```

(Add `sessions` to the helpers import.)

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/server && bun test test/account.test.ts`
Expected: FAIL, `/v1/export` answers 404.

- [ ] **Step 3: Write the zip writer**

Create `apps/server/src/zip.ts`:

```ts
import { deflateRawSync } from "node:zlib";

export type ZipFile = { name: string; data: Uint8Array };

// A zip file holding these files, each deflated. Names are flagged as UTF-8
// (bit 11), so a realm or character with an accent keeps it. Every file is
// dated 1 January 1980, zip's earliest date: the journeys carry their own
// times. ponytail: no zip64, so the whole zip must stay under 4 GB.
export function zip(files: ZipFile[]): Uint8Array {
  const out: Uint8Array[] = [];
  const directory: Uint8Array[] = [];
  let offset = 0;
  for (const file of files) {
    const name = new TextEncoder().encode(file.name);
    const packed = deflateRawSync(file.data);
    const crc = Bun.hash.crc32(file.data);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true);
    local.setUint16(8, 8, true);
    local.setUint16(12, 0x21, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, packed.length, true);
    local.setUint32(22, file.data.length, true);
    local.setUint16(26, name.length, true);
    const entry = new DataView(new ArrayBuffer(46));
    entry.setUint32(0, 0x02014b50, true);
    entry.setUint16(4, 20, true);
    entry.setUint16(6, 20, true);
    entry.setUint16(8, 0x0800, true);
    entry.setUint16(10, 8, true);
    entry.setUint16(14, 0x21, true);
    entry.setUint32(16, crc, true);
    entry.setUint32(20, packed.length, true);
    entry.setUint32(24, file.data.length, true);
    entry.setUint16(28, name.length, true);
    entry.setUint32(42, offset, true);
    out.push(new Uint8Array(local.buffer), name, packed);
    directory.push(new Uint8Array(entry.buffer), name);
    offset += 30 + name.length + packed.length;
  }
  const size = directory.reduce((n, part) => n + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, files.length, true);
  end.setUint16(10, files.length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  return new Uint8Array(Buffer.concat([...out, ...directory, new Uint8Array(end.buffer)]));
}
```

- [ ] **Step 4: Add the route**

In `apps/server/src/account.ts` (import `get` from `./storage`, `zip` from `./zip`):

```ts
// Characters as folder names: no slashes or characters Windows refuses.
const safe = (s: string) => s.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_");
```

and chain:

```ts
  // Each character's current journey as the game would save it, so a
  // player can keep it, or put it back in their SavedVariables folder.
  .get("/export", async ({ device }) => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .innerJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    const files = [];
    for (const { c, head } of rows) {
      const journey = await get(c.userId, head.fingerprint);
      const data = Buffer.concat([new TextEncoder().encode("RoadToSixtyCharDB = "), journey, new TextEncoder().encode("\n")]);
      files.push({ name: `${safe(c.game)}/${safe(c.realm)}/${safe(c.name)}.lua`, data: new Uint8Array(data) });
    }
    return new Response(zip(files), {
      headers: { "content-type": "application/zip", "content-disposition": 'attachment; filename="road-to-sixty.zip"' },
    });
  })
```

- [ ] **Step 5: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add apps/server
git commit -m "Server: download all my data as a zip of each character's journey (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Delete everything

**Files:**
- Modify: `apps/server/src/storage.ts` (`removeAll`)
- Modify: `apps/server/src/account.ts` (`DELETE /v1/account`)
- Test: `apps/server/test/account.test.ts`

**Interfaces:**
- Produces: `removeAll(userId: string): Promise<void>` (every file under the user's prefix). Route `DELETE /v1/account` → `{ ok: true }`; afterwards none of the player's rows, files or tokens remain.

- [ ] **Step 1: Write the failing test**

Append to `apps/server/test/account.test.ts` (imports: `config` from `../src/config`, `db` from `../src/db`, `characters, devices, jobs, user, versions` from `../src/schema`, `eq` from `drizzle-orm`):

```ts
test("delete everything removes the player's rows, files and PCs, even with a merge waiting, and no one else's", async () => {
  const desk = await newDevice("user-1", "Desk");
  const other = await newDevice("user-2", "Elsewhere");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await upload(other.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(desk.token, savedFile(journey({ events: session(5000) }))); // still queued
  expect((await call(desk.token, "/v1/account", { method: "DELETE" })).status).toBe(200);

  expect((await call(desk.token, "/v1/check")).status).toBe(401);
  expect(await db.select().from(user).where(eq(user.id, "user-1"))).toEqual([]);
  expect(await db.select().from(devices).where(eq(devices.userId, "user-1"))).toEqual([]);
  expect(await db.select().from(characters).where(eq(characters.userId, "user-1"))).toEqual([]);
  expect((await db.select().from(jobs)).length).toBe(1); // only user-2's finished job is left
  const s3 = new Bun.S3Client(config.s3);
  expect((await s3.list({ prefix: "user-1/" })).contents ?? []).toEqual([]);
  expect(((await s3.list({ prefix: "user-2/" })).contents ?? []).length).toBeGreaterThan(0);
  expect((await call(other.token, "/v1/check")).status).toBe(200);
  expect((await db.select().from(versions)).length).toBeGreaterThan(0);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/server && bun test test/account.test.ts`
Expected: FAIL, `DELETE /v1/account` answers 404.

- [ ] **Step 3: Delete the files**

`apps/server/src/storage.ts`:

```ts
// Every journey file of a player. Listing again after each page works
// because the page just listed is gone.
// ponytail: one request per file; a bulk delete if players hold thousands.
export async function removeAll(userId: string): Promise<void> {
  for (;;) {
    const page = await s3.list({ prefix: `${userId}/` });
    const keys = (page.contents ?? []).map((o) => o.key);
    for (const k of keys) await s3.delete(k);
    if (!page.isTruncated || keys.length === 0) return;
  }
}
```

- [ ] **Step 4: Add the route**

`apps/server/src/account.ts` (import `jobs`, `user` from `./schema`, `removeAll` from `./storage`):

```ts
  // Spec, "Deleting an account". The PCs are unlinked first so nothing new
  // arrives, and the files go before the rows, so if anything fails part
  // way the player can try again and no file is left with no owner.
  .delete("/account", async ({ device }) => {
    const userId = device!.userId;
    await db.update(devices).set({ revokedAt: new Date() }).where(and(eq(devices.userId, userId), isNull(devices.revokedAt)));
    const theirs = db.select({ id: characters.id }).from(characters).where(eq(characters.userId, userId));
    await db.delete(jobs).where(inArray(jobs.characterId, theirs));
    await removeAll(userId);
    await db.transaction(async (tx) => {
      const theirVersions = tx.select({ id: versions.id }).from(versions).where(inArray(versions.characterId, theirs));
      await tx.delete(versionParents).where(inArray(versionParents.versionId, theirVersions));
      await tx.delete(versions).where(inArray(versions.characterId, theirs));
      await tx.delete(characters).where(eq(characters.userId, userId));
      await tx.delete(devices).where(eq(devices.userId, userId));
      // Sessions, Battle.net accounts and device codes go with the user.
      await tx.delete(user).where(eq(user.id, userId));
    });
    return { ok: true };
  })
```

- [ ] **Step 5: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add apps/server
git commit -m "Server: delete everything removes a player's journeys, PCs and account (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The app names the PC when it asks for a code

**Files:**
- Modify: `apps/desktop/engine/src/api.rs` (`device_code`)
- Modify: `apps/desktop/engine/src/link.rs` (pass the name)
- Test: `apps/desktop/engine/src/link.rs` tests; `apps/server/test/auth.test.ts`
- Modify: `apps/desktop/AGENTS.md`

**Interfaces:**
- Produces: `Client::device_code(&self, name: &str, platform: &str) -> Result<DeviceCode, ApiError>`, sending `scope` as the JSON text `{"pc":"<name>","platform":"<platform>"}`. Task 10's page reads it back from `GET /api/auth/device?user_code=`.

- [ ] **Step 1: Write the failing engine test**

In `apps/desktop/engine/src/link.rs`, test `opens_the_page_polls_until_approved_then_links`, after the existing assertions add:

```rust
        let seen = fake.seen.lock().unwrap();
        let asked = seen.iter().find(|s| s.url == "/api/auth/device/code").unwrap();
        let body: serde_json::Value = serde_json::from_slice(&asked.body).unwrap();
        let scope: serde_json::Value = serde_json::from_str(body["scope"].as_str().unwrap()).unwrap();
        assert_eq!(scope["pc"], "Desk");
        assert_eq!(scope["platform"], platform());
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/desktop && cargo test -p rts-sync link`
Expected: FAIL, `body["scope"]` is null so `unwrap` panics.

- [ ] **Step 3: Send the name**

`apps/desktop/engine/src/api.rs`:

```rust
    /// Asks for a code to link with. The PC's name rides in `scope`, which
    /// the server keeps with the code and shows only to the player who
    /// types it in, so the link page can say which PC it is.
    pub fn device_code(&self, name: &str, platform: &str) -> Result<DeviceCode, ApiError> {
        let scope = serde_json::json!({ "pc": name, "platform": platform }).to_string();
        json(
            self.agent
                .post(self.url("/api/auth/device/code"))
                .send_json(serde_json::json!({ "client_id": APP_CLIENT_ID, "scope": scope })),
        )
    }
```

`apps/desktop/engine/src/link.rs`: `let code = client.device_code(pc_name, platform())?;`

- [ ] **Step 4: Run the engine tests**

Run: `cd apps/desktop && cargo test -p rts-sync`
Expected: all pass.

- [ ] **Step 5: Pin the server side**

Append to `apps/server/test/auth.test.ts`:

```ts
test("the PC's name comes back with its code, but only to the player who typed the code in", async () => {
  const scope = JSON.stringify({ pc: "Desk", platform: "darwin" });
  const code = (await (await post("/api/auth/device/code", { client_id: APP_CLIENT_ID, scope })).json()) as { user_code: string };
  const ann = await signIn({ id: 1, battletag: "Ann#1111" });
  const bob = await signIn({ id: 2, battletag: "Bob#2222" });
  const first = (await (await get(`/api/auth/device?user_code=${code.user_code}`, { cookie: ann })).json()) as { scope?: string };
  expect(JSON.parse(first.scope!)).toEqual({ pc: "Desk", platform: "darwin" });
  const second = (await (await get(`/api/auth/device?user_code=${code.user_code}`, { cookie: bob })).json()) as { scope?: string };
  expect(second.scope).toBeUndefined();
});
```

Run: `cd apps/server && bun test test/auth.test.ts`
Expected: PASS. This pins Better Auth's behaviour the link page depends on; if an upgrade changes it, this test says so.

- [ ] **Step 6: Update AGENTS.md and commit**

`apps/desktop/AGENTS.md`, `link.rs` line: add "The PC's name goes with the code request, in `scope`, so the link page can show it."

```bash
git add apps/desktop apps/server/test/auth.test.ts
git commit -m "Desktop: send the PC's name with the link code, so the link page can show it (#40)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The fog animation, shared

**Files:**
- Modify: `packages/ui/src/dots.ts`
- Modify: `packages/ui/src/Fog.tsx` (`animate` prop)
- Test: `packages/ui/src/dots.test.ts`
- Modify: `packages/ui/AGENTS.md`

**Interfaces:**
- Produces: `type Dot = [x: number, y: number, at: number]` (`at` is how far along its nearest road, 0 to 1). `fogDots(width, height, step, roads)` returns `{ lit: Dot[]; edge: Dot[]; fog: Point[] }`. `fogAnimation(seconds: number): string` (CSS for the class `rts-fog-road`, with the reduced-motion rule). `fogDelay(at: number, seconds: number): string` (a negative `animation-delay`). `<Fog animate={seconds} />` animates; without it, the drawing is unchanged.

- [ ] **Step 1: Write the failing tests**

Replace `packages/ui/src/dots.test.ts` with:

```ts
import { expect, test } from "bun:test";
import { fogAnimation, fogDelay, fogDots } from "./dots";

const xy = (dots: number[][]) => dots.map(([x, y]) => [x, y]);

test("dots on the road are lit, near it half lit, the rest fogged", () => {
  const road: [number, number][] = [[0, 50], [200, 50]];
  const { lit, edge, fog } = fogDots(200, 200, 20, [road]);
  expect(xy(lit)).toContainEqual([70, 50]);
  expect(xy(edge)).toContainEqual([70, 90]);
  expect(fog).toContainEqual([70, 150]);
  expect(lit.length + edge.length + fog.length).toBe(100);
});

test("with no roads everything is fogged", () => {
  const { lit, edge, fog } = fogDots(100, 100, 50, []);
  expect([lit.length, edge.length, fog.length]).toEqual([0, 0, 4]);
});

test("each lit dot knows how far along its road it sits, so the light can travel along it", () => {
  const road: [number, number][] = [[0, 50], [100, 50], [200, 50]];
  const { lit } = fogDots(200, 100, 20, [road]);
  const at = (x: number) => lit.find(([lx, ly]) => lx === x && ly === 50)![2];
  expect(at(10)).toBeCloseTo(0.05);
  expect(at(190)).toBeCloseTo(0.95);
});

test("the animation starts each dot as far into its loop as it is along the road, and stays still for reduced motion", () => {
  expect(fogDelay(0.25, 20)).toBe("-15.00s");
  expect(fogDelay(0, 14)).toBe("-14.00s");
  const css = fogAnimation(14);
  expect(css).toContain("rts-fog-road");
  expect(css).toContain("14s");
  expect(css).toContain("prefers-reduced-motion");
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd packages/ui && bun test`
Expected: FAIL, `fogAnimation` and `fogDelay` aren't exported.

- [ ] **Step 3: Write the shared fog**

Replace `packages/ui/src/dots.ts` with:

```ts
// The fog of war background: a grid of faint dots, lit along the roads a
// journey took, like the map uncovering where you've been. Animated, the
// lit stretch travels along each road: dots light up in turn, swell for a
// moment, then fade back into the fog.

export type Point = [number, number];
// at: how far along its nearest road the dot sits, from 0 to 1.
export type Dot = [x: number, y: number, at: number];

// Grid dots start half a step in, so the grid sits centred in the box.
export function fogDots(width: number, height: number, step: number, roads: Point[][]) {
  const lengths = roads.map((road) => road.slice(1).map((b, i) => Math.hypot(b[0] - road[i]![0], b[1] - road[i]![1])));
  const totals = lengths.map((l) => l.reduce((a, b) => a + b, 0));
  const lit: Dot[] = [],
    edge: Dot[] = [],
    fog: Point[] = [];
  for (let x = step / 2; x < width; x += step) {
    for (let y = step / 2; y < height; y += step) {
      let near = Infinity,
        at = 0;
      roads.forEach((road, r) => {
        let before = 0;
        for (let i = 0; i + 1 < road.length; i++) {
          const [d, t] = distance([x, y], road[i]!, road[i + 1]!);
          if (d < near) {
            near = d;
            at = totals[r]! > 0 ? (before + t * lengths[r]![i]!) / totals[r]! : 0;
          }
          before += lengths[r]![i]!;
        }
      });
      if (near < step * 1.2) lit.push([x, y, at]);
      else if (near < step * 3.2) edge.push([x, y, at]);
      else fog.push([x, y]);
    }
  }
  return { lit, edge, fog };
}

// The CSS for lit and half-lit dots with the class rts-fog-road. Every dot
// runs the same loop; fogDelay starts each one partway in.
export function fogAnimation(seconds: number): string {
  return [
    "@keyframes rts-fog{0%{opacity:0;transform:scale(.4)}5%{opacity:1;transform:scale(1.9)}12%{opacity:1;transform:scale(1)}" +
      "40%{opacity:1;transform:scale(1)}55%{opacity:0;transform:scale(.6)}100%{opacity:0;transform:scale(.6)}}",
    `.rts-fog-road{opacity:0;transform-box:fill-box;transform-origin:center;animation:rts-fog ${seconds}s linear infinite}`,
    "@media (prefers-reduced-motion:reduce){.rts-fog-road{animation:none;opacity:1}}",
  ].join("\n");
}

// Negative, so the loop is already running when the page appears.
export function fogDelay(at: number, seconds: number): string {
  return `${(at * seconds - seconds).toFixed(2)}s`;
}

// How far p is from the segment a to b, and where along it (0 to 1) the
// nearest point lies.
function distance([px, py]: Point, [ax, ay]: Point, [bx, by]: Point): [number, number] {
  const dx = bx - ax,
    dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy || 1)));
  return [Math.hypot(px - ax - t * dx, py - ay - t * dy), t];
}
```

- [ ] **Step 4: Let Fog animate**

Replace `packages/ui/src/Fog.tsx` with:

```tsx
import { useMemo } from "react";
import { fogAnimation, fogDelay, fogDots, type Point } from "./dots";

// Draws the fog grid at a fixed size; the parent clips and fades it.
// animate is the loop's length in seconds; without it the fog is still.
export function Fog({ width, height, step, roads, marks = [], animate }: { width: number; height: number; step: number; roads: Point[][]; marks?: Point[]; animate?: number }) {
  const { lit, edge, fog } = useMemo(() => fogDots(width, height, step, roads), [width, height, step, roads]);
  const road = (at: number) => (animate ? { className: "rts-fog-road", style: { animationDelay: fogDelay(at, animate) } } : {});
  return (
    <svg aria-hidden="true" width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="pointer-events-none absolute left-0 top-0">
      {animate && <style>{fogAnimation(animate)}</style>}
      {fog.map(([x, y]) => <circle key={`f${x},${y}`} cx={x} cy={y} r={1.1} fill="rgba(154,149,168,0.16)" />)}
      {edge.map(([x, y, at]) => <circle key={`e${x},${y}`} cx={x} cy={y} r={1.4} fill="rgba(154,149,168,0.4)" {...road(at)} />)}
      {lit.map(([x, y, at]) => {
        const r = road(at);
        return <circle key={`l${x},${y}`} cx={x} cy={y} r={1.8} fillOpacity={0.85} className={`fill-accent ${r.className ?? ""}`} style={r.style} />;
      })}
      {marks.map(([x, y]) => (
        <g key={`m${x},${y}`}>
          <circle cx={x} cy={y} r={8} fill="none" className="stroke-accent" strokeOpacity={0.35} />
          <circle cx={x} cy={y} r={3} className="fill-accent" />
        </g>
      ))}
    </svg>
  );
}
```

- [ ] **Step 5: Run the UI tests, types and the app's build**

Run: `cd packages/ui && bun test && bun run typecheck && cd ../../apps/desktop && bun run build`
Expected: all pass; the app's window builds (its first-run fog is unchanged, it passes no `animate`).

- [ ] **Step 6: Update AGENTS.md and commit**

`packages/ui/AGENTS.md`: add "`src/dots.ts` is the fog of war background and its animation (`fogAnimation`, `fogDelay`); `Fog.tsx` draws it in React, and the server's link page draws it from the same file without React. The website uses it with `animate`."

```bash
git add packages/ui
git commit -m "UI: the fog of war can animate, a lit stretch travelling along each road (#39)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The link page in look A

**Files:**
- Modify: `apps/server/src/link.html` (rewritten)
- Create: `apps/server/src/link-page.ts` (the page's script, built by the server)
- Modify: `apps/server/src/link.ts` (`/link.js`, `/link/compass.png`, `/link/geist.woff2`)
- Modify: `apps/server/package.json` (`"@road-to-sixty/ui": "workspace:*"`), `bun.lock`
- Modify: `apps/server/Dockerfile` (copy `packages/ui`)
- Test: `apps/server/test/auth.test.ts` ("the link page is served")
- Modify: `apps/server/AGENTS.md`

**Interfaces:**
- Consumes: `fogDots`, `fogAnimation`, `fogDelay`, `Point` from `@road-to-sixty/ui/dots` (Task 9); the PC's name in `scope` (Task 8).
- Produces: `GET /link` (the page), `GET /link.js` (its script, built once with `Bun.build`), `GET /link/compass.png`, `GET /link/geist.woff2`.

- [ ] **Step 1: Write the failing test**

In `apps/server/test/auth.test.ts`, replace "the link page is served" with:

```ts
test("the link page, its script and its pictures are served, and the code is typed, never filled in", async () => {
  const page = await get("/link?user_code=ABCD1234");
  expect(page.headers.get("content-type")).toContain("text/html");
  const text = await page.text();
  expect(text).toContain("Link a PC");
  expect(text).toContain("If someone sent you here with a code, don't type it.");
  const script = await get("/link.js");
  expect(script.headers.get("content-type")).toContain("javascript");
  const js = await script.text();
  expect(js).toContain("rts-fog-road");
  expect(js).not.toContain("URLSearchParams"); // the code is never read from the address
  expect((await get("/link/compass.png")).headers.get("content-type")).toBe("image/png");
  expect((await get("/link/geist.woff2")).status).toBe(200);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/server && bun test test/auth.test.ts`
Expected: FAIL, the page still says "Link this PC" and `/link.js` answers 404.

- [ ] **Step 3: Add the dependency**

In `apps/server/package.json` dependencies add `"@road-to-sixty/ui": "workspace:*",`, then run `bun install` at the repo root.
Expected: `bun.lock` updated, no errors.

- [ ] **Step 4: Write the page**

Replace `apps/server/src/link.html` with:

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Link a PC · Road to Sixty</title>
<!-- Look A from the mockups (#39); the website shares its fog. -->
<style>
  @font-face { font-family: Geist; src: url(/link/geist.woff2) format("woff2"); font-weight: 100 900; }
  :root { --ground: #07060a; --panel: #0c0b10; --line: #1f1d26; --outline: #3a3746; --text: #ece9f2; --muted: #9a95a8; --faint: #6f6a7d; --cream: #f7f4ee; --ink: #17141d; --warn: #e5b84a; }
  body { margin: 0; min-height: 100vh; background: var(--ground); color: var(--text); font: 14px/1.5 Geist, system-ui, sans-serif; overflow-x: hidden; position: relative; }
  #fog { position: absolute; left: 50%; top: 0; transform: translateX(-50%); pointer-events: none;
         -webkit-mask-image: linear-gradient(#000 40%, transparent); mask-image: linear-gradient(#000 40%, transparent); }
  main { position: relative; max-width: 400px; margin: 0 auto; padding: 96px 16px 48px; display: flex; flex-direction: column; gap: 20px; }
  h1 { margin: 0; font-size: 24px; font-weight: 500; letter-spacing: -0.02em; }
  p { margin: 0; }
  .muted { color: var(--muted); }
  .faint { color: var(--faint); font-size: 12px; }
  .card { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); padding: 20px; display: flex; flex-direction: column; gap: 14px; }
  label { font-weight: 500; }
  input { height: 48px; box-sizing: border-box; border-radius: 10px; border: 1px solid var(--outline); background: var(--ground); color: var(--text);
          padding: 0 14px; font: 20px ui-monospace, monospace; letter-spacing: 0.12em; text-transform: uppercase; }
  .pc { border-radius: 10px; background: #12101a; padding: 12px 14px; display: flex; flex-direction: column; gap: 4px; }
  .pc strong { font-weight: 500; }
  button { height: 42px; border-radius: 10px; border: 0; background: var(--cream); color: var(--ink); font: 500 14px Geist, system-ui, sans-serif; cursor: pointer; }
  #result:empty { display: none; }
  .note { font-size: 13px; color: var(--muted); }
</style>
<svg id="fog" aria-hidden="true" width="1400" height="360" viewBox="0 0 1400 360"></svg>
<main>
  <img src="/link/compass.png" alt="" width="48" height="48" style="border-radius: 10px" />
  <div>
    <h1>Link a PC</h1>
    <p id="who" class="muted"></p>
  </div>
  <button id="sign-in" hidden>Sign in with Battle.net</button>
  <form id="form" class="card" hidden>
    <label for="code">Type the code Road to Sixty shows on your PC</label>
    <input id="code" autocomplete="off" spellcheck="false" required />
    <div id="pc" class="pc" hidden>
      <span class="faint">This code belongs to</span>
      <strong id="pc-name"></strong>
    </div>
    <button id="link">Link</button>
  </form>
  <p id="result"></p>
  <p class="note">Only link a PC you're sitting at. A linked PC can read and change your journeys. If someone sent you here with a code, don't type it.</p>
</main>
<script type="module" src="/link.js"></script>
</html>
```

- [ ] **Step 5: Write the page's script**

Create `apps/server/src/link-page.ts`:

```ts
/// <reference lib="dom" />
// The link page's script, built for the browser by link.ts. The code is
// always typed by the player, never read from the address: a link with
// someone else's code filled in is how a PC gets phished onto an account.
import { fogAnimation, fogDelay, fogDots, type Point } from "@road-to-sixty/ui/dots";

const $ = (id: string) => document.getElementById(id)!;
const SVG = "http://www.w3.org/2000/svg";
const LOOP = 14;
const ROAD: Point[] = [[-20, 300], [220, 250], [420, 190], [620, 170], [820, 110], [1040, 80], [1420, 20]];
const PLATFORMS: Record<string, string> = { darwin: "Mac", windows: "Windows", linux: "Linux" };

function drawFog() {
  const svg = $("fog");
  const style = document.createElementNS(SVG, "style");
  style.textContent = fogAnimation(LOOP);
  svg.append(style);
  const { lit, edge, fog } = fogDots(1400, 360, 18, [ROAD]);
  const dot = (x: number, y: number, r: number, fill: string, at?: number) => {
    const c = document.createElementNS(SVG, "circle");
    c.setAttribute("cx", String(x));
    c.setAttribute("cy", String(y));
    c.setAttribute("r", String(r));
    c.setAttribute("fill", fill);
    if (at !== undefined) {
      c.setAttribute("class", "rts-fog-road");
      c.style.animationDelay = fogDelay(at, LOOP);
    }
    svg.append(c);
  };
  for (const [x, y] of fog) dot(x, y, 1.1, "rgba(154,149,168,0.14)");
  for (const [x, y, at] of edge) dot(x, y, 1.4, "rgba(154,149,168,0.38)", at);
  for (const [x, y, at] of lit) dot(x, y, 1.8, "rgba(58,160,255,0.85)", at);
}

async function call(path: string, body?: object) {
  const r = await fetch(`/api/auth${path}`, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : {});
  return { ok: r.ok, data: await r.json().catch(() => null) };
}

// The name the app sent with its code, if it sent one (app 0.1.1 doesn't).
function pcOf(scope: unknown): string | null {
  try {
    const { pc, platform } = JSON.parse(String(scope)) as { pc?: unknown; platform?: unknown };
    if (typeof pc !== "string" || !pc) return null;
    const where = typeof platform === "string" ? PLATFORMS[platform] : undefined;
    return where ? `${pc} · ${where}` : pc;
  } catch {
    return null;
  }
}

const typed = () => ($("code") as HTMLInputElement).value.toUpperCase().replace(/[^A-Z0-9]/g, "");

drawFog();
const signedIn = (await call("/get-session")).data as { user: { name: string } } | null;
if (!signedIn) {
  $("sign-in").hidden = false;
  $("sign-in").onclick = async () => {
    const r = await call("/sign-in/social", { provider: "battlenet", callbackURL: location.pathname });
    if (r.data?.url) location.href = r.data.url;
  };
} else {
  $("who").textContent = `Signed in as ${signedIn.user.name}`;
  $("form").hidden = false;
  let looked = "";
  // Looking the code up ties it to this player; only then is the PC's name
  // shown, and only then can they approve it.
  $("code").oninput = async () => {
    const code = typed();
    if (code.length < 8 || code === looked) return;
    looked = code;
    const found = await call(`/device?user_code=${encodeURIComponent(code)}`);
    const name = found.ok ? pcOf(found.data?.scope) : null;
    $("pc").hidden = !found.ok;
    $("pc-name").textContent = name ?? "a PC";
    $("link").textContent = name ? `Link ${name.split(" · ")[0]}` : "Link";
  };
  $("form").onsubmit = async (e) => {
    e.preventDefault();
    const userCode = typed();
    const found = await call(`/device?user_code=${encodeURIComponent(userCode)}`);
    const r = found.ok ? await call("/device/approve", { userCode }) : found;
    $("result").textContent = r.ok
      ? "Linked. You can close this page; the app takes it from here."
      : `That didn't work: ${r.data?.message ?? "check the code and try again"}`;
  };
}
```

Before relying on the code's shape, check what Better Auth's default user code looks like: `cd apps/server && bun -e 'import("./test/helpers").then(async (h) => { await h.reset(); const { app } = await import("./src/app"); const r = await app.handle(new Request("http://localhost:3000/api/auth/device/code", { method: "POST", headers: { "content-type": "application/json", origin: "http://localhost:3000" }, body: JSON.stringify({ client_id: "road-to-sixty-app" }) })); console.log((await r.json()).user_code); process.exit(0) })'`
Expected: 8 letters and digits. If it is longer, or holds a dash, change `code.length < 8` and the `replace` in `typed` to match, and record the ruling in the ledger.

- [ ] **Step 6: Serve the script and pictures**

In `apps/server/src/link.ts`:

```ts
import { dirname } from "node:path";

const COMPASS = Bun.resolveSync("@road-to-sixty/ui/compass.png", import.meta.dir);
const GEIST = Bun.resolveSync("@fontsource-variable/geist/files/geist-latin-wght-normal.woff2", dirname(COMPASS));

// The page's script, built for the browser the first time it is asked for.
let script: Promise<string> | undefined;
function pageScript(): Promise<string> {
  script ??= Bun.build({ entrypoints: [`${import.meta.dir}/link-page.ts`], target: "browser", minify: true }).then((r) => {
    if (!r.success) throw new AggregateError(r.logs, "the link page's script didn't build");
    return r.outputs[0]!.text();
  });
  return script;
}
```

and chain onto `link` after `.get("/link", …)`:

```ts
  .get("/link.js", async () => new Response(await pageScript(), { headers: { "content-type": "text/javascript; charset=utf-8" } }))
  .get("/link/compass.png", () => new Response(Bun.file(COMPASS), { headers: { "content-type": "image/png" } }))
  .get("/link/geist.woff2", () => new Response(Bun.file(GEIST), { headers: { "content-type": "font/woff2" } }))
```

- [ ] **Step 7: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass.

- [ ] **Step 8: Look at it**

Run `cd apps/server && bun run dev` (with `.env`), open `http://localhost:3000/link`, sign in through the local test login if `.env` points at it, or check the signed-out view. Expected: near-black page, compass, "Link a PC", the fog with a lit stretch moving along the road. Take a screenshot for Jordan.

- [ ] **Step 9: Copy the UI package into the image**

In `apps/server/Dockerfile`, add `COPY packages/ui/package.json packages/ui/` beside the other `package.json` copies, and `COPY packages/ui packages/ui` after `COPY packages/api packages/api`. Update the comment that says every workspace's `package.json` is copied if it isn't true.

Run: `docker build -f apps/server/Dockerfile -t rts-server-check .` from the repo root.
Expected: the build succeeds.

Run: `docker run --rm --entrypoint bun rts-server-check -e 'const r = await Bun.build({ entrypoints: ["/app/apps/server/src/link-page.ts"], target: "browser" }); console.log(r.success, Bun.resolveSync("@road-to-sixty/ui/compass.png", "/app/apps/server/src"))'`
Expected: `true /app/packages/ui/compass.png`.

- [ ] **Step 10: Update AGENTS.md and commit**

`apps/server/AGENTS.md`, the `link.ts` line becomes: "`src/link.ts`, `src/link.html` and `src/link-page.ts` link a PC: the player types the app's code on `/link`, sees the PC's name the app sent in the code's `scope`, and approves it; the app trades it for a PC token (`src/devices.ts`, which keeps only the token's hash). The page's script is built once by `Bun.build` and draws the fog from `packages/ui`, so the image copies that package." Under "Rules that bite" add: "Never fill the link code in from the address: typing it is the protection against a link with someone else's code."

```bash
git add apps/server bun.lock
git commit -m "Server: the link page in look A: type the code, see which PC it is, over the moving fog (#39, #40)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: The spec

**Files:**
- Modify: `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`

- [ ] **Step 1: Bring the spec up to date**

- "Account API": replace the one-line list with the routes: `GET /v1/characters`, `GET /v1/characters/:id/versions`, `POST /v1/characters/:id/restore`, `GET /v1/devices`, `PATCH /v1/devices/:id`, `DELETE /v1/devices/:id`, `GET /v1/export`, `DELETE /v1/account`, each with one line on what it does, and that every one uses the PC token.
- "Restore": a restore is a new version; `/check` sends its id as `restore` until the PC's uploads show it took it in; the addon replaces only a copy older than that id, so play since the restore merges instead (#40 item 7).
- "Postgres": add `level` to `versions`; note that the character file now holds `class`.
- "Linking the app" or "First run": the PC's name goes with the code request in `scope`; the player types the code on the link page, which shows that name.
- "The website", "Look": the fog's lit stretch travels along the roads, shared with the link page.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
git commit -m "Docs: the account API, restores by id and the link page in the sync spec (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

After the final review: merge `account-api` into `dev`, push `dev`, watch CI and the Dokploy deploy (migration `0003` runs at start), check `https://api.rts.everhold.online/link` shows the new page, and comment on #1, #39 and #40.
