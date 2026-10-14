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
  - `inbox.rs` writes the `RoadToSixty_Sync` folder.
  - `api.rs` is the server client; `link.rs` links a PC.
  - `state.rs` is what the app remembers (the PC token lives in the
    Keychain or Credential Manager, never in the state file).
  - `sync.rs` is one sync pass; `watch.rs` decides when to upload.
  - `src/bin/rts-sync.rs` runs the engine from a terminal.
- `Cargo.toml` is the Rust workspace; `rust-toolchain.toml` pins Rust.

## Commands (from apps/desktop)

```
cargo test                          # engine tests (one needs luajit on the path)
cargo run --bin rts-sync -- status  # what the engine finds on this PC; also link, once, run, unlink
```

If `cargo` isn't found, run `. ~/.cargo/env` first.

## Rules that bite

- A character is named by the `rosterKey` in its saved file, never by the
  game's folder names, which don't give the realm the addon uses.
- `installs::find_installs` scans this machine's real WoW installs. Tests
  hand the engine made-up game folders instead (`watch::run` takes
  `games`), so they never touch a real install or a real character.
- Tests that need a server use `api::fake`, which the `fake` feature lends
  to other crates' tests.
- The request and response shapes mirror `packages/api`; change them
  together with the server.
- Files the game reads are written to a temporary file and renamed over the
  old one, so the game never reads half a file.
