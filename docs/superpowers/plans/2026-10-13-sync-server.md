# Sync Server: the Merge Pipeline, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `apps/server` takes a PC's character file, stores it, merges it into that character's journey with the addon's own `Merge.lua` under standard Lua 5.1, and hands the merged journey to every PC of that user.

**Architecture:** One Bun service using Elysia. Postgres is reached through Drizzle and Bun's built-in SQL client, and an S3 store through Bun's built-in S3 client: R2 in production, SeaweedFS locally and in CI. An upload is stored straight away and queued. One worker takes jobs in order and runs `runner.lua` as a process of its own. The runner holds its own memory and time limits, and Bun kills it if it overruns. It prepares, tidies, merges and checks, and the result becomes the character's new head version. The app fetches with its PC token: upload, check and download. Sign-in is the next plan. Until then a token made by a script stands in for Better Auth's device tokens.

**Tech Stack:** Bun 1.4.2, Elysia 1.4.30, Drizzle ORM 0.45.4 (`drizzle-orm/bun-sql`) with drizzle-kit 0.31.11, Postgres 17.11, SeaweedFS 4.48 (S3), PUC Lua 5.1, TypeScript 7.0.2, Docker.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "The backend" (Sync API, Merge jobs, Mismatched addon versions, Restore), "Storage" (Postgres, R2), "Testing" (Server), "Repo layout".

## Global Constraints

- One Bun service in `apps/server`, using Elysia. The Docker image is based on the official Bun image, installs `lua5.1`, and copies `Merge.lua`, `Parse.lua`, `Tidy.lua`, `Packed.lua` and `Tally.lua` from `apps/addon/RoadToSixty/` (spec).
- Uploads over 32 MB uncompressed are refused, as are files starting with compiled Lua bytecode, first byte 0x1B (spec).
- An upload is stored straight away and a job goes into `jobs`. Two uploads for one character never merge at once. The runner is a separate `lua5.1` process with a memory cap and a time limit, given only the two files. A failed check, crash or timeout marks the job and the upload rejected with the reason, and the character keeps its old merged version. The first upload becomes the first merged version (spec).
- R2 keys are `<user id>/<fingerprint>.zst`, zstd-compressed. Identical files are stored once (spec).
- The server never sends a version in a data layout newer than the PC's addon understands (spec).
- Never commit secrets, personal paths or real saved files. Test journeys are made up. Commit subjects are `Area: what changed (#1)`.
- Subagents run on at most Opus, never Fable.

## Decisions the spec leaves open

- **Merged versions are stored as `Parse.Write` text of one journey**, which is exactly what the app puts in `data.lua`'s `journey` string. Download returns it unchanged, still zstd-compressed. Uploads are stored as sent: the zstd of the SavedVariables file.
- **The upload says which version the PC last received by its id, not its fingerprint.** A restore holds the same text, and so has the same fingerprint, as the version it restores. `UploadQuery.received` is that id.
- **An upload made before a restore reached its PC is `superseded`, not merged.** It still holds what the restore took out. The rule: the character has a restore R, and the upload's `received` is below R. A PC that never received anything (no `received`) merges as usual, since it holds only its own play.
- **A merge that changes nothing makes no new version.** The upload is accepted and the head stays.
- **`Merge.Prepare` refuses damaged journeys.** This is the shape check that was in `Sync.lua`. The server and the addon both need it, so it moves into the shared file (Task 1).
- **The identity check** the Merge header leaves to the caller is the character row: `(user, game, realm, name)` from the upload's query. The runner never sees names.
- **A PC's data layout** is the `version` its last upload was saved in, which the runner reports before preparing it. A PC that hasn't uploaded yet isn't filtered: its addon refuses a newer layout itself (Sync.lua).
- **`class` stays null.** The character file has none (only the roster in the account file does). The account backup step can fill it.
- **Places for `Tidy.Events`:** 946, 947, 1414 and 1415 (the cosmos, Azeroth, Kalimdor, the Eastern Kingdoms) aren't places. The repo uses these IDs (`Map.lua`, `zone-overlays.py`). wago.tools answered 503 while this plan was written, so the full `UiMap` table wasn't checked. Zephras Isle (2991 in `Islands.lua` and `Routes.lua`) is left out, since those files call it a continent ID rather than clearly a map type. Task 4 asks for the check once wago.tools is back.
- **SeaweedFS stands in for R2** locally and in CI. MinIO's images are no longer pullable (Docker Hub denies them, quay.io answers 401). With no keys configured, SeaweedFS accepts any.
- **One worker takes one job at a time.** That also covers "never two merges of one character at once". A `ponytail:` comment names the per-character lock to add if more workers ever run.
- **Bun's `proc.killed` is true after any exit**, so a killed runner is detected by `proc.signalCode`. A probe showed this while writing the plan.
- **`LUA51`** names the Lua 5.1 binary when `lua5.1` isn't on the path, as the addon tests already do. Turbo passes it through. The server tests aren't cached, since they need running services.
- **Root `bun run test` now needs Docker** for the server tests. The addon's CI job runs `--filter=@road-to-sixty/addon`, and a new `server` job runs Postgres and SeaweedFS with `docker compose`.

## Review Focus

1. A zstd file that unpacks to gigabytes: refused at 32 MB without allocating more (Task 3 tests a 32 MB + 1 bomb under 10 KB).
2. A merge that runs away: the runner stops itself at the memory or time limit, and a runner that ignores its limits is killed by Bun (Task 4).
3. Another user's version id, or a revoked token: 404 and 401 (Task 5).
4. A server restart in the middle of a job: the job goes back to the queue, and a job that keeps throwing is failed after 3 attempts with the upload rejected (Task 5's worker, which no test kills mid-job; the reviewer reads it).
5. The image Dokploy deploys: built in CI, and a merge is run inside it (Task 6).

---

### Task 1: Merge.Prepare refuses a damaged journey

**Files:**
- Modify: `apps/addon/RoadToSixty/Merge.lua` (above `Merge.Prepare`, and its first lines), `apps/addon/RoadToSixty/Sync.lua` (the shape check moves out), `apps/addon/tests/merge_test.lua` (section 13)

**Interfaces:**
- Produces: `ns.Merge.Prepare(char, pc) -> char | nil, why`, which now also returns `nil, "a damaged journey: <what>"`.

- [ ] **Step 1: Cut the branch**

```bash
git switch dev && git switch -c sync-server && git status -sb | head -1
```
Expected: `## sync-server`.

- [ ] **Step 2: Write the failing test**

Apply this to `apps/addon/tests/merge_test.lua`:

```diff
diff --git a/apps/addon/tests/merge_test.lua b/apps/addon/tests/merge_test.lua
index 4cadffe..9b718d1 100644
--- a/apps/addon/tests/merge_test.lua
+++ b/apps/addon/tests/merge_test.lua
@@ -295,6 +295,13 @@ check(none == nil and reason, "layout 1 is refused")
 none, reason = Merge.Prepare(Journey({ version = 4 }), "pcz")
 check(none == nil and tostring(reason):find("newer"), "a newer layout is refused")
 check(Merge.Prepare(Journey(), "pcz").version == 3, "layout 3 is left as it is")
+for _, bad in ipairs({ { totals = 5 }, { kills = "x" }, { levels = 1 }, { events = { 1 } }, { events = { { "t", "on" } } },
+    { totals = { kills = "many" } }, { kills = { d = 5 } } }) do
+    local damaged = Journey()
+    for k, v in pairs(bad) do damaged[k] = v end
+    none, reason = Merge.Prepare(damaged, "pcz")
+    check(none == nil and tostring(reason):find("damaged"), "a damaged journey is refused: " .. Write(bad) .. " " .. tostring(reason))
+end
 
 -- 14. Check: a result holds every session and no count went down.
 local function Copy(t) return ns.Parse.Read(Write(t)) end
```

Run: `cd apps/addon && luajit tests/merge_test.lua; cd ../..`
Expected: seven `FAIL: a damaged journey is refused: ...` lines (Prepare returns the journey).

- [ ] **Step 3: Move the check into Prepare**

Apply this to `apps/addon/RoadToSixty/Merge.lua` and `apps/addon/RoadToSixty/Sync.lua`:

```diff
diff --git a/apps/addon/RoadToSixty/Merge.lua b/apps/addon/RoadToSixty/Merge.lua
index 08154f1..e5c2ab9 100644
--- a/apps/addon/RoadToSixty/Merge.lua
+++ b/apps/addon/RoadToSixty/Merge.lua
@@ -479,14 +479,35 @@ end
 
 -- For the server -------------------------------------------------------------
 
+-- The parts the addon adds to or indexes. A journey with one of the wrong
+-- shape would stop the recording once the addon took it in, and the server
+-- would hand it to every PC.
+local TABLES = { "segments", "events", "levels", "kills", "recipes", "people", "totals" }
+
+local function Misshapen(j)
+    for _, k in ipairs(TABLES) do
+        if j[k] ~= nil and type(j[k]) ~= "table" then return k .. " isn't a table" end
+    end
+    for _, e in ipairs(j.events or {}) do
+        if type(e) ~= "table" or type(e[1]) ~= "number" then return "an event has no time" end
+    end
+    for k, v in pairs(j.totals or {}) do
+        if type(v) ~= "number" then return "totals." .. tostring(k) .. " isn't a number" end
+    end
+    if j.kills and j.kills.d ~= nil and type(j.kills.d) ~= "string" then return "the kills aren't packed text" end
+end
+
 -- Brings a journey saved by an older addon up to Merge.VERSION before it is
--- merged, its counts counted as pc's, the PC it came from. Changes the
--- journey in place. Returns it, or nil and why it can't be merged.
+-- merged, its counts counted as pc's, the PC it came from, and refuses one
+-- that is damaged. Changes the journey in place. Returns it, or nil and why
+-- it can't be merged.
 function Merge.Prepare(char, pc)
     if type(char) ~= "table" then return nil, "not a journey" end
     local version = tonumber(char.version) or 0
     if version > Merge.VERSION then return nil, "a newer layout than this merge knows" end
     if version < 2 then return nil, "a layout from before journeys used the realm's clock" end
+    local damaged = Misshapen(char)
+    if damaged then return nil, "a damaged journey: " .. damaged end
     if version < 3 then
         ns.Tally.Upgrade(char, pc)
         char.version = 3
diff --git a/apps/addon/RoadToSixty/Sync.lua b/apps/addon/RoadToSixty/Sync.lua
index 72402fe..c4f8fd9 100644
--- a/apps/addon/RoadToSixty/Sync.lua
+++ b/apps/addon/RoadToSixty/Sync.lua
@@ -31,24 +31,6 @@ local function TidyUp(char)
     if not char.seeded then ns.Tidy.Guilds(char) end
 end
 
--- The parts the addon adds to or indexes once the journey is copied in. A
--- journey with one of the wrong shape would stop the recording, and at the
--- next logout that is what would be saved.
-local TABLES = { "segments", "events", "levels", "kills", "recipes", "people", "totals" }
-
-local function Misshapen(j)
-    for _, k in ipairs(TABLES) do
-        if j[k] ~= nil and type(j[k]) ~= "table" then return k .. " isn't a table" end
-    end
-    for _, e in ipairs(j.events or {}) do
-        if type(e) ~= "table" or type(e[1]) ~= "number" then return "an event has no time" end
-    end
-    for k, v in pairs(j.totals or {}) do
-        if type(v) ~= "number" then return "totals." .. tostring(k) .. " isn't a number" end
-    end
-    if j.kills and j.kills.d ~= nil and type(j.kills.d) ~= "string" then return "the kills aren't packed text" end
-end
-
 -- What a sync folder entry does to char, the journey this PC saved: "same"
 -- when that version was already brought in; "merged" or "replaced" with
 -- the journey to keep; "problem" with why it can't be used. Tidies char in
@@ -65,9 +47,8 @@ function Sync.Apply(char, entry)
     if (tonumber(journey.version) or 0) > ns.Merge.VERSION then
         return "problem", "it was saved by a newer Road to Sixty. Update the addon on this PC"
     end
-    local why = Misshapen(journey)
-    if why then return "problem", "the synced journey is damaged: " .. why end
     if char.seeded or journey.seeded then return "problem", "a seeded test journey is never merged or restored" end
+    local why
     journey, why = ns.Merge.Prepare(journey, ns.pc)
     if not journey then return "problem", why end
     TidyUp(char)
```

- [ ] **Step 4: Run the addon's tests**

Run: `cd apps/addon && bun scripts/test.ts; cd ../..`
Expected: `luajit: 21 test files` and exit 0. `sync_test.lua`'s damaged-journey cases now get Prepare's reason.

- [ ] **Step 5: Commit**

```bash
git add apps/addon/RoadToSixty/Merge.lua apps/addon/RoadToSixty/Sync.lua apps/addon/tests/merge_test.lua
git commit -m "Merge: Prepare refuses a damaged journey, for the server as well as the addon (#1)

The shape check moves from Sync.lua into the shared file, so the server
refuses an upload the addon would stop recording with.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The TypeScript workspace, the shared API types and the server package

**Files:**
- Create: `tsconfig.base.json`, `packages/api/package.json`, `packages/api/tsconfig.json`, `packages/api/src/index.ts`, `apps/server/package.json`, `apps/server/tsconfig.json`, `apps/server/docker-compose.yml`, `apps/server/.env.test`, `apps/server/.env.example`, `apps/server/src/config.ts`
- Modify: `package.json`, `turbo.json`, `.gitignore`, `bun.lock` (by `bun add`)

**Interfaces:**
- Produces: `@road-to-sixty/api` types `UploadQuery`, `UploadResponse`, `CheckEntry`, `CheckResponse`; `config` (`port`, `databaseUrl`, `s3`, `lua51`, `luaDir`) from `apps/server/src/config.ts`; root scripts `typecheck`.

- [ ] **Step 1: Root files**

Set `package.json`'s `workspaces` to `["apps/*", "packages/*"]` and add the script `"typecheck": "turbo run typecheck"`. Then:

```bash
bun add -d typescript@^7.0.2 @types/bun@^1.4.3
```

Expected `package.json`:

```json
{
  "name": "road-to-sixty",
  "private": true,
  "packageManager": "bun@1.4.2",
  "workspaces": [
    "apps/*",
    "packages/*"
  ],
  "scripts": {
    "test": "turbo run test",
    "check": "turbo run check",
    "package": "turbo run package",
    "typecheck": "turbo run typecheck"
  },
  "devDependencies": {
    "@types/bun": "^1.4.3",
    "turbo": "^2.11.7",
    "typescript": "^7.0.2"
  }
}
```

Create `tsconfig.base.json`:

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "Preserve",
    "moduleResolution": "bundler",
    "lib": ["ESNext"],
    "types": ["bun"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": true,
    "noEmit": true,
    "verbatimModuleSyntax": true
  }
}
```

Replace `turbo.json` with:

```json
{
  "$schema": "https://turborepo.com/schema.json",
  "agentGuidance": false,
  "tasks": {
    "test": { "env": ["LUA51"] },
    "@road-to-sixty/server#test": { "cache": false, "env": ["LUA51"] },
    "check": {},
    "typecheck": {},
    "package": { "cache": false, "outputs": ["build/**", "dist/**"] }
  }
}
```

In `.gitignore`, after the `.turbo/` line, add:

```

# Local settings with secrets (apps/server/.env.example lists them)
.env
```

- [ ] **Step 2: packages/api**

Create `packages/api/package.json`:

```json
{
  "name": "@road-to-sixty/api",
  "private": true,
  "type": "module",
  "exports": { ".": "./src/index.ts" },
  "scripts": {
    "typecheck": "tsc --noEmit -p ."
  }
}
```

`packages/api/tsconfig.json`:

```json
{ "extends": "../../tsconfig.base.json", "include": ["src"] }
```

`packages/api/src/index.ts`:

```ts
// What the sync API sends and receives, shared by the server, the website
// and the app's window. The app's Rust side mirrors these by hand.

// POST /v1/upload?game=&realm=&name=&addon=&received=, body: the character's
// SavedVariables file compressed with zstd.
export type UploadQuery = {
  game: string; // the game folder, such as _classic_beta_
  realm: string;
  name: string;
  addon?: string; // the addon version that wrote the file
  // The last version this PC received, by id. Not by fingerprint: a
  // restore holds the same text as the version it restores.
  received?: string;
};

export type UploadResponse = {
  version: number;
  // queued: stored and waiting to be merged; known: this exact file was
  // uploaded before, so nothing new happened.
  status: "queued" | "known";
};

// GET /v1/check
export type CheckEntry = {
  game: string;
  realm: string;
  name: string;
  // The version to deliver, or null when it needs a newer addon than this PC has.
  version: number | null;
  fingerprint: string;
  replace: boolean; // a restore: the addon replaces instead of merging
  updateAddon: boolean;
};

export type CheckResponse = { characters: CheckEntry[] };

// GET /v1/versions/:id returns the journey as zstd-compressed Parse.Write
// text: what the app puts in data.lua's journey string, after decompressing.
```

- [ ] **Step 3: The server package**

Create `apps/server/package.json`:

```json
{
  "name": "@road-to-sixty/server",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "bun --watch src/index.ts",
    "start": "bun src/index.ts",
    "test": "bun test",
    "typecheck": "tsc --noEmit -p .",
    "db:generate": "drizzle-kit generate",
    "device:new": "bun scripts/new-device.ts"
  }
}
```

Then, from `apps/server`:

```bash
bun add elysia@1.4.30 drizzle-orm@0.45.4 '@road-to-sixty/api@workspace:*'
bun add -d drizzle-kit@0.31.11
```

Create `apps/server/tsconfig.json`:

```json
{ "extends": "../../tsconfig.base.json", "include": ["src", "test", "scripts", "drizzle.config.ts"] }
```

`apps/server/docker-compose.yml`:

```yaml
# Postgres and an S3 store for running the server and its tests locally and
# in CI. SeaweedFS stands in for R2: it speaks the same S3 API, and with no
# keys configured it accepts any. Ports are off the defaults so they don't
# clash with anything else running.
name: rts-server
services:
  postgres:
    image: postgres:17.11
    environment:
      POSTGRES_USER: rts
      POSTGRES_PASSWORD: rts
      POSTGRES_DB: rts
    ports: ["55432:5432"]
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "rts"]
      interval: 2s
      retries: 30
  s3:
    image: chrislusf/seaweedfs:4.48
    command: server -s3
    ports: ["58333:8333"]
```

`apps/server/.env.test`:

```
# The local services in docker-compose.yml. Not secrets: they exist only on
# this machine and in CI.
DATABASE_URL=postgres://rts:rts@localhost:55432/rts
S3_ENDPOINT=http://localhost:58333
S3_BUCKET=journeys-test
S3_ACCESS_KEY_ID=local
S3_SECRET_ACCESS_KEY=local
```

`apps/server/.env.example`:

```
# Copy to .env (git ignores it) and fill in. Dokploy sets these on the server.
PORT=3000
DATABASE_URL=postgres://rts:rts@localhost:55432/rts
# Cloudflare R2: https://<account id>.r2.cloudflarestorage.com
S3_ENDPOINT=http://localhost:58333
S3_BUCKET=journeys
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
# Standard Lua 5.1 and the addon's folder of shared Lua files. The Docker
# image sets both; locally lua5.1 must be on the path or named here.
LUA51=lua5.1
LUA_DIR=../addon/RoadToSixty
```

`apps/server/src/config.ts`:

```ts
// Settings from the environment; .env.example lists them. Bun reads .env,
// and .env.test under bun test.

function env(name: string, fallback?: string): string {
  const value = process.env[name] || fallback;
  if (value === undefined) throw new Error(`${name} is not set`);
  return value;
}

export const config = {
  port: Number(env("PORT", "3000")),
  databaseUrl: env("DATABASE_URL"),
  s3: {
    endpoint: env("S3_ENDPOINT"),
    bucket: env("S3_BUCKET"),
    accessKeyId: env("S3_ACCESS_KEY_ID"),
    secretAccessKey: env("S3_SECRET_ACCESS_KEY"),
  },
  lua51: env("LUA51", "lua5.1"),
  luaDir: env("LUA_DIR", `${import.meta.dir}/../../addon/RoadToSixty`),
};
```

- [ ] **Step 4: Check it**

Run: `bun install && bun run typecheck && (cd apps/server && docker compose up -d --wait)`
Expected: turbo runs `typecheck` in `@road-to-sixty/api` and `@road-to-sixty/server`, `Tasks: 2 successful`. (The server has only `config.ts` so far.) Compose reports `rts-server-postgres-1 Healthy`. If port 55432 or 58333 is taken, stop whatever holds it.

Run: `git status --short`
Expected: the new files plus `package.json`, `turbo.json`, `.gitignore`, `bun.lock`. No `node_modules/` or `.env`.

- [ ] **Step 5: Commit**

```bash
git add tsconfig.base.json package.json turbo.json .gitignore bun.lock packages/api apps/server
git commit -m "Server: the TypeScript workspace, shared API types and the server package (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Tables, migrations and storage

**Files:**
- Create: `apps/server/src/schema.ts`, `apps/server/src/db.ts`, `apps/server/drizzle.config.ts`, `apps/server/drizzle/` (generated), `apps/server/src/storage.ts`, `apps/server/test/helpers.ts`, `apps/server/test/storage.test.ts`

**Interfaces:**
- Consumes: `config` (Task 2).
- Produces: tables `devices`, `characters`, `versions`, `versionParents`, `jobs`; `db`, `client`, `migrateDb()`; `MAX_RAW`, `fingerprint(raw)`, `pack(raw)`, `unpack(packed)`, `put(userId, fp, packed)`, `getPacked(userId, fp)`, `get(userId, fp)`; test helpers `reset()`, `lua(v)`, `journey(fields)`, `session(t)`, `savedFile(j)`, `sessions(text)`.

- [ ] **Step 1: Write the failing test and the helpers**

Create `apps/server/test/helpers.ts`:

```ts
// Shared by the server tests: a clean database and bucket, and made-up
// journeys in the game's saved format. Never a real save: those hold other
// players' names.
import { config } from "../src/config";
import { client, migrateDb } from "../src/db";

export async function reset() {
  await migrateDb();
  await client`TRUNCATE jobs, version_parents, versions, characters, devices RESTART IDENTITY CASCADE`;
  // SeaweedFS makes a bucket on an unsigned PUT (409 once it exists); it
  // takes a few seconds to start in CI. R2's bucket is made once by hand.
  for (let tries = 0; ; tries++) {
    const put = fetch(`${config.s3.endpoint}/${config.s3.bucket}`, { method: "PUT" });
    const ok = await put.then((r) => r.ok || r.status === 409, () => false);
    if (ok) return;
    if (tries === 40) throw new Error(`no S3 store at ${config.s3.endpoint}: run docker compose up -d in apps/server`);
    await Bun.sleep(500);
  }
}

// A value as Lua table text the addon's Parse.lua reads. Arrays become the
// array part, null a gap; object keys made of digits become number keys.
export function lua(v: unknown): string {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `{${v.map((x) => `${lua(x)},`).join("")}}`;
  const entries = Object.entries(v as Record<string, unknown>);
  return `{${entries.map(([k, x]) => `[${/^\d+$/.test(k) ? k : JSON.stringify(k)}] = ${lua(x)},`).join("")}}`;
}

export type Event = (string | number | boolean | null | object)[];

// A journey at layout 3 with nothing in it but what is given.
export function journey(fields: Record<string, unknown> = {}) {
  return {
    version: 3,
    segments: [],
    events: [] as Event[],
    levels: {},
    recipes: {},
    people: {},
    kills: { d: "", last: 0, names: [] },
    totals: { kills: 0, killXP: 0, questXP: 0, deaths: 0, quests: 0, instances: 0, distance: 0, flown: 0 },
    ...fields,
  };
}

// One session: logged on, died, logged off.
export const session = (t: number): Event[] => [
  [t, "on", 0, 0, 0, 10],
  [t + 60, "die", 0, 0, 0],
  [t + 120, "off", 0, 0, 0],
];

// The character's SavedVariables file as the game writes it.
export const savedFile = (j: object) => new TextEncoder().encode(`\r\nRoadToSixtyCharDB = ${lua(j)}\r\n`);

// How many sessions a journey's text holds, by its "on" events.
export const sessions = (text: Uint8Array | string) =>
  (typeof text === "string" ? text : new TextDecoder().decode(text)).split('"on"').length - 1;
```

Create `apps/server/test/storage.test.ts`:

```ts
import { beforeAll, expect, test } from "bun:test";
import { MAX_RAW, fingerprint, get, pack, put, unpack } from "../src/storage";
import { reset } from "./helpers";

beforeAll(reset);

test("a file is stored once under its fingerprint and read back", async () => {
  const raw = new TextEncoder().encode("RoadToSixtyCharDB = {}");
  const fp = fingerprint(raw);
  expect(fp).toMatch(/^[0-9a-f]{64}$/);
  await put("user-1", fp, pack(raw));
  await put("user-1", fp, pack(raw));
  expect(new TextDecoder().decode(await get("user-1", fp))).toBe("RoadToSixtyCharDB = {}");
});

test("unpacking refuses more than 32 MB, however small the packed file", () => {
  const bomb = pack(new Uint8Array(MAX_RAW + 1));
  expect(bomb.length).toBeLessThan(10_000);
  expect(() => unpack(bomb)).toThrow();
  expect(unpack(pack(new Uint8Array(MAX_RAW))).length).toBe(MAX_RAW);
});
```

Run: `cd apps/server && bun test test/storage.test.ts; cd ../..`
Expected: errors that `../src/storage` and `../src/db` can't be found.

- [ ] **Step 2: The tables**

Create `apps/server/src/schema.ts`:

```ts
import { bigint, bigserial, integer, pgTable, primaryKey, text, timestamp, unique } from "drizzle-orm/pg-core";

// A linked PC. Its id is also the PC ID the addon keeps counts under, so a
// journey uploaded from an older addon is prepared with it. tokenHash
// stands in for Better Auth's device tokens until sign-in is built.
// dataLayout is the journey layout its addon writes, from its last upload,
// so check never offers it a version it can't read.
export const devices = pgTable("devices", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  name: text("name").notNull(),
  platform: text("platform"),
  appVersion: text("app_version"),
  addonVersion: text("addon_version"),
  dataLayout: integer("data_layout"),
  tokenHash: text("token_hash").notNull().unique(),
  lastSeenAt: timestamp("last_seen_at", { withTimezone: true }),
  revokedAt: timestamp("revoked_at", { withTimezone: true }),
});

// One character of one user. The data holds no name, so this row is how
// the server knows two uploads are the same character.
export const characters = pgTable(
  "characters",
  {
    id: bigserial("id", { mode: "number" }).primaryKey(),
    userId: text("user_id").notNull(),
    game: text("game").notNull(),
    realm: text("realm").notNull(),
    name: text("name").notNull(),
    class: text("class"),
    level: integer("level"),
    played: integer("played"),
    lastPlayedAt: timestamp("last_played_at", { withTimezone: true }),
    headVersionId: bigint("head_version_id", { mode: "number" }),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [unique().on(t.userId, t.game, t.realm, t.name)],
);

// Every upload, merge result and restore. Ids only grow: the addon takes a
// version that is higher than the one it last brought in. receivedId is the
// version the uploading PC had last received, so an upload made before a
// restore reached it doesn't undo the restore.
export const versions = pgTable("versions", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  characterId: bigint("character_id", { mode: "number" }).notNull().references(() => characters.id),
  deviceId: text("device_id").references(() => devices.id),
  kind: text("kind", { enum: ["upload", "merged", "restore"] }).notNull(),
  fingerprint: text("fingerprint").notNull(),
  rawSize: integer("raw_size").notNull(),
  dataVersion: integer("data_version"),
  addonVersion: text("addon_version"),
  receivedId: bigint("received_id", { mode: "number" }),
  status: text("status", { enum: ["pending", "accepted", "rejected", "superseded"] }).notNull(),
  rejectReason: text("reject_reason"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const versionParents = pgTable(
  "version_parents",
  {
    versionId: bigint("version_id", { mode: "number" }).notNull().references(() => versions.id),
    parentId: bigint("parent_id", { mode: "number" }).notNull().references(() => versions.id),
  },
  (t) => [primaryKey({ columns: [t.versionId, t.parentId] })],
);

export const jobs = pgTable("jobs", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  characterId: bigint("character_id", { mode: "number" }).notNull().references(() => characters.id),
  versionId: bigint("version_id", { mode: "number" }).notNull().references(() => versions.id),
  state: text("state", { enum: ["queued", "running", "done", "failed"] }).notNull().default("queued"),
  attempts: integer("attempts").notNull().default(0),
  error: text("error"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  finishedAt: timestamp("finished_at", { withTimezone: true }),
});
```

`apps/server/src/db.ts`:

```ts
import { SQL } from "bun";
import { drizzle } from "drizzle-orm/bun-sql";
import { migrate } from "drizzle-orm/bun-sql/migrator";
import { config } from "./config";
import * as schema from "./schema";

export const client = new SQL(config.databaseUrl);
export const db = drizzle({ client, schema });

export function migrateDb() {
  return migrate(db, { migrationsFolder: `${import.meta.dir}/../drizzle` });
}
```

`apps/server/drizzle.config.ts`:

```ts
import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/schema.ts",
  out: "./drizzle",
});
```

Run: `cd apps/server && bunx drizzle-kit generate --name init; cd ../..`
Expected: `drizzle/0000_init.sql` with `CREATE TABLE` for `characters`, `devices`, `jobs`, `version_parents` and `versions`, and `drizzle/meta/`.

- [ ] **Step 3: Storage**

Create `apps/server/src/storage.ts`:

```ts
import { zstdDecompressSync } from "node:zlib";
import { config } from "./config";

// The most a character file may hold uncompressed (spec). A level 60
// journey is 2 to 3 MB.
export const MAX_RAW = 32 * 1024 * 1024;

const s3 = new Bun.S3Client(config.s3);

const key = (userId: string, fingerprint: string) => `${userId}/${fingerprint}.zst`;

export function fingerprint(raw: Uint8Array): string {
  return new Bun.CryptoHasher("sha256").update(raw).digest("hex");
}

export function pack(raw: Uint8Array): Uint8Array {
  return Bun.zstdCompressSync(raw);
}

// Refuses more than MAX_RAW: a few KB of zstd can unpack to gigabytes.
export function unpack(packed: Uint8Array): Uint8Array {
  return new Uint8Array(zstdDecompressSync(packed, { maxOutputLength: MAX_RAW }));
}

// Identical files share one key, so a file is stored once.
export async function put(userId: string, fp: string, packed: Uint8Array): Promise<void> {
  const k = key(userId, fp);
  if (!(await s3.exists(k))) await s3.write(k, packed);
}

export async function getPacked(userId: string, fp: string): Promise<Uint8Array> {
  return new Uint8Array(await s3.file(key(userId, fp)).arrayBuffer());
}

export async function get(userId: string, fp: string): Promise<Uint8Array> {
  return unpack(await getPacked(userId, fp));
}
```

- [ ] **Step 4: Run the test**

Run: `cd apps/server && bun test test/storage.test.ts && bunx tsc --noEmit -p .; cd ../..`
Expected: `2 pass`, `0 fail`, and no type errors.

- [ ] **Step 5: Commit**

```bash
git add apps/server
git commit -m "Server: tables, the first migration, and zstd files in the S3 store (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The merge under Lua 5.1, with its limits

**Files:**
- Create: `apps/server/src/runner.lua`, `apps/server/src/lua.ts`, `apps/server/test/lua.test.ts`, `apps/server/test/fixtures/hang.lua`

**Interfaces:**
- Consumes: `config.lua51`, `config.luaDir` (Task 2); `ns.Merge.Prepare/Merge/Check`, `ns.Parse.File/Read/Write`, `ns.Tidy.Runs/Events/Guilds` (the addon).
- Produces: `runMerge(upload, current | null, pc, limits = LIMITS, runner?) -> MergeResult`; `MergeResult` is `{ ok: true, from, layout, level, played, lastSeen, journey }` or `{ ok: false, from, reason }`; `LIMITS = { mb: 512, seconds: 60 }`.

- [ ] **Step 1: Write the failing tests**

Create `apps/server/test/fixtures/hang.lua`, a runner that never ends:

```lua
while true do end
```

Create `apps/server/test/lua.test.ts`:

```ts
import { expect, test } from "bun:test";
import { runMerge } from "../src/lua";
import { journey, lua, savedFile, session, sessions } from "./helpers";

const text = (j: object) => new TextEncoder().encode(lua(j));

test("a first upload is prepared and tidied, and becomes the journey", async () => {
  const upload = journey({
    version: 2,
    events: [...session(1000), [1200, "zone", 0, 0, 0, 1415]], // a continent logged as a zone, which the tidy drops
    people: { "Player-1-0001": { name: "Ann", groups: 2 } },
    levels: { 5: { t: 900 }, 6: { t: 1100 } },
    played: 3600,
  });
  const r = await runMerge(savedFile(upload), null, "pc-1");
  if (!r.ok) throw new Error(r.reason);
  expect(r).toMatchObject({ from: 2, layout: 3, level: 6, played: 3600, lastSeen: 1120 });
  const out = new TextDecoder().decode(r.journey);
  expect(sessions(out)).toBe(1);
  expect(out).not.toContain("1415");
  expect(out).toContain('["pc-1"]=2'); // the old count, now this PC's tally
});

test("an upload merges into the current journey", async () => {
  const current = text(journey({ events: session(1000), totals: { ...journey().totals, deaths: 1 } }));
  const r = await runMerge(savedFile(journey({ events: session(5000) })), current, "pc-2");
  if (!r.ok) throw new Error(r.reason);
  expect(sessions(r.journey)).toBe(2);
  expect(r.lastSeen).toBe(5120);
});

test("uploads the merge can't take are rejected with a reason", async () => {
  const cases: [Uint8Array, RegExp][] = [
    [savedFile(journey({ seeded: true })), /seeded/],
    [savedFile(journey({ version: 4 })), /newer layout/],
    [savedFile(journey({ totals: 5 })), /damaged/],
    [new TextEncoder().encode("RoadToSixtyCharDB = { os.exit() }"), /./],
    [new TextEncoder().encode("SomethingElse = {}"), /no journey/],
  ];
  for (const [upload, why] of cases) {
    const r = await runMerge(upload, null, "pc-1");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(why);
  }
});

test("the runner stops itself over the memory or time limit", async () => {
  const upload = savedFile(journey({ events: session(1000) }));
  const memory = await runMerge(upload, null, "pc-1", { mb: 0.05, seconds: 30 });
  expect(memory).toMatchObject({ ok: false, reason: "over the memory limit" });
  const time = await runMerge(upload, null, "pc-1", { mb: 512, seconds: 0 });
  expect(time).toMatchObject({ ok: false, reason: "over the time limit" });
});

test("a runner that never ends is killed", async () => {
  const started = Date.now();
  const r = await runMerge(savedFile(journey()), null, "pc-1", { mb: 512, seconds: 1 }, `${import.meta.dir}/fixtures/hang.lua`);
  expect(r).toMatchObject({ ok: false, reason: "the merge didn't finish in time and was stopped" });
  expect(Date.now() - started).toBeLessThan(10_000);
});
```

Run: `cd apps/server && LUA51=<PUC Lua 5.1, e.g. the scratchpad's lua-5.1.5/src/lua> bun test test/lua.test.ts; cd ../..`
Expected: an error that `../src/lua` can't be found.

- [ ] **Step 2: The runner**

Create `apps/server/src/runner.lua`:

```lua
-- Merges a character's upload into its merged journey for the sync server
-- (#1), under standard Lua 5.1 with the addon's own files: the same
-- Prepare, tidy, Merge and Check the addon runs at login. src/lua.ts runs
-- it as a process of its own, given only the two files.
--
--   lua5.1 runner.lua <lua dir> <upload> <current or ""> <out> <pc> <max MB> <max seconds>
--
-- <upload> is the SavedVariables file a PC uploaded, <current> the
-- character's merged journey as Parse.Write text (none for a first
-- upload), <pc> the uploading device's ID. Writes the result to <out> as
-- Parse.Write text and prints one line, - for anything unknown:
--   ok <layout uploaded> <layout> <level> <played> <last seen>
--   rejected <layout uploaded> <reason>

local dir, uploadPath, currentPath, outPath, pc, maxMB, maxSeconds = ...

-- Data can't hold code, so only a fault in the merge could run away, but a
-- stuck merge must never hold up the worker: checked every 10,000
-- instructions, and lua.ts kills the process if even this fails.
-- ponytail: one huge string operation between checks can pass the memory
-- limit; the 32 MB upload limit bounds how far.
local started, limitKB, limitSeconds = os.clock(), tonumber(maxMB) * 1024, tonumber(maxSeconds)
debug.sethook(function()
    if collectgarbage("count") > limitKB then error("over the memory limit", 0) end
    if os.clock() - started > limitSeconds then error("over the time limit", 0) end
end, "", 10000)

-- Maps that aren't places (the cosmos, Azeroth, Kalimdor, the Eastern
-- Kingdoms), which ns.IsPlaceMap finds in game from the map type:
-- Tidy.Events drops "zone" events for them.
local NOT_PLACES = { [946] = true, [947] = true, [1414] = true, [1415] = true }
local function IsPlace(mapID) return mapID ~= nil and not NOT_PLACES[mapID] end

local function Read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local from = "-"

local function Run()
    local ns = {}
    for _, name in ipairs({ "Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua", "Merge.lua" }) do
        assert(loadfile(dir .. "/" .. name))("RoadToSixty", ns)
    end
    local function TidyUp(char)
        if not char.seeded then ns.Tidy.Runs(char) end
        ns.Tidy.Events(char, IsPlace)
        if not char.seeded then ns.Tidy.Guilds(char) end
    end

    local upload = ns.Parse.File(Read(uploadPath)).RoadToSixtyCharDB
    if type(upload) ~= "table" then error("the upload holds no journey", 0) end
    from = tostring(tonumber(upload.version) or "-")
    if upload.seeded then error("a seeded test journey", 0) end
    local why
    upload, why = ns.Merge.Prepare(upload, pc)
    if not upload then error(why, 0) end
    TidyUp(upload)
    local out = upload
    if currentPath ~= "" then
        local current = ns.Parse.Read(Read(currentPath))
        TidyUp(current)
        out, why = ns.Merge.Merge(current, upload)
        if not out then error(why, 0) end
        local passed, failed = ns.Merge.Check(current, upload, out)
        if not passed then error(failed, 0) end
    end
    local file = assert(io.open(outPath, "wb"))
    file:write(ns.Parse.Write(out))
    file:close()

    local level, last
    for l in pairs(out.levels or {}) do
        if type(l) == "number" and (not level or l > level) then level = l end
    end
    for _, e in ipairs(out.events) do
        if not last or e[1] > last then last = e[1] end
    end
    return ("ok %s %d %s %s %s"):format(from, out.version, tostring(level or "-"),
        tostring(tonumber(out.played) or "-"), tostring(last or "-"))
end

local ok, result = pcall(Run)
debug.sethook()
if ok then
    io.write(result, "\n")
else
    io.write("rejected ", from, " ", (tostring(result):gsub("\n", " ")), "\n")
end
```

Before going on, try `curl -s -A "RoadToSixty zone map generator" "https://wago.tools/db2/UiMap/csv?build=1.60.1.70245"`. If it returns CSV, check that the IDs with `Type` 2 or less are exactly 946, 947, 1414 and 1415, and fix `NOT_PLACES` and its comment if not. Otherwise ledger that wago.tools was still down.

- [ ] **Step 3: Running it from Bun**

Create `apps/server/src/lua.ts`:

```ts
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { config } from "./config";

export type Limits = { mb: number; seconds: number };
export const LIMITS: Limits = { mb: 512, seconds: 60 };

export type MergeResult =
  | {
      ok: true;
      from: number | null; // the layout the upload was saved in
      layout: number;
      level: number | null;
      played: number | null;
      lastSeen: number | null; // Unix seconds of the last event
      journey: Uint8Array; // Parse.Write text
    }
  | { ok: false; from: number | null; reason: string };

const num = (s: string | undefined) => (s === undefined || s === "-" ? null : Number(s));

// Runs runner.lua under standard Lua 5.1 as its own process, in a fresh
// folder holding only the upload and the current journey.
export async function runMerge(
  upload: Uint8Array,
  current: Uint8Array | null,
  pc: string,
  limits: Limits = LIMITS,
  runner = `${import.meta.dir}/runner.lua`,
): Promise<MergeResult> {
  const dir = await mkdtemp(join(tmpdir(), "rts-merge-"));
  try {
    const uploadPath = join(dir, "upload.lua");
    const currentPath = join(dir, "current.lua");
    const outPath = join(dir, "out.lua");
    await Bun.write(uploadPath, upload);
    if (current) await Bun.write(currentPath, current);
    const args = [uploadPath, current ? currentPath : "", outPath, pc, String(limits.mb), String(limits.seconds)];
    const proc = Bun.spawn([config.lua51, runner, config.luaDir, ...args], {
      stdout: "pipe",
      stderr: "pipe",
      // The runner stops itself at the limit; this is for when it can't.
      timeout: limits.seconds * 1000 + 2000,
      killSignal: "SIGKILL",
    });
    const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    await proc.exited;
    // Bun sets proc.killed after any exit; a signal means it was stopped.
    if (proc.signalCode) return { ok: false, from: null, reason: "the merge didn't finish in time and was stopped" };
    const [word, from, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word === "ok") {
      const [layout, level, played, lastSeen] = rest;
      return {
        ok: true,
        from: num(from),
        layout: Number(layout),
        level: num(level),
        played: num(played),
        lastSeen: num(lastSeen),
        journey: new Uint8Array(await Bun.file(outPath).arrayBuffer()),
      };
    }
    if (word === "rejected") return { ok: false, from: num(from), reason: rest.join(" ") };
    const first = (stderr || stdout).trim().split("\n")[0];
    return { ok: false, from: null, reason: `the merge failed: ${first || `exit code ${proc.exitCode}`}` };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd apps/server && LUA51=<PUC Lua 5.1, e.g. the scratchpad's lua-5.1.5/src/lua> bun test test/lua.test.ts && bunx tsc --noEmit -p .; cd ../..`
Expected: `5 pass`, `0 fail`. The killed-runner test takes about 3 s.

Then break the limit on purpose: in `runner.lua`, change `> limitKB` to `> limitKB * 1e9`, run again, and expect `FAIL` on "the runner stops itself over the memory or time limit". Change it back.

- [ ] **Step 5: Commit**

```bash
git add apps/server
git commit -m "Server: merge an upload under standard Lua 5.1, in a process with limits (#1)

runner.lua runs the addon's own Prepare, tidy, Merge and Check, and
stops itself over its memory or time limit. Bun kills it if it can't.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The sync API and the merge worker

**Files:**
- Create: `apps/server/src/devices.ts`, `apps/server/src/sync.ts`, `apps/server/src/app.ts`, `apps/server/src/worker.ts`, `apps/server/src/index.ts`, `apps/server/scripts/new-device.ts`, `apps/server/test/sync.test.ts`

**Interfaces:**
- Consumes: Tasks 2 to 4; `@road-to-sixty/api` types.
- Produces: `newDevice(userId, name) -> { device, token }`, `deviceFor(authorization)`; `app` (Elysia) with `GET /health`, `POST /v1/upload`, `GET /v1/check`, `GET /v1/versions/:id`; `work() -> boolean`, `startWorker() -> stop`.

- [ ] **Step 1: Write the failing tests**

Create `apps/server/test/sync.test.ts`:

```ts
import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { eq } from "drizzle-orm";
import { app } from "../src/app";
import { db } from "../src/db";
import { newDevice } from "../src/devices";
import { characters, devices, versions } from "../src/schema";
import { pack, unpack } from "../src/storage";
import { work } from "../src/worker";
import { journey, savedFile, session, sessions } from "./helpers";
import { reset } from "./helpers";

beforeEach(reset);

const CHAR = { game: "_classic_beta_", realm: "Test Realm", name: "Ann" };

function call(token: string, path: string, init: RequestInit = {}) {
  return app.handle(
    new Request(`http://local${path}`, { ...init, headers: { authorization: `Bearer ${token}`, ...init.headers } }),
  );
}

async function upload(token: string, file: Uint8Array, extra: Record<string, string> = {}) {
  const query = new URLSearchParams({ ...CHAR, addon: "1.9.0", ...extra });
  return call(token, `/v1/upload?${query}`, { method: "POST", body: pack(file) });
}

const check = async (token: string) => (await (await call(token, "/v1/check")).json()) as CheckResponse;

async function workAll() {
  while (await work()) {}
}

test("a PC needs a token that is known and not revoked", async () => {
  expect((await app.handle(new Request("http://local/v1/check"))).status).toBe(401);
  expect((await call("nope", "/v1/check")).status).toBe(401);
  const { device, token } = await newDevice("user-1", "Desk");
  expect((await call(token, "/v1/check")).status).toBe(200);
  await db.update(devices).set({ revokedAt: new Date() }).where(eq(devices.id, device.id));
  expect((await call(token, "/v1/check")).status).toBe(401);
});

test("an upload is refused when it isn't zstd, is too large, or is compiled Lua", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const query = new URLSearchParams(CHAR);
  expect((await call(token, `/v1/upload?${query}`, { method: "POST", body: "plain text" })).status).toBe(413);
  expect((await call(token, `/v1/upload?${query}`, { method: "POST", body: pack(new Uint8Array(33 * 1024 * 1024)) })).status).toBe(413);
  expect((await upload(token, new Uint8Array([0x1b, 0x4c, 0x75, 0x61]))).status).toBe(400);
  expect((await call(token, "/v1/upload", { method: "POST", body: pack(savedFile(journey())) })).status).toBe(400);
});

test("the first upload becomes the character's journey, and the same file again is known", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const file = savedFile(journey({ events: session(1000), levels: { 4: { t: 900 } }, played: 600 }));
  const first = (await (await upload(token, file)).json()) as UploadResponse;
  expect(first.status).toBe("queued");
  expect(((await (await upload(token, file)).json()) as UploadResponse).status).toBe("known");
  expect((await check(token)).characters).toEqual([]); // nothing merged yet

  await workAll();
  const [entry] = (await check(token)).characters;
  expect(entry).toMatchObject({ ...CHAR, replace: false, updateAddon: false });
  const [c] = await db.select().from(characters);
  expect(c).toMatchObject({ level: 4, played: 600, headVersionId: entry!.version });

  const download = await call(token, `/v1/versions/${entry!.version}`);
  expect(download.headers.get("content-type")).toBe("application/zstd");
  expect(sessions(unpack(new Uint8Array(await download.arrayBuffer())))).toBe(1);
});

test("two PCs' play becomes one journey that both can download, and only their own user's", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  const other = await newDevice("user-2", "Elsewhere");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(laptop.token, savedFile(journey({ events: session(5000) })));
  await workAll();

  const [entry] = (await check(laptop.token)).characters;
  const text = unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer()));
  expect(sessions(text)).toBe(2);
  expect((await call(other.token, `/v1/versions/${entry!.version}`)).status).toBe(404);
  expect((await check(other.token)).characters).toEqual([]);
  const parents = await db.select().from(versions).where(eq(versions.kind, "merged"));
  expect(parents).toHaveLength(2);
});

test("an upload the merge refuses is rejected with its reason, and the journey stays", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const before = (await check(token)).characters[0]!.version;
  await upload(token, savedFile(journey({ events: session(5000), seeded: true })));
  await workAll();
  const [rejected] = await db.select().from(versions).where(eq(versions.status, "rejected"));
  expect(rejected?.rejectReason).toMatch(/seeded/);
  expect((await check(token)).characters[0]!.version).toBe(before);
});

test("a PC whose addon writes an older layout is told to update instead of given a newer one", async () => {
  const fresh = await newDevice("user-1", "Desk");
  const old = await newDevice("user-1", "Old laptop");
  await upload(fresh.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(old.token, savedFile(journey({ version: 2, events: session(5000) })));
  await workAll();
  expect((await check(fresh.token)).characters[0]).toMatchObject({ updateAddon: false });
  expect((await check(old.token)).characters[0]).toMatchObject({ version: null, updateAddon: true });
});

test("a restore is delivered as a replace, and an upload made before it arrived doesn't undo it", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const merged = (await check(token)).characters[0]!;
  // The website's restore (a later step) adds a version like this.
  const [c] = await db.select().from(characters);
  const [restore] = await db
    .insert(versions)
    .values({ characterId: c!.id, kind: "restore", fingerprint: merged.fingerprint, rawSize: 1, dataVersion: 3, status: "accepted" })
    .returning();
  await db.update(characters).set({ headVersionId: restore!.id });
  expect((await check(token)).characters[0]).toMatchObject({ version: restore!.id, replace: true });

  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] })), { received: String(merged.version) });
  await workAll();
  const [superseded] = await db.select().from(versions).where(eq(versions.status, "superseded"));
  expect(superseded?.deviceId).toBe(device.id);
  expect((await check(token)).characters[0]!.version).toBe(restore!.id);
});
```

Run: `cd apps/server && LUA51=<PUC Lua 5.1, e.g. the scratchpad's lua-5.1.5/src/lua> bun test test/sync.test.ts; cd ../..`
Expected: an error that `../src/app` can't be found.

- [ ] **Step 2: PC tokens**

Create `apps/server/src/devices.ts`:

```ts
import { and, eq, isNull } from "drizzle-orm";
import { db } from "./db";
import { devices } from "./schema";

export type Device = typeof devices.$inferSelect;

const hash = (token: string) => new Bun.CryptoHasher("sha256").update(token).digest("hex");

// A new linked PC with a random token, which is shown once and stored only
// as its hash. Stands in for Better Auth's device sign-in until it is built.
export async function newDevice(userId: string, name: string): Promise<{ device: Device; token: string }> {
  const token = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
  const [device] = await db.insert(devices).values({ id: crypto.randomUUID(), userId, name, tokenHash: hash(token) }).returning();
  return { device: device!, token };
}

// The PC an Authorization: Bearer header belongs to, unless revoked.
export async function deviceFor(authorization: string | undefined): Promise<Device | null> {
  const token = authorization?.match(/^Bearer (\S+)$/)?.[1];
  if (!token) return null;
  const [device] = await db.select().from(devices).where(and(eq(devices.tokenHash, hash(token)), isNull(devices.revokedAt)));
  return device ?? null;
}
```

`apps/server/scripts/new-device.ts`:

```ts
// Links a PC by hand until sign-in exists: prints its token once.
//   bun scripts/new-device.ts <user id> <PC name>
import { client } from "../src/db";
import { newDevice } from "../src/devices";

const [userId, name] = process.argv.slice(2);
if (!userId || !name) throw new Error("usage: bun scripts/new-device.ts <user id> <PC name>");
const { device, token } = await newDevice(userId, name);
console.log(`PC ${device.id} for ${userId}. Its token, shown only now:\n${token}`);
await client.close();
```

- [ ] **Step 3: The API**

Create `apps/server/src/sync.ts`:

```ts
import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { and, eq, inArray } from "drizzle-orm";
import { Elysia } from "elysia";
import { db } from "./db";
import { deviceFor } from "./devices";
import { characters, devices, jobs, versions } from "./schema";
import { fingerprint, getPacked, put, unpack } from "./storage";

// The sync API the app calls with its PC token (spec, "Sync API").
export const sync = new Elysia({ prefix: "/v1" })
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
      .set({ lastSeenAt: new Date(), ...(query.addon ? { addonVersion: query.addon } : {}) })
      .where(eq(devices.id, device!.id));
  })

  // A character's SavedVariables file, zstd-compressed. Stored at once; a
  // job merges it.
  .post(
    "/upload",
    async ({ device, query, request, set }): Promise<UploadResponse | { error: string }> => {
      const { game, realm, name, addon, received } = query;
      if (!game || !realm || !name) {
        set.status = 400;
        return { error: "game, realm and name are required" };
      }
      const packed = new Uint8Array(await request.arrayBuffer());
      let raw: Uint8Array;
      try {
        raw = unpack(packed);
      } catch {
        set.status = 413;
        return { error: "not zstd, or over 32 MB uncompressed" };
      }
      if (raw[0] === 0x1b) {
        set.status = 400;
        return { error: "compiled Lua is refused" };
      }
      const userId = device!.userId;
      await db.insert(characters).values({ userId, game, realm, name }).onConflictDoNothing();
      const [character] = await db
        .select()
        .from(characters)
        .where(and(eq(characters.userId, userId), eq(characters.game, game), eq(characters.realm, realm), eq(characters.name, name)));
      const fp = fingerprint(raw);
      const [known] = await db
        .select({ id: versions.id })
        .from(versions)
        .where(and(eq(versions.characterId, character!.id), eq(versions.fingerprint, fp)));
      if (known) return { version: known.id, status: "known" };

      const [last] = received
        ? await db
            .select({ id: versions.id })
            .from(versions)
            .where(and(eq(versions.characterId, character!.id), eq(versions.id, Number(received) || 0)))
        : [];
      await put(userId, fp, packed);
      const id = await db.transaction(async (tx) => {
        const [version] = await tx
          .insert(versions)
          .values({
            characterId: character!.id,
            deviceId: device!.id,
            kind: "upload",
            fingerprint: fp,
            rawSize: raw.length,
            addonVersion: addon ?? null,
            receivedId: last?.id ?? null,
            status: "pending",
          })
          .returning({ id: versions.id });
        await tx.insert(jobs).values({ characterId: character!.id, versionId: version!.id });
        return version!.id;
      });
      return { version: id, status: "queued" };
    },
    { parse: "none" },
  )

  // The newest version of every character of this user, from any PC.
  .get("/check", async ({ device }): Promise<CheckResponse> => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .innerJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    return {
      characters: rows.map(({ c, head }) => {
        // Never a layout newer than this PC's addon writes (spec, "Mismatched
        // addon versions"). A PC that hasn't uploaded yet is unknown; its
        // addon refuses a newer layout itself.
        const updateAddon = device!.dataLayout !== null && (head.dataVersion ?? 0) > device!.dataLayout;
        return {
          game: c.game,
          realm: c.realm,
          name: c.name,
          version: updateAddon ? null : head.id,
          fingerprint: head.fingerprint,
          replace: head.kind === "restore",
          updateAddon,
        };
      }),
    };
  })

  // One merged or restored version, as stored: zstd-compressed Parse.Write text.
  .get("/versions/:id", async ({ device, params, set }) => {
    const [row] = await db
      .select({ v: versions, userId: characters.userId })
      .from(versions)
      .innerJoin(characters, eq(characters.id, versions.characterId))
      .where(and(eq(versions.id, Number(params.id)), inArray(versions.kind, ["merged", "restore"])));
    if (!row || row.userId !== device!.userId) {
      set.status = 404;
      return { error: "no such version" };
    }
    return new Response(await getPacked(row.userId, row.v.fingerprint), { headers: { "content-type": "application/zstd" } });
  });
```

`apps/server/src/app.ts`:

```ts
import { Elysia } from "elysia";
import { sync } from "./sync";

export const app = new Elysia().get("/health", () => "ok").use(sync);
```

- [ ] **Step 4: The worker and the entry point**

Create `apps/server/src/worker.ts`:

```ts
import { and, desc, eq } from "drizzle-orm";
import { client, db } from "./db";
import { runMerge } from "./lua";
import { characters, devices, jobs, versionParents, versions } from "./schema";
import { fingerprint, get, pack, put } from "./storage";

type Job = typeof jobs.$inferSelect;
type Version = typeof versions.$inferSelect;

const MAX_ATTEMPTS = 3;

// The oldest queued job's id, now marked running, or null.
// ponytail: one worker taking one job at a time, which also keeps two
// uploads of one character from merging at once; take a lock per
// character if more workers ever run.
async function claim(): Promise<number | null> {
  const [row] = await client`
    UPDATE jobs SET state = 'running', attempts = attempts + 1
    WHERE id = (SELECT id FROM jobs WHERE state = 'queued' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
    RETURNING id`;
  return row ? Number(row.id) : null;
}

async function settle(job: Job, upload: Version, status: "accepted" | "rejected" | "superseded", reason?: string) {
  await db.transaction(async (tx) => {
    await tx.update(versions).set({ status, rejectReason: reason ?? null }).where(eq(versions.id, upload.id));
    await tx
      .update(jobs)
      .set({ state: status === "rejected" ? "failed" : "done", error: reason ?? null, finishedAt: new Date() })
      .where(eq(jobs.id, job.id));
  });
}

// Merges one upload into its character's journey (spec, "Merge jobs").
async function runJob(job: Job) {
  const [upload] = await db.select().from(versions).where(eq(versions.id, job.versionId));
  const [character] = await db.select().from(characters).where(eq(characters.id, job.characterId));
  if (!upload || !character) throw new Error(`job ${job.id} has no upload or character`);

  // An upload from a PC that hadn't yet received the latest restore still
  // holds what the restore took out; merging it would undo the restore.
  const [restore] = await db
    .select({ id: versions.id })
    .from(versions)
    .where(and(eq(versions.characterId, character.id), eq(versions.kind, "restore")))
    .orderBy(desc(versions.id))
    .limit(1);
  if (restore && upload.receivedId !== null && upload.receivedId < restore.id) {
    return settle(job, upload, "superseded", "made before the restore reached this PC");
  }

  const [head] = character.headVersionId
    ? await db.select().from(versions).where(eq(versions.id, character.headVersionId))
    : [];
  const result = await runMerge(
    await get(character.userId, upload.fingerprint),
    head ? await get(character.userId, head.fingerprint) : null,
    upload.deviceId ?? "server",
  );
  if (result.from !== null && upload.deviceId) {
    await db.update(devices).set({ dataLayout: result.from }).where(eq(devices.id, upload.deviceId));
  }
  if (!result.ok) return settle(job, upload, "rejected", result.reason);

  const fp = fingerprint(result.journey);
  if (head && fp === head.fingerprint) return settle(job, upload, "accepted"); // nothing new in it
  await put(character.userId, fp, pack(result.journey));
  await db.transaction(async (tx) => {
    const [merged] = await tx
      .insert(versions)
      .values({
        characterId: character.id,
        kind: "merged",
        fingerprint: fp,
        rawSize: result.journey.length,
        dataVersion: result.layout,
        status: "accepted",
      })
      .returning({ id: versions.id });
    await tx
      .insert(versionParents)
      .values([upload.id, ...(head ? [head.id] : [])].map((parentId) => ({ versionId: merged!.id, parentId })));
    await tx
      .update(characters)
      .set({
        headVersionId: merged!.id,
        level: result.level,
        played: result.played === null ? null : Math.round(result.played),
        lastPlayedAt: result.lastSeen === null ? null : new Date(result.lastSeen * 1000),
        updatedAt: new Date(),
      })
      .where(eq(characters.id, character.id));
    await tx.update(versions).set({ status: "accepted", dataVersion: result.from }).where(eq(versions.id, upload.id));
    await tx.update(jobs).set({ state: "done", finishedAt: new Date() }).where(eq(jobs.id, job.id));
  });
}

// Runs the oldest queued job. False when there was none. A job that throws
// (storage down, say) goes back in the queue, up to MAX_ATTEMPTS.
export async function work(): Promise<boolean> {
  const id = await claim();
  if (id === null) return false;
  const [job] = await db.select().from(jobs).where(eq(jobs.id, id));
  try {
    await runJob(job!);
  } catch (e) {
    const error = String(e);
    if (job!.attempts >= MAX_ATTEMPTS) {
      await db.update(jobs).set({ state: "failed", error, finishedAt: new Date() }).where(eq(jobs.id, id));
      await db
        .update(versions)
        .set({ status: "rejected", rejectReason: "the server couldn't merge it" })
        .where(eq(versions.id, job!.versionId));
    } else {
      await db.update(jobs).set({ state: "queued", error }).where(eq(jobs.id, id));
    }
  }
  return true;
}

// Works through the queue until stopped, checking each second when empty.
export function startWorker(): () => void {
  let stopped = false;
  void (async () => {
    // A job left running by a crash or restart goes back in the queue.
    await db.update(jobs).set({ state: "queued" }).where(eq(jobs.state, "running"));
    while (!stopped) {
      const worked = await work().catch((e) => {
        console.error("worker:", e);
        return false;
      });
      if (!worked) await Bun.sleep(1000);
    }
  })();
  return () => {
    stopped = true;
  };
}
```

`apps/server/src/index.ts`:

```ts
import { app } from "./app";
import { config } from "./config";
import { migrateDb } from "./db";
import { startWorker } from "./worker";

await migrateDb();
startWorker();
// 32 MB uncompressed is the most an upload may hold; compressed it is smaller.
app.listen({ port: config.port, maxRequestBodySize: 33 * 1024 * 1024 });
console.log(`Road to Sixty server on port ${config.port}`);
```

- [ ] **Step 5: Run every server test**

Run: `cd apps/server && LUA51=<PUC Lua 5.1, e.g. the scratchpad's lua-5.1.5/src/lua> bun test && bunx tsc --noEmit -p .; cd ../..`
Expected: `14 pass`, `0 fail` across 3 files, and no type errors.

Then break the restore rule on purpose: in `worker.ts`, change `upload.receivedId < restore.id` to `upload.receivedId > restore.id`, run `bun test test/sync.test.ts`, and expect the restore test to fail. Change it back.

- [ ] **Step 6: Try it by hand**

```bash
cd apps/server && cp .env.test .env && bun run device:new user-1 Desk
bun src/index.ts &   # Road to Sixty server on port 3000
curl -s localhost:3000/health; curl -s -H "authorization: Bearer <the token>" localhost:3000/v1/check
kill %1; rm .env; cd ../..
```
Expected: `ok`, then `{"characters":[]}`.

- [ ] **Step 7: Commit**

```bash
git add apps/server
git commit -m "Server: upload, check and download, and the worker that merges uploads (#1)

An upload is stored at once and queued. The worker merges it into the
character's journey, or rejects it with the merge's reason, and an
upload made before a restore reached its PC is set aside so it can't
undo the restore. A PC token made by a script stands in for sign-in.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The image, CI and the docs

**Files:**
- Create: `apps/server/Dockerfile`, `.dockerignore`, `apps/server/scripts/smoke.ts`
- Modify: `.github/workflows/ci.yml`, `CLAUDE.md`, `README.md`

- [ ] **Step 1: The image**

Create `apps/server/Dockerfile`:

```dockerfile
# The sync server's image (#1): Bun, standard Lua 5.1 for the merge, and
# the addon's shared Lua files. Dokploy builds it from the repo root:
#   docker build -f apps/server/Dockerfile .
FROM oven/bun:1.4.2
RUN apt-get update && apt-get install -y --no-install-recommends lua5.1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# Every workspace's package.json, so the frozen lockfile matches.
COPY package.json bun.lock ./
COPY apps/addon/package.json apps/addon/
COPY apps/server/package.json apps/server/
COPY packages/api/package.json packages/api/
RUN bun install --frozen-lockfile --production
COPY packages/api packages/api
COPY apps/server apps/server
COPY apps/addon/RoadToSixty/Packed.lua apps/addon/RoadToSixty/Tidy.lua apps/addon/RoadToSixty/Parse.lua \
     apps/addon/RoadToSixty/Tally.lua apps/addon/RoadToSixty/Merge.lua /app/lua/
ENV NODE_ENV=production LUA51=lua5.1 LUA_DIR=/app/lua PORT=3000
USER bun
EXPOSE 3000
CMD ["bun", "apps/server/src/index.ts"]
```

`.dockerignore`:

```
**/node_modules
**/.turbo
**/.env
.git
.superpowers
apps/addon/build
apps/addon/dist
```

`apps/server/scripts/smoke.ts`:

```ts
// Checks a built image can merge: Lua 5.1, the runner and the addon's files
// are all where the server looks. CI runs it inside the image.
import { runMerge } from "../src/lua";

const upload = new TextEncoder().encode('RoadToSixtyCharDB = {["version"] = 3, ["events"] = {{100, "on"}}}');
const result = await runMerge(upload, null, "smoke");
console.log(result.ok ? `merge ok, layout ${result.layout}` : `merge failed: ${result.reason}`);
process.exit(result.ok ? 0 : 1);
```

Run:

```bash
docker build -q -f apps/server/Dockerfile -t rts-server .
docker run --rm -e DATABASE_URL=unused -e S3_ENDPOINT=unused -e S3_BUCKET=unused -e S3_ACCESS_KEY_ID=unused -e S3_SECRET_ACCESS_KEY=unused rts-server bun apps/server/scripts/smoke.ts
docker run -d --rm --name rts-server-smoke -p 53000:3000 -e DATABASE_URL=postgres://rts:rts@host.docker.internal:55432/rts -e S3_ENDPOINT=http://host.docker.internal:58333 -e S3_BUCKET=journeys-test -e S3_ACCESS_KEY_ID=local -e S3_SECRET_ACCESS_KEY=local rts-server
sleep 4; curl -s localhost:53000/health; curl -s -o /dev/null -w "%{{http_code}}\n" localhost:53000/v1/check; docker stop rts-server-smoke
```
Expected: `merge ok, layout 3`, then `ok` and `401`.

- [ ] **Step 2: CI**

Apply this to `.github/workflows/ci.yml`:

```diff
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index 2b75ace..cc9e9f1 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -30,7 +30,7 @@ jobs:
         run: bun run check
 
       - name: Tests under LuaJIT and Lua 5.1
-        run: bun run test
+        run: bun run test --filter=@road-to-sixty/addon
 
       - name: Release build
         id: package
@@ -44,3 +44,39 @@ jobs:
         with:
           name: RoadToSixty-${{ steps.package.outputs.version }}
           path: apps/addon/build/
+
+  # The sync server: its tests against Postgres and an S3 store, then the
+  # image Dokploy deploys, checked to merge with Lua 5.1 inside it.
+  server:
+    runs-on: ubuntu-latest
+    steps:
+      - uses: actions/checkout@v4
+
+      - uses: oven-sh/setup-bun@v2
+        with:
+          bun-version: 1.4.2
+
+      - name: Install Lua 5.1
+        run: sudo apt-get update && sudo apt-get install -y lua5.1
+
+      - name: Install
+        run: bun install --frozen-lockfile
+
+      - name: Start Postgres and S3
+        run: docker compose -f apps/server/docker-compose.yml up -d --wait
+
+      - name: Typecheck
+        run: bun run typecheck
+
+      - name: Server tests
+        working-directory: apps/server
+        run: bun test
+
+      - name: Image
+        run: docker build -f apps/server/Dockerfile -t rts-server .
+
+      - name: The image can merge
+        run: >
+          docker run --rm -e DATABASE_URL=unused -e S3_ENDPOINT=unused -e S3_BUCKET=unused
+          -e S3_ACCESS_KEY_ID=unused -e S3_SECRET_ACCESS_KEY=unused
+          rts-server bun apps/server/scripts/smoke.ts
```

- [ ] **Step 3: Docs**

Apply this to `CLAUDE.md` and `README.md`:

```diff
diff --git a/CLAUDE.md b/CLAUDE.md
index 3352735..64cc89b 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -45,6 +45,14 @@ for data, its exact format; read that before changing a module.
 | MinimapTiles.lua, ZoneOverlays.lua, ZoneMasks/ | generated data, do not edit by hand (the MinimapTiles.lua generator is not in the repo) |
 | Probe.lua, Seed.lua, Swatch.lua, IconBrowser.lua, GuildProbe.lua, PartyProbe.lua, LevelProbe.lua, MountProbe.lua, PortraitProbe.lua | developer tools, left out of releases |
 
+`apps/server/` is the sync server (#1): Elysia on Bun, Postgres through
+Drizzle, an S3 store (R2 in production). `src/sync.ts` is the API the app
+calls, `src/worker.ts` runs the merge jobs, `src/runner.lua` merges under
+standard Lua 5.1 with the addon's pure files, and `src/schema.ts` holds the
+tables (migrations in `drizzle/`, made by `bun run db:generate`).
+`packages/api/` holds the request and response types the server, website
+and app share.
+
 Saved variables: `RoadToSixtyDB` (account) and `RoadToSixtyCharDB`
 (per character). Its `version` is `DATA_VERSION` in Core.lua: bump it at
 every change to what is saved or what it means, list the change there, and
@@ -58,6 +66,7 @@ last loaded the file.
 bun install                         # once, for turbo
 bun run test                        # every addon test under LuaJIT, and under Lua 5.1 if installed
 bun run check                       # check.ps1 through turbo (needs PowerShell)
+bun run typecheck                   # TypeScript in the server and packages
 
 # From apps/addon
 ./check.ps1                         # LuaJIT syntax check, LuaLS diagnostics, offline tests (tests/*_test.lua)
@@ -65,6 +74,12 @@ bun run check                       # check.ps1 through turbo (needs PowerShell)
 ./scripts/sync-version.ps1          # set the toc Interface from the installed client after a patch
 python scripts/zone-overlays.py <build>   # regenerate ZoneOverlays.lua and ZoneMasks/ (needs Pillow)
 luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]   # a sync folder by hand, to try the login merge
+
+# From apps/server (Docker running)
+docker compose up -d                # Postgres and an S3 store, for the tests and a local server
+bun test                            # server tests; LUA51 names Lua 5.1 if lua5.1 isn't on the path
+bun run dev                         # the server on port 3000, with .env (copied from .env.example)
+bun run device:new <user> <PC name> # link a PC by hand until sign-in exists; prints its token once
 ```
 
 Run the addon commands from `apps/addon/`. `check.ps1` currently reports three old
diff --git a/README.md b/README.md
index f61e943..53739a7 100644
--- a/README.md
+++ b/README.md
@@ -13,8 +13,9 @@ Needs [LuaJIT](https://luajit.org/) on the path. [Lua Language Server](https://l
 is optional; when installed, `check.ps1` also reports its diagnostics.
 
 The repo is a Bun and Turborepo workspace: `bun install`, then `bun run test` at
-the root runs every addon test. The addon's own commands below run from
-`apps/addon/`.
+the root runs every test. The addon's own commands below run from
+`apps/addon/`. The sync server in `apps/server/` needs Docker for its tests
+(`docker compose up -d` there first) and standard Lua 5.1.
 
 ```powershell
 ./check.ps1                      # syntax check, diagnostics, offline tests
```

- [ ] **Step 4: Every test, then commit and merge**

Run: `LUA51=<PUC Lua 5.1, e.g. the scratchpad's lua-5.1.5/src/lua> bun run test && bun run typecheck`
Expected: the addon's 21 test files under both runtimes, `14 pass` from the server, and both typechecks successful.

```bash
git add apps/server/Dockerfile .dockerignore apps/server/scripts/smoke.ts .github/workflows/ci.yml CLAUDE.md README.md
git commit -m "Server: the image Dokploy deploys, and CI for it (#1)

CI runs the server's tests against Postgres and SeaweedFS, builds the
image, and runs a merge inside it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

The CI run needs the branch on GitHub. After the final review, merge into `dev`, push `dev`, and watch both jobs:

```bash
gh run list --branch dev --workflow CI --limit 1
gh run watch <id> --exit-status
```
Expected: `build` and `server` both pass, and `server`'s log shows `14 pass` and `merge ok, layout 3`.

---

## Notes for later steps

- **Sign-in (the next plan):** Better Auth with Battle.net and device sign-in. It replaces `devices.tokenHash` and `scripts/new-device.ts`, and adds `user` tables. `devices.userId` and `characters.userId` become foreign keys to its user id. Needs from Jordan: a Battle.net developer client (ID and secret), an R2 bucket with an access key, and the `everhold.online` subdomain.
- **The account API** (website): list characters and versions, restore (creates a `restore` version whose fingerprint is the restored one's), unlink PCs, download everything, delete. The worker already handles restores.
- **Deploying:** Dokploy builds `apps/server/Dockerfile` from the repo root with `DATABASE_URL`, `S3_*` and `PORT` set. R2's bucket is made once by hand.
- **The daily cleanup** (keep 30 days, then weekly) and account backups are separate later pieces.
- **`NOT_PLACES`** should be checked against wago.tools' `UiMap` if Task 4 couldn't.

