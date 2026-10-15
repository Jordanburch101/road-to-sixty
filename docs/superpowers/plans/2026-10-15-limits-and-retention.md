# Upload Limits and Version Clean-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Limit what one PC or account can send the sync server, and thin out stored journey versions to every version from the last 30 days plus one a week.

**Architecture:** Limits live in the server's request path: an in-memory sliding window per PC (`src/limits.ts`) checked in `pcRoutes` and the upload route, size and field caps in the upload route, and folding of queued uploads inside the upload's transaction. The clean-up is a daily job (`src/prune.ts`) started next to the merge worker; it marks one version per finished week, deletes files no kept version needs, and stamps `versions.pruned_at`, keeping every row. History and downloads skip pruned versions.

**Tech Stack:** Bun, Elysia, Drizzle and postgres.js on Postgres 17, Bun's S3 client (R2 in production, SeaweedFS in tests), `bun test`.

**Spec:** `docs/superpowers/specs/2026-10-15-limits-and-retention-design.md`

## Global Constraints

- Body cap 8 MB compressed (`MAX_PACKED = 8 * 1024 * 1024`), answered 413.
- `game`, `realm`, `name`, `addon` at most 64 characters, else 400.
- Uploads: at most 30 per PC in any 15 minutes; all `/v1/*` requests: at most 600 per PC an hour; both answer 429 with `Retry-After` in seconds.
- At most 100 characters per account; a new 101st answers 422 with the plain-text body `This account has reached 100 characters`.
- Keep every merged and restored version from the last 30 days; older, the newest per finished calendar week (Monday to Sunday, UTC) is kept for good; uploads' files go once their merge has finished.
- Never delete: a character's head, an upload with a `queued` or `running` job, a file an unpruned version of the same account shares.
- Rows are never deleted by the clean-up; `pruned_at` marks a version whose file is gone.
- `PRUNE` setting: `dry` (default), `on`, `off`.
- History: newest 100 unpruned merged or restored versions, then every older `weekly` one, newest first.
- Comments are plain sentences that say why; British spelling. Commit subjects `Area: what changed (#40)` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests use made-up journeys only (`test/helpers.ts`); never a real save.

## Review Focus

1. A player logging through many alts after a long time offline sends more than 30 uploads in 15 minutes: the extra uploads get 429, the app retries them next pass, and nothing is lost. (Task 1 test: refused at 31, allowed once the window moves.)
2. The clean-up deletes a file at the same moment an upload or merge stores an identical file for the same account: the new version's file can go missing. The merge then retries, fails as `SERVER_FAILED`, and the app sends the file again, which stores it again. Accepted as self-healing; the reviewer should confirm no path leaves a head without its file. (Task 4 notes it in a `ponytail:` comment.)
3. A character not played for months: its head is older than 30 days and must stay, and History must still list it. (Task 4 test: the head stays at any age; Task 5 test lists it.)
4. A restore row whose file was pruned must still strip its stretches from a stale upload. (Task 5 test.)
5. A week boundary in a timezone other than UTC: the weekly pick must use UTC weeks so two runs never disagree. (Task 4 test with dates on a Sunday 23:00 and Monday 01:00 UTC.)

---

### Task 1: Rate limits per PC

**Files:**
- Create: `apps/server/src/limits.ts`
- Modify: `apps/server/src/pc.ts`
- Modify: `apps/server/src/sync.ts` (the upload handler's start)
- Modify: `apps/server/test/helpers.ts` (`reset`)
- Create: `apps/server/test/limits.test.ts`
- Test: `apps/server/test/sync.test.ts`

**Interfaces:**
- Produces: `class Window { constructor(max: number, seconds: number, now?: () => number); take(key: string): boolean; retryAfter(key: string): number; clear(): void }`, and `export const uploads: Window` (30 per 900 s), `export const requests: Window` (600 per 3600 s).

- [ ] **Step 1: Write the failing unit tests**

`apps/server/test/limits.test.ts`:

```ts
import { expect, test } from "bun:test";
import { Window } from "../src/limits";

test("a window allows its maximum, refuses the next, and allows again once the oldest leaves", () => {
  let now = 0;
  const w = new Window(3, 60, () => now);
  expect([w.take("pc"), w.take("pc"), w.take("pc")]).toEqual([true, true, true]);
  expect(w.take("pc")).toBe(false);
  expect(w.retryAfter("pc")).toBe(60);
  now = 59_000;
  expect(w.take("pc")).toBe(false);
  expect(w.retryAfter("pc")).toBe(1);
  now = 60_001;
  expect(w.take("pc")).toBe(true);
});

test("each PC has its own count, and a refused try isn't counted", () => {
  let now = 0;
  const w = new Window(1, 60, () => now);
  expect(w.take("a")).toBe(true);
  expect(w.take("a")).toBe(false);
  expect(w.take("a")).toBe(false);
  expect(w.take("b")).toBe(true);
  now = 60_001;
  expect(w.take("a")).toBe(true);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && bun test test/limits.test.ts`
Expected: FAIL, cannot find module `../src/limits`.

- [ ] **Step 3: Write `src/limits.ts`**

```ts
// How often one PC may call the server (spec, "Limits"). The app uploads a
// character at most every 15 minutes while the game runs, so these only
// stop a runaway app or someone scripting the API.
// ponytail: counted in memory by one server process, so a restart forgets
// them and a second instance wouldn't share them; move to Postgres if the
// server ever runs twice.
export class Window {
  private hits = new Map<string, number[]>();

  constructor(
    readonly max: number,
    readonly seconds: number,
    private now: () => number = Date.now,
  ) {}

  // Counts the hit and says yes, or says no without counting it.
  take(key: string): boolean {
    const recent = this.recent(key);
    if (recent.length >= this.max) return false;
    recent.push(this.now());
    return true;
  }

  // Whole seconds until the oldest counted hit leaves the window.
  retryAfter(key: string): number {
    const oldest = this.recent(key)[0];
    return oldest === undefined ? 0 : Math.ceil((oldest + this.seconds * 1000 - this.now()) / 1000);
  }

  clear() {
    this.hits.clear();
  }

  private recent(key: string): number[] {
    const since = this.now() - this.seconds * 1000;
    const recent = (this.hits.get(key) ?? []).filter((t) => t > since);
    this.hits.set(key, recent);
    return recent;
  }
}

export const uploads = new Window(30, 15 * 60);
export const requests = new Window(600, 3600);
```

- [ ] **Step 4: Run the unit tests**

Run: `cd apps/server && bun test test/limits.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 5: Write the failing route tests**

Add to `apps/server/test/sync.test.ts` (import `uploads, requests` from `../src/limits`):

```ts
test("a PC that uploads too often is told to wait, and other PCs aren't", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  for (let i = 0; i < 30; i++) uploads.take(desk.device.id);
  const refused = await upload(desk.token, savedFile(journey({ events: session(1000) })));
  expect(refused.status).toBe(429);
  expect(Number(refused.headers.get("retry-after"))).toBeGreaterThan(0);
  expect((await upload(laptop.token, savedFile(journey({ events: session(1000) })))).status).toBe(200);
});

test("a PC that calls the server too often is told to wait on every route", async () => {
  const desk = await newDevice("user-1", "Desk");
  for (let i = 0; i < 600; i++) requests.take(desk.device.id);
  const refused = await call(desk.token, "/v1/check");
  expect(refused.status).toBe(429);
  expect(refused.headers.get("retry-after")).not.toBeNull();
  expect((await call(desk.token, "/v1/characters")).status).toBe(429);
});
```

- [ ] **Step 6: Run them to see them fail**

Run: `cd apps/server && LUA51=… bun test test/sync.test.ts -t "too often"`
Expected: FAIL, status 200 instead of 429.

- [ ] **Step 7: Check the limits in `pc.ts` and the upload route, and clear them in `reset`**

In `apps/server/src/pc.ts`, import `{ requests } from "./limits"` and add between the token check and the last-seen update:

```ts
    // A runaway app is told to wait instead of keeping the server busy.
    .onBeforeHandle(({ device, set }) => {
      if (!requests.take(device!.id)) {
        set.status = 429;
        set.headers["retry-after"] = String(requests.retryAfter(device!.id));
        return { error: "too many requests" };
      }
    })
```

In `apps/server/src/sync.ts`, import `{ uploads } from "./limits"` and make this the first statement of the upload handler:

```ts
      if (!uploads.take(device!.id)) {
        set.status = 429;
        set.headers["retry-after"] = String(uploads.retryAfter(device!.id));
        return { error: "too many uploads" };
      }
```

In `apps/server/test/helpers.ts` `reset()`, first line: `uploads.clear(); requests.clear();` (import both from `../src/limits`).

- [ ] **Step 8: Run the server tests**

Run: `cd apps/server && LUA51=… bun test`
Expected: PASS, every test.

- [ ] **Step 9: Commit**

```bash
git add apps/server/src/limits.ts apps/server/src/pc.ts apps/server/src/sync.ts apps/server/test
git commit -m "Server: limit how often one PC can call and upload (#40)"
```

### Task 2: Size, field and character caps

**Files:**
- Modify: `apps/server/src/storage.ts` (add `MAX_PACKED`)
- Modify: `apps/server/src/index.ts` (`maxRequestBodySize`)
- Modify: `apps/server/src/sync.ts` (upload handler)
- Test: `apps/server/test/sync.test.ts`

**Interfaces:**
- Consumes: Task 1's upload handler start.
- Produces: `export const MAX_PACKED = 8 * 1024 * 1024` in `storage.ts`; `MAX_FIELD = 64` and `MAX_CHARACTERS = 100` local to `sync.ts`.

- [ ] **Step 1: Write the failing tests**

Add to `apps/server/test/sync.test.ts` (import `MAX_PACKED` from `../src/storage`, `characters` is already imported):

```ts
test("an upload over 8 MB compressed is refused before it is unpacked", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const r = await call(token, `/v1/upload?${new URLSearchParams(CHAR)}`, { method: "POST", body: new Uint8Array(MAX_PACKED + 1) });
  expect(r.status).toBe(413);
  expect(await r.json()).toEqual({ error: "over 8 MB compressed" });
});

test("a character, realm, game or addon name over 64 characters is refused", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const file = savedFile(journey({ events: session(1000) }));
  for (const field of ["game", "realm", "name", "addon"]) {
    expect((await upload(token, file, { [field]: "x".repeat(65) })).status).toBe(400);
  }
  expect((await upload(token, file, { name: "x".repeat(64) })).status).toBe(200);
});

test("an account can have 100 characters; a new one after that is refused, the others still upload", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await db
    .insert(characters)
    .values(Array.from({ length: 99 }, (_, i) => ({ userId: device.userId, game: CHAR.game, realm: CHAR.realm, name: `Alt${i}` })));
  const file = savedFile(journey({ events: session(1000) }));
  expect((await upload(token, file)).status).toBe(200); // the 100th
  const refused = await upload(token, file, { name: "OneTooMany" });
  expect(refused.status).toBe(422);
  expect(await refused.text()).toBe("This account has reached 100 characters");
  expect((await upload(token, savedFile(journey({ events: session(2000) })), { name: "Alt5" })).status).toBe(200);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=… bun test test/sync.test.ts -t "8 MB|64 characters|100 characters"`
Expected: FAIL (413 with the zstd message, 200 for long names, 200 for the 101st).

- [ ] **Step 3: Implement**

`apps/server/src/storage.ts`, after `MAX_RAW`:

```ts
// The most an upload may send compressed. A 32 MB journey compresses far
// below this, so anything bigger isn't a journey.
export const MAX_PACKED = 8 * 1024 * 1024;
```

`apps/server/src/index.ts`: import `MAX_PACKED` from `./storage`, replace the comment and call with:

```ts
// Bun refuses a bigger body before reading it (413).
app.listen({ port: config.port, maxRequestBodySize: MAX_PACKED });
```

`apps/server/src/sync.ts`, at the top level:

```ts
const MAX_FIELD = 64;
const MAX_CHARACTERS = 100;
```

In the upload handler, after the `game, realm and name are required` check:

```ts
      if ([game, realm, name, addon].some((v) => v !== undefined && v.length > MAX_FIELD)) {
        set.status = 400;
        return { error: `game, realm, name and addon are at most ${MAX_FIELD} characters` };
      }
```

Right after reading `packed`, before `unpack`:

```ts
      // Bun stops a bigger body in production; this also covers a body sent without its length.
      if (packed.length > MAX_PACKED) {
        set.status = 413;
        return { error: "over 8 MB compressed" };
      }
```

Replace the `insert(characters)...onConflictDoNothing()` line with:

```ts
      const [existing] = await db
        .select({ id: characters.id })
        .from(characters)
        .where(and(eq(characters.userId, userId), eq(characters.game, game), eq(characters.realm, realm), eq(characters.name, name)));
      if (!existing) {
        const [{ n }] = await db.select({ n: count() }).from(characters).where(eq(characters.userId, userId));
        // Plain text: the app shows the body as the reason on the character's row.
        if (n >= MAX_CHARACTERS) return new Response(`This account has reached ${MAX_CHARACTERS} characters`, { status: 422 });
        await db.insert(characters).values({ userId, game, realm, name }).onConflictDoNothing();
      }
```

Add `count` to the `drizzle-orm` import.

- [ ] **Step 4: Run the server tests and the typecheck**

Run: `cd apps/server && LUA51=… bun test && bun run typecheck`
Expected: PASS; no type errors.

- [ ] **Step 5: Commit**

```bash
git add apps/server/src apps/server/test
git commit -m "Server: cap an upload at 8 MB, names at 64 characters, an account at 100 characters (#40)"
```

### Task 3: Fold a PC's queued uploads of one character

**Files:**
- Modify: `apps/server/src/sync.ts` (the upload's transaction)
- Test: `apps/server/test/sync.test.ts`

**Interfaces:**
- Consumes: the upload handler from Task 2; `last` (the validated `received` version) already computed there.
- Produces: an older `pending` upload from the same PC and character, with the same `received_id` and a `queued` job, ends `superseded` with `reject_reason = 'folded into a newer upload'`, its job `done`.

- [ ] **Step 1: Write the failing tests**

Add to `apps/server/test/sync.test.ts` (import `inArray` is not needed; use `eq`):

```ts
test("a newer upload from the same PC replaces its older one still waiting in the queue", async () => {
  const desk = await newDevice("user-1", "Desk");
  const older = (await (await upload(desk.token, savedFile(journey({ events: session(1000) })))).json()) as UploadResponse;
  const newer = (await (await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000)] })))).json()) as UploadResponse;
  const [o] = await db.select().from(versions).where(eq(versions.id, older.version));
  expect(o).toMatchObject({ status: "superseded", rejectReason: "folded into a newer upload" });
  expect((await db.select().from(jobs).where(eq(jobs.versionId, older.version)))[0]!.state).toBe("done");
  await workAll();
  const [n] = await db.select().from(versions).where(eq(versions.id, newer.version));
  expect(n!.status).toBe("accepted");
  const [entry] = (await check(desk.token)).characters;
  expect(sessions(unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer())))).toBe(2);
});

test("an upload isn't folded once its merge started, or from another PC, or across a restore", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const head = (await check(desk.token)).characters[0]!.version!;

  const running = (await (await upload(desk.token, savedFile(journey({ events: session(2000) })))).json()) as UploadResponse;
  await db.update(jobs).set({ state: "running" }).where(eq(jobs.versionId, running.version));
  const other = (await (await upload(laptop.token, savedFile(journey({ events: session(3000) })))).json()) as UploadResponse;
  const before = (await (await upload(desk.token, savedFile(journey({ events: session(4000) })))).json()) as UploadResponse;
  await upload(desk.token, savedFile(journey({ events: session(5000) })), { received: String(head) });

  for (const id of [running.version, other.version, before.version]) {
    const [v] = await db.select().from(versions).where(eq(versions.id, id));
    expect(v!.status).toBe("pending");
  }
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=… bun test test/sync.test.ts -t "replaces its older|isn't folded"`
Expected: the first FAILS (older stays `pending`); the second passes already, which is fine: it guards the fold's limits.

- [ ] **Step 3: Fold inside the upload's transaction**

In `apps/server/src/sync.ts`, add `sql` to the `drizzle-orm` import. In the upload's `db.transaction`, before inserting the new version:

```ts
        // The newer file holds everything the older one did, so this PC's
        // older upload of the character still waiting in the queue is
        // dropped. Not across a restore (a different received id): those
        // two were made against different journeys. A job the worker has
        // started is no longer queued, so it is left alone.
        const receivedId = last?.id ?? null;
        const folded = await tx
          .update(jobs)
          .set({ state: "done", error: "folded into a newer upload", finishedAt: new Date() })
          .where(
            and(
              eq(jobs.state, "queued"),
              inArray(
                jobs.versionId,
                tx
                  .select({ id: versions.id })
                  .from(versions)
                  .where(
                    and(
                      eq(versions.characterId, character!.id),
                      eq(versions.deviceId, device!.id),
                      eq(versions.kind, "upload"),
                      eq(versions.status, "pending"),
                      sql`${versions.receivedId} IS NOT DISTINCT FROM ${receivedId}::bigint`,
                    ),
                  ),
              ),
            ),
          )
          .returning({ versionId: jobs.versionId });
        if (folded.length > 0) {
          await tx
            .update(versions)
            .set({ status: "superseded", rejectReason: "folded into a newer upload" })
            .where(inArray(versions.id, folded.map((f) => f.versionId)));
        }
```

And use `receivedId` in the insert's `receivedId:` field.

- [ ] **Step 4: Run the server tests**

Run: `cd apps/server && LUA51=… bun test`
Expected: PASS, every test.

- [ ] **Step 5: Commit**

```bash
git add apps/server/src/sync.ts apps/server/test/sync.test.ts
git commit -m "Server: a PC's newer upload replaces its older one still in the queue (#40)"
```

### Task 4: The clean-up job

**Files:**
- Modify: `apps/server/src/schema.ts` (`versions.weekly`, `versions.prunedAt`)
- Create: `apps/server/drizzle/0005_*.sql` (generated)
- Create: `apps/server/src/prune.ts`
- Modify: `apps/server/test/helpers.ts` (`stored`)
- Create: `apps/server/test/prune.test.ts`

**Interfaces:**
- Produces: `export async function prune(mode: "dry" | "on"): Promise<Pruned[]>` with `type Pruned = { characterId: number; versions: number; files: number; bytes: number }` (one entry per character with anything to prune; `bytes` sums `raw_size` of the files deleted); `export function startPrune(mode: "dry" | "on" | "off"): void`. Test helper `stored(userId: string, fp: string): Promise<boolean>`.

- [ ] **Step 1: Add the columns and generate the migration**

In `apps/server/src/schema.ts`, add `boolean` to the pg-core import and, in `versions` after `rejectReason`:

```ts
  // Set on the newest merged or restored version of each finished week, the
  // one the clean-up keeps for that week.
  weekly: boolean("weekly").notNull().default(false),
  // When the clean-up deleted this version's file. The row stays: restores'
  // windows, parents and the known-file check still need it.
  prunedAt: timestamp("pruned_at", { withTimezone: true }),
```

Run: `cd apps/server && bun run db:generate --name version_prune`
Expected: `drizzle/0005_version_prune.sql` adding both columns.

- [ ] **Step 2: Write the failing tests**

Add to `apps/server/test/helpers.ts`:

```ts
const s3 = new Bun.S3Client(config.s3);
// Whether a journey file is in the bucket.
export const stored = (userId: string, fp: string) => s3.exists(`${userId}/${fp}.zst`);
```

`apps/server/test/prune.test.ts`:

```ts
import { beforeEach, expect, test } from "bun:test";
import { eq, inArray } from "drizzle-orm";
import { client, db } from "../src/db";
import { prune } from "../src/prune";
import { characters, jobs, versions } from "../src/schema";
import { remove } from "../src/storage";
import { journey, newDevice, reset, savedFile, session, stored, upload, workAll } from "./helpers";

beforeEach(reset);

const at = (id: number, when: string) => client`UPDATE versions SET created_at = ${when}::timestamptz WHERE id = ${id}`;
const row = async (id: number) => (await db.select().from(versions).where(eq(versions.id, id)))[0]!;
// Plays and merges n sessions in a row; returns the merged versions' ids, oldest first.
async function play(token: string, n: number) {
  const ids: number[] = [];
  for (let i = 1; i <= n; i++) {
    await upload(token, savedFile(journey({ events: Array.from({ length: i }, (_, k) => session(1000 * (k + 1))).flat() })));
    await workAll();
    const [c] = await db.select().from(characters);
    ids.push(c!.headVersionId!);
  }
  return ids;
}

test("an upload's file goes once its merge is done, not while it waits", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  const [waiting] = await db.select().from(versions).where(eq(versions.kind, "upload"));
  await prune("on");
  expect((await row(waiting!.id)).prunedAt).toBeNull();
  expect(await stored(device.userId, waiting!.fingerprint)).toBe(true);
  await workAll();
  await prune("on");
  expect((await row(waiting!.id)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, waiting!.fingerprint)).toBe(false);
});

test("versions from the last 30 days stay; older, the newest of each week and the head stay", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a, b, c, d, head] = await play(token, 5);
  await at(a!, "2025-01-06T10:00Z"); // Monday
  await at(b!, "2025-01-08T10:00Z"); // same week, newer: kept
  await at(c!, "2025-01-13T10:00Z"); // the next week's only one: kept
  await at(head!, "2025-01-01T10:00Z"); // the head stays at any age
  await prune("on");
  expect((await row(a!)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, (await row(a!)).fingerprint)).toBe(false);
  for (const id of [b!, c!, d!, head!]) expect((await row(id)).prunedAt).toBeNull();
  expect([(await row(b!)).weekly, (await row(c!)).weekly]).toEqual([true, true]);
});

test("weeks are counted in UTC: Sunday 23:00 and Monday 01:00 are different weeks", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const [sun, mon] = await play(token, 3);
  await at(sun!, "2025-01-12T23:00Z");
  await at(mon!, "2025-01-13T01:00Z");
  await prune("on");
  expect([(await row(sun!)).weekly, (await row(mon!)).weekly]).toEqual([true, true]);
});

test("a file another kept version shares stays", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a, b] = await play(token, 3);
  await at(a!, "2025-01-06T10:00Z");
  await at(b!, "2025-01-07T10:00Z"); // b is that week's keeper, a is pruned
  const shared = await row(a!);
  await db.insert(versions).values({ ...shared, id: undefined, weekly: false, createdAt: new Date() });
  await prune("on");
  expect((await row(a!)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, shared.fingerprint)).toBe(true);
});

test("dry deletes nothing and says what it would; a second run finds nothing; a missing file doesn't stop it", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a] = await play(token, 2);
  await at(a!, "2025-01-06T10:00Z");
  await db.update(versions).set({ weekly: true }).where(eq(versions.id, a!)); // not the one tested here
  const uploads = await db.select().from(versions).where(eq(versions.kind, "upload"));
  const dry = await prune("dry");
  expect(dry).toEqual([{ characterId: expect.any(Number), versions: 2, files: 2, bytes: expect.any(Number) }]);
  for (const u of uploads) expect(await stored(device.userId, u.fingerprint)).toBe(true);
  expect((await db.select().from(versions)).every((v) => v.prunedAt === null)).toBe(true);

  await remove(device.userId, uploads[0]!.fingerprint);
  expect((await prune("on")).length).toBe(1);
  expect((await db.select().from(versions).where(inArray(versions.id, uploads.map((u) => u.id)))).every((v) => v.prunedAt !== null)).toBe(true);
  expect(await prune("on")).toEqual([]);
});
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd apps/server && LUA51=… bun test test/prune.test.ts`
Expected: FAIL, cannot find module `../src/prune`.

- [ ] **Step 4: Write `src/prune.ts`**

```ts
import { and, eq, inArray, isNull, notInArray } from "drizzle-orm";
import { client, db } from "./db";
import { characters, versions } from "./schema";
import { remove } from "./storage";

export type Pruned = { characterId: number; versions: number; files: number; bytes: number };

// The daily clean-up (spec, "Version clean-up"): every merged and restored
// version from the last 30 days stays, then the newest of each finished
// week; an upload's file goes once its merge is done. Rows stay, with
// pruned_at set, because restores' windows, parents and the known-file
// check still need them.
// ponytail: an upload or merge storing a file identical to one being
// deleted here can lose it; its merge then fails and the app sends the
// file again. Lock per account if that is ever seen.
export async function prune(mode: "dry" | "on"): Promise<Pruned[]> {
  // A week still under way is left alone, so the mark lands on the week's
  // last version and each finished week gets exactly one. Weeks are UTC.
  await client`
    UPDATE versions SET weekly = true
    WHERE id IN (
      SELECT DISTINCT ON (character_id, date_trunc('week', created_at, 'UTC')) id
      FROM versions v
      WHERE kind IN ('merged', 'restore') AND pruned_at IS NULL
        AND created_at < date_trunc('week', now(), 'UTC')
        AND NOT EXISTS (
          SELECT 1 FROM versions w
          WHERE w.character_id = v.character_id AND w.weekly
            AND date_trunc('week', w.created_at, 'UTC') = date_trunc('week', v.created_at, 'UTC'))
      ORDER BY character_id, date_trunc('week', created_at, 'UTC'), id DESC)`;

  const rows = await client`
    SELECT v.id, v.fingerprint, v.raw_size, v.character_id, c.user_id
    FROM versions v JOIN characters c ON c.id = v.character_id
    WHERE v.pruned_at IS NULL AND (
      (v.kind = 'upload' AND v.status IN ('accepted', 'rejected', 'superseded')
        AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.version_id = v.id AND j.state IN ('queued', 'running')))
      OR (v.kind IN ('merged', 'restore') AND NOT v.weekly
        AND v.created_at < now() - interval '30 days'
        AND v.id IS DISTINCT FROM c.head_version_id))
    ORDER BY v.id`;
  const chosen = rows.map((r) => ({
    id: Number(r.id),
    fingerprint: String(r.fingerprint),
    rawSize: Number(r.raw_size),
    characterId: Number(r.character_id),
    userId: String(r.user_id),
  }));

  const pruned: Pruned[] = [];
  for (const userId of new Set(chosen.map((c) => c.userId))) {
    const theirs = chosen.filter((c) => c.userId === userId);
    const ids = theirs.map((c) => c.id);
    // Identical files are stored once, so a file goes only when no version
    // that stays has it.
    const kept = new Set(
      (
        await db
          .selectDistinct({ fp: versions.fingerprint })
          .from(versions)
          .innerJoin(characters, eq(characters.id, versions.characterId))
          .where(and(eq(characters.userId, userId), isNull(versions.prunedAt), notInArray(versions.id, ids)))
      ).map((k) => k.fp),
    );
    const files = new Map<string, number>();
    for (const c of theirs) if (!kept.has(c.fingerprint)) files.set(c.fingerprint, c.rawSize);
    if (mode === "on") {
      // Files first: if this stops part way, the next run deletes again,
      // and a file already gone is no error.
      for (const fp of files.keys()) await remove(userId, fp);
      await db.update(versions).set({ prunedAt: new Date() }).where(inArray(versions.id, ids));
    }
    for (const characterId of new Set(theirs.map((c) => c.characterId))) {
      const mine = theirs.filter((c) => c.characterId === characterId);
      const myFiles = [...new Set(mine.map((c) => c.fingerprint))].filter((fp) => files.has(fp));
      pruned.push({
        characterId,
        versions: mine.length,
        files: myFiles.length,
        bytes: myFiles.reduce((sum, fp) => sum + files.get(fp)!, 0),
      });
    }
  }
  for (const p of pruned) {
    console.log(`prune (${mode}): character ${p.characterId}: ${p.versions} versions, ${p.files} files, ${(p.bytes / 1e6).toFixed(1)} MB`);
  }
  return pruned;
}

const DAY = 24 * 3600 * 1000;

// A few minutes after start, so a deploy settles first, then once a day.
export function startPrune(mode: "dry" | "on" | "off") {
  if (mode === "off") return;
  const run = () => prune(mode).catch((e) => console.error("prune:", e));
  setTimeout(() => {
    void run();
    setInterval(run, DAY);
  }, 5 * 60 * 1000);
}
```

A shared file counts once per character that holds it, so per-character byte totals can add up to more than was deleted; the log is a rough size, not an invoice.

- [ ] **Step 5: Run the tests**

Run: `cd apps/server && LUA51=… bun test test/prune.test.ts`
Expected: PASS, 5 tests. If the dry test's counts differ, read the rows it chose before changing the test: each `play` session makes one upload and one merged version.

- [ ] **Step 6: Run the server tests and typecheck**

Run: `cd apps/server && LUA51=… bun test && bun run typecheck`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/server/src/schema.ts apps/server/drizzle apps/server/src/prune.ts apps/server/test
git commit -m "Server: the daily clean-up keeps 30 days of versions, then one a week (#40)"
```

### Task 5: History, downloads and restores skip pruned versions

**Files:**
- Modify: `apps/server/src/account.ts` (History route, restore route)
- Modify: `apps/server/src/sync.ts` (`GET /versions/:id`)
- Test: `apps/server/test/account.test.ts`, `apps/server/test/sync.test.ts`

**Interfaces:**
- Consumes: `versions.weekly`, `versions.prunedAt` (Task 4).

- [ ] **Step 1: Write the failing tests**

Add to `apps/server/test/account.test.ts`:

```ts
test("history lists the newest 100 versions, then each older week's kept one, and never a pruned one", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await db.select().from(characters);
  const [head] = await db.select().from(versions).where(eq(versions.id, c!.headVersionId!));
  const made = await db
    .insert(versions)
    .values(Array.from({ length: 105 }, () => ({ ...head!, id: undefined })))
    .returning({ id: versions.id });
  const ids = made.map((m) => m.id); // oldest first
  await db.update(versions).set({ weekly: true }).where(inArray(versions.id, [ids[0]!, ids[2]!]));
  await db.update(versions).set({ prunedAt: new Date() }).where(eq(versions.id, ids[1]!));
  const history = await json<VersionInfo[]>(call(token, `/v1/characters/${c!.id}/versions`));
  const listed = history.map((v) => v.id);
  expect(listed.slice(0, 100)).toEqual([...ids].reverse().slice(0, 100));
  expect(listed.slice(100)).toEqual([ids[2]!, ids[0]!]);
  expect(listed).not.toContain(ids[1]!);
});

test("a pruned version can't be restored", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] })));
  await workAll();
  const [c] = await db.select().from(characters);
  const [old] = await db.select().from(versions).where(and(eq(versions.kind, "merged"), ne(versions.id, c!.headVersionId!)));
  await db.update(versions).set({ prunedAt: new Date() }).where(eq(versions.id, old!.id));
  const r = await call(token, `/v1/characters/${c!.id}/restore`, { method: "POST", body: JSON.stringify({ version: old!.id }), headers: { "content-type": "application/json" } });
  expect(r.status).toBe(404);
});
```

(Add `and, inArray, ne` to the test's `drizzle-orm` import.)

Add to `apps/server/test/sync.test.ts`:

```ts
test("a pruned version downloads as not found", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [entry] = (await check(token)).characters;
  await db.update(versions).set({ prunedAt: new Date() }).where(eq(versions.id, entry!.version!));
  expect((await call(token, `/v1/versions/${entry!.version}`)).status).toBe(404);
});

test("a restore whose file was pruned still keeps what it took out of a stale upload", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await restoreHead(desk.token);
  await db.update(versions).set({ prunedAt: new Date() }).where(eq(versions.kind, "restore"));
  const copied = await newDevice("user-1", "Copied WTF folder");
  await upload(copied.token, savedFile(journey({ events: [...session(1000), ...session(20000), ...session(30000)] })));
  await workAll();
  const [entry] = (await check(desk.token)).characters;
  const text = new TextDecoder().decode(unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer())));
  expect(text).toContain("30000");
  expect(text).not.toContain("20000");
});
```

(The restore is marked pruned by hand while it is still the head, which the clean-up never does; the point is only that the worker still reads its stretches.)

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && LUA51=… bun test -t "pruned|newest 100"`
Expected: the History test, the restore test and the download test FAIL; the stale-upload test passes (the worker already reads restore rows whatever their file), which pins it.

- [ ] **Step 3: Implement**

`apps/server/src/account.ts` History route: replace the `rows` query with:

```ts
    const shown = and(eq(versions.characterId, c.id), inArray(versions.kind, ["merged", "restore"]), isNull(versions.prunedAt));
    const recent = await db.select().from(versions).where(shown).orderBy(desc(versions.id)).limit(HISTORY);
    // Past the newest 100, the one version kept for each week, so the
    // clean-up never keeps a version the player can't get back to.
    const older =
      recent.length === HISTORY
        ? await db
            .select()
            .from(versions)
            .where(and(shown, eq(versions.weekly, true), lt(versions.id, recent.at(-1)!.id)))
            .orderBy(desc(versions.id))
        : [];
    const rows = [...recent, ...older];
```

Add `isNull`, `lt` to its `drizzle-orm` import. In the restore route's `source` query, add `isNull(versions.prunedAt)` to the `and(...)`.

`apps/server/src/sync.ts` `GET /versions/:id`: add `isNull(versions.prunedAt)` to its `and(...)` (import `isNull`).

- [ ] **Step 4: Run the server tests and typecheck**

Run: `cd apps/server && LUA51=… bun test && bun run typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/server/src apps/server/test
git commit -m "Server: History shows the newest 100 versions and each older week's, never a pruned one (#40)"
```

### Task 6: Start the clean-up, settings, wording and docs

**Files:**
- Modify: `apps/server/src/config.ts`, `apps/server/src/index.ts`, `apps/server/.env.example`
- Modify: `apps/server/AGENTS.md`
- Modify: `apps/web/src/components/Facts.astro`, `apps/web/src/pages/privacy.astro`
- Modify: `docs/superpowers/specs/2026-10-15-limits-and-retention-design.md` (dry marks weekly)
- Test: `apps/server/test/config.test.ts` (create)

**Interfaces:**
- Consumes: `startPrune` (Task 4).
- Produces: `config.prune: "dry" | "on" | "off"`.

- [ ] **Step 1: Write the failing test**

`apps/server/test/config.test.ts`:

```ts
import { expect, test } from "bun:test";
import { pruneMode } from "../src/config";

test("the clean-up runs dry unless told otherwise, and refuses a value it doesn't know", () => {
  expect(pruneMode(undefined)).toBe("dry");
  expect(pruneMode("on")).toBe("on");
  expect(pruneMode("off")).toBe("off");
  expect(() => pruneMode("yes")).toThrow("PRUNE");
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/server && bun test test/config.test.ts`
Expected: FAIL, `pruneMode` is not exported.

- [ ] **Step 3: Implement the setting and start the job**

`apps/server/src/config.ts`, before `config`:

```ts
// The daily clean-up: "dry" only logs what it would delete, so a deploy
// never deletes anything until someone has read that log and set "on".
export function pruneMode(value: string | undefined): "dry" | "on" | "off" {
  const mode = value || "dry";
  if (mode !== "dry" && mode !== "on" && mode !== "off") throw new Error(`PRUNE must be dry, on or off, not ${mode}`);
  return mode;
}
```

and in `config`: `prune: pruneMode(process.env.PRUNE),`.

`apps/server/src/index.ts`: import `{ startPrune } from "./prune"` and call `startPrune(config.prune);` after `startWorker();`.

`apps/server/.env.example`, at the end:

```
# The daily clean-up of old versions: dry (log what it would delete), on, off.
PRUNE=dry
```

- [ ] **Step 4: Run the server tests**

Run: `cd apps/server && LUA51=… bun test && bun run typecheck`
Expected: PASS.

- [ ] **Step 5: Docs and wording**

`apps/server/AGENTS.md`: under Layout add "`src/limits.ts` counts each PC's requests and uploads; `src/prune.ts` is the daily clean-up of old versions." Under Rules that bite add:

```
- Limits (spec 2026-10-15): 30 uploads per PC in 15 minutes and 600
  requests an hour answer 429, which the app retries; 8 MB compressed and
  64-character names answer 413 and 400; a 101st character answers 422 in
  plain text, which the app shows on the row. The counts are in memory.
- The clean-up never deletes a row, only files, and sets `pruned_at`.
  Anything that reads a version's file must skip pruned versions. `PRUNE`
  is `dry` by default: read its log before setting `on` in Dokploy.
```

`apps/web/src/components/Facts.astro`: the first fact's text becomes `"Every version from the last 30 days, then one a week. The newer one stays, so you can switch back."`

`apps/web/src/pages/privacy.astro`, "Where it's kept", after "Journey files are in Cloudflare R2 storage.": add `Older versions of a journey are thinned out: every version from the last 30 days is kept, then one a week.`

Spec: in "The daily job", replace "`dry` logs, per character, how many versions and bytes it would prune and does nothing else" with "`dry` marks each week's kept version (which deletes nothing) and logs, per character, how many versions, files and bytes it would prune".

- [ ] **Step 6: Build the website and run every test**

Run: `cd apps/web && bun run build` then from the repo root `. ~/.cargo/env && LUA51=… bun run test`
Expected: the site builds; every suite passes.

- [ ] **Step 7: Commit**

```bash
git add apps/server apps/web docs
git commit -m "Server: start the clean-up dry by default; the site says how versions are kept (#40)"
```
