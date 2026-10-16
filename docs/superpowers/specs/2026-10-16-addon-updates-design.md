# The app installs the addon and keeps it up to date

Issue #54. Mockups: `2026-10-16-addon-updates-mockup.html` beside this file
(open it in a browser; new parts have a dashed yellow outline).

## Why

A player with the app can still be on an old addon. Since the server
merges at layout 4, a PC on addon 1.9.x is told "Update the addon on this
PC" and gets no journeys until someone updates it by hand. A player who
installs the app first also has to find the addon on CurseForge before
anything works.

Success: a player with the app always has the newest addon in each
Classic game folder that has it, without clicking anything; a new release
reaches every running app within about 6 hours and goes in while WoW is
closed. It only ever goes into a game that runs the client the addon is
built for (Forever's), never Classic Era, retail or another version. Installing the app leads straight to installing the addon.
Developer copies are never touched, and the game never sees half an addon.

Decided with Jordan: update installed copies and offer to install where
it's missing (never by itself); on by default with a switch; signed
updates from our downloads bucket; the check rides on the app's own update
check rather than a push or a clock of its own.

## Publishing (addon release)

The Release workflow (`release.yml`), after the GitHub release, publishes
the same zip it gives GitHub and CurseForge, byte for byte, to the
downloads bucket:

- It signs the zip with the key the app releases use
  (`TAURI_SIGNING_PRIVATE_KEY` and its password, already repository
  secrets) through the Tauri CLI's `signer sign`, run with Bun
  (`oven-sh/setup-bun` and the repo's own `@tauri-apps/cli`; the job has
  no Bun today), then checks the signature with minisign against the
  public key in `apps/desktop/src-tauri/tauri.conf.json`, as
  `desktop-release.yml` does.
- It uploads `addon/RoadToSixty-<version>.zip` and `addon/RoadToSixty-<version>.zip.sig`.
- Last, for a full release only (not a tag containing `alpha` or `beta`),
  it writes `addon/latest.json`, then reads it back from
  `https://dl.roadtosixty.online/addon/latest.json` to check:

  ```json
  { "version": "1.10.1", "interface": 16001, "zip": "https://dl.roadtosixty.online/addon/RoadToSixty-1.10.1.zip", "signature": "<the .sig file's text>" }
  ```

  `interface` is the toc's `## Interface`, read by the publish script.

The steps live in `apps/addon/scripts/publish.sh <zip> <version> <type>`.
A manual workflow, `addon-publish.yml` (input: a tag), runs it on that
tag's GitHub release zip, the way `curseforge-check.yml` re-uploads one:
it publishes 1.10.0 once, so the feature has something to install before
the next release, and redoes a publish that failed.

## The app

### Which folders

The addon is built for one client (toc `## Interface: 16001`, client
1.60); in Classic Era (1.15), Classic Progression or retail it would show
as out of date and not load. So a game folder qualifies by the client it
runs, not by its name:

- Its `.flavor.info` names its product (`Product Flavor` line, such as
  `wow_classic_beta`).
- The install's `.build.info` has a row per product with its `Version`
  (`1.60.1.70374`).
- It qualifies when that version's major and minor match the release's
  `interface` (16001 is 1.60; the interface is major × 10000 + minor ×
  100 + patch).

Checked on Jordan's Mac: `_classic_beta_` is `wow_classic_beta` at
1.60.1.70374. Whatever folder Forever launches in qualifies by its build,
with no app release. A folder without both files, or on another client,
is never offered the addon and never updated; one that has the addon
anyway (put there by hand) shows "Addon 1.10.0 · not for this version of
WoW". The sync keeps working with every folder that has the addon, as
now.

### What it never touches

- A copy whose toc has no version filled in (a developer build): the
  window says "Developer addon · the app leaves it alone".
- An addon folder that is a link (the developer junction), whatever its
  toc says.
- A copy newer than the release (by its numbers, `1.11.0-beta` counting as
  1.11.0), or the same version: never backwards, never again.

### When

- **Check:** together with the app's own update check (at start and every
  6 hours, `update.rs`), on its own thread so a waiting app update never
  holds it up. It reads `latest.json`; a newer version is downloaded once
  into the app's data folder (`addon/`, keeping only the newest) and its
  signature checked. A check that can't reach the bucket is tried again at
  the next one, quietly.
- **Update:** put in place for each game folder whose copy is behind, only
  while that game isn't running (`watch::game_running`, which the sync
  already uses to start a pass when the game starts). While it is running,
  the folder shows "1.10.1 installs when WoW closes", and it goes in as
  soon as the game closes (the sync's watch loop already notices that).
- **First install:** when the player clicks Install, at once, even with
  the game running: a new folder is only read at the game's next start.
- **Switch off:** nothing is updated by itself; a copy that is behind
  shows "1.10.1 is out" and an Update button, which updates it under the
  same rules.

### Installing

1. The zip's signature is checked against the updater public key built
   into the app (`minisign-verify`, already in the app through the
   updater). A bad signature installs nothing and the folder shows the
   failure.
2. It is unpacked into a new folder beside `RoadToSixty` in the game's
   AddOns folder (`.RoadToSixty-new`). Any entry outside `RoadToSixty/`,
   with `..`, absolute, or a link, refuses the whole zip.
3. The folders are swapped by renaming: `RoadToSixty` to
   `.RoadToSixty-old`, the new one to `RoadToSixty`, then the old one is
   deleted. If the second rename fails, the old one is renamed back. Left
   over `.RoadToSixty-new` or `-old` folders from a crash are cleared
   before the next install. WoW never loads either: a folder loads only
   when its toc has the folder's own name.
4. Only `RoadToSixty` is ever written. `RoadToSixty_Sync` stays the
   inbox's, and saved journeys live under `WTF`, which this never touches.

A failure (the folder can't be written, the disk is full, a file is locked)
leaves the old copy in place, shows on the folder in the warning colour
with a plain reason ("Couldn't update the addon: the folder can't be
written to. Trying again in a few hours."), and is tried again at the next
check.

### What it remembers

In `state.json`: `addon_updates` (the switch, on by default) and, by game
folder, when the app last put the addon in and the last failure with its
reason. "updated today" shows for a day after an update.

### The window

Each game folder in the status carries its addon state, which the window
words as the mockups show:

| State | Words | Action |
|---|---|---|
| current | Addon 1.10.1 (· updated today, for a day) | |
| waiting | Addon 1.10.0 · 1.10.1 installs when WoW closes | |
| missing | No addon yet | Install the addon |
| developer | Developer addon · the app leaves it alone | |
| failed | Couldn't update the addon: <why>. Trying again in a few hours. (warning colour) | |
| behind (switch off) | Addon 1.10.0 · 1.10.1 is out | Update |
| other client | Addon 1.10.0 · not for this version of WoW | |

- **First run, step 1:** with no qualifying game folder at all, it stays
  as today: "WoW not found", "Install the Road to Sixty addon first, or
  show us where WoW is.", with Add a game folder. With no qualifying
  folder holding the addon, the
  step is "Install the addon", listing the game it found ("No addon yet")
  and one button, "Install Road to Sixty <version>", with the line "Puts
  the addon in this game's AddOns folder. It keeps itself up to date after
  that." Linking waits until it is in. With the addon in one folder, step 1
  is "WoW found", and any other qualifying folder without it gets a small
  "Install the addon" button; linking goes ahead. After an install, step 1
  reads "Addon installed". Step 3's line becomes "So the game loads the
  addon and the sync folder. Your journeys stay where they are."
- **Account, Game folders:** the cards from app 0.1.8, with the states
  above.
- **Account, This PC:** "Keep the addon up to date", "New versions install
  while WoW is closed. A developer copy is never changed.", a switch like
  Start at login, on.
- **Status pill:** "Addon updated to 1.10.1" for an hour after an update,
  as it says "Updated to" after an app update.
- **Characters list:** a character the server holds back for a newer
  addon (`updateAddon`) reads "Its newest journey comes in when you next
  log in to <Name>." (not a warning) while updates are on; with them off,
  the warning stays, as "Update the addon on this PC to get the newest
  journey (Account, Game folders)."

### Where the code goes

- `engine/src/addon.rs` (new): reading `latest.json`, checking a
  signature, comparing versions, unpacking safely and swapping folders, as
  plain functions tested with a test key. `installs.rs` gains every game
  folder with its client version (from `.flavor.info` and `.build.info`),
  with or without the addon.
- `src-tauri`: the check beside the app's in `update.rs`, the per-folder
  state and the pill in `status.rs`, new commands `install_addon`,
  `update_addon` and `set_addon_updates` in `commands.rs`, the switch in
  `state.json`. The updater public key reaches the engine from
  `tauri.conf.json`, passed in as a string; it is base64 of the minisign
  public key text, so the engine decodes it before
  `minisign_verify::PublicKey::decode`.
- `src/`: `FirstRun.tsx`, `Account.tsx`, the words in `format.ts`, tested
  there.
- Version: app 0.1.9.

## The website

Launch section: "Install the addon before you log in." becomes "Install
the app before you log in: it puts the addon in for you and keeps every
step safe on every PC you play." The CurseForge links stay for players
without the app.

## Testing

- Engine: a zip signed with a test key installs and replaces an older
  copy; a bad signature, an entry outside `RoadToSixty/` (`..`, absolute,
  a link), a developer copy, a linked folder, a newer copy and a running
  game each leave the folder exactly as it was; a failed second rename
  puts the old folder back; leftovers from a crash are cleared; version
  order (1.9.0 < 1.10.0, 1.11.0-beta newer than 1.10.1); a folder on
  another client version (1.15, or with no `.flavor.info`) is never offered
  or updated; `.build.info` and `.flavor.info` read from made-up files in
  the game's format.
- The window's words for each state, and the Characters note, in
  `format.test.ts` and `status.rs`.
- The release workflow: the signature is checked with minisign before
  anything is uploaded, and `latest.json` is read back after.
- By hand, before release: on Jordan's Mac, a CurseForge-installed 1.10.0
  updated by the app, then the CurseForge app opened, to see whether it
  calls the addon up to date or changed. On Windows: an update while WoW
  runs waits and goes in when it closes; a first install from first run.

## Rollout

1. The publishing workflow, merged to `main`, then `addon-publish.yml` run
   for v1.10.0, and `latest.json` checked.
2. App 0.1.9.
3. The website line, with the app.

## Limits

- An update reaches a running app within about 6 hours, not at once.
- A player who turns updates off keeps the warning and the Update button.
- If the CurseForge app turns out to treat an app-updated copy as changed,
  the player may see CurseForge offer to reinstall the same version; the
  by-hand check above decides whether anything more is needed.
