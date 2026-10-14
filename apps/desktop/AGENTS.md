# Desktop app (apps/desktop)

The Road to Sixty app (#1): it finds WoW, uploads each character's saved
journey after play, and brings the merged journey back through the
`RoadToSixty_Sync` addon folder. It never writes the game's SavedVariables.
The design is the spec's "The desktop app" section
(`docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`); the app
shell plan is `docs/superpowers/plans/2026-10-14-app-shell.md`.

## Layout

- `engine/` is the sync engine, a Rust library with no window (package
  `rts-sync`):
  - `installs.rs` finds WoW installs, game folders and saved journeys.
  - `inbox.rs` writes the `RoadToSixty_Sync` folder. A restore reaches the
    addon as `restore = <id>`, never as a yes or no: the addon replaces only
    a copy older than that restore (`Sync.lua`).
  - `api.rs` is the server client; `link.rs` links a PC. The PC's name goes
    with the code request, in `scope`, so the link page can show it.
  - `state.rs` is what the app remembers. The PC token is in `token`
    beside `state.json`, readable only by the player, and never in
    `state.json` itself, so that can be shared when asking for help.
    Not the Keychain: an unsigned Mac app gets asked for it after every
    update, which players wouldn't understand.
    `state.json` also remembers refused files (`refused`), so a refusal
    stays shown, without sending the file again, until the file changes.
  - `sync.rs` is one sync pass; `watch.rs` decides when to upload. It
    looks for game folders and changed files again whenever a game or
    install folder changes and every five minutes, so WoW making its WTF
    folder after the app started is noticed. It also looks for a game starting
    every five seconds and syncs at once when one does, so other PCs' play
    is in the sync folder before the player logs in, and it sets `busy`
    while a pass runs. A
    pass's `problems` name the character (`who`) and say what's wrong in
    words a player can read, with no codes or file paths.
  - `src/bin/rts-sync.rs` runs the engine from a terminal.
- `src-tauri/` is the app around the engine (package `road-to-sixty-app`):
  `tauri.conf.json` sets the window, bundles and icons (made from
  `packages/ui/compass.png` by `bunx tauri icon`), `capabilities/` says what
  the window may call. `src/runner.rs` runs the engine on a thread of its
  own; linking, pausing, unlinking and adding a folder stop it, change the
  saved state and start it again, and every change to the status goes
  through its `Notifier`. While nothing syncs (not linked, no WoW yet, the
  thread stopped) the 30-second ticker calls `rescan`, which starts it
  again; a damaged `state.json` is moved aside to `state.json.damaged` and
  the app starts over unlinked, saying so, so the player can link again. Problems that name a character show on its row and
  count in the tray line ("2 characters not backed up"). `src/status.rs` words the tray line and each
  character's note from the engine's reports, as plain tested functions.
  `src/tray.rs` is the menu bar or tray icon (a left click opens the window, a right click the menu), `src/window.rs` opens the window under it with tauri-plugin-positioner and hides it when it loses focus, except while one of our dialogs is open or a link waits on the browser (so dialogs run from Rust, through `window::holding`, and confirmations are inline in the window), `src/commands.rs` is what the
  window can ask (anything that restarts the sync thread runs on a thread
  of its own), `src/account.rs` holds the account screens' calls
  (characters, history, restore, PCs, export, delete everything): the
  window asks the app, which calls the server with the PC token, so the
  window never holds it. Answers pass through as JSON and the window reads
  them with `@road-to-sixty/api`'s types. Unlinking this PC revokes it on
  the server first, and still unlinks here when offline; and `src/main.rs` puts them together: closing the window
  only hides it, and only Quit in the menu ends the app.
  `src/update.rs` checks the downloads bucket's `latest.json` at start and
  every six hours (never in debug builds), downloads a newer version at
  once, and restarts into it only while the window is hidden and the sync
  thread isn't busy, or when the player asks (the tray item or Restart
  now). Installing waits for the restart, because on Windows it ends the
  app. A `version` file in the data folder tells a start after an update,
  which stays hidden and says "Updated to X" for an hour. Start at login is tauri-plugin-autostart (a LaunchAgent on the Mac,
  the per-user Run key on Windows), started with `--hidden`.
- `src/` is the app's window, Vite and React styled from `packages/ui`.
  `api.ts` is the only file that talks to the app (its commands and the
  `status` event); `FirstRun.tsx` (with the PC's name), `Characters.tsx`,
  `History.tsx` and `Account.tsx` are the screens, after the mockups'
  A-Characters-2, A-History and A-Account (#39). `format.ts` works out
  every word and number they show and is tested (`bun test src`);
  `classes.ts` holds the class icons, cut from the game's art by
  `scripts/class-icons.py`. `packages/ui/theme.css` gives every scrolling
  list a thin dark scroll bar (#41).
- `scripts/latest-json.ts` writes the updater's `latest.json` in the
  release workflow (`.github/workflows/desktop-release.yml`, on `app-v*`
  tags), which uploads the builds to the public R2 bucket
  `road-to-sixty-downloads` at `https://dl.rts.everhold.online/app/`.
- `Cargo.toml` is the Rust workspace; `rust-toolchain.toml` pins Rust.

## Commands (from apps/desktop)

```
bun run test                        # every Rust test (one needs luajit; build the window first) and the script tests
cargo run --bin rts-sync -- status  # what the engine finds on this PC; also link, once, run, unlink
bunx tauri dev                      # the app, using this PC's real link and WoW
bun run build                       # the window into dist/
bun run typecheck
```

If `cargo` isn't found, run `. ~/.cargo/env` first.

## Rules that bite

- A character is named by the `rosterKey` in its saved file, never by the
  game's folder names, which don't give the realm the addon uses.
- `installs::find_installs` scans this machine's real WoW installs. Tests
  hand the engine made-up game folders instead (`watch::run` takes a
  `find` that returns them), so they never touch a real install or a real
  character.
- Tests that need a server use `api::fake`, which the `fake` feature lends
  to other crates' tests. The runner's tests pass a made-up `find` and a
  temporary data folder, so they never touch a real install or link.
- The engine's request and response shapes mirror `packages/api` by hand;
  the window imports `@road-to-sixty/api` itself. Change them together
  with the server.
- Updates are signed: the private key is only in GitHub secrets
  (`TAURI_SIGNING_PRIVATE_KEY` and its password) and in Jordan's
  `~/.config/road-to-sixty/`; the public key is in `tauri.conf.json`.
  Losing the private key means every installed copy has to be reinstalled
  by hand, so never regenerate it.
- Tray menu calls (`set_text` and friends) from any thread but the main
  one wait for the main thread. Never make them while holding a lock the
  main thread also takes: `Notifier::update` lets go of the status before
  it tells the tray, because the `status` command and the tray's own
  handlers read it on the main thread.
- Commands that aren't `async` run on the main thread. Anything slow
  (linking, stopping the sync thread) goes to a thread of its own.
- Files the game reads are written to a temporary file and renamed over the
  old one, so the game never reads half a file.
- A release needs `version` raised in both `src-tauri/tauri.conf.json` and
  `src-tauri/Cargo.toml`, and a tag `app-v<that version>`; the workflow
  refuses a tag that doesn't match.
