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
  window calls (characters, history, restore, remove one character, PCs,
  export, delete everything). Both start from `src/pc.ts`, the PC token check.
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
  tries again for about a day with a doubling wait; a time or memory limit
  gets one more try only. A job left running past `STALE_SECONDS` is taken
  back by the next claim. The worker takes the next job from the account it
  served least recently.
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
- Limits (spec 2026-10-15, `src/limits.ts`): per PC, 120 uploads in 15
  minutes and 600 requests an hour; per account, 240 uploads in 15
  minutes, 500 and 200 MB a day, 2,000 requests an hour, 10 links a day, 5
  exports and 10 restores an hour; 200 new players an hour; one export and
  one restore at a time. All answer 429. 20 linked PCs per account (409),
  100 characters (422, plain text the app shows on the row), 8 MB uploads
  and 16 KB for any other body (413), 64-character names (400). The counts
  are in memory, so a restart forgets them.
- `api.roadtosixty.online` is behind Cloudflare's proxy. When
  Cloudflare changes its ranges (https://www.cloudflare.com/ips/), update
  `src/proxies.ts`, or sign-in limits count Cloudflare instead of visitors.
- The clean-up never deletes a version row, only files, and sets
  `pruned_at` before deleting. It keeps each character's newest 100
  versions, the head, and those marked `weekly` (each finished week's
  newest, and any version a restore replaced). Anything that reads a
  version's file must skip pruned versions, and a restore must lock its
  source `FOR SHARE` and check it isn't pruned. `PRUNE` is `dry` by
  default: read its log before setting `on` in Dokploy.
- A name has a row per journey (spec 2026-10-15, journeys): the addon's
  stamp, `journeyId`, is read from each upload (`stampOf`) and kept on the
  row and the upload. The newest row of a name is its current journey;
  check offers only that, so a PC is never handed an earlier one. A stamped
  upload queued against a row from before stamps joins it only when
  `runner.lua`'s `same` mode says it continues it; otherwise the worker
  moves it to its own row. An upload without a stamp never goes to a newer
  journey than the oldest.
- Removing a character locks its jobs and answers 409 while one runs, and
  while it is a name's current journey with earlier ones left (removed
  first, an earlier one would become current again); its files go only
  when no other version of the account shares them. The app's "Remove all
  beta characters" removes oldest first, so it never meets that 409.
- Secrets live in Dokploy and in `.env`, which git ignores. Never put one in
  code, a test or an issue.
