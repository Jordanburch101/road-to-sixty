# Sync server (apps/server)

The backend for sync and backup (#1): Elysia on Bun, Postgres through
Drizzle, journeys in an S3 store (Cloudflare R2 in production), sign-in with
Battle.net through Better Auth. Dokploy builds it from `Dockerfile` on every
push to `main` that touches it. The design is
`docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`.

## Layout

- `src/index.ts` starts the server and the merge worker; `src/app.ts` puts
  the routes together; `src/config.ts` reads the settings `.env.example`
  lists.
- `src/sync.ts` is the API the desktop app calls with its PC token:
  upload, check, download. `src/account.ts` is the account API the app's
  window calls (characters, history, restore, PCs, export, delete
  everything). Both start from `src/pc.ts`, the PC token check.
- `src/auth.ts` is Better Auth with Battle.net (the account ID is kept only
  as a keyed hash); `src/auth-schema.ts` holds its tables.
- `src/link.ts`, `src/link.html` and `src/link-page.ts` link a PC: the
  app's link fills its code in on `/link`, the player sees the PC's name the app sent
  in the code's `scope`, and approves it; the app trades it for a PC token
  (`src/devices.ts`, which keeps only the token's hash). The page's script
  is built once by `Bun.build`, draws the fog from `packages/ui` (so the
  image copies that package), and is typechecked with the browser's types
  by `tsconfig.page.json`, kept apart so they don't clash with Bun's.
- `src/limits.ts` counts each PC's and account's requests, uploads and
  exports; `src/proxies.ts` lists the proxies sign-in trusts (Dokploy's and
  Cloudflare's); `src/prune.ts` is the daily clean-up of old versions,
  finished jobs and expired sign-in rows.
- `src/worker.ts` runs merge jobs one at a time per character; it fills
  each character's level, class and time played, and each merged
  version's level, from the runner's `ok` line;
  `src/lua.ts` starts `src/runner.lua` under standard Lua 5.1, with the
  addon's pure files, under a memory and time limit.
- `src/schema.ts` holds the tables; migrations are in `drizzle/`, made by
  `bun run db:generate`, never by hand.
- `src/storage.ts` reads and writes journeys in the bucket and refuses
  anything that unpacks past 32 MB.
- `test/` holds the tests; `test/battlenet.ts` stands in for Battle.net's
  sign-in. `scripts/` holds tools to try a running server by hand.

## Commands (from apps/server)

```
docker compose up -d      # Postgres and an S3 store for the tests and a local server
bun test                  # needs Lua 5.1 on the path, or LUA51 naming it (not LuaJIT:
                          # its count hook doesn't fire, so the limit tests fail)
bun run typecheck
bun run dev               # port 3000, with .env copied from .env.example
```

## Rules that bite

- The request and response shapes live in `packages/api`; the desktop
  app's Rust side mirrors them by hand. Change all three together.
- Never change `ACCOUNT_HASH_KEY` once players have signed in: everyone
  would come back as a new account.
- Uploads are untrusted. Keep the size cap and the bytecode refusal, and
  never run a journey anywhere but inside the runner's process limits.
- The runner tells a refusal from a fault. Only an `error(why, 0)` from the
  merge rules rejects an upload. Anything else (a limit, a crash, a bug with
  a file and line, storage down) makes `runMerge` throw, and the worker
  tries again for about a day with a doubling wait. A job left running past
  `STALE_SECONDS` is taken back by the next claim.
- An upload made before the latest restore reached its PC is merged
  without the play inside every restore's windows (`versions.removed`,
  worked out by the restore route with `runWindows`). Only a restore made
  before windows were kept (`removed` is null) still sets it aside.
- The link page fills the code in from the app's link (Jordan's call), so
  a link with someone else's code works too. Keep the PC's name and the
  "check the code matches" note on the page; they are what's left of the
  protection.
- Test journeys are made up (`test/helpers.ts`). Real saved files hold other
  players' names and never go into a test.
- Limits (spec 2026-10-15): 30 uploads per PC in 15 minutes, 600
  requests an hour, 60 uploads per account in 15 minutes and 500 a day,
  and 5 exports an hour answer 429, which the app retries; 20 linked PCs
  per account (409 on the 21st); 8 MB compressed and 64-character names
  answer 413 and 400; a 101st character answers 422 in plain text, which
  the app shows on the row. The counts are in memory.
- `api.roadtosixty.online` is behind Cloudflare's proxy. When
  Cloudflare changes its ranges (https://www.cloudflare.com/ips/), update
  `src/proxies.ts`, or sign-in limits count Cloudflare instead of visitors.
- The clean-up never deletes a version row, only files, and sets
  `pruned_at`. Anything that reads a version's file must skip pruned
  versions. `PRUNE` is `dry` by default: read its log before setting `on`
  in Dokploy.
- Secrets live in Dokploy and in `.env`, which git ignores. Never put one in
  code, a test or an issue.
