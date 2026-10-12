# Sync and backup: design

Issue #1. Pre-launch addon changes are in #35. Written 2026-10-12.

## What this is for

A player who plays one character on two computers, say a Windows PC and a Mac, ends up with two partial journeys today. WoW keeps addon data on each machine and never syncs it. A player who wipes their PC or reinstalls the game loses their journey outright.

This design adds a free service with three parts:

- a website where players sign in with Battle.net and download a desktop app,
- a desktop app that backs up each character's journey after every session and brings back the merged journey from the other machine,
- a server that merges recordings of the same character, keeps the merged journey and a history of versions, and lets players restore an older one.

The addon keeps working exactly as it does today for anyone who never installs the app.

Success means a player plays one character on two machines and sees one complete journey on both, with nothing counted twice and nothing lost, and a player who loses their PC gets their journey back by installing the app and signing in.

There is no deadline. The service should be solid before it ships. The only time-critical part is #35, because journeys recorded at launch (2026-11-04) can't be redone.

## Decisions

| Area | Decision |
|---|---|
| Sign-in | Battle.net, through Better Auth running in the backend |
| Linking the app | Better Auth device sign-in: the app shows a code, the player confirms it on the website |
| Where the merge runs | One `Merge.lua` in plain Lua 5.1. The server runs it to keep the merged journey. The addon runs the same file at login to fold the server's copy into anything played since |
| Delivery to the PC | The app writes its own addon folder, `RoadToSixty_Sync`. It never writes the game's SavedVariables |
| Backend | Elysia on Bun, deployed by Dokploy on our own server, with Postgres beside it |
| Website | Next.js on Vercel |
| File storage | Cloudflare R2: one bucket for journeys, the existing Dokploy R2 connection for Postgres backups |
| Desktop app | Tauri v2 with Rust, Windows and macOS. Linux and Steam Deck later |
| Signing | Mac unsigned at first. Windows unsigned at first, then the free Microsoft Store listing |
| Repo | Turborepo with Bun workspaces. Every part, the addon included, under `apps/` |
| Domains | Testing on a subdomain of `everhold.online`, release on `roadtosixty.online` |
| Look | Dark, minimal, Vercel-like, shadcn components, electric blue accent, built around Jordan's compass icon |

Approaches considered for the merge and turned down:

- A server-only merge written in TypeScript or Go. The addon tidies its own data at every login (joining dungeon visits, dropping duplicate deaths, lowering totals to match). A second copy of those rules in another language would drift from the addon with every new module, and the offline tests would not catch it.
- A server that only stores files and an addon that does all the merging. It works, but the database would never hold the merged journey, and Jordan wants the server to hold it.

## How the pieces connect

```
 PC (Mac or Windows)                         Our server (Dokploy)              Vercel
 ┌──────────────────────────────┐           ┌──────────────────────┐          ┌──────────────┐
 │ WoW                          │           │ Elysia on Bun        │          │ Next.js site │
 │  SavedVariables/RoadToSixty  │──read──┐  │  Better Auth         │◀─cookie──│              │
 │  AddOns/RoadToSixty_Sync ◀───┼──write─┤  │  sync API            │          └──────────────┘
 │                              │        │  │  merge worker ─ lua5.1│
 │ Desktop app (Tauri) ─────────┼────────┴─▶│  Postgres            │
 └──────────────────────────────┘   HTTPS   └──────────┬───────────┘
                                                       │
                                              R2: journeys bucket
                                              R2: Postgres backups
```

The app talks straight to the backend. Nothing large goes through Vercel, which caps request bodies at 4.5 MB.

## The addon

### New files

- `Merge.lua` holds the merge rules. Plain Lua 5.1 with no game calls, so the server and the offline tests run it unchanged.
- `Parse.lua` reads saved-data text. It accepts data only (tables, strings, numbers, booleans) and refuses anything that looks like code, so a journey from outside can never run in game.
- `Packed.lua` holds the packed kill and path formats (decode kills, pack kills, decode a path segment) as plain functions, used by the journal, the recorder and the merge.
- `Tidy.lua` holds the login tidy-ups now inside `Journal.lua` (`TidyRuns`, `TidyEvents`) and `Guilds.lua` (`Guilds:Tidy`), moved into plain functions. The addon calls them at login as before, and the merge calls them on each input.
- `Sync.lua` reads the sync folder at login and merges or replaces.

### The sync folder

The app owns `Interface/AddOns/RoadToSixty_Sync/`. It holds:

- `RoadToSixty_Sync.toc`, with its `Interface` number copied from `RoadToSixty.toc` so the game never marks it out of date,
- `data.lua`, setting one global with the PC's ID and, per character, the version ID, a replace flag and the journey as one long string.

Shipping each journey as a string keeps `data.lua` far below the game's limit on distinct constants in one file. `Parse.lua` turns the string back into tables.

`RoadToSixty.toc` lists `RoadToSixty_Sync` under `## OptionalDeps`, so the sync data is loaded first whenever it exists. The sync folder sits outside `RoadToSixty/` because the CurseForge app reinstalls addon folders whose files have changed.

The game reads a new addon folder only when it starts. The app creates the folder during setup and asks the player to restart WoW once.

### At login

1. If the sync folder holds a version for this character newer than `ns.char.syncedVersion`, parse it.
2. If the replace flag is set (a restore), replace the character's data with it. Otherwise merge it into the character's data.
3. Set `ns.char.syncedVersion` to that version ID.
4. Run the usual login tidy-up over the result.

Parsing and merging a full 3 MB journey in the game's Lua may take a second or two. If that stutters, spread the work over frames. This is a test item, not an open design question.

### Counts that can't be recounted

The time spent with each player met (`people[guid]` groups, seconds, raids, raid seconds, dungeons, raid runs) and rare kill counts (`rares[key].count`) cannot be rebuilt from events without porting all of `Groups.lua`. These move to per-PC tallies: each PC keeps its own numbers under its PC ID, a merge keeps the higher tally for each PC, and the number shown is the sum across PCs. The PC ID comes from the sync folder. Without the app, the addon makes a random ID once and keeps it in the account saved variables. Code that reads these counts goes through one helper that sums the tallies.

This is a data layout change, so `version` goes up with it.

### Left out for now

A copy-and-paste import for players without the app. `Parse.lua` and `Merge.lua` make it a small addition later.

## The merge rules

`Merge(a, b)` takes two copies of one character's data and returns one. Three properties hold for every input, and the tests check them:

- `Merge(a, b)` equals `Merge(b, a)`,
- `Merge(a, a)` equals `a`,
- `Merge(Merge(a, b), c)` equals `Merge(a, Merge(b, c))`.

These make repeated syncs, out-of-order uploads and stale copies safe.

Before merging, each input goes through `Tidy.lua`, so both look the way the game would leave them after a login.

| Data | Rule |
|---|---|
| Sessions | A session runs from an `on` event to its `off`. One character can't be online on two machines at once, so sessions from different machines never overlap. A session is identified by its `on` time on the server clock (#35). Sessions found in one copy only are kept. A session in both becomes one, the fuller copy winning |
| Events | Matched by time, kind and what the event is about: questID for `qa` and `qd`, slot for `eq`, item link for `loot`, player GUID for `grpa`, `grpl` and `grps`, instanceID for `in` and `out`, factionID for `rep`, name for `prof` and `rec`, mountID for `mount`, spellID for `ride`, guild name for `gj`, `gl` and `gr`, rare key for `rare`, level for `lvl`, uiMapID for `zone`, time and kind alone for `on`, `off`, `die`, `grpx` and `grpk`. Some modules fill in details after logging (group members, guild tabard, recipe details, run summaries), so a matched pair keeps every detail either copy has. Two identical events in one second, such as two copies of the same green drop, stay as two: the merge keeps the larger count of each match |
| Path segments | Matched by start time, continent and mode. A stale copy's path string is always the start of the newer one, so the longer wins. Sorted by start time, since teleport detection compares each segment with the previous one |
| Kills | Both packed strings decoded to time, XP and mob name, combined keeping the larger count per match, then packed again with a fresh name list and a recomputed `last` |
| Totals | Recounted from the merged data: kills and kill XP from the kill list, quests and quest XP from `qd`, deaths from `die`, instances from `in`, distance and flown from the path. For journeys recorded before something was counted, the part of each copy's total that the recount can't explain is carried over, keeping the larger leftover |
| Level snapshots | A full snapshot beats one taken at a later login, then the earliest wins. Gear, money, skills and `played` are kept as recorded. The counts in each snapshot are recounted at the snapshot's time |
| Growing sets | Recipes and mounts combine. Riding and profession ranks keep the higher value. `played` keeps the higher value. Rares keep the earliest first kill |
| Current state | Guild, reputation, the group in progress, the dungeon in progress, `lastZone`: taken from the copy whose last session ended latest |
| Per-PC tallies | Higher tally per PC ID |
| Never merged | Settings, which stay per machine, and the roster's copy of the journey, which the addon rebuilds. The merge clears `rosterBuilt` so the next login rebuilds it |

The merge refuses, with a reason, when a copy is a seeded test journey (`seeded`), when its `version` is newer than the merge knows, or when the two copies are different characters.

After merging, the server checks the result before accepting it: every session from both inputs is present, and no total or tally is lower than in either input.

### Rules for writing `Merge.lua`, `Parse.lua`, `Tidy.lua` and `Packed.lua`

These files run in WoW's Lua, in standard Lua 5.1 on the server and in LuaJIT in the tests, and must behave the same in all three:

- never depend on the order `pairs` returns, and sort keys wherever order matters,
- never use `#` on tables with holes,
- standard Lua 5.1 only: no WoW globals (`wipe`, `strsplit`, `tinsert`, `CopyTable`) and no LuaJIT extras,
- build strings from integers only.

## The backend

One Bun service in `apps/server`, using Elysia. Dokploy builds it from a Dockerfile based on the official Bun image, which also installs the `lua5.1` package and copies `Merge.lua`, `Parse.lua`, `Tidy.lua` and `Packed.lua` from `apps/addon/RoadToSixty/`.

It holds:

- Better Auth, with Battle.net through its generic OAuth plugin (Battle.net publishes its OpenID settings at `https://oauth.battle.net/.well-known/openid-configuration`) and its device authorization plugin for linking the app,
- the sync API for the app,
- the account API for the website,
- the merge worker,
- the daily cleanup job.

Postgres is reachable only from the backend.

### Sync API, called by the app with its PC token

- **Upload** a compressed character file, with game folder, realm, character, addon version and the fingerprint of the last version this PC received. Files over 32 MB uncompressed are refused, as are files starting with compiled Lua bytecode (first byte 0x1B).
- **Check** the newest merged version of every character this user has, including characters only ever played on another PC.
- **Download** one version.

The upload format leaves room for sending only the difference from a previous version later. Version one sends whole files: about 400 KB compressed for a level 60 journey.

### Account API, called by the website as the signed-in user

List characters, list a character's versions, restore a version, list and unlink PCs, download all my data as a zip, delete everything.

### Merge jobs

An upload is stored straight away and a job goes into a `jobs` table. The worker takes jobs one at a time per character, so two uploads for one character never merge at once. Each job:

1. fetches the upload and the character's current merged version from R2,
2. starts `lua5.1 runner.lua` with `Bun.spawn`, under a memory cap and a time limit, with only the two files,
3. inside that process, parses both, tidies both, merges, runs the checks and writes the result,
4. stores the result in R2 as a new `merged` version with two `version_parents` rows,
5. moves the character's current version to it.

A failed check, a crash or a timeout marks the job and the upload rejected with the reason. The character keeps its old merged version. The website shows the problem.

The first upload of a character becomes its first merged version with no merge needed.

### Mismatched addon versions

Every request from the app carries the PC's addon version. The server never sends a version in a data layout newer than that addon understands. The app and the website show "update the addon on this PC" instead.

### Restore

Restoring a version creates a new version with the replace flag set. The app delivers it, and the addon replaces its data for that character instead of merging. The pre-restore version stays in history, so a restore can be undone.

## Storage

### Postgres

Better Auth's own tables (users, sessions, accounts, device codes), plus:

```
devices          id, user_id, name, platform, app_version, addon_version, last_seen_at, revoked_at
characters       id, user_id, game, realm, name, class, level, played, last_played_at,
                 head_version_id, updated_at          unique (user_id, game, realm, name)
versions         id, character_id, device_id, kind ('upload' | 'merged' | 'restore'),
                 fingerprint, raw_size, data_version, addon_version, status, reject_reason, created_at
version_parents  version_id, parent_id
jobs             id, character_id, version_id, state, attempts, error, created_at, finished_at
account_backups  id, user_id, device_id, game, account_hash, fingerprint, created_at
```

Device tokens are Better Auth's. The server stores only their hashes. The Battle.net account ID is stored as a hash, and the BattleTag is refreshed at each sign-in, as Blizzard's API terms require.

The server fills in `level`, `class`, `played` and `last_played_at` when it accepts an upload, so the website lists characters without opening any file.

The account-wide file is backed up at most once a day and never merged.

### R2

The journeys bucket holds every upload and every merged result at `<user id>/<fingerprint>.zst`, compressed with zstd. Identical files are stored once. The backend has its own access key for this bucket.

The backups bucket is Dokploy's existing R2 connection, used for a daily Postgres backup. Keeping journeys in a separate bucket means a cleanup rule for database backups can never touch them.

### History and size

A daily job keeps every version for 30 days and one per week after that. It never deletes a character's current version, or any version an unfinished job, a recent merge or a restore depends on.

A full level 60 character file is 2 to 3 MB, about 400 KB compressed. The account file adds about 650 KB per character before compression. At 20,000 players with three characters each, the journeys bucket holds roughly 0.3 to 0.5 TB under the retention rule, about $5 to $8 a month on R2. R2 charges nothing for downloads.

### Recovery

The journeys bucket is off our server, so a dead disk loses no journeys. Postgres can lose at most a day back to its last backup. Each app remembers the fingerprint of everything it uploaded, and uploads again if the server doesn't recognise it.

### Deleting an account

Delete removes the user's rows and their whole prefix in the journeys bucket. Postgres backups age out within 30 days, and the privacy policy says so.

### Privacy

Stored personal data: a hash of the Battle.net account ID, the BattleTag, character names, where the character went, and the names and GUIDs of other players met in groups. Nothing is public. If journeys are ever shown publicly, other players' names must be hidden first.

## The desktop app

Tauri v2 in `apps/desktop`. It lives in the Mac menu bar and the Windows tray, with a small window (about 360 px wide) for first-run setup and status. The menu shows the status ("Synced 2 minutes ago", "Update the addon on this PC"), then Link this PC, Game folders, Open website, Pause syncing, Quit.

### First run

1. Find WoW installs: Battle.net's own install list (`C:\ProgramData\Battle.net\Agent\product.db` on Windows, `/Users/Shared/Battle.net/Agent/product.db` on Mac), the default locations (`C:\Program Files (x86)\World of Warcraft`, `/Applications/World of Warcraft`), then a folder picker. Inside each install, check every game folder matching `_*_` that has the addon, so the folder name Forever launches with doesn't matter. Each game folder's `.build.info` names its product.
2. Link the PC through Better Auth's device sign-in. The token goes into the Mac Keychain or Windows Credential Manager.
3. Create `RoadToSixty_Sync` in every game folder with the addon, and ask the player to restart WoW once.

### While running

- Watch each `WTF` folder. When a character's `RoadToSixty.lua` changes, wait until it has been unchanged for about ten seconds, then upload it. Reading while the game runs is safe.
- While the game runs, upload each character at most once every 15 minutes, so repeated `/reload`s don't flood the server. When the game closes, upload straight away.
- Upload the account file at most once a day. Fingerprint WTF account folder names before they leave the PC.
- Remember the fingerprint of everything uploaded and received. Queue uploads while offline.
- Check for new merged versions after each upload and every few minutes. Write a new version into `RoadToSixty_Sync/data.lua` by writing a temporary file in the same folder and renaming it over the old one, so the game never reads half a file.
- Never write the game's SavedVariables, not even for a restore.

Detecting whether the game is running (to apply the 15-minute limit) matches the running process's file path against the game folder, since process names differ by version and processor (`WowClassic.exe`, `WowClassicB.exe`, `WowClassic-arm64.exe`, the binary inside `World of Warcraft Classic.app`).

### Start at login and updates

On macOS the app registers through `SMAppService` (macOS 13 and later), so it appears under System Settings, General, Login Items. On Windows it uses the per-user `Run` registry key. Updates come through Tauri's updater, which checks the app's own signature against a manifest published with each GitHub release. That works without Apple or Microsoft signing.

### Signing and builds

The Mac build is unsigned at first, apart from the ad-hoc signature the Rust toolchain adds, which Apple Silicon needs to run any binary. The download page shows the System Settings, Privacy & Security, "Open Anyway" steps with screenshots. Windows ships as an unsigned per-user installer that needs no admin rights at first, with the "More info, Run anyway" steps on the download page, and moves to the free Microsoft Store individual account once stable.

GitHub Actions builds one universal Mac app (Intel and Apple Silicon) and the Windows installer. App releases use `app-*` tags so they never trigger the addon's `v*` release workflow.

## The website

Next.js on Vercel in `apps/web`. It talks only to the backend, as the signed-in user, through Better Auth's client and its shared cookie.

| Page | Contents |
|---|---|
| Home | What sync does, Mac and Windows downloads from the latest GitHub release, the "Open Anyway" and "Run anyway" steps, and a note that the addon works without the app |
| Sign in | Battle.net only |
| Link | Shows the code from the app, "Link this PC" |
| Characters | Each character with level, class, time played, last sync and which PC. Problems flagged: a rejected merge, a PC whose addon needs updating |
| Character history | Versions over time (upload, merged, restore, which PC), "Restore this version" with a confirmation that says the current version stays in history |
| PCs | Linked PCs with name, platform, app and addon versions, last seen, "Unlink" |
| Account | "Download all my data" (a zip of each character's latest merged file), "Delete everything" with confirmation |
| Privacy, Terms | Required by Blizzard's API terms and privacy law |

Viewing journeys on a map in the browser is left out. Storing journeys as whole files keeps it possible.

### Look

Dark and minimal in the Vercel style: near-black background, thin borders, plenty of space, the Geist font, shadcn components close to their defaults. One accent colour, the electric blue from the icon, used for buttons, links, the sync status dot and a soft glow behind the icon on the home page. The icon's compass rings may appear as faint lines behind the home page's top section and nowhere else.

The site and the app's window share one set of components and colours in `packages/ui`.

The icon is the glowing blue compass Jordan provided, used for the site, the app and its installers. This was Jordan's call after the question of whether it is Blizzard art came up. If Blizzard objects later, the icon files in `packages/ui` are the one place to swap it.

Before any screen is built, mock the key ones (home, characters, character history, the app's window, first-run setup) with a few candidate looks each, and Jordan picks from screenshots.

### Domains

During testing, the site and backend sit on a subdomain of `everhold.online`, for example `rts.everhold.online` and `api.rts.everhold.online`. At release they move to `roadtosixty.online` and `api.roadtosixty.online`.

- The sign-in cookie is scoped to the site's own domain (`rts.everhold.online` during testing), never to all of `everhold.online`.
- Every address (backend URL, site URL, cookie domain, allowed origins) comes from environment variables in Dokploy and Vercel, never from code.
- The Battle.net developer client lists the return address for each domain, or testing uses its own client.
- Each app build has the backend address built in. Everhold builds are for testers only. The first public build points at `api.roadtosixty.online`. During the switch Dokploy serves the backend on both domains. Players sign in again on the new site. PC links keep working.

The domains contain no Blizzard trademarks, as the API terms require.

## Repo layout

The repo becomes a Turborepo workspace with Bun. The addon moves into `apps/addon/` as the first commit of the workspace step, after #35 has shipped. Its folder keeps the name `RoadToSixty`, because WoW loads an addon only from a folder named like its `.toc`.

```
road-to-sixty/
├── package.json, turbo.json, bun.lock, tsconfig.base.json
├── CLAUDE.md, README.md, CHANGELOG.md, LICENSE
├── .github/workflows/
│   ├── ci.yml                addon checks (LuaJIT and Lua 5.1), bun turbo test
│   ├── release.yml           addon release on v* tags
│   ├── curseforge-check.yml
│   └── desktop-release.yml   app builds on app-* tags
├── apps/
│   ├── addon/
│   │   ├── package.json      tasks: test, check, package
│   │   ├── check.ps1, .luarc.json
│   │   ├── RoadToSixty/      the addon; Merge.lua, Parse.lua, Tidy.lua, Packed.lua, Sync.lua added
│   │   ├── tests/            existing tests plus merge, parse, tidy and sync tests
│   │   └── scripts/          package.ps1, sync-version.ps1, curseforge.sh, changelog.sh,
│   │                         zone-overlays.py and the texture scripts
│   ├── server/
│   │   ├── Dockerfile, package.json, drizzle/
│   │   ├── src/              index.ts, auth.ts, schema.ts, sync.ts, account.ts,
│   │   │                     worker.ts, lua.ts, runner.lua, storage.ts, cleanup.ts
│   │   └── test/
│   ├── web/
│   │   ├── app/              the pages above
│   │   └── lib/              auth-client.ts, api.ts
│   └── desktop/
│       ├── src/              the window (Vite and React, from packages/ui)
│       └── src-tauri/src/    main.rs, installs.rs, watch.rs, link.rs, sync.rs, inbox.rs, state.rs
├── packages/
│   ├── ui/                   shadcn components, colours, Geist, the icon
│   └── api/                  request and response types for server, web and the app's window
├── docs/superpowers/specs/
└── branding/
```

The move updates every path that points at `RoadToSixty/` from the repo root: `package.ps1`, `check.ps1`, `.luarc.json`, `ci.yml`, `release.yml`, the tests' `loadfile` calls, the data generator scripts, CLAUDE.md's layout table, and the dev junction on Jordan's Windows PC.

The Rust side of the app mirrors the few upload and download shapes from `packages/api`. A server test checks that they still match.

Vercel builds `apps/web` and Dokploy builds `apps/server`, each only when its own folder or a package it uses changes. The addon release build still copies only the `RoadToSixty` folder.

## Testing

- **Merge.** Offline tests run under both LuaJIT and standard Lua 5.1, with CI installing both. One test per rule. Checks of the three merge properties on generated journeys. Scenario tests that split a seeded journey across two PCs and play out four cases: a new PC with no data, shared history with new play on both, an old pre-sync copy against a newer merged one, and a hand-copied WTF folder.
- **Parse.** Writing a journey out and reading it back gives identical data. Code, compiled bytecode and deep nesting are refused.
- **Tidy.** The moved tidy-ups give the same results as before the move.
- **Sync, addon side.** Merge, replace, and a version already merged.
- **Server.** Bun tests for upload, merge jobs, rejected merges, mismatched addon versions, restore, delete. The Lua process limits are tested with a memory bomb and an endless loop.
- **App.** Rust tests for finding installs, waiting for a file to settle, the 15-minute limit and the safe write. Hands-on testing on a Mac and a Windows PC.
- **In game.** The sync folder loads, the login merge works, and a full-size journey merges without a long freeze.
- **End to end.** Jordan plays one character on a Mac and a PC and gets one journey on both.

## Build order

Each step is usable on its own.

1. #35: server clock, data version, size test. Ships before launch.
2. `Packed.lua`, `Tidy.lua`, `Parse.lua` and `Merge.lua` with their tests. Pure Lua, no servers.
3. The addon reads a sync folder (`Sync.lua`), tested with a hand-made one.
4. Workspace: move the addon to `apps/addon`, add Turborepo and Bun. Then the server: auth, upload, storage, merge jobs.
5. The desktop app: install finding, linking, upload, delivery.
6. Mockups, then the website and the app's window.
7. Testers on `everhold.online`, then the public release on `roadtosixty.online`.

## Costs per year

| Item | Cost |
|---|---|
| Battle.net developer access | $0 |
| Domains | about $20 to $40 |
| R2 journeys storage | about $60 to $100 at 20,000 players |
| Server | already running |
| Apple Developer Program | $0 while the Mac build is unsigned ($99 if that changes) |
| Microsoft Store individual account | $0 |
| UK data protection fee, if it applies | about £52 |

Sync stays free: Blizzard's addon policy forbids charging for addon services.

## Risks and things to verify

- `GetServerTime()` on Forever is unverified. #35 checks it first.
- Journeys recorded before #35 ships use each PC's own clock. Sessions from two machines with skewed clocks may look as if they overlap. The merge keeps both such sessions rather than guessing, and the `played` values in level snapshots, which come from the game server, can show which came first. Expect this only for beta journeys.
- The game's limit of about 262k distinct constants per file. #35 tests a huge seeded journey. If the recorder hits it, the save format changes before launch regardless of sync.
- Better Auth's generic OAuth plugin with Battle.net, and its device authorization plugin, are expected to work but unverified. Check on day one of step 4.
- Battle.net's userinfo is reported to return a numeric ID and the BattleTag. Libraries disagree on which one `sub` holds. Check with a real sign-in.
- macOS is not expected to ask permission to read `/Applications/World of Warcraft/`, because WTF sits beside the game app rather than inside it. Verify on current macOS.
- Login merge time for a full journey in the game's Lua. Measure in step 3.
- Forever's game folder name at launch is unknown. The app scans every `_*_` folder, so it doesn't matter, but check wago.tools on launch day.
- Using the provided icon outside the game, if it is Blizzard art (see Look).
