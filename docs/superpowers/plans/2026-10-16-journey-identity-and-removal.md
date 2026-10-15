# One journey per character, removing characters, and beta characters: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A remade namesake or an erased journey starts a journey of its own, any character can be removed from the backup, and beta characters are tagged in the app with one button to remove them all (#51).

**Architecture:** The addon writes a stamp, `journeyId = "<GUID>:<start>"`, into each character file at login (start `0`, or the time of an Erase). The server reads the stamp from each upload and keeps one row per journey; a stamped upload meeting a row from before stamps joins it only when `Merge.SameJourney` (run by `runner.lua`) says they begin alike. A name's current journey is its newest row. A new `DELETE /v1/characters/:id` removes one row, and app 0.1.7 offers it per character, per earlier journey, and for every beta character at once.

**Tech Stack:** Lua 5.1 / LuaJIT (addon, `runner.lua`), Bun + Elysia + Drizzle + Postgres 17 (server), Tauri 2 + React (app), Astro (website).

**Spec:** `docs/superpowers/specs/2026-10-15-journey-identity-and-removal-design.md`

**Worktree:** `/Users/jordan/personal/road-to-sixty-journeys`, branch `journeys` (from `dev`). Run `bun install` there first if `node_modules` is missing.

## Global Constraints

- Stamp format: `<GUID>:<start>`, GUID from `UnitGUID("player")` (letters, digits, hyphens), start `0` for an ordinary journey or `ns.Now()` for an Erase. At most 64 characters.
- `DATA_VERSION` 3 → 4 in Core.lua and `Merge.VERSION` 3 → 4 in Merge.lua, together.
- Migration 0009 is made by `bun run db:generate` (drizzle-kit), never by hand.
- The 409 text, verbatim: `Its latest upload is being merged; try again in a minute`.
- The Erase popup line, verbatim: `Your backup keeps the old journey as an earlier one; remove it in the Road to Sixty app.`
- The app's remove confirmation, verbatim: `Removes [Name]'s journey from the backup. Journeys on your PCs stay. If you play [Name] again, its journey is backed up again from that PC.`
- App version 0.1.7, in both `apps/desktop/src-tauri/tauri.conf.json` and `apps/desktop/src-tauri/Cargo.toml`. Addon release 1.10.0.
- Test data is made up: GUIDs like `Player-1-0A`, names like Ann. Never a real saved file, name or GUID.
- Comments in plain words, explaining why; British spelling. Commit subjects `Area: what (#51)`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Each app's `AGENTS.md` is updated in the same commit as the change it describes.
- Rust: before committing, `. ~/.cargo/env && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings` from `apps/desktop`.
- Lua 5.1 for the server tests: `LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua`. Server tests need the containers `rts-server-postgres-1` and `rts-server-s3-1` (`docker compose up -d` in `apps/server`).

## Review Focus

1. A PC on addon 1.9.x after the server deploys: every head is layout 4, so it is told to update the addon and gets nothing. Expected and written in the rollout; the reviewer checks no path leaves it uploading into the wrong row (Task 3 test "an upload from an addon before stamps never joins a newer journey").
2. Two uploads with one new stamp queued against the unstamped row before the worker runs: both must end up in one new row, with no failed job (Task 3 test "two uploads of a namesake queued before the worker runs").
3. Removing a character while the worker holds its job, or claims it mid-delete: 409, never a half-deleted character or a job that fails twelve times (Task 5 test "removing a character while its merge runs answers 409").
4. A file shared by two characters (identical journeys under two names) must survive removing one of them (Task 5 test "removing a character keeps a file another character shares").
5. `UnitGUID` failing or giving a secret value at login: the file must be left exactly as it was (Task 6 test 12).

---

### Task 1: Merge.lua: layout 4, the stamp in the merge, `SameJourney`

**Files:**
- Modify: `apps/addon/RoadToSixty/Merge.lua` (header, `Merge.VERSION`, `RULES`, `Merge.Merge`, `Merge.Prepare`, new `Merge.SameJourney`)
- Modify: `apps/addon/RoadToSixty/Core.lua:52-62` (`DATA_VERSION` and its list)
- Modify: `apps/addon/tests/merge_test.lua`, `sync_test.lua`, `restore_test.lua`, `pure_test.lua`, `core_test.lua` (fixtures to layout 4)

**Interfaces:**
- Produces: `Merge.VERSION = 4`; `Merge.Merge(a, b)` returns `nil, "these are two different journeys"` when both have a `journeyId` and they differ, and keeps a lone `journeyId`; `Merge.SameJourney(head, upload) -> boolean` (true when `head` has no events, or both first events have the same time `e[1]` and kind `e[2]`); `Merge.Prepare` brings layout 3 up to 4.

- [ ] **Step 1: Move the fixtures to layout 4 and write the failing tests**

In `apps/addon/tests/merge_test.lua`, change the `Journey` helper's `version = 3` to `version = 4` and its comment to "A journey at layout 4". Change line 89's check to `m.version == 4` with message `"layout 4, and the roster copy to be rebuilt"`. Replace line 297's check with:

```lua
check(Merge.Prepare(Journey(), "pcz").version == 4, "layout 4 is left as it is")
check(Merge.Prepare(Journey({ version = 3 }), "pcz").version == 4, "layout 3 comes up to 4 as it is: it has no stamp yet")
```

Add before the `DATA_VERSION` check at the end:

```lua
-- The journey stamp (Core.lua): two different journeys never merge, and a
-- copy that has one keeps it whichever copy was seen last.
do
    local a = Journey({ journeyId = "Player-1-0A:0", events = { On(1000) } })
    local erased = Journey({ journeyId = "Player-1-0A:7000", events = { On(8000) } })
    local bare = Journey({ events = { On(2000) } })
    local out, why = Merge.Merge(a, erased)
    check(out == nil and why == "these are two different journeys", "two stamps that differ are refused: " .. tostring(why))
    check(Merge.Merge(a, bare).journeyId == "Player-1-0A:0", "a lone stamp is kept though the other copy was seen last")
    check(Merge.Merge(bare, a).journeyId == "Player-1-0A:0", "and either way round")
    check(Merge.Merge(a, a).journeyId == "Player-1-0A:0", "the same stamp stays")

    local SameJourney = Merge.SameJourney
    check(SameJourney(Journey(), bare), "a journey with no events yet is anyone's start")
    check(SameJourney(Journey({ events = { On(1000), On(3000) } }), Journey({ events = { On(1000), On(5000) } })),
        "two copies that begin with the same event are one journey")
    check(not SameJourney(Journey({ events = { On(1000) } }), Journey({ events = { On(9000) } })),
        "a namesake begins later")
    check(not SameJourney(Journey({ events = { On(1000) } }), Journey({ events = { { 1000, "die", 0, 0, 0 } } })),
        "the same second but another kind of event is another journey")
    check(not SameJourney(Journey({ events = { On(1000) } }), Journey()), "an upload with no events doesn't continue one that has some")
end
```

In `apps/addon/tests/sync_test.lua`: line 64 `local j = { version = 3 }` → `{ version = 4 }` and its comment "A journey at layout 4"; line 132 and line 185 `version = 3` → `version = 4`; in the "newer layout" check (`Journey({ version = 4 })`) → `Journey({ version = 5 })`. Leave line 211 (`Write({ version = 3, events = 5 })`): it is refused for its shape.

In `apps/addon/tests/restore_test.lua:21`, `apps/addon/tests/pure_test.lua:61` (both tables) and `apps/addon/tests/core_test.lua:100`: `version = 3` → `version = 4`. In `core_test.lua` line 44: `check(current == 4, "a new character is on layout 4, got " .. tostring(current))`; line 75: `check(ns.char.version == 4, "a layout 2 file is brought up to layout 4")`; line 100's check message stays.

- [ ] **Step 2: Run the addon tests to see them fail**

Run: `cd apps/addon && bun run test 2>&1 | tail -30`
Expected: FAIL. merge_test reports `attempt to call field 'SameJourney'` or the stamp checks failing; sync, restore, pure and core tests fail with "a newer layout than this merge knows" or "layout 4" checks.

- [ ] **Step 3: Implement in Merge.lua and Core.lua**

In `Merge.lua`'s header, change "Both copies are at layout 3 (Prepare brings a layout 2 upload up)" to "Both copies are at layout 4 (Prepare brings older uploads up)", and replace the line "- Both are copies of the same character. The data doesn't say whose it is, so the caller checks that: the server from the WTF path, the addon from the sync folder's character key." with:

```lua
-- - Both are copies of the same character: the caller checks the name (the
--   server from the upload's, the addon from the sync folder's key). Two
--   journeys of one name that are stamped differently (journeyId, Core.lua)
--   are refused here.
```

Then:

```lua
Merge.VERSION = 4   -- the layout it merges, DATA_VERSION in Core.lua
```

In `RULES`, add:

```lua
    journeyId = Join,   -- the stamp, kept from whichever copy has one (Merge refuses two that differ)
```

At the top of `Merge.Merge`, after the `Refused` check:

```lua
    if a.journeyId and b.journeyId and a.journeyId ~= b.journeyId then
        return nil, "these are two different journeys"
    end
```

In `Merge.Prepare`, after the `if version < 3 then ... end` block:

```lua
    -- Layout 4 only adds the stamp, which the login writes.
    if version < 4 then char.version = 4 end
```

Add after `Merge.Prepare`:

```lua
-- Whether upload continues head, a journey from before stamps, when upload
-- has a stamp: head has nothing yet, or both begin with the same event. A
-- namesake made later begins later. Both prepared and tidied first.
function Merge.SameJourney(head, upload)
    local h, u = (head.events or {})[1], (upload.events or {})[1]
    if not h then return true end
    return u ~= nil and h[1] == u[1] and h[2] == u[2]
end
```

In `Core.lua`, add to the layout list above `DATA_VERSION`:

```lua
--   4  journeyId, the journey's stamp: "<GUID>:<start>", start 0 for an
--      ordinary journey or the time of an Erase. Set at each login (see
--      PLAYER_LOGIN below) and by ns.ResetCharacter.
```

and change `local DATA_VERSION = 3` to `local DATA_VERSION = 4`.

- [ ] **Step 4: Run the addon tests to see them pass**

Run: `cd apps/addon && bun run test 2>&1 | tail -30`
Expected: every test file passes ("Merge tests passed.", "Sync tests passed.", and so on).

- [ ] **Step 5: Commit**

```bash
git add apps/addon/RoadToSixty/Merge.lua apps/addon/RoadToSixty/Core.lua apps/addon/tests
git commit -m "Merge: layout 4, two differently stamped journeys never merge, SameJourney (#51)"
```

---

### Task 2: Server: migration 0009 and the runner's `same` mode

**Files:**
- Modify: `apps/server/src/schema.ts` (`characters.journey`, the unique key, `versions.journey`)
- Create: `apps/server/drizzle/0009_journeys.sql` and its snapshot (generated)
- Modify: `apps/server/src/runner.lua` (`TidyUp` to file level, `same` mode)
- Modify: `apps/server/src/lua.ts` (new `runSame`)
- Modify: `apps/server/test/helpers.ts:48-51` (journeys at layout 4)
- Modify: `apps/server/test/lua.test.ts:22,41,77`, `apps/server/test/sync.test.ts:283`
- Create: `apps/server/test/journeys.test.ts`

**Interfaces:**
- Consumes: `Merge.SameJourney(head, upload)` and layout 4 from Task 1.
- Produces: `characters.journey: string | null`, unique (userId, game, realm, name, journey) NULLS NOT DISTINCT; `versions.journey: string | null`; `runSame(head: Uint8Array, upload: Uint8Array, limits?: Limits, runner?: string): Promise<boolean>` in `src/lua.ts` (`head` is stored Parse.Write text, `upload` a SavedVariables file).

- [ ] **Step 1: Write the failing tests**

In `apps/server/test/helpers.ts`, change the comment to "A journey at layout 4 with nothing in it but what is given." and `version: 3` to `version: 4`.

In `apps/server/test/lua.test.ts`: line 22 `layout: 3` → `layout: 4`; line 41 `journey({ version: 4 })` → `journey({ version: 5 })`; line 77 `expect(r.layout).toBe(3)` → `toBe(4)`. Add `runSame` to the import from `../src/lua`, and append:

```ts
test("same tells an upload that continues a journey from a namesake's", async () => {
  const head = text(journey({ events: session(1000) }));
  const stamp = (s: string, events: unknown[]) => savedFile(journey({ journeyId: s, events }));
  expect(await runSame(head, stamp("Player-1-0A:0", [...session(1000), ...session(5000)]))).toBe(true);
  expect(await runSame(head, stamp("Player-1-0B:0", session(9000)))).toBe(false);
  expect(await runSame(text(journey()), stamp("Player-1-0B:0", session(9000)))).toBe(true);
});
```

In `apps/server/test/sync.test.ts:283`: `expect(d!.dataLayout).toBe(3)` → `toBe(4)` (Ann's upload is now layout 4, the highest).

Create `apps/server/test/journeys.test.ts`:

```ts
// One journey per character (spec 2026-10-15, journeys): stamps, which row
// an upload goes to, current and earlier journeys, removing a character.
// GUIDs here are made up.
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { db } from "../src/db";
import { characters } from "../src/schema";
import { CHAR, addUser, reset } from "./helpers";

beforeEach(reset);
afterEach(() => mock.restore());

test("a name holds several journeys but only one from before stamps", async () => {
  const userId = await addUser("user-1");
  const row = (journey: string | null) => ({ userId, ...CHAR, journey });
  await db.insert(characters).values([row(null), row("Player-1-0A:0"), row("Player-1-0A:7000")]);
  await expect(db.insert(characters).values(row(null))).rejects.toThrow();
  await expect(db.insert(characters).values(row("Player-1-0A:0"))).rejects.toThrow();
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test test/lua.test.ts test/journeys.test.ts 2>&1 | tail -30`
Expected: FAIL: `runSame` is not exported, `journey` is not a column of characters.

- [ ] **Step 3: Change the schema and generate the migration**

In `apps/server/src/schema.ts`, in `characters`, add after `name`:

```ts
    // The journey's stamp from the addon (Core.lua, "<GUID>:<start>"); null
    // for a row made before addon 1.10.0. A name has a row per journey, and
    // its newest row is the current one.
    journey: text("journey"),
```

and change the table's third argument to:

```ts
  (t) => [unique().on(t.userId, t.game, t.realm, t.name, t.journey).nullsNotDistinct()],
```

In `versions`, add after `addonVersion`:

```ts
  // An upload's stamp, read from the file, so the worker can tell where it belongs.
  journey: text("journey"),
```

Run: `cd apps/server && bunx drizzle-kit generate --name journeys`
Expected: `drizzle/0009_journeys.sql` is written. Read it: it adds both `journey` columns, drops `characters_user_id_game_realm_name_unique` and adds a `UNIQUE NULLS NOT DISTINCT("user_id","game","realm","name","journey")` constraint. Nothing else.

- [ ] **Step 4: Add the `same` mode to runner.lua and `runSame` to lua.ts**

In `runner.lua`'s header usage, add:

```lua
--   lua5.1 runner.lua <lua dir> same <head> <upload> <max MB> <max seconds>
```

and after the `windows:` paragraph:

```lua
-- same: <head> is a stored journey from before stamps, <upload> a stamped
-- SavedVariables file; prints whether the upload continues it
-- (Merge.SameJourney), after both are prepared and tidied:
--   same yes|no
```

Change the argument parsing to:

```lua
local headPath
if mode == "windows" then
    oldPath, keptPath, maxMB, maxSeconds = args[3], args[4], args[5], args[6]
elseif mode == "same" then
    headPath, uploadPath, maxMB, maxSeconds = args[3], args[4], args[5], args[6]
else
    uploadPath, currentPath, outPath, pc, windowsPath, maxMB, maxSeconds = args[3], args[4], args[5], args[6], args[7], args[8], args[9]
end
```

Move `TidyUp` out of `Run` to file level, just after the loop that loads the addon's files (delete it from inside `Run`):

```lua
local function TidyUp(char)
    if not char.seeded then ns.Tidy.Runs(char) end
    ns.Tidy.Events(char, IsPlace)
    if not char.seeded then ns.Tidy.Guilds(char) end
end
```

Add before the final `pcall`:

```lua
local function Same()
    local read, head = Try(ns.Parse.Read, Read(headPath))
    if not read then Fault("the stored journey can't be read: " .. tostring(head)) end
    local bad
    head, bad = ns.Merge.Prepare(head, "server")
    if not head then Fault("the stored journey can't be used: " .. tostring(bad)) end
    local upload = ns.Parse.File(Read(uploadPath)).RoadToSixtyCharDB
    if type(upload) ~= "table" then error("the upload holds no journey", 0) end
    upload, bad = ns.Merge.Prepare(upload, "server")
    if not upload then error(bad, 0) end
    TidyUp(head)
    TidyUp(upload)
    return "same " .. (ns.Merge.SameJourney(head, upload) and "yes" or "no")
end
```

and change the call to:

```lua
local ok, result = pcall(({ windows = Windows, same = Same })[mode] or Run)
```

In `apps/server/src/lua.ts`, append:

```ts
// Whether a stamped upload continues head, a stored journey from before
// stamps (Merge.SameJourney). An upload the merge would refuse counts as
// the same, so the merge refuses it with its own reason.
export async function runSame(head: Uint8Array, upload: Uint8Array, limits: Limits = LIMITS, runner = `${import.meta.dir}/runner.lua`): Promise<boolean> {
  const dir = await mkdtemp(join(tmpdir(), "rts-same-"));
  try {
    await Bun.write(join(dir, "head.lua"), head);
    await Bun.write(join(dir, "upload.lua"), upload);
    const { stdout, stderr, exitCode } = await run(["same", join(dir, "head.lua"), join(dir, "upload.lua"), String(limits.mb), String(limits.seconds)], limits, runner);
    const [word, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word === "same") return rest[0] === "yes";
    if (word === "rejected") return true;
    throw new Error(`couldn't tell whose journey an upload is: ${(word === "failed" ? rest.join(" ") : stderr.trim().split("\n")[0]) || `exit code ${exitCode}`}`);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
```

- [ ] **Step 5: Run the whole server suite**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test 2>&1 | tail -30` and `bun run typecheck`
Expected: all pass, typecheck clean. If any other test names layout 3 for a merged head or a PC's `dataLayout`, it moves to 4 the same way as line 283.

- [ ] **Step 6: Commit**

```bash
git add apps/server/src/schema.ts apps/server/drizzle apps/server/src/runner.lua apps/server/src/lua.ts apps/server/test
git commit -m "Server: a row per journey, the upload's stamp, and the runner's same check (#51)"
```

---

### Task 3: Server: the upload's row and the worker's adoption

**Files:**
- Modify: `apps/server/src/sync.ts` (new `stampOf`, new `rowFor`, the upload route)
- Modify: `apps/server/src/worker.ts` (new `journeyRow`, adoption at the start of `runJob`, the row takes the stamp at commit)
- Test: `apps/server/test/journeys.test.ts`

**Interfaces:**
- Consumes: `runSame` and the `journey` columns from Task 2.
- Produces: `stampOf(raw: Uint8Array): string | null | undefined` exported from `src/sync.ts` (null: no stamp; undefined: a malformed one); `journeyRow(userId, game, realm, name, journey: string | null): Promise<Character>` exported from `src/worker.ts` (select-or-insert, no cap).

- [ ] **Step 1: Write the failing tests**

Change the imports at the top of `apps/server/test/journeys.test.ts` to:

```ts
import type { CharacterInfo } from "@road-to-sixty/api";
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { characters, jobs } from "../src/schema";
import { unpack } from "../src/storage";
import { stampOf } from "../src/sync";
import { CHAR, addUser, call, check, journey, newDevice, reset, savedFile, session, sessions, stored, upload, workAll } from "./helpers";
```

Add helpers below `afterEach`:

```ts
const A = "Player-1-0A";
const B = "Player-1-0B";
const stamped = (stamp: string, events: unknown[] = session(1000)) => savedFile(journey({ journeyId: stamp, events }));
const rows = () => db.select().from(characters).orderBy(characters.id);
const download = async (token: string, id: number) =>
  unpack(new Uint8Array(await (await call(token, `/v1/versions/${id}`)).arrayBuffer()));
```

Then the tests:

```ts
test("the stamp is read from the uploaded file, and a malformed one is refused", async () => {
  expect(stampOf(stamped(`${A}:0`))).toBe(`${A}:0`);
  expect(stampOf(savedFile(journey()))).toBeNull();
  expect(stampOf(stamped(`Player-1-${"0".repeat(60)}:0`))).toBeUndefined();
  expect(stampOf(stamped("no colon"))).toBeUndefined();
  const { token } = await newDevice("user-1", "Desk");
  expect((await upload(token, stamped("no colon"))).status).toBe(400);
});

test("a stamped upload adopts the same journey from before stamps", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${A}:0`, [...session(1000), ...session(5000)]));
  await workAll();
  const [only, ...more] = await rows();
  expect(more).toEqual([]);
  expect(only!.journey).toBe(`${A}:0`);
  const [entry] = (await check(token)).characters;
  expect(sessions(await download(token, entry!.version!))).toBe(2);
});

test("a namesake remade before its old journey had a stamp gets a journey of its own, which becomes current", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${B}:0`, session(9000)));
  await workAll();
  const [old, made] = await rows();
  expect(old!.journey).toBeNull();
  expect(made!.journey).toBe(`${B}:0`);
  expect(sessions(await download(token, old!.headVersionId!))).toBe(1);
  expect(sessions(await download(token, made!.headVersionId!))).toBe(1);
});

test("two uploads of a namesake queued before the worker runs both go to its new journey", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(desk.token, stamped(`${B}:0`, session(9000)));
  await upload(laptop.token, stamped(`${B}:0`, [...session(9000), ...session(9500)]));
  await workAll();
  const all = await rows();
  expect(all).toHaveLength(2);
  expect(sessions(await download(desk.token, all[1]!.headVersionId!))).toBe(2);
  expect(await db.select().from(jobs).where(eq(jobs.state, "failed"))).toEqual([]);
});

test("an erase starts a new journey; a PC still on the old one keeps updating that one", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, stamped(`${A}:0`, session(1000)));
  await workAll();
  await upload(desk.token, stamped(`${A}:7000`, session(8000)));
  await workAll();
  await upload(laptop.token, stamped(`${A}:0`, [...session(1000), ...session(3000)]));
  await workAll();
  const [old, erased] = await rows();
  expect(old!.journey).toBe(`${A}:0`);
  expect(erased!.journey).toBe(`${A}:7000`);
  expect(sessions(await download(desk.token, old!.headVersionId!))).toBe(2);
  expect(sessions(await download(desk.token, erased!.headVersionId!))).toBe(1);
});

test("an upload from an addon before stamps never joins a newer journey", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, stamped(`${A}:0`, session(1000)));
  await workAll();
  await upload(token, stamped(`${A}:7000`, session(8000)));
  await workAll();
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(2000)] })));
  await workAll();
  const [old, erased] = await rows();
  expect(sessions(await download(token, old!.headVersionId!))).toBe(2);
  expect(sessions(await download(token, erased!.headVersionId!))).toBe(1);
});

test("a new journey of a name counts toward the 100", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await db
    .insert(characters)
    .values(Array.from({ length: 99 }, (_, i) => ({ userId: device.userId, game: CHAR.game, realm: CHAR.realm, name: `Alt${i}` })));
  expect((await upload(token, stamped(`${A}:0`))).status).toBe(200);
  const refused = await upload(token, stamped(`${A}:7000`, session(8000)));
  expect(refused.status).toBe(422);
  expect(await refused.text()).toBe("This account has reached 100 characters");
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test test/journeys.test.ts 2>&1 | tail -30`
Expected: FAIL: `stampOf` is not exported; the adoption and namesake tests find one row with no stamp.

- [ ] **Step 3: Add `journeyRow` and the adoption to worker.ts**

Add `runSame` to the import from `./lua`, and below `SERVER_FAILED`:

```ts
type Character = typeof characters.$inferSelect;

// The row of this name for this journey, made if there is none. Two
// uploads may race to make it, hence the insert that does nothing on a
// clash and the read after.
export async function journeyRow(userId: string, game: string, realm: string, name: string, journey: string | null): Promise<Character> {
  await db.insert(characters).values({ userId, game, realm, name, journey }).onConflictDoNothing();
  const [row] = await db
    .select()
    .from(characters)
    .where(
      and(
        eq(characters.userId, userId),
        eq(characters.game, game),
        eq(characters.realm, realm),
        eq(characters.name, name),
        sql`${characters.journey} IS NOT DISTINCT FROM ${journey}::text`,
      ),
    );
  return row!;
}
```

In `runJob`, move the `head` lookup up to just after the `if (!upload || !character)` line, and add after it:

```ts
  // A stamped upload queued against a journey from before stamps joins it
  // only if it continues it; otherwise (a namesake remade before the old
  // journey had a stamp) it moves to its journey's own row and runs again
  // there. A second upload of that namesake finds the row the first made.
  // ponytail: that row skips the 100-character cap; at most one per name
  // from before stamps.
  if (upload.journey && character.journey === null) {
    const [own] = await db
      .select()
      .from(characters)
      .where(
        and(
          eq(characters.userId, character.userId),
          eq(characters.game, character.game),
          eq(characters.realm, character.realm),
          eq(characters.name, character.name),
          eq(characters.journey, upload.journey),
        ),
      );
    const apart =
      own !== undefined ||
      (head !== undefined && !(await runSame(await get(character.userId, head.fingerprint), await get(character.userId, upload.fingerprint))));
    if (apart) {
      const row = own ?? (await journeyRow(character.userId, character.game, character.realm, character.name, upload.journey));
      await db.transaction(async (tx) => {
        await tx.update(versions).set({ characterId: row.id }).where(eq(versions.id, upload.id));
        await tx.update(jobs).set({ characterId: row.id, state: "queued", runAfter: new Date() }).where(eq(jobs.id, job.id));
      });
      return;
    }
  }
```

In the commit transaction's `update(characters).set({...})`, add after `headVersionId: merged!.id,`:

```ts
          // A journey from before stamps takes its first stamped upload's.
          ...(character.journey === null && upload.journey ? { journey: upload.journey } : {}),
```

- [ ] **Step 4: Add `stampOf` and `rowFor`, and use them in the upload route**

In `sync.ts`, add `journeyRow` to the import from `./worker`, and below `MAX_CHARACTERS`:

```ts
const STAMP = '["journeyId"] = "';

// The journey's stamp the addon saved (Core.lua): null when the file has
// none (addon before 1.10.0), undefined when it isn't one.
export function stampOf(raw: Uint8Array): string | null | undefined {
  const text = Buffer.from(raw.buffer, raw.byteOffset, raw.length);
  const at = text.indexOf(STAMP);
  if (at < 0) return null;
  const from = at + STAMP.length;
  const to = text.indexOf('"', from);
  if (to < 0 || to - from > MAX_FIELD) return undefined;
  const stamp = text.toString("utf8", from, to);
  return /^[A-Za-z0-9-]+:\d+$/.test(stamp) ? stamp : undefined;
}

type Character = typeof characters.$inferSelect;

// The row an upload goes to (spec 2026-10-15 journeys, "Characters"): its
// journey's own row; else the name's row from before stamps, for the
// worker to check; else a new one, within the cap. An upload without a
// stamp goes to the row from before stamps or the oldest, never a newer
// journey. Null when the cap is reached.
async function rowFor(userId: string, game: string, realm: string, name: string, stamp: string | null): Promise<Character | null> {
  const rows = await db
    .select()
    .from(characters)
    .where(and(eq(characters.userId, userId), eq(characters.game, game), eq(characters.realm, realm), eq(characters.name, name)))
    .orderBy(characters.id);
  const bare = rows.find((r) => r.journey === null);
  const found = stamp ? (rows.find((r) => r.journey === stamp) ?? bare) : (bare ?? rows[0]);
  if (found) return found;
  const [held] = await db.select({ n: count() }).from(characters).where(eq(characters.userId, userId));
  if (held!.n >= MAX_CHARACTERS) return null;
  return journeyRow(userId, game, realm, name, stamp);
}
```

In the upload route, after the bytecode check (`if (raw[0] === 0x1b) ...`), replace everything from `const userId = device!.userId;` down to and including the `const [character] = await db.select()...` statement with:

```ts
      const stamp = stampOf(raw);
      if (stamp === undefined) {
        set.status = 400;
        return { error: "the journey's stamp isn't one the addon writes" };
      }
      const userId = device!.userId;
      const character = await rowFor(userId, game, realm, name, stamp);
      // Plain text: the app shows the body as the reason on the character's row.
      if (!character) return new Response(`This account has reached ${MAX_CHARACTERS} characters`, { status: 422 });
```

Replace every `character!.id` in the rest of the route with `character.id`, and add `journey: stamp,` to the upload version's `values({...})` after `addonVersion`.

- [ ] **Step 5: Run the whole server suite and the typecheck**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test 2>&1 | tail -30 && bun run typecheck`
Expected: all pass, typecheck clean.

- [ ] **Step 6: Commit**

```bash
git add apps/server/src/sync.ts apps/server/src/worker.ts apps/server/test/journeys.test.ts
git commit -m "Server: uploads go to their journey's row, and a namesake gets one of its own (#51)"
```

---

### Task 4: Server: current journeys in check, `earlier` in the list, the export

**Files:**
- Modify: `packages/api/src/index.ts` (`CharacterInfo.earlier`, the `DELETE` route's comment)
- Modify: `apps/server/src/sync.ts` (new `currentIds`, `/check`)
- Modify: `apps/server/src/account.ts` (`/characters`, `/export`)
- Test: `apps/server/test/journeys.test.ts`

**Interfaces:**
- Consumes: the rows from Task 3.
- Produces: `currentIds(rows: { id: number; game: string; realm: string; name: string }[]): Set<number>` exported from `src/sync.ts`; `CharacterInfo.earlier: boolean`; export names `<game>/<realm>/<name> (earlier <id>).lua` for earlier journeys.

- [ ] **Step 1: Write the failing tests**

Add `mkdtemp, rm` from `node:fs/promises`, `tmpdir` from `node:os` and `join` from `node:path` to the imports of `journeys.test.ts`, and append:

```ts
test("check offers only a name's current journey, and the list marks the earlier one", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${B}:0`, session(9000)));
  await workAll();
  const [old, made] = await rows();
  expect((await check(token)).characters.map((c) => c.version)).toEqual([made!.headVersionId]);
  const list = (await (await call(token, "/v1/characters")).json()) as CharacterInfo[];
  expect(list.map((c) => [c.id, c.earlier])).toEqual([
    [old!.id, true],
    [made!.id, false],
  ]);
});

test("the export names an earlier journey apart from the current one", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${B}:0`, session(9000)));
  await workAll();
  const [old] = await rows();
  const dir = await mkdtemp(join(tmpdir(), "rts-export-"));
  try {
    const path = join(dir, "export.zip");
    await Bun.write(path, await (await call(token, "/v1/export")).arrayBuffer());
    const names = Bun.spawnSync(["python3", "-I", "-c", "import sys, zipfile; print('\\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))", path]);
    expect(names.stdout.toString().trim().split("\n").sort()).toEqual([
      `_classic_beta_/Test Realm/Ann (earlier ${old!.id}).lua`,
      "_classic_beta_/Test Realm/Ann.lua",
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test test/journeys.test.ts 2>&1 | tail -20`
Expected: FAIL: check lists two versions; `earlier` is undefined; the zip has one `Ann.lua` twice.

- [ ] **Step 3: Implement**

In `packages/api/src/index.ts`, change the `/v1/characters` comment to "GET /v1/characters: each character with a merged journey, earlier journeys of a name included." and add to `CharacterInfo` after `syncedFrom`:

```ts
  // Not its name's current journey: an Erase, or a character deleted in
  // game and made again with the same name, started a newer one. It can be
  // removed or exported, not made current again.
  earlier: boolean;
```

Below `RestoreResponse`, add:

```ts
// DELETE /v1/characters/:id removes one journey from the backup: { ok: true },
// 404 if it isn't this player's, 409 while its latest upload is being merged.
```

In `sync.ts`, add above the `sync` routes:

```ts
// The id of each name's current journey: its newest row (spec 2026-10-15
// journeys). Older rows are earlier journeys.
export function currentIds(rows: { id: number; game: string; realm: string; name: string }[]): Set<number> {
  const newest = new Map<string, number>();
  for (const r of rows) {
    const key = JSON.stringify([r.game, r.realm, r.name]);
    newest.set(key, Math.max(newest.get(key) ?? 0, r.id));
  }
  return new Set(newest.values());
}
```

In `/check`, after `const rows = ...`, add `const current = currentIds(rows.map((r) => r.c));` and change the filter to:

```ts
        // Only a name's current journey, so a PC is never handed an earlier
        // one. One with nothing merged yet is listed only to say why it was refused.
        .filter(({ c, head }) => current.has(c.id) && (head !== null || newest.get(c.id)?.status === "rejected"))
```

In `account.ts`, import `currentIds` from `./sync`, and add above `export const account`:

```ts
// Which of the player's rows are current, counting rows with nothing merged yet.
async function current(userId: string): Promise<Set<number>> {
  return currentIds(
    await db
      .select({ id: characters.id, game: characters.game, realm: characters.realm, name: characters.name })
      .from(characters)
      .where(eq(characters.userId, userId)),
  );
}
```

In `/characters`, add `const now = await current(device!.userId);` after `from`, and `earlier: !now.has(c.id),` after `syncedFrom`. In `/export`, add `const now = await current(device!.userId);` after `rows`, and change the file name to:

```ts
        // An earlier journey of a name sits beside the current one.
        const file = now.has(c.id) ? safe(c.name) : `${safe(c.name)} (earlier ${c.id})`;
        files.push({ name: `${safe(c.game)}/${safe(c.realm)}/${file}.lua`, data: new Uint8Array(data) });
```

- [ ] **Step 4: Run the server suite and every typecheck**

Add `earlier: false` to the `ann` fixture in `apps/desktop/src/format.test.ts`, since `CharacterInfo` now requires it.

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test 2>&1 | tail -20 && cd ../.. && bun run typecheck`
Expected: all pass, the desktop's typecheck included.

- [ ] **Step 5: Commit**

```bash
git add packages/api/src/index.ts apps/server/src/sync.ts apps/server/src/account.ts apps/server/test/journeys.test.ts apps/desktop/src/format.test.ts
git commit -m "Server: check offers a name's current journey; earlier ones are listed and exported apart (#51)"
```

---

### Task 5: Server: `DELETE /v1/characters/:id`

**Files:**
- Modify: `apps/server/src/account.ts` (new route)
- Modify: `apps/server/AGENTS.md`
- Test: `apps/server/test/journeys.test.ts`

**Interfaces:**
- Consumes: `own(device, id)` in `account.ts`; `remove(userId, fp)` from `src/storage.ts`.
- Produces: `DELETE /v1/characters/:id` → `{ ok: true }`, 404 `{ error: "no such character" }`, 409 `{ error: "Its latest upload is being merged; try again in a minute" }`.

- [ ] **Step 1: Write the failing tests**

Add `versions` to the schema import of `journeys.test.ts`, and append:

```ts
const remove = (token: string, id: number) => call(token, `/v1/characters/${id}`, { method: "DELETE" });

test("removing a character takes its rows and files, and frees its place", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await rows();
  const files = (await db.select().from(versions).where(eq(versions.characterId, c!.id))).map((v) => v.fingerprint);
  expect((await remove(token, c!.id)).status).toBe(200);
  expect(await rows()).toEqual([]);
  expect(await db.select().from(versions)).toEqual([]);
  for (const fp of files) expect(await stored("user-1", fp)).toBe(false);
  expect((await check(token)).characters).toEqual([]);
});

test("removing a character keeps a file another character shares", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const file = savedFile(journey({ events: session(1000) }));
  await upload(token, file);
  await upload(token, file, { name: "Bob" });
  await workAll();
  const [ann, bob] = await rows();
  expect((await remove(token, ann!.id)).status).toBe(200);
  expect(sessions(await download(token, bob!.headVersionId!))).toBe(1);
});

test("removing another player's character, or one that isn't there, is not found", async () => {
  const mine = await newDevice("user-1", "Desk");
  const theirs = await newDevice("user-2", "Elsewhere");
  await upload(theirs.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await rows();
  expect((await remove(mine.token, c!.id)).status).toBe(404);
  expect((await remove(mine.token, 999)).status).toBe(404);
  expect(await rows()).toHaveLength(1);
});

test("removing a character while its merge runs answers 409 and keeps it", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await db.update(jobs).set({ state: "running", claimedAt: new Date() });
  const [c] = await rows();
  const r = await remove(token, c!.id);
  expect(r.status).toBe(409);
  expect(((await r.json()) as { error: string }).error).toBe("Its latest upload is being merged; try again in a minute");
  expect(await rows()).toHaveLength(1);
});

test("a removed character's place under the 100 frees at once", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await db
    .insert(characters)
    .values(Array.from({ length: 100 }, (_, i) => ({ userId: device.userId, game: CHAR.game, realm: CHAR.realm, name: `Alt${i}` })));
  expect((await upload(token, savedFile(journey({ events: session(1000) })))).status).toBe(422);
  const [first] = await rows();
  expect((await remove(token, first!.id)).status).toBe(200);
  expect((await upload(token, savedFile(journey({ events: session(1000) })))).status).toBe(200);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test test/journeys.test.ts 2>&1 | tail -20`
Expected: FAIL: the DELETE answers 404 (no such route) where 200 and 409 are expected.

- [ ] **Step 3: Implement the route**

In `account.ts`, add `or` to the `drizzle-orm` import and `remove` to the `./storage` import. Add the route after `.post("/characters/:id/restore", ...)`:

```ts
  // Spec 2026-10-15 journeys, "Removing a character". Its files go after its
  // rows, each only when no other version of the account has it.
  // ponytail: an upload storing the same file for another character at
  // that moment can lose it, as with the clean-up; its merge fails and the
  // app sends it again.
  .delete("/characters/:id", async ({ device, params, set }) => {
    const c = await own(device!, params.id);
    if (!c) {
      set.status = 404;
      return { error: "no such character" };
    }
    const files = await db.transaction(async (tx) => {
      // Locked, so the worker's claim skips them; a job it already took
      // shows as running, and its commit would meet a deleted row.
      const held = await tx.select({ state: jobs.state }).from(jobs).where(eq(jobs.characterId, c.id)).for("update");
      if (held.some((j) => j.state === "running")) return null;
      const theirs = tx.select({ id: versions.id }).from(versions).where(eq(versions.characterId, c.id));
      const fps = await tx.selectDistinct({ fp: versions.fingerprint }).from(versions).where(eq(versions.characterId, c.id));
      await tx.delete(jobs).where(eq(jobs.characterId, c.id));
      await tx.delete(versionParents).where(or(inArray(versionParents.versionId, theirs), inArray(versionParents.parentId, theirs)));
      await tx.delete(versions).where(eq(versions.characterId, c.id));
      await tx.delete(characters).where(eq(characters.id, c.id));
      return fps.map((f) => f.fp);
    });
    if (files === null) {
      set.status = 409;
      return { error: "Its latest upload is being merged; try again in a minute" };
    }
    for (const fp of files) {
      const [shared] = await db
        .select({ id: versions.id })
        .from(versions)
        .innerJoin(characters, eq(characters.id, versions.characterId))
        .where(and(eq(characters.userId, c.userId), eq(versions.fingerprint, fp)))
        .limit(1);
      if (!shared) await remove(c.userId, fp);
    }
    return { ok: true };
  })
```

- [ ] **Step 4: Run the server suite**

Run: `cd apps/server && LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun test 2>&1 | tail -20 && bun run typecheck`
Expected: all pass.

- [ ] **Step 5: Update AGENTS.md, commit, and note it on #51**

In `apps/server/AGENTS.md`: in Layout, change the `src/account.ts` sentence's list to "(characters, history, restore, remove one character, PCs, export, delete everything)". Add to "Rules that bite":

```markdown
- A name has a row per journey (spec 2026-10-15, journeys): the addon's
  stamp, `journeyId`, is read from each upload (`stampOf`) and kept on the
  row and the upload. The newest row of a name is its current journey;
  check offers only that, so a PC is never handed an earlier one. A stamped
  upload queued against a row from before stamps joins it only when
  `runner.lua`'s `same` mode says it continues it; otherwise the worker
  moves it to its own row. An upload without a stamp never goes to a newer
  journey than the oldest.
- Removing a character locks its jobs and answers 409 while one runs;
  its files go only when no other version of the account shares them.
```

```bash
git add apps/server/src/account.ts apps/server/test/journeys.test.ts apps/server/AGENTS.md
git commit -m "Server: remove one character from the backup (#51)"
gh issue comment 51 --body "Server side done on branch \`journeys\`: a row per journey (migration 0009), the stamp read from each upload, adoption checked with the addon's own \`Merge.SameJourney\`, check offers only current journeys, \`earlier\` in the list, earlier journeys exported apart, and \`DELETE /v1/characters/:id\`. Not deployed yet. It must go out the same day as addon 1.10.0: from then the server merges at layout 4, so PCs on 1.9.x are told to update the addon."
```

---

### Task 6: Addon: the stamp at login and at Erase

**Files:**
- Modify: `apps/addon/RoadToSixty/Core.lua` (header, new `PlayerGUID`, `PLAYER_LOGIN`, `ns.ResetCharacter`)
- Modify: `apps/addon/RoadToSixty/Options.lua:98-100` (popup text)
- Test: `apps/addon/tests/core_test.lua`

**Interfaces:**
- Consumes: layout 4 from Task 1.
- Produces: `ns.char.journeyId` set at `PLAYER_LOGIN` before Sync.lua's handler; `ns.ResetCharacter()` writes `<GUID>:<ns.Now()>`.

- [ ] **Step 1: Write the failing tests**

In `apps/addon/tests/core_test.lua`, add above `local function Load`:

```lua
local guid = "Player-1-0A"
UnitGUID = function() return guid end
issecretvalue = function(v) return v == "secret" end
```

and before the final `if failures == 0`:

```lua
-- 9. Login stamps a file from before stamps as this character's.
ns = Load({ version = 3, events = { { 500, "on" } } }, db)
script(nil, "PLAYER_LOGIN")
check(ns.char.journeyId == "Player-1-0A:0", "a file without a stamp becomes this character's: " .. tostring(ns.char.journeyId))
check(#ns.char.events == 1, "and keeps its journey")

-- 10. This character's own stamp is kept, an erased one too.
ns = Load({ version = 4, journeyId = "Player-1-0A:3000", events = { { 500, "on" } } }, db)
script(nil, "PLAYER_LOGIN")
check(ns.char.journeyId == "Player-1-0A:3000" and #ns.char.events == 1, "the character's own stamp stays")

-- 11. Another GUID's file belongs to a deleted namesake: a fresh start.
ns = Load({ version = 4, journeyId = "Player-1-0B:0", events = { { 500, "on" } }, totals = { kills = 9 } }, db)
script(nil, "PLAYER_LOGIN")
check(ns.char.journeyId == "Player-1-0A:0", "a namesake's file starts again for this character: " .. tostring(ns.char.journeyId))
check(#ns.char.events == 0 and ns.char.totals.kills == 0 and ns.char.version == 4, "with nothing of the old journey")
check(ns.char.addon == "9.9.9", "and the addon version kept")

-- 12. A GUID the client won't give leaves the file as it is.
for _, broken in ipairs({ function() error("blocked") end, function() return "secret" end, function() return nil end }) do
    UnitGUID = broken
    ns = Load({ version = 4, journeyId = "Player-1-0B:0", events = { { 500, "on" } } }, db)
    script(nil, "PLAYER_LOGIN")
    check(ns.char.journeyId == "Player-1-0B:0" and #ns.char.events == 1, "an unreadable GUID changes nothing")
end
UnitGUID = function() return guid end

-- 13. Erase keeps the GUID with a later start, read again or from the old stamp.
local function Erase(char)
    ns = Load(char, db)
    ns.Recorder, ns.Journal, ns.Roster = { Reset = function() end }, { Reset = function() end }, { Rebuild = function() end }
    ns.ResetCharacter()
    return ns.char
end
local erased = Erase({ version = 4, journeyId = "Player-1-0A:0", events = { { 500, "on" } } })
check(erased.journeyId == "Player-1-0A:2000" and #erased.events == 0, "Erase gives the same GUID, starting now: " .. tostring(erased.journeyId))
UnitGUID = function() error("blocked") end
erased = Erase({ version = 4, journeyId = "Player-1-0A:0" })
check(erased.journeyId == "Player-1-0A:2000", "Erase without a GUID read keeps the old stamp's GUID")
UnitGUID = function() return guid end
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/addon && luajit tests/core_test.lua`
Expected: FAIL on checks 9, 11 and 13 (no stamp is written; ResetCharacter wipes it).

- [ ] **Step 3: Implement in Core.lua and Options.lua**

In Core.lua's header list of `RoadToSixtyCharDB` fields, add after `rosterKey`:

```lua
--   journeyId  the journey's stamp, "<GUID>:<start>" (see DATA_VERSION 4),
--              so a namesake made after a character is deleted, or an
--              erased journey, is never merged with the old one (#51)
```

Above the `PLAYER_LOGIN` handler:

```lua
-- The logged-in character's GUID, or nil when the client gives none or a
-- secret value, which would error when compared.
local function PlayerGUID()
    local ok, guid = pcall(function()
        local g = UnitGUID("player")
        if issecretvalue and issecretvalue(g) then return nil end
        return type(g) == "string" and g:match("^[%w%-]+$") and g or nil
    end)
    return ok and guid or nil
end

local function StampGUID(char)
    return type(char.journeyId) == "string" and char.journeyId:match("^([%w%-]+):%d+$") or nil
end
```

Replace the `PLAYER_LOGIN` handler with:

```lua
-- Stamps the journey as this character's, first at login so Sync.lua sees
-- it. A file stamped with another GUID was a deleted namesake's (WoW keeps
-- it under the same name): this character starts fresh, as a new one would,
-- before the recorder, journal and roster read it. The old journey is on
-- the server if it was ever synced.
ns.On("PLAYER_LOGIN", function()
    local guid = PlayerGUID()
    if guid then
        local char, stamped = ns.char, StampGUID(ns.char)
        if stamped and stamped ~= guid then
            local addon = char.addon
            wipe(char)
            ApplyDefaults(char, charDefaults)
            char.addon, stamped = addon, nil
        end
        if not stamped then char.journeyId = guid .. ":0" end
    end
    if ns.db.greet then
        Print("Recording your journey. Type /rts for commands.")
    end
end)
```

Replace `ns.ResetCharacter` with:

```lua
-- Empties this character's journey in place, keeping the same table, and
-- brings the recorder and roster in line without needing a reload. The new
-- stamp starts now, so the sync keeps the erased journey apart instead of
-- merging it back.
function ns.ResetCharacter()
    local guid = PlayerGUID() or StampGUID(ns.char)
    wipe(ns.char)
    ApplyDefaults(ns.char, charDefaults)
    if guid then ns.char.journeyId = guid .. ":" .. ns.Now() end
    ns.Recorder:Reset()
    ns.Journal:Reset()
    ns.Roster:Rebuild()
end
```

In `Options.lua`, change the popup's `text` to:

```lua
    text = "Erase the whole journey of this character?\n\nIts path, history, level ups and gear are deleted for good. The interface reloads afterwards.\n\nYour backup keeps the old journey as an earlier one; remove it in the Road to Sixty app.",
```

- [ ] **Step 4: Run every addon test**

Run: `cd apps/addon && bun run test 2>&1 | tail -30`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add apps/addon/RoadToSixty/Core.lua apps/addon/RoadToSixty/Options.lua apps/addon/tests/core_test.lua
git commit -m "Core: stamp each journey with the character's GUID, fresh for a namesake, new at Erase (#51)"
```

---

### Task 7: Addon: `Sync.Apply` reads the stamp; changelog

**Files:**
- Modify: `apps/addon/RoadToSixty/Sync.lua` (`Sync.Apply`)
- Modify: `apps/addon/CHANGELOG.md` (new `## 1.10.0`)
- Modify: `apps/addon/AGENTS.md` (one rule on stamps)
- Test: `apps/addon/tests/sync_test.lua`

**Interfaces:**
- Consumes: `journeyId` from Task 6, `Merge.Merge`'s refusal from Task 1.
- Produces: `Sync.Apply(char, entry)` returns `"replaced", journey` for the same GUID with a later start, `"same"` for another GUID or an earlier start.

- [ ] **Step 1: Write the failing tests**

In `apps/addon/tests/sync_test.lua`, add after section 3 ("Already brought in"):

```lua
-- 3b. The journey stamp (Core.lua): only this journey merges; an erase on
-- another PC replaces; another GUID's, or the journey before an erase, is
-- left alone.
do
    local mine = "Player-1-0A:0"
    local function Entry(stamp, events)
        return { version = 8, journey = Write(Journey({ journeyId = stamp, events = events or Session(5000) })) }
    end
    local w, o = Sync.Apply(Journey({ journeyId = mine, events = Session(1000) }), Entry(mine))
    check(w == "merged" and #o.events == 6 and o.journeyId == mine, "the same journey merges: " .. tostring(w))
    w, o = Sync.Apply(Journey({ journeyId = mine, events = Session(1000) }), Entry("Player-1-0A:7000", Session(8000)))
    check(w == "replaced" and Same(o.events, Session(8000)) and o.journeyId == "Player-1-0A:7000",
        "an erase on another PC replaces this copy: " .. tostring(w))
    check(Sync.Apply(Journey({ journeyId = mine, events = Session(1000) }), Entry("Player-1-0B:0")) == "same",
        "another character's journey is left alone")
    check(Sync.Apply(Journey({ journeyId = "Player-1-0A:7000", events = Session(8000) }), Entry(mine)) == "same",
        "the journey from before this PC's erase is left alone")
    w, o = Sync.Apply(Journey({ journeyId = mine, events = Session(1000) }),
        { version = 8, journey = Write(Journey({ events = Session(5000) })) })
    check(w == "merged" and o.journeyId == mine, "a server copy from before stamps merges and takes this stamp: " .. tostring(w))
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/addon && luajit tests/sync_test.lua`
Expected: FAIL: the erase comes back "problem" ("these are two different journeys"), and the other GUID's and earlier start's come back "problem" instead of "same".

- [ ] **Step 3: Implement**

In `Sync.lua`, add above `Sync.Apply`:

```lua
-- A journey's stamp (Core.lua) as its GUID and start, or nil for none.
local function Stamp(char)
    local guid, start = tostring(char.journeyId or ""):match("^(.+):(%d+)$")
    return guid, tonumber(start)
end
```

Extend `Sync.Apply`'s comment with: "An entry for another journey of this name (another GUID's, or the one before an erase here) is \"same\": nothing to bring in." In the function, after the `Merge.Prepare` lines (`if not journey then return "problem", why end`) and before `TidyUp(char)`:

```lua
    -- Both stamped and different: erased on another PC (same GUID, later
    -- start), which replaces this copy; anything else isn't this journey.
    -- No stamp on either side merges as before stamps.
    local mine, mineStart = Stamp(char)
    local theirs, theirStart = Stamp(journey)
    local erased = mine and theirs and (mine ~= theirs or mineStart ~= theirStart)
    if erased and (mine ~= theirs or theirStart < mineStart) then return "same" end
```

and change the restore condition to:

```lua
    if erased or (restore and (char.syncedVersion or 0) < restore) or (not restore and entry.replace) then
```

In `apps/addon/CHANGELOG.md`, add above `## 1.9.0`:

```markdown
## 1.10.0

### New
- Deleted a character and made a new one with the same name? The new
  character now starts a journey of its own, instead of carrying on the
  old one's.

### Fixed
- Erasing a character's journey now sticks with the Road to Sixty app:
  before, the app brought the old journey back at the next login. The
  backup keeps the old journey as an earlier one, which you can remove in
  the app.
```

In `apps/addon/AGENTS.md`, add after the `class` rule:

```markdown
- Each character file carries `journeyId`, the journey's stamp
  (`<GUID>:<start>`, Core.lua). The login writes it, a GUID that differs
  starts the file fresh (a deleted namesake's), Erase gives a new start,
  and `Sync.Apply` and `Merge.Merge` never join two different stamps. The
  sync server reads it from uploads to keep journeys of one name apart.
```

- [ ] **Step 4: Run every addon test and the changelog check**

Run: `cd apps/addon && bun run test 2>&1 | tail -30 && bash scripts/changelog.sh 1.10.0`
Expected: all tests pass; the script prints the 1.10.0 section.

- [ ] **Step 5: Commit and note it on #51**

```bash
git add apps/addon/RoadToSixty/Sync.lua apps/addon/tests/sync_test.lua apps/addon/CHANGELOG.md apps/addon/AGENTS.md
git commit -m "Sync: bring in only this journey; an erase on another PC replaces it (#51)"
gh issue comment 51 --body "Addon side done on branch \`journeys\` for 1.10.0: \`journeyId\` stamped at login (fresh start for a namesake's file, nothing changed if the GUID can't be read), Erase writes a new start, \`Sync.Apply\` merges only the same journey and lets an erase from another PC replace. Changelog section written."
```

---

### Task 8: App 0.1.7: remove characters, earlier journeys, Beta

**Files:**
- Modify: `apps/desktop/src-tauri/src/account.rs` (new `remove_character`)
- Modify: `apps/desktop/src-tauri/src/main.rs:125-143` (register it)
- Modify: `apps/desktop/src/api.ts` (new `removeCharacter`)
- Modify: `apps/desktop/src/format.ts` (new `BETA`, `byGame`, `earlierOf`, `earlierLine`, `removeWords`, `betaWords`)
- Modify: `apps/desktop/src/format.test.ts`
- Modify: `apps/desktop/src/Characters.tsx`, `apps/desktop/src/History.tsx`
- Modify: `apps/desktop/src-tauri/tauri.conf.json`, `apps/desktop/src-tauri/Cargo.toml`, `apps/desktop/Cargo.lock` (0.1.7)
- Modify: `apps/desktop/AGENTS.md`

**Interfaces:**
- Consumes: `CharacterInfo.earlier` and `DELETE /v1/characters/:id` from Tasks 4 and 5.
- Produces: Tauri command `remove_character(id: i64)`; `removeCharacter(id: number): Promise<unknown>`; the format functions below.

- [ ] **Step 1: Write the failing tests**

In `apps/desktop/src/format.test.ts`, add `BETA, betaWords, byGame, earlierLine, earlierOf, removeWords` to the import from `./format`, and append:

```ts
test("beta characters are listed apart, by the server's game for each", () => {
  const info = new Map([
    ["Ann-Classic Beta PvE 2", ann],
    ["Bob-Nightslayer", { ...ann, id: 2, name: "Bob", realm: "Nightslayer", game: "_classic_" }],
  ]);
  const rows = [{ key: "Ann-Classic Beta PvE 2" }, { key: "Bob-Nightslayer" }, { key: "Cy-Nightslayer" }];
  expect(byGame(rows, info)).toEqual({ main: [rows[1], rows[2]], beta: [rows[0]] });
  expect(BETA).toBe("_classic_beta_");
  expect(betaWords(1)).toBe("Remove 1 beta journey from the backup? Journeys on your PCs stay.");
  expect(betaWords(3)).toBe("Remove 3 beta journeys from the backup? Journeys on your PCs stay.");
});

test("a character's earlier journeys are its name's, newest first", () => {
  const old = { ...ann, id: 3, earlier: true, level: 12, lastPlayedAt: at(2026, 9, 12, 20, 0) };
  const older = { ...ann, id: 2, earlier: true, level: null, lastPlayedAt: null };
  const otherName = { ...ann, id: 4, name: "Bob", earlier: true };
  expect(earlierOf([ann, older, otherName, old], ann)).toEqual([old, older]);
  expect(earlierLine(old, now)).toBe("Level 12 · last played 3 days ago");
  expect(earlierLine(older, now)).toBe("");
});

test("removing says what stays", () => {
  expect(removeWords("Ann")).toBe(
    "Removes Ann's journey from the backup. Journeys on your PCs stay. If you play Ann again, its journey is backed up again from that PC.",
  );
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && bun test src 2>&1 | tail -20`
Expected: FAIL: `byGame` (and the rest) are not exported.

- [ ] **Step 3: Implement the format functions**

Append to `apps/desktop/src/format.ts`:

```ts
// The beta's game folder: its characters are tagged and removed together.
export const BETA = "_classic_beta_";

// The list's rows, this game's first and the beta's apart, by the server's
// game for each. A row the server doesn't have stays in the main list.
export function byGame<T extends { key: string }>(rows: T[], info: Map<string, CharacterInfo>): { main: T[]; beta: T[] } {
  const beta = rows.filter((r) => info.get(r.key)?.game === BETA);
  return { main: rows.filter((r) => !beta.includes(r)), beta };
}

export const betaWords = (n: number) => `Remove ${n} beta ${n === 1 ? "journey" : "journeys"} from the backup? Journeys on your PCs stay.`;

// A character's earlier journeys: the same game, realm and name, newest first.
export function earlierOf(all: CharacterInfo[], c: CharacterInfo): CharacterInfo[] {
  return all.filter((e) => e.earlier && e.game === c.game && e.realm === c.realm && e.name === c.name).sort((a, b) => b.id - a.id);
}

export function earlierLine(c: CharacterInfo, now: Date): string {
  return [c.level !== null ? `Level ${c.level}` : "", c.lastPlayedAt ? `last played ${ago(c.lastPlayedAt, now)}` : ""].filter(Boolean).join(" · ");
}

export const removeWords = (name: string) =>
  `Removes ${name}'s journey from the backup. Journeys on your PCs stay. If you play ${name} again, its journey is backed up again from that PC.`;
```

- [ ] **Step 4: Run the format tests to see them pass**

Run: `cd apps/desktop && bun test src 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 5: The command, the call and the screens**

In `account.rs`, after `restore`:

```rust
/// Removes one journey from the backup. A 409 while its merge runs comes
/// back as the server's own words.
#[tauri::command]
pub async fn remove_character(account: State<'_, Account>, id: i64) -> Result<Value, String> {
    account.call("DELETE", format!("/v1/characters/{id}"), None).await
}
```

In `main.rs`'s `generate_handler!`, add `account::remove_character,` after `account::restore,`. In `api.ts`, after `restore`:

```ts
export const removeCharacter = (id: number) => invoke("remove_character", { id });
```

In `Characters.tsx`: import `useState` from `react`, `removeCharacter` from `./api`, and `BETA, betaWords, byGame` from `./format`. Build `info` from current journeys only, and split the rows:

```tsx
  const info = new Map((server.data ?? []).filter((c) => !c.earlier).map((c) => [`${c.name}-${c.realm}`, c]));
  const { main, beta } = byGame(status.characters, info);
  const betaRows = (server.data ?? []).filter((c) => c.game === BETA);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function removeBeta() {
    setError(null);
    try {
      for (const c of betaRows) await removeCharacter(c.id);
      setAsking(false);
    } catch (e) {
      setError(`Couldn't remove them all: ${String(e)}`);
    }
    server.reload();
  }
```

Move the `status.characters.map((c) => { ... })` body into a local `function row(c: Status["characters"][number])` returning the `<li>`, and in it show the tag after the name's `<span>` when `i?.game === BETA`:

```tsx
                  {i?.game === BETA && <span className="rounded-full border border-outline px-1.5 text-[10px] text-muted">Beta</span>}
```

The list becomes `{main.map(row)}` followed by:

```tsx
        {beta.length > 0 && (
          <>
            <li className="mt-2 flex items-center gap-2 px-1">
              <h2 className="text-xs font-medium text-faint">Beta</h2>
              {!asking && (
                <Button className="ml-auto h-[26px] rounded-lg px-2.5 text-xs" onClick={() => setAsking(true)}>
                  Remove all beta characters
                </Button>
              )}
            </li>
            {asking && (
              <li className="flex flex-col gap-2.5 rounded-[10px] border border-[#3a3746] bg-[#100f15] px-3.5 py-3">
                <p className="text-[13px] leading-[1.45] text-[#c9c4d6]">{betaWords(betaRows.length)}</p>
                <div className="flex gap-2">
                  <Button look="cream" onClick={removeBeta}>
                    Remove
                  </Button>
                  <Button onClick={() => setAsking(false)}>Cancel</Button>
                </div>
              </li>
            )}
            {beta.map(row)}
          </>
        )}
```

and below the server error line: `{error && <p className="mx-5 mb-2 text-xs text-warn">{error}</p>}`.

In `History.tsx`: import `characters, removeCharacter` from `./api` and `earlierLine, earlierOf, removeWords` from `./format`. Add:

```tsx
  const all = useLoad(characters, [status.lastSynced]);
  const earlier = earlierOf(all.data ?? [], character);
  const [removing, setRemoving] = useState<number | null>(null);

  async function remove(id: number) {
    setError(null);
    try {
      await removeCharacter(id);
      setRemoving(null);
      if (id === character.id) onBack();
      else all.reload();
    } catch (e) {
      setError(`Couldn't remove: ${String(e)}`);
    }
  }

  // Asks first, in place: the removal can't be undone.
  const confirm = (id: number, words: string) => (
    <div className="flex flex-col gap-2.5 rounded-[10px] border border-[#3a3746] bg-[#100f15] px-3.5 py-3">
      <p className="text-[13px] leading-[1.45] text-[#c9c4d6]">{words}</p>
      <div className="flex gap-2">
        <Button look="cream" onClick={() => remove(id)}>
          Remove from backup
        </Button>
        <Button onClick={() => setRemoving(null)}>Cancel</Button>
      </div>
    </div>
  );
```

After the History `</ol>`:

```tsx
      {earlier.length > 0 && (
        <>
          <h2 className="mx-5 mt-1 text-xs font-medium text-faint">Earlier journeys</h2>
          <ul className="flex flex-col gap-2 px-4 pb-3 pt-2">
            {earlier.map((e) => (
              <li key={e.id}>
                {removing === e.id ? (
                  confirm(e.id, `Removes this earlier journey of ${character.name} from the backup. It can't be brought back.`)
                ) : (
                  <div className="flex items-center gap-2.5 rounded-[10px] border border-line bg-panel px-3.5 py-3">
                    <span className="flex-1 text-xs text-muted">{earlierLine(e, now) || "An earlier journey"}</span>
                    <Button className="h-[30px] rounded-lg px-3 text-xs" onClick={() => setRemoving(e.id)}>
                      Remove
                    </Button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </>
      )}
      <footer className="border-t border-line-soft px-4 py-3">
        {removing === character.id ? (
          confirm(character.id, removeWords(character.name))
        ) : (
          <Button onClick={() => setRemoving(character.id)}>Remove from backup</Button>
        )}
      </footer>
```

The History `<ol>` keeps its `flex-1`, so the footer sits at the bottom.

- [ ] **Step 6: Version 0.1.7, AGENTS.md, and the checks**

Set `"version": "0.1.7"` in `apps/desktop/src-tauri/tauri.conf.json` and `version = "0.1.7"` in `apps/desktop/src-tauri/Cargo.toml`. In `apps/desktop/AGENTS.md`, change the `src/account.rs` list to "(characters, history, restore, remove a character, PCs, export, delete everything)" and add after it: "The Characters list tags a character Beta from the server's `game` (`_classic_beta_`) and lists them apart with one button to remove them all; a character the server doesn't have stays in the main list, since the app's own list doesn't know a file's game. History lists a name's earlier journeys (`earlier` from the server), each removable."

Run: `cd apps/desktop && . ~/.cargo/env && bun run build && bun run test 2>&1 | tail -20 && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings`
Expected: the window builds, every test passes (Cargo.lock now says 0.1.7 for road-to-sixty-app), no fmt or clippy complaints.

- [ ] **Step 7: Look at it**

Run `bunx tauri dev` from `apps/desktop` against a local server (`bun run dev` in `apps/server` with made-up uploads from `bun scripts/try-upload.ts`), or take a screenshot of the Characters and History screens, and check the Beta heading, tag, both confirmations and the earlier list read right at the window's width. If running it isn't possible here, say so in the task's ledger line.

- [ ] **Step 8: Commit**

```bash
git add apps/desktop
git commit -m "App: remove a character or an earlier journey, and every beta character at once; 0.1.7 (#51)"
```

---

### Task 9: Website: the Privacy line

**Files:**
- Modify: `apps/web/src/pages/privacy.astro:46-50`

- [ ] **Step 1: Add the sentence**

In "Deleting it", after the paragraph ending "from the same screen.", add:

```astro
    <p>
      To remove just one character, open it in the app's Characters list and choose Remove from backup; an earlier journey of a character (from
      before an Erase, or a deleted character of the same name) is removed the same way. Beta characters are listed apart, with one button to remove
      them all.
    </p>
```

- [ ] **Step 2: Build**

Run: `cd apps/web && bun run build 2>&1 | tail -5`
Expected: the build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/pages/privacy.astro
git commit -m "Website: Privacy says one character, an earlier journey or every beta character can be removed (#51)"
```

---

### Task 10: The in-game checks on #23, and the whole suite

- [ ] **Step 1: Add the checks to the launch checklist**

```bash
gh issue view 23 --json body -q .body > "$TMPDIR/23.md"
cat >> "$TMPDIR/23.md" <<'EOF'

**Journey stamps (#51), addon 1.10.0**
- [ ] `/dump UnitGUID("player")` gives a plain `Player-...` string at login, and inside a dungeon.
- [ ] Delete a character, make one with the same name, log in: the map starts empty, and the app lists the old journey as an earlier one.
- [ ] Erase a synced character on one PC, log in on another: the other PC takes the erased journey; the app lists the old one as earlier.
EOF
gh issue edit 23 --body-file "$TMPDIR/23.md"
```

The first check can be done on the beta now; ask Jordan for a `/dump` screenshot.

- [ ] **Step 2: Run everything from the root**

Run: `. ~/.cargo/env && PATH="$TMPDIR/luabin:$PATH" LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun run test 2>&1 | tail -30 && bun run typecheck`
Expected: every package passes.

---

## After the tasks (not part of execution)

- Final whole-branch review on Opus, then one fix pass, each fix with a test that fails first.
- Merge `journeys` into `dev` with `--no-ff` and push `dev`; bring `main` up for Jordan to push.
- Rollout order: the server deploys from `main`; addon 1.10.0 is released the same day (changelog, `check.ps1`, `package.ps1`, tag `v1.10.0`); app 0.1.7 tagged `app-v0.1.7` after the review. Until 1.10.0 is out, PCs on 1.9.x see "Update the addon on this PC to get the newest journey".
- Close #51 once all three are released, with a summary; sweep per CLAUDE.md.
