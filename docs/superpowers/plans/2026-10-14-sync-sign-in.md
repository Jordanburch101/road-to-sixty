# Sync Server: Sign-in and Linking a PC, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Players sign up and sign in through the app: it opens a page on the sync server with its code, the player signs in with Battle.net there and approves, and the app gets its PC token. The script-made PC tokens go.

**Architecture:** Better Auth 1.7.7 runs inside the Elysia server at `/api/auth/*`, on the same Postgres through Drizzle. Battle.net comes in through its generic OAuth plugin. Linking uses its device authorization plugin. The app polls `/api/auth/device/token` and gets a short-lived session, then trades it at `/v1/link` for a PC token of its own, and the session ends. The upload, check and download code doesn't change. A plain page at `/link`, which the app opens in the browser with its code filled in, does the sign-in and the approval. The website only offers downloads and has no sign-in.

**Tech Stack:** Bun 1.4.2, Elysia 1.4.30, Better Auth 1.7.7 (`genericOAuth`, `deviceAuthorization`, `bearer`), Drizzle ORM 0.45.4 with drizzle-kit 0.31.11, Postgres 17.11, Dokploy.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "The backend" (Better Auth), "Storage" (Postgres, Privacy), "The desktop app" (First run, step 2), "Domains", "Risks and things to verify" (the two Better Auth and Battle.net lines), "Decisions" (Sign-in, Linking the app).

## Global Constraints

- Sign-in is Battle.net only, through Better Auth running in the backend (spec).
- Linking the app is Better Auth device sign-in: the app shows a code, the player confirms it (spec).
- The Battle.net account ID is stored as a hash, and the BattleTag is refreshed at each sign-in (spec).
- Device tokens: the server stores only their hashes (spec).
- Sign-up and sign-in happen through the app; the website has no sign-in and shares no cookie (Jordan, 2026-10-14; spec, "The website"). Every address comes from environment variables in Dokploy, never from code (spec).
- Never commit secrets, personal paths or real saved files. Secrets live in Dokploy and in `~/.config/road-to-sixty/dokploy.env` (mode 600) on Jordan's Mac. Commit subjects are `Area: what changed (#1)`.
- Subagents run on at most Opus, never Fable.

## Decisions the spec leaves open

- **The Battle.net return address is `/api/auth/callback/battlenet`.** Better Auth 1.7 sends generic OAuth providers through its core `callback/:id` route. The address Jordan registered (`/api/auth/oauth2/callback/battlenet`) was for older versions and must be changed in the Battle.net developer portal (Task 3).
- **The account ID hash is an HMAC** keyed by `ACCOUNT_HASH_KEY`. Battle.net account IDs are small numbers, so a plain SHA-256 could be reversed by trying them all. It is Better Auth's `accountSubject`, so `account.account_id` holds the hash and never the ID.
- **Each player gets a made-up email**, `<hash>@battlenet.invalid`. Battle.net gives none, and Better Auth needs one per user. `.invalid` can never receive mail.
- **Battle.net's tokens are dropped** by a database hook on every account write. Sign-in needs them only once, to read who signed in.
- **Accounts are keyed by `id`, falling back to `sub`.** Blizzard documents both as the account ID. The server logs a warning if they ever differ.
- **The app trades its device sign-in session for a PC token at `/v1/link`**, and the session is deleted. The sync API keeps using hashed PC tokens (`devices.token_hash`), and only a bearer token links: a browser's sign-in cookie can't.
- **The link page is served by the server** (`/link`, plain HTML). The app opens it at `verification_uri_complete`, with its code filled in. The device plugin's `verificationUri` is `/link` on the server's own address, so the sign-in cookie never leaves it.
- **Better Auth's tables are written by hand** in `src/auth-schema.ts`. Its CLI (`auth generate`) runs under Node and can't load this Bun project. The fields match `getAuthTables` for 1.7.7. `account` gets a unique `(provider_id, account_id)`.
- **`devices.user_id` and `characters.user_id` reference `user.id`.** The live tables are empty (no PC was linked before this), so the foreign keys apply cleanly.
- **Rate limits read the visitor's address from `X-Forwarded-For`**, which Dokploy's Traefik sets. Without it, Better Auth puts every visitor in one shared bucket.
- **PKCE stays on** (Better Auth's default). If Battle.net refuses it at the live sign-in, Task 3 turns it off for this provider.
- **`scripts/new-device.ts` goes.** `scripts/link-pc.ts` links a PC the way the app will, and `scripts/try-upload.ts` uploads a made-up journey as it, to try a running server.

## Review Focus

1. Real Battle.net: the return address, PKCE, the userinfo fields and the cookie over HTTPS. Only Task 3's live sign-in checks them; the tests use a stand-in.
2. A PC linked by the wrong player: approving needs the code looked up first by the signed-in player (Better Auth ties it to them), codes are 8 characters and last 30 minutes, and rate limits count by `X-Forwarded-For` (Task 2 tests approval and refusal; the reviewer reads the plugin's checks).
3. `ACCOUNT_HASH_KEY` or `BETTER_AUTH_SECRET` changed or lost: every player comes back as new, or every session ends. Both are kept in Dokploy and the private file (Task 3); nothing else derives from them.
4. The live migration: `0001_sign_in.sql` adds foreign keys to tables that must hold no rows without a user (Task 3 checks the deploy).
5. A session token used where a PC token belongs: `/v1/check` refuses it (Task 2 test), and `/v1/link` refuses a cookie or a used token (Task 2 test).

---

### Task 1: Sign in with Battle.net

**Files:**
- Create: `apps/server/src/auth.ts`, `apps/server/src/auth-schema.ts`, `apps/server/drizzle/0001_sign_in.sql` and `drizzle/meta/0001_snapshot.json` (generated), `apps/server/test/battlenet.ts`, `apps/server/test/auth.test.ts`
- Modify: `apps/server/src/config.ts`, `apps/server/src/schema.ts`, `apps/server/src/app.ts`, `apps/server/.env.test`, `apps/server/.env.example`, `apps/server/test/helpers.ts`, `apps/server/test/sync.test.ts`, `apps/server/package.json` and `bun.lock` (by `bun add`), `apps/server/drizzle/meta/_journal.json` (generated)

**Interfaces:**
- Consumes: `db` (`src/db.ts`), `config` (`src/config.ts`), the existing tables in `src/schema.ts`.
- Produces: `auth` (Better Auth instance) and `accountHash(id)` from `src/auth.ts`; tables `user`, `session`, `account`, `verification`, `deviceCode` exported from `src/schema.ts`; `config.auth` (`url`, `secret`, `accountHashKey`) and `config.battlenet` (`url`, `clientId`, `clientSecret`); test helpers `signIn(as?) -> cookie`, `player`, `addUser(id)`; routes `/api/auth/*`.

- [ ] **Step 1: Cut the branch and add Better Auth**

```bash
git switch dev && git switch -c sync-sign-in
cd apps/server && bun add better-auth@1.7.7; cd ../..
```
Expected: `apps/server/package.json` lists `"better-auth": "1.7.7"` under `dependencies`.

- [ ] **Step 2: Write the failing tests**

Create `apps/server/test/battlenet.ts`:

```ts
// A stand-in for Battle.net's sign-in, so the tests sign in without a
// browser: it signs in whoever `player` says. BATTLENET_URL in .env.test
// points the server here.
import { app } from "../src/app";

export const player = { id: 1234, battletag: "Ann#1234" };

Bun.serve({
  port: 58444,
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/authorize") {
      const back = new URL(url.searchParams.get("redirect_uri")!);
      back.searchParams.set("code", `code-${player.id}`);
      back.searchParams.set("state", url.searchParams.get("state")!);
      return Response.redirect(back.toString(), 302);
    }
    if (url.pathname === "/token") return Response.json({ access_token: `token-${player.id}`, token_type: "bearer", expires_in: 3600 });
    if (url.pathname === "/userinfo") return Response.json({ sub: String(player.id), id: player.id, battletag: player.battletag });
    return new Response("not found", { status: 404 });
  },
});

const cookies = (r: Response) => r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");

// Signs in through the whole Battle.net round trip and returns the sign-in
// cookie, as a browser would hold it.
export async function signIn(as: Partial<typeof player> = {}): Promise<string> {
  Object.assign(player, { id: 1234, battletag: "Ann#1234" }, as);
  const start = await app.handle(
    new Request("http://localhost:3000/api/auth/sign-in/social", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:3000" },
      body: JSON.stringify({ provider: "battlenet", callbackURL: "/link" }),
    }),
  );
  const { url } = (await start.json()) as { url: string };
  const authorize = await fetch(url, { redirect: "manual" });
  const callback = await app.handle(new Request(authorize.headers.get("location")!, { headers: { cookie: cookies(start) } }));
  if (callback.status !== 302) throw new Error(`sign-in failed: ${callback.status} ${await callback.text()}`);
  return cookies(callback);
}
```

Create `apps/server/test/auth.test.ts`:

```ts
import { beforeEach, expect, test } from "bun:test";
import { app } from "../src/app";
import { accountHash } from "../src/auth";
import { db } from "../src/db";
import { account, user } from "../src/schema";
import { signIn } from "./battlenet";
import { reset } from "./helpers";

beforeEach(reset);

const get = (path: string, headers: Record<string, string> = {}) => app.handle(new Request(`http://localhost:3000${path}`, { headers }));

test("signing in with Battle.net makes a player named by BattleTag, keyed by a hash of the account ID", async () => {
  const cookie = await signIn({ id: 1234, battletag: "Ann#1234" });
  const signedIn = (await (await get("/api/auth/get-session", { cookie })).json()) as { user: { name: string } };
  expect(signedIn.user.name).toBe("Ann#1234");
  const [row] = await db.select().from(account);
  expect(row).toMatchObject({ providerId: "battlenet", accountId: accountHash(1234), accessToken: null, idToken: null });
  expect(JSON.stringify(await db.select().from(user))).not.toContain("1234@");
});

test("signing in again is the same player, with the BattleTag brought up to date", async () => {
  await signIn({ id: 1234, battletag: "Ann#1234" });
  await signIn({ id: 1234, battletag: "Annie#1234" });
  await signIn({ id: 5678, battletag: "Bob#5678" });
  const users = await db.select().from(user).orderBy(user.name);
  expect(users.map((u) => u.name)).toEqual(["Annie#1234", "Bob#5678"]);
  expect((await db.select().from(account)).map((a) => a.accessToken)).toEqual([null, null]);
});
```

Apply this to `apps/server/.env.test`, so the server reaches the stand-in:

```diff
diff --git a/apps/server/.env.test b/apps/server/.env.test
index 8a26987..998f1d2 100644
--- a/apps/server/.env.test
+++ b/apps/server/.env.test
@@ -5,3 +5,10 @@ S3_ENDPOINT=http://localhost:58333
 S3_BUCKET=journeys-test
 S3_ACCESS_KEY_ID=local
 S3_SECRET_ACCESS_KEY=local
+BETTER_AUTH_URL=http://localhost:3000
+BETTER_AUTH_SECRET=test-secret-at-least-32-characters-long
+ACCOUNT_HASH_KEY=test-account-hash-key
+# The tests' stand-in for Battle.net (test/battlenet.ts).
+BATTLENET_URL=http://localhost:58444
+BATTLENET_CLIENT_ID=test-client
+BATTLENET_CLIENT_SECRET=test-secret
```

Run: `cd apps/server && LUA51=<PUC Lua 5.1> bun test test/auth.test.ts; cd ../..`
Expected: an error that `../src/auth` can't be found.

- [ ] **Step 3: Settings**

Apply this to `apps/server/src/config.ts` and `apps/server/.env.example`:

```diff
diff --git a/apps/server/.env.example b/apps/server/.env.example
index af442b3..4da7ace 100644
--- a/apps/server/.env.example
+++ b/apps/server/.env.example
@@ -6,6 +6,16 @@ S3_ENDPOINT=http://localhost:58333
 S3_BUCKET=journeys
 S3_ACCESS_KEY_ID=
 S3_SECRET_ACCESS_KEY=
+# Sign-in. BETTER_AUTH_URL is this server's address, which Battle.net
+# returns players to (/api/auth/callback/battlenet). The secret and the hash
+# key are random strings (openssl rand -hex 32). Never change
+# ACCOUNT_HASH_KEY once players have signed in: they would all come back as
+# new accounts.
+BETTER_AUTH_URL=http://localhost:3000
+BETTER_AUTH_SECRET=
+ACCOUNT_HASH_KEY=
+BATTLENET_CLIENT_ID=
+BATTLENET_CLIENT_SECRET=
 # Standard Lua 5.1 and the addon's folder of shared Lua files. The Docker
 # image sets both; locally lua5.1 must be on the path or named here.
 LUA51=lua5.1
diff --git a/apps/server/src/config.ts b/apps/server/src/config.ts
index a9a17f2..decff6a 100644
--- a/apps/server/src/config.ts
+++ b/apps/server/src/config.ts
@@ -16,6 +16,19 @@ export const config = {
     accessKeyId: env("S3_ACCESS_KEY_ID"),
     secretAccessKey: env("S3_SECRET_ACCESS_KEY"),
   },
+  auth: {
+    // The server's own address, which Battle.net returns players to.
+    url: env("BETTER_AUTH_URL"),
+    secret: env("BETTER_AUTH_SECRET"),
+    // Keys the hash of each Battle.net account ID. Never change it: every
+    // player would come back as a new account.
+    accountHashKey: env("ACCOUNT_HASH_KEY"),
+  },
+  battlenet: {
+    url: env("BATTLENET_URL", "https://oauth.battle.net"),
+    clientId: env("BATTLENET_CLIENT_ID"),
+    clientSecret: env("BATTLENET_CLIENT_SECRET"),
+  },
   lua51: env("LUA51", "lua5.1"),
   luaDir: env("LUA_DIR", `${import.meta.dir}/../../addon/RoadToSixty`),
 };
```

- [ ] **Step 4: Better Auth's tables**

Create `apps/server/src/auth-schema.ts`:

```ts
import { boolean, integer, pgTable, text, timestamp, unique } from "drizzle-orm/pg-core";

// Better Auth's tables (users, sessions, accounts, verifications, device
// codes), with the fields its version 1.7 expects. Its CLI can't load this
// Bun project, so they are written by hand: when Better Auth is upgraded,
// compare with getAuthTables from better-auth/db.

const created = () => timestamp("created_at", { withTimezone: true }).notNull().defaultNow();
const updated = () => timestamp("updated_at", { withTimezone: true }).notNull().defaultNow();

// One player. name is the BattleTag; email is made up (auth.ts), since
// Battle.net gives none.
export const user = pgTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").notNull().default(false),
  image: text("image"),
  createdAt: created(),
  updatedAt: updated(),
});

export const session = pgTable("session", {
  id: text("id").primaryKey(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  token: text("token").notNull().unique(),
  createdAt: created(),
  updatedAt: updated(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  userId: text("user_id").notNull().references(() => user.id, { onDelete: "cascade" }),
});

// A Battle.net sign-in. accountId is the keyed hash of the Battle.net
// account ID, never the ID itself; the tokens are dropped (auth.ts).
export const account = pgTable(
  "account",
  {
  id: text("id").primaryKey(),
  accountId: text("account_id").notNull(),
  providerId: text("provider_id").notNull(),
  userId: text("user_id").notNull().references(() => user.id, { onDelete: "cascade" }),
  accessToken: text("access_token"),
  refreshToken: text("refresh_token"),
  idToken: text("id_token"),
  accessTokenExpiresAt: timestamp("access_token_expires_at", { withTimezone: true }),
  refreshTokenExpiresAt: timestamp("refresh_token_expires_at", { withTimezone: true }),
  scope: text("scope"),
  password: text("password"),
  createdAt: created(),
  updatedAt: updated(),
  },
  (t) => [unique().on(t.providerId, t.accountId)],
);

export const verification = pgTable("verification", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull(),
  value: text("value").notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: created(),
  updatedAt: updated(),
});

// The code the app shows while a PC is being linked.
export const deviceCode = pgTable("device_code", {
  id: text("id").primaryKey(),
  deviceCode: text("device_code").notNull(),
  userCode: text("user_code").notNull(),
  userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  status: text("status").notNull(),
  lastPolledAt: timestamp("last_polled_at", { withTimezone: true }),
  pollingInterval: integer("polling_interval"),
  clientId: text("client_id"),
  scope: text("scope"),
});
```

Apply this to `apps/server/src/schema.ts`:

```diff
diff --git a/apps/server/src/schema.ts b/apps/server/src/schema.ts
index 10f8d78..5aa6fe6 100644
--- a/apps/server/src/schema.ts
+++ b/apps/server/src/schema.ts
@@ -1,13 +1,17 @@
 import { bigint, bigserial, integer, pgTable, primaryKey, text, timestamp, unique } from "drizzle-orm/pg-core";
+import { user } from "./auth-schema";
+
+export * from "./auth-schema";
 
 // A linked PC. Its id is also the PC ID the addon keeps counts under, so a
-// journey uploaded from an older addon is prepared with it. tokenHash
-// stands in for Better Auth's device tokens until sign-in is built.
+// journey uploaded from an older addon is prepared with it. tokenHash is
+// the hash of the token /v1/link gave the app; the token itself is never
+// stored.
 // dataLayout is the newest journey layout its addon has written, from its
 // uploads, so check never offers it a version it can't read.
 export const devices = pgTable("devices", {
   id: text("id").primaryKey(),
-  userId: text("user_id").notNull(),
+  userId: text("user_id").notNull().references(() => user.id),
   name: text("name").notNull(),
   platform: text("platform"),
   appVersion: text("app_version"),
@@ -24,7 +28,7 @@ export const characters = pgTable(
   "characters",
   {
     id: bigserial("id", { mode: "number" }).primaryKey(),
-    userId: text("user_id").notNull(),
+    userId: text("user_id").notNull().references(() => user.id),
     game: text("game").notNull(),
     realm: text("realm").notNull(),
     name: text("name").notNull(),
```

Run: `cd apps/server && bunx drizzle-kit generate --name sign_in; cd ../..`
Expected: `drizzle/0001_sign_in.sql` creating `account` (with `UNIQUE("provider_id","account_id")`), `device_code`, `session`, `user` and `verification`, then foreign keys from `account`, `device_code` and `session` to `user` with `ON DELETE cascade`, and from `characters` and `devices` to `user` with `ON DELETE no action`.

- [ ] **Step 5: Better Auth with Battle.net**

Create `apps/server/src/auth.ts`:

```ts
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { genericOAuth } from "better-auth/plugins/generic-oauth";
import { config } from "./config";
import { db } from "./db";
import * as schema from "./schema";

// The Battle.net account ID, kept only as a keyed hash (spec, "Privacy").
export function accountHash(id: string | number): string {
  return new Bun.CryptoHasher("sha256", config.auth.accountHashKey).update(String(id)).digest("hex");
}

export const auth = betterAuth({
  baseURL: config.auth.url,
  secret: config.auth.secret,
  database: drizzleAdapter(db, { provider: "pg", schema }),
  // Dokploy's proxy passes the visitor's address on; rate limits count by it.
  advanced: { ipAddress: { ipAddressHeaders: ["x-forwarded-for"] } },
  databaseHooks: {
    account: {
      // Sign-in needs Battle.net's tokens only once, to read who signed in.
      create: { before: async (account) => ({ data: { ...account, accessToken: null, refreshToken: null, idToken: null } }) },
      update: { before: async (account) => ({ data: { ...account, accessToken: null, refreshToken: null, idToken: null } }) },
    },
  },
  plugins: [
    genericOAuth({
      config: [
        {
          providerId: "battlenet",
          name: "Battle.net",
          authorizationUrl: `${config.battlenet.url}/authorize`,
          tokenUrl: `${config.battlenet.url}/token`,
          userInfoUrl: `${config.battlenet.url}/userinfo`,
          clientId: config.battlenet.clientId,
          clientSecret: config.battlenet.clientSecret,
          scopes: ["openid"],
          accountSubject: ({ profile }) => {
            // Blizzard documents sub and id as the same account ID, but
            // libraries disagree (spec, "Risks"). Accounts are keyed by id.
            if (profile.sub != null && profile.id != null && String(profile.sub) !== String(profile.id)) {
              console.warn("battle.net: sub and id differ; accounts are keyed by id");
            }
            return accountHash(profile.id ?? profile.sub!);
          },
          // Battle.net gives no email, and Better Auth needs one per user:
          // an address that can never receive mail, unique to the account.
          mapProfileToUser: (profile) => ({
            name: String(profile.battletag ?? "Player"),
            email: `${accountHash(profile.id ?? profile.sub!)}@battlenet.invalid`,
            emailVerified: false,
          }),
          // The BattleTag can change; Blizzard's terms want it kept current.
          overrideUserInfo: true,
        },
      ],
    }),
  ],
});
```

Apply this to `apps/server/src/app.ts`:

```diff
diff --git a/apps/server/src/app.ts b/apps/server/src/app.ts
index e8ae0cb..35edd87 100644
--- a/apps/server/src/app.ts
+++ b/apps/server/src/app.ts
@@ -1,4 +1,9 @@
 import { Elysia } from "elysia";
+import { auth } from "./auth";
 import { sync } from "./sync";
 
-export const app = new Elysia().get("/health", () => "ok").use(sync);
+export const app = new Elysia()
+  .get("/health", () => "ok")
+  // Better Auth reads the request itself, so Elysia must leave the body alone.
+  .all("/api/auth/*", ({ request }) => auth.handler(request), { parse: "none" })
+  .use(sync);
```

- [ ] **Step 6: The sync tests' made-up players**

The sync tests make PCs for users that now need a `user` row. Apply this to `apps/server/test/helpers.ts` and `apps/server/test/sync.test.ts`:

```diff
diff --git a/apps/server/test/helpers.ts b/apps/server/test/helpers.ts
index e2e0f15..56d2fb7 100644
--- a/apps/server/test/helpers.ts
+++ b/apps/server/test/helpers.ts
@@ -2,11 +2,12 @@
 // journeys in the game's saved format. Never a real save: those hold other
 // players' names.
 import { config } from "../src/config";
-import { client, migrateDb } from "../src/db";
+import { client, db, migrateDb } from "../src/db";
+import { user } from "../src/schema";
 
 export async function reset() {
   await migrateDb();
-  await client`TRUNCATE jobs, version_parents, versions, characters, devices RESTART IDENTITY CASCADE`;
+  await client`TRUNCATE jobs, version_parents, versions, characters, devices, "user", session, account, verification, device_code RESTART IDENTITY CASCADE`;
   // SeaweedFS makes a bucket on an unsigned PUT (409 once it exists); it
   // takes a few seconds to start in CI. R2's bucket is made once by hand.
   for (let tries = 0; ; tries++) {
@@ -18,6 +19,12 @@ export async function reset() {
   }
 }
 
+// A player, as signing in would make one.
+export async function addUser(id: string) {
+  await db.insert(user).values({ id, name: `${id}#1234`, email: `${id}@battlenet.invalid` }).onConflictDoNothing();
+  return id;
+}
+
 // A value as Lua table text the addon's Parse.lua reads. Arrays become the
 // array part, null a gap; object keys made of digits become number keys.
 export function lua(v: unknown): string {
diff --git a/apps/server/test/sync.test.ts b/apps/server/test/sync.test.ts
index 678cb5e..2416a32 100644
--- a/apps/server/test/sync.test.ts
+++ b/apps/server/test/sync.test.ts
@@ -4,12 +4,14 @@ import { eq } from "drizzle-orm";
 import { app } from "../src/app";
 import { config } from "../src/config";
 import { client, db } from "../src/db";
-import { newDevice } from "../src/devices";
+import { newDevice as linkDevice } from "../src/devices";
 import { characters, devices, jobs, versions } from "../src/schema";
 import { pack, unpack } from "../src/storage";
 import { work } from "../src/worker";
 import { journey, savedFile, session, sessions } from "./helpers";
-import { reset } from "./helpers";
+import { addUser, reset } from "./helpers";
+
+const newDevice = async (userId: string, name: string) => linkDevice(await addUser(userId), name);
 
 beforeEach(reset);
 
```

- [ ] **Step 7: Run every server test**

Run: `cd apps/server && LUA51=<PUC Lua 5.1> bun test && bunx tsc --noEmit -p .; cd ../..`
Expected: `23 pass`, `0 fail` across 4 files, and no type errors. If the local database already ran a different `0001` (a stale throwaway), recreate it with `docker compose down -v && docker compose up -d --wait` in `apps/server`.

- [ ] **Step 8: Commit**

```bash
git add apps/server bun.lock
git commit -m "Server: sign in with Battle.net through Better Auth (#1)

The Battle.net account ID is kept only as a keyed hash, the BattleTag is
refreshed at each sign-in, and Battle.net's tokens are never stored.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Link a PC with a code

**Files:**
- Create: `apps/server/src/link.ts`, `apps/server/src/link.html`, `apps/server/scripts/link-pc.ts`, `apps/server/scripts/try-upload.ts`
- Modify: `apps/server/src/auth.ts`, `apps/server/src/app.ts`, `apps/server/src/devices.ts`, `packages/api/src/index.ts`, `apps/server/test/auth.test.ts`, `apps/server/package.json`
- Delete: `apps/server/scripts/new-device.ts`

**Interfaces:**
- Consumes: `auth`, `signIn`, `session`, `deviceCode`, `devices` (Task 1); `newDevice` (`src/devices.ts`).
- Produces: `APP_CLIENT_ID` and `LinkResponse` (`{ token, pc }`) from `@road-to-sixty/api`; `newDevice(userId, name, platform?)`; routes `GET /link`, `POST /v1/link?name=&platform=`, and Better Auth's `/api/auth/device/code`, `/api/auth/device/token`, `/api/auth/device` and `/api/auth/device/approve`.

- [ ] **Step 1: Write the failing tests**

Apply this to `apps/server/test/auth.test.ts`:

```diff
diff --git a/apps/server/test/auth.test.ts b/apps/server/test/auth.test.ts
index 7b83cbd..7ac29aa 100644
--- a/apps/server/test/auth.test.ts
+++ b/apps/server/test/auth.test.ts
@@ -1,13 +1,23 @@
+import { APP_CLIENT_ID, type LinkResponse } from "@road-to-sixty/api";
 import { beforeEach, expect, test } from "bun:test";
+import { eq } from "drizzle-orm";
 import { app } from "../src/app";
 import { accountHash } from "../src/auth";
 import { db } from "../src/db";
-import { account, user } from "../src/schema";
+import { account, deviceCode as deviceCodes, devices, session, user } from "../src/schema";
 import { signIn } from "./battlenet";
 import { reset } from "./helpers";
 
 beforeEach(reset);
 
+const post = (path: string, body: object, headers: Record<string, string> = {}) =>
+  app.handle(
+    new Request(`http://localhost:3000${path}`, {
+      method: "POST",
+      headers: { "content-type": "application/json", origin: "http://localhost:3000", ...headers },
+      body: JSON.stringify(body),
+    }),
+  );
 const get = (path: string, headers: Record<string, string> = {}) => app.handle(new Request(`http://localhost:3000${path}`, { headers }));
 
 test("signing in with Battle.net makes a player named by BattleTag, keyed by a hash of the account ID", async () => {
@@ -27,3 +37,62 @@ test("signing in again is the same player, with the BattleTag brought up to date
   expect(users.map((u) => u.name)).toEqual(["Annie#1234", "Bob#5678"]);
   expect((await db.select().from(account)).map((a) => a.accessToken)).toEqual([null, null]);
 });
+
+async function deviceCode(clientId = APP_CLIENT_ID) {
+  return post("/api/auth/device/code", { client_id: clientId });
+}
+
+// What the link page does with the code the player types.
+async function approve(userCode: string, cookie: string) {
+  await get(`/api/auth/device?user_code=${userCode}`, { cookie });
+  return post("/api/auth/device/approve", { userCode }, { cookie });
+}
+
+test("a PC is linked by the code its app shows, approved by the signed-in player", async () => {
+  const code = (await (await deviceCode()).json()) as { device_code: string; user_code: string; verification_uri: string };
+  expect(code.verification_uri).toBe("http://localhost:3000/link");
+
+  const tokenRequest = { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: code.device_code, client_id: APP_CLIENT_ID };
+  const early = await post("/api/auth/device/token", tokenRequest);
+  expect(await early.json()).toMatchObject({ error: "authorization_pending" });
+  await db.update(deviceCodes).set({ lastPolledAt: null }); // the app waits between polls
+
+  const cookie = await signIn();
+  expect((await approve(code.user_code, cookie)).status).toBe(200);
+  const { access_token } = (await (await post("/api/auth/device/token", tokenRequest)).json()) as { access_token: string };
+
+  const linked = await app.handle(
+    new Request("http://localhost:3000/v1/link?name=Desk&platform=windows", { method: "POST", headers: { authorization: `Bearer ${access_token}` } }),
+  );
+  const { token, pc } = (await linked.json()) as LinkResponse;
+  const [device] = await db.select().from(devices).where(eq(devices.id, pc));
+  expect(device).toMatchObject({ name: "Desk", platform: "windows" });
+  expect((await get("/v1/check", { authorization: `Bearer ${token}` })).status).toBe(200);
+  // The device sign-in's session is gone; only the PC token remains.
+  expect(await db.select().from(session).where(eq(session.token, access_token))).toEqual([]);
+});
+
+test("linking needs the device sign-in's token: not a cookie, and not twice", async () => {
+  const cookie = await signIn();
+  const link = (headers: Record<string, string>) => app.handle(new Request("http://localhost:3000/v1/link", { method: "POST", headers }));
+  expect((await link({})).status).toBe(401);
+  expect((await link({ cookie })).status).toBe(401);
+
+  const code = (await (await deviceCode()).json()) as { device_code: string; user_code: string };
+  await approve(code.user_code, cookie);
+  const tokenRequest = { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: code.device_code, client_id: APP_CLIENT_ID };
+  const { access_token } = (await (await post("/api/auth/device/token", tokenRequest)).json()) as { access_token: string };
+  expect((await get("/v1/check", { authorization: `Bearer ${access_token}` })).status).toBe(401); // a session is not a PC token
+  expect((await link({ authorization: `Bearer ${access_token}` })).status).toBe(200);
+  expect((await link({ authorization: `Bearer ${access_token}` })).status).toBe(401);
+});
+
+test("only the app may ask for a device code", async () => {
+  expect((await deviceCode("something-else")).status).toBe(400);
+});
+
+test("the link page is served", async () => {
+  const page = await get("/link");
+  expect(page.headers.get("content-type")).toContain("text/html");
+  expect(await page.text()).toContain("Link this PC");
+});
```

Run: `cd apps/server && LUA51=<PUC Lua 5.1> bun test test/auth.test.ts; cd ../..`
Expected: `SyntaxError: Export named 'APP_CLIENT_ID' not found in module` for `packages/api/src/index.ts`.

- [ ] **Step 2: The shared names**

Apply this to `packages/api/src/index.ts`:

```diff
diff --git a/packages/api/src/index.ts b/packages/api/src/index.ts
index fb1f693..3f698e6 100644
--- a/packages/api/src/index.ts
+++ b/packages/api/src/index.ts
@@ -1,6 +1,18 @@
 // What the sync API sends and receives, shared by the server, the website
 // and the app's window. The app's Rust side mirrors these by hand.
 
+// The desktop app's client ID for Better Auth's device sign-in
+// (/api/auth/device/code); the server accepts no other.
+export const APP_CLIENT_ID = "road-to-sixty-app";
+
+// POST /v1/link?name=&platform=, with the access token Better Auth's device
+// sign-in gave the app (/api/auth/device/token) as Authorization: Bearer.
+// That session ends; the app keeps the PC token instead.
+export type LinkResponse = {
+  token: string; // the PC token, for Authorization: Bearer on every /v1 call
+  pc: string; // this PC's ID, which the addon keeps its counts under
+};
+
 // POST /v1/upload?game=&realm=&name=&addon=&received=, body: the character's
 // SavedVariables file compressed with zstd.
 export type UploadQuery = {
```

- [ ] **Step 3: Device sign-in in Better Auth**

Apply this to `apps/server/src/auth.ts` and `apps/server/src/devices.ts`:

```diff
diff --git a/apps/server/src/auth.ts b/apps/server/src/auth.ts
index 09a941b..50a30cd 100644
--- a/apps/server/src/auth.ts
+++ b/apps/server/src/auth.ts
@@ -1,5 +1,8 @@
+import { APP_CLIENT_ID } from "@road-to-sixty/api";
 import { betterAuth } from "better-auth";
 import { drizzleAdapter } from "better-auth/adapters/drizzle";
+import { bearer } from "better-auth/plugins/bearer";
+import { deviceAuthorization } from "better-auth/plugins/device-authorization";
 import { genericOAuth } from "better-auth/plugins/generic-oauth";
 import { config } from "./config";
 import { db } from "./db";
@@ -55,5 +58,10 @@ export const auth = betterAuth({
         },
       ],
     }),
+    deviceAuthorization({
+      verificationUri: "/link",
+      validateClient: (clientId) => clientId === APP_CLIENT_ID,
+    }),
+    bearer(),
   ],
 });
diff --git a/apps/server/src/devices.ts b/apps/server/src/devices.ts
index 213bc29..b13152b 100644
--- a/apps/server/src/devices.ts
+++ b/apps/server/src/devices.ts
@@ -6,11 +6,14 @@ export type Device = typeof devices.$inferSelect;
 
 const hash = (token: string) => new Bun.CryptoHasher("sha256").update(token).digest("hex");
 
-// A new linked PC with a random token, which is shown once and stored only
-// as its hash. Stands in for Better Auth's device sign-in until it is built.
-export async function newDevice(userId: string, name: string): Promise<{ device: Device; token: string }> {
+// A new linked PC with a random token, which is handed to the app once and
+// stored only as its hash.
+export async function newDevice(userId: string, name: string, platform?: string): Promise<{ device: Device; token: string }> {
   const token = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
-  const [device] = await db.insert(devices).values({ id: crypto.randomUUID(), userId, name, tokenHash: hash(token) }).returning();
+  const [device] = await db
+    .insert(devices)
+    .values({ id: crypto.randomUUID(), userId, name, platform: platform ?? null, tokenHash: hash(token) })
+    .returning();
   return { device: device!, token };
 }
 
```

- [ ] **Step 4: The link endpoint and page**

Create `apps/server/src/link.ts`:

```ts
import type { LinkResponse } from "@road-to-sixty/api";
import { eq } from "drizzle-orm";
import { Elysia } from "elysia";
import { auth } from "./auth";
import { db } from "./db";
import { newDevice } from "./devices";
import { session } from "./schema";

const PAGE = Bun.file(`${import.meta.dir}/link.html`);

// Linking a PC (spec, "Linking the app"). The app shows a code from
// /api/auth/device/code, the player approves it on /link, and the app's
// poll of /api/auth/device/token returns a session. The app trades that
// session here for a PC token of its own, and the session ends.
export const link = new Elysia()
  .get("/link", () => new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } }))
  .post("/v1/link", async ({ headers, query, set }): Promise<LinkResponse | { error: string }> => {
    // Only the bearer token counts: a browser's sign-in cookie can't link a PC.
    const signedIn = headers.authorization
      ? await auth.api.getSession({ headers: new Headers({ authorization: headers.authorization }) })
      : null;
    if (!signedIn) {
      set.status = 401;
      return { error: "sign in on the link page first" };
    }
    const name = query.name?.trim().slice(0, 100) || "PC";
    const platform = query.platform?.slice(0, 20);
    const { device, token } = await newDevice(signedIn.user.id, name, platform);
    await db.delete(session).where(eq(session.id, signedIn.session.id));
    return { token, pc: device.id };
  });
```

Create `apps/server/src/link.html`:

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Link this PC · Road to Sixty</title>
<!-- Until the website is built (step 6), this page links PCs. -->
<style>
  body { font: 16px/1.5 system-ui, sans-serif; background: #0a0a0a; color: #ededed; max-width: 28rem; margin: 4rem auto; padding: 0 1rem; }
  input, button { font: inherit; padding: 0.5rem 0.75rem; border-radius: 6px; border: 1px solid #333; background: #111; color: inherit; }
  button { background: #2563eb; border: 0; cursor: pointer; }
  .quiet { color: #a1a1a1; }
</style>
<h1>Link this PC</h1>
<p id="who" class="quiet"></p>
<button id="sign-in" hidden>Sign in with Battle.net</button>
<form id="form" hidden>
  <input id="code" placeholder="Code from the app" autocomplete="off" required />
  <button>Link</button>
</form>
<p id="result"></p>
<script type="module">
  const $ = (id) => document.getElementById(id);
  const call = async (path, body) => {
    const r = await fetch(`/api/auth${path}`, body
      ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }
      : {});
    return { ok: r.ok, data: await r.json().catch(() => null) };
  };
  const signedIn = (await call("/get-session")).data;
  if (!signedIn) {
    $("sign-in").hidden = false;
    $("sign-in").onclick = async () => {
      const r = await call("/sign-in/social", { provider: "battlenet", callbackURL: location.pathname + location.search });
      if (r.data?.url) location.href = r.data.url;
    };
  } else {
    $("who").textContent = `Signed in as ${signedIn.user.name}`;
    $("form").hidden = false;
    $("code").value = new URLSearchParams(location.search).get("user_code") ?? "";
    $("form").onsubmit = async (e) => {
      e.preventDefault();
      const userCode = $("code").value.trim();
      // Looking the code up ties it to this player; only then can they approve it.
      const found = await call(`/device?user_code=${encodeURIComponent(userCode)}`);
      const r = found.ok ? await call("/device/approve", { userCode }) : found;
      $("result").textContent = r.ok
        ? "Linked. You can close this page; the app takes it from here."
        : `That didn't work: ${r.data?.message ?? "check the code and try again"}`;
    };
  }
</script>
</html>
```

Apply this to `apps/server/src/app.ts`:

```diff
diff --git a/apps/server/src/app.ts b/apps/server/src/app.ts
index 35edd87..eb74a77 100644
--- a/apps/server/src/app.ts
+++ b/apps/server/src/app.ts
@@ -1,9 +1,11 @@
 import { Elysia } from "elysia";
 import { auth } from "./auth";
+import { link } from "./link";
 import { sync } from "./sync";
 
 export const app = new Elysia()
   .get("/health", () => "ok")
   // Better Auth reads the request itself, so Elysia must leave the body alone.
   .all("/api/auth/*", ({ request }) => auth.handler(request), { parse: "none" })
+  .use(link)
   .use(sync);
```

- [ ] **Step 5: Run every server test**

Run: `cd apps/server && LUA51=<PUC Lua 5.1> bun test && bunx tsc --noEmit -p .; cd ../..`
Expected: `27 pass`, `0 fail`, and no type errors.

- [ ] **Step 6: Scripts in place of the hand-made tokens**

```bash
git rm apps/server/scripts/new-device.ts
```

Apply this to `apps/server/package.json`:

```diff
diff --git a/apps/server/package.json b/apps/server/package.json
index 0d7a689..a52ba77 100644
--- a/apps/server/package.json
+++ b/apps/server/package.json
@@ -7,8 +7,7 @@
     "start": "bun src/index.ts",
     "test": "bun test",
     "typecheck": "tsc --noEmit -p .",
-    "db:generate": "drizzle-kit generate",
-    "device:new": "bun scripts/new-device.ts"
+    "db:generate": "drizzle-kit generate"
   },
   "dependencies": {
     "@road-to-sixty/api": "workspace:*",
```

Create `apps/server/scripts/link-pc.ts`:

```ts
// Links this machine as a PC the way the desktop app will, to try sign-in
// against a running server. Prints the PC token once, and the PC's ID.
//   bun scripts/link-pc.ts <server URL> [PC name]
import { APP_CLIENT_ID, type LinkResponse } from "@road-to-sixty/api";

const [server, name = "Script"] = process.argv.slice(2);
if (!server) throw new Error("usage: bun scripts/link-pc.ts <server URL> [PC name]");

// Better Auth's device sign-in answers (RFC 8628).
type Answer = Record<string, string> & { interval: number };
const post = async (path: string, body: object) =>
  (await (await fetch(`${server}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })).json()) as Answer;

const code = await post("/api/auth/device/code", { client_id: APP_CLIENT_ID });
console.log(`Open ${code.verification_uri_complete} and link code ${code.user_code}.`);
for (;;) {
  await Bun.sleep(code.interval * 1000);
  const answer = await post("/api/auth/device/token", {
    grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    device_code: code.device_code,
    client_id: APP_CLIENT_ID,
  });
  if (answer.access_token) {
    const query = new URLSearchParams({ name, platform: process.platform });
    const linked = await fetch(`${server}/v1/link?${query}`, { method: "POST", headers: { authorization: `Bearer ${answer.access_token}` } });
    const { token, pc } = (await linked.json()) as LinkResponse;
    console.log(`Linked as PC ${pc}. Its token, shown only now:\n${token}`);
    break;
  }
  if (answer.error !== "authorization_pending" && answer.error !== "slow_down") throw new Error(answer.error_description ?? answer.error);
}
```

Create `apps/server/scripts/try-upload.ts`:

```ts
// Uploads a made-up journey as a linked PC, waits for the merge and
// downloads it, to try a running server end to end. The character is
// "Scripttest" on "Script Realm"; remove it once the website can.
//   bun scripts/try-upload.ts <server URL> <PC token>
import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { zstdDecompressSync } from "node:zlib";

const [server, token] = process.argv.slice(2);
if (!server || !token) throw new Error("usage: bun scripts/try-upload.ts <server URL> <PC token>");
const auth = { authorization: `Bearer ${token}` };
const who = { game: "_classic_beta_", realm: "Script Realm", name: "Scripttest" };

const t = Math.floor(Date.now() / 1000);
const file = `RoadToSixtyCharDB = {["version"] = 3, ["events"] = {{${t}, "on", 0, 0, 0, 10}, {${t + 60}, "off", 0, 0, 0}}}`;
const query = new URLSearchParams({ ...who, addon: "script" });
const upload = await fetch(`${server}/v1/upload?${query}`, { method: "POST", headers: auth, body: Bun.zstdCompressSync(file) });
console.log("upload:", upload.status, (await upload.json()) as UploadResponse);

for (let tries = 0; tries < 30; tries++) {
  const { characters } = (await (await fetch(`${server}/v1/check`, { headers: auth })).json()) as CheckResponse;
  const mine = characters.find((c) => c.realm === who.realm && c.name === who.name);
  if (mine?.version) {
    const download = await fetch(`${server}/v1/versions/${mine.version}`, { headers: auth });
    const text = new TextDecoder().decode(zstdDecompressSync(new Uint8Array(await download.arrayBuffer())));
    console.log(`merged as version ${mine.version}; sessions in it: ${text.split('"on"').length - 1}`);
    process.exit(0);
  }
  await Bun.sleep(1000);
}
throw new Error("no merged version after 30 s");
```

Run: `cd apps/server && bunx tsc --noEmit -p .; cd ../..`
Expected: no type errors.

- [ ] **Step 7: Try the page in a browser**

Run the server locally against the stand-in Battle.net: a scratch script (in the session scratchpad, not the repo) that imports `test/battlenet.ts`, runs `migrateDb()` and `startWorker()`, then `app.listen(3000)`, started with `bun --env-file=.env.test`. Then:

```bash
cd apps/server && bun scripts/link-pc.ts http://localhost:3000 Probe
```

Open the printed `/link?user_code=…` address in a browser (Playwright is fine), click "Sign in with Battle.net", then "Link".
Expected: the page shows "Signed in as Ann#1234" with the code filled in, then "Linked. You can close this page; the app takes it from here." `link-pc.ts` prints `Linked as PC <id>` and a token. `bun scripts/try-upload.ts http://localhost:3000 <token>` prints `merged as version <n>; sessions in it: 1`. Stop the server and remove any `.playwright-mcp/` folder it left in the repo.

- [ ] **Step 8: Commit**

```bash
git add apps/server packages/api
git commit -m "Server: link a PC with the code its app shows, approved on /link (#1)

The app trades the session Better Auth's device sign-in gives it for a PC
token of its own, stored only as a hash. scripts/link-pc.ts and
try-upload.ts replace the hand-made tokens for trying a server.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: CI, docs, and sign-in on the live server

**Files:**
- Modify: `.github/workflows/ci.yml`, `CLAUDE.md`
- Live: Dokploy's `sync-server` environment, the Battle.net developer client's return addresses

- [ ] **Step 1: CI and docs**

The smoke run inside the image loads the settings, which now include sign-in's. Apply this to `.github/workflows/ci.yml` and `CLAUDE.md`:

```diff
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index cc9e9f1..0df6538 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -79,4 +79,6 @@ jobs:
         run: >
           docker run --rm -e DATABASE_URL=unused -e S3_ENDPOINT=unused -e S3_BUCKET=unused
           -e S3_ACCESS_KEY_ID=unused -e S3_SECRET_ACCESS_KEY=unused
+          -e BETTER_AUTH_URL=unused -e BETTER_AUTH_SECRET=unused -e ACCOUNT_HASH_KEY=unused
+          -e BATTLENET_CLIENT_ID=unused -e BATTLENET_CLIENT_SECRET=unused
           rts-server bun apps/server/scripts/smoke.ts
diff --git a/CLAUDE.md b/CLAUDE.md
index a3be3c6..2bc8dbd 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -47,7 +47,8 @@ for data, its exact format; read that before changing a module.
 
 `apps/server/` is the sync server (#1): Elysia on Bun, Postgres through
 Drizzle, an S3 store (R2 in production). `src/sync.ts` is the API the app
-calls, `src/worker.ts` runs the merge jobs, `src/runner.lua` merges under
+calls, `src/auth.ts` is sign-in (Better Auth with Battle.net), `src/link.ts`
+and `src/link.html` link a PC, `src/worker.ts` runs the merge jobs, `src/runner.lua` merges under
 standard Lua 5.1 with the addon's pure files, and `src/schema.ts` holds the
 tables (migrations in `drizzle/`, made by `bun run db:generate`).
 `packages/api/` holds the request and response types the server, website
@@ -79,7 +80,8 @@ luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]
 docker compose up -d                # Postgres and an S3 store, for the tests and a local server
 bun test                            # server tests; LUA51 names Lua 5.1 if lua5.1 isn't on the path
 bun run dev                         # the server on port 3000, with .env (copied from .env.example)
-bun run device:new <user> <PC name> # link a PC by hand until sign-in exists; prints its token once
+bun scripts/link-pc.ts <server> [name]   # link this machine as the app will: approve the code on <server>/link
+bun scripts/try-upload.ts <server> <token>   # upload a made-up journey as that PC and wait for the merge
 ```
 
 Run the addon commands from `apps/addon/`. `check.ps1` currently reports three old
```

Run: `LUA51=<PUC Lua 5.1> bun run test && bun run typecheck`
Expected: the addon's 21 test files under both runtimes, `27 pass` from the server, and both typechecks successful.

Run: `docker build -q -f apps/server/Dockerfile -t rts-server . && bash -c 'docker run --rm -e DATABASE_URL=unused -e S3_ENDPOINT=unused -e S3_BUCKET=unused -e S3_ACCESS_KEY_ID=unused -e S3_SECRET_ACCESS_KEY=unused -e BETTER_AUTH_URL=unused -e BETTER_AUTH_SECRET=unused -e ACCOUNT_HASH_KEY=unused -e BATTLENET_CLIENT_ID=unused -e BATTLENET_CLIENT_SECRET=unused rts-server bun apps/server/scripts/smoke.ts'`
Expected: `merge ok, layout 3`. (Run it through `bash -c`: zsh passes an unquoted list of `-e` options as one argument.)

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml CLAUDE.md
git commit -m "Server: sign-in settings in CI's image check, and the docs (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: The live server's sign-in settings**

Dokploy deploys every push to `dev` that touches the server, and the server won't start without these, so they go in first. This keeps the secrets in Dokploy and in the private file only:

```bash
python3 - <<'PY'
import json, os, secrets, urllib.request
path = os.path.expanduser("~/.config/road-to-sixty/dokploy.env")
env = dict(l.strip().split("=", 1) for l in open(path) if "=" in l)
for key in ("BETTER_AUTH_SECRET", "ACCOUNT_HASH_KEY"):
    if key not in env:
        env[key] = secrets.token_hex(32)
        with open(path, "a") as f: f.write(f"{key}={env[key]}\n")
def call(name, body=None):
    request = urllib.request.Request(f"{env['DOKPLOY_URL']}/api/{name}", method="POST" if body else "GET",
        data=json.dumps(body).encode() if body else None,
        headers={"x-api-key": env["DOKPLOY_API_KEY"], "content-type": "application/json"})
    raw = urllib.request.urlopen(request, timeout=60).read()
    return json.loads(raw) if raw else None
app = call(f"application.one?applicationId={env['DOKPLOY_APPLICATION_ID']}")
settings = dict(l.split("=", 1) for l in app["env"].splitlines() if "=" in l)
settings.update({
    "BETTER_AUTH_URL": "https://api.rts.everhold.online",
    "BETTER_AUTH_SECRET": env["BETTER_AUTH_SECRET"],
    "ACCOUNT_HASH_KEY": env["ACCOUNT_HASH_KEY"],
    "BATTLENET_CLIENT_ID": env["BATTLENET_CLIENT_ID"],
    "BATTLENET_CLIENT_SECRET": env["BATTLENET_CLIENT_SECRET"],
})
call("application.saveEnvironment", {"applicationId": env["DOKPLOY_APPLICATION_ID"],
    "env": "\n".join(f"{k}={v}" for k, v in settings.items()),
    "buildArgs": app.get("buildArgs") or "", "buildSecrets": app.get("buildSecrets") or "", "createEnvFile": False})
print(sorted(settings))
PY
```
Expected: the list of setting names includes the five above beside `DATABASE_URL`, `PORT` and the four `S3_*`. No values are printed.

- [ ] **Step 4: Battle.net's return addresses (Jordan)**

Jordan changes the developer client's redirect URLs at develop.battle.net to:

```
https://api.rts.everhold.online/api/auth/callback/battlenet
http://localhost:3000/api/auth/callback/battlenet
```

- [ ] **Step 5: After the final review: merge, push, deploy**

Merge `sync-sign-in` into `dev`, run `bun run test` on the result, push `dev` (never `main`), and watch CI to the end (`gh run watch <id> --exit-status`).
Expected: `build` and `server` pass; `server`'s log shows `27 pass` and `merge ok, layout 3`.

Then wait for Dokploy's deployment of that commit (`deployment.all?applicationId=…`, newest entry) to reach `done`, and check:

```bash
curl -s https://api.rts.everhold.online/health
curl -s -o /dev/null -w "%{http_code}\n" https://api.rts.everhold.online/link
```
Expected: `ok`, then `200`. A deployment in `error` most likely means the migration failed or a setting is missing: read its log in Dokploy.

- [ ] **Step 6: Sign in for real (Jordan)**

```bash
cd apps/server && bun scripts/link-pc.ts https://api.rts.everhold.online "Jordan's Mac"
```
Jordan opens the printed address, signs in with Battle.net, and clicks Link.
Expected: the page shows "Signed in as <BattleTag>", then "Linked."; the script prints `Linked as PC <id>` and a token.

If Battle.net shows an error instead of its sign-in page, or the return to `/api/auth/callback/battlenet` fails with `invalid_grant` or a PKCE complaint, add `pkce: false` to the `battlenet` entry in `src/auth.ts`, ledger it, commit (`Server: Battle.net without PKCE (#1)`), push `dev`, wait for the deploy, and try again.

- [ ] **Step 7: A journey through the live server**

```bash
cd apps/server && bun scripts/try-upload.ts https://api.rts.everhold.online <token from step 6>
```
Expected: `upload: 200 { version: …, status: "queued" }`, then `merged as version <n>; sessions in it: 1`. It leaves a character "Scripttest" on "Script Realm" in Jordan's account, for the account API to remove later.

- [ ] **Step 8: Record it**

Comment on #1: sign-in and linking are live, the return address, the decisions above, whether PKCE stayed on, and that the spec's two Better Auth risks are settled. Update the spec's "Risks and things to verify" lines for Better Auth and Battle.net's `sub` with what the live sign-in showed, and commit that on `dev`.

---

## Notes for later steps

- **The desktop app (step 5)** opens `verification_uri_complete` in the browser and links with `APP_CLIENT_ID` through `/api/auth/device/code` and `/api/auth/device/token` (poll at `interval`, keep going on `authorization_pending` and `slow_down`), then `POST /v1/link?name=&platform=`. It keeps `token` in the Keychain or Credential Manager and writes `pc` into the sync folder as `RoadToSixtySync.pc`. `scripts/link-pc.ts` is the reference.
- **The website (step 6)** only offers downloads, picked by the visitor's platform. It needs nothing from the server's sign-in.
- **The account API**, called by the app's window with its PC token, lists and unlinks PCs (`devices.revoked_at`) and deletes everything. Deleting a user must remove `devices` and `characters` rows first, since their foreign keys don't cascade.
- **Release:** add `https://api.roadtosixty.online/api/auth/callback/battlenet` to the Battle.net client, and serve both domains during the switch.
