# Desktop App: the Sync Engine, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Rust sync engine that finds WoW installs and the characters using the addon, uploads their saved journeys, links the PC, and delivers each character's merged journey back through the `RoadToSixty_Sync` addon folder, with a terminal tool, `rts-sync`, to run it until the app's window exists.

**Architecture:** A library crate, `apps/desktop/engine` (package `rts-sync`), with one module per job: finding installs, the sync folder, the server's API, linking, saved state, one sync pass, and the watcher that decides when to upload. Blocking HTTP (`ureq`) on plain threads; the Tauri app in the next plan calls it from a background thread. Every module is tested without a window, against temporary folders and a fake server, and one test has LuaJIT read back the sync folder it writes. The addon gains one field, `rosterKey`, because the game's folder names don't give the realm the addon uses.

**Tech Stack:** Rust 1.99.0 (rustup, pinned by `rust-toolchain.toml`), ureq 3.4.2, zstd 0.14.0, sha2 0.11.0, serde 1.0.229, serde_json 1.0.151, notify 8.2.0, keyring 4.2.0, sysinfo 0.39.6, dirs 7.0.0, hex 0.4.3; tests with tempfile 3.27.0 and tiny_http 0.12.0; LuaJIT for the round-trip test.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "The sync folder", "The desktop app" (First run, While running), "Repo layout", "Testing" (App), and the sign-in plan's notes for the app (`docs/superpowers/plans/2026-10-14-sync-sign-in.md`, "Notes for later steps").

## Global Constraints

- Never write the game's SavedVariables, not even for a restore (spec).
- Write a new version into `RoadToSixty_Sync/data.lua` by writing a temporary file in the same folder and renaming it over the old one (spec).
- Wait until a changed file has been unchanged for about ten seconds, upload each character at most once every 15 minutes while the game runs, and straight away when it closes (spec).
- Check every `_*_` game folder that has the addon, so the folder name Forever launches with doesn't matter (spec).
- The PC token goes into the Mac Keychain or Windows Credential Manager (spec).
- Remember the fingerprint of everything uploaded (spec).
- Real saved files hold other players' names and GUIDs: they never go into the repo, a test, a fixture or an issue. Tests use made-up files only.
- Never commit secrets or personal paths. Commit subjects are `Area: what changed (#1)`.
- Subagents run on at most Opus, never Fable.

## What the live install showed (2026-10-14)

The prototype behind this plan ran against Jordan's new WoW install on this Mac and the live server: it found the install through Battle.net's `product.db`, linked through the browser, uploaded a character, and delivered the merge. In game, `/rts check` then said "Sync: version 4 was already brought in". Three facts from that run shape the plan:

- **Forever saves characters under `WTF/Account/<account>/70/<Name>-<something>/`**, and those folders don't give the realm the addon uses: the addon's key was `<Name>-Classic Beta PvE 2`, the folder `70/<Name>-<something else>`. So the addon now writes its key into the character's file as `rosterKey` (Task 1), and the engine names characters by it.
- **The game writes SavedVariables with no indentation**, so a top-level field can't be told from a nested one by its indent. `rosterKey` and `syncedVersion` are names nothing else in the file uses.
- **`product.db` holds each path after a length byte**, which reads as a letter for paths of 32 to 126 characters, so the engine looks for the path inside each run of text, not only at its start.
- **The game sets the executable bit on the addon files it reads** through the dev link. The repo's local git config now has `core.fileMode false`, so those changes don't show up in commits.

## Decisions the spec leaves open

- **The engine is its own crate, `apps/desktop/engine`**, not files under `src-tauri/src/`. It builds and tests without Tauri's toolchain, and `cargo tauri init` in the next plan won't clash with it. The spec's module names are kept (`installs`, `watch`, `link`, `sync`, `inbox`, `state`), plus `api`. The spec's repo layout is updated (Task 6).
- **`received` is the `syncedVersion` in the uploaded file itself:** what the addon really brought in, not what the app wrote to the sync folder. The server's restore rule depends on exactly that.
- **The account-wide file isn't uploaded.** The server has no endpoint for it yet.
- **A file without `rosterKey`** (from an addon older than Task 1) is reported as "log in once with the updated addon" and not uploaded.
- **Downloaded journeys are cached by version** in the app's data folder, so each is downloaded once; `data.lua` is rebuilt from the cache, and versions no longer delivered are removed.
- **`data.lua` holds every character of the user in that game folder**, including ones only played elsewhere: the addon takes only its own.
- **Unlinked (401) and offline stop a pass** and are reported; a file the server refuses (413, say) is a problem for that file only. After a failed pass the watcher waits a minute.
- **The server address is built in** (`https://api.rts.everhold.online`), with `RTS_SERVER` to change it, as the spec's Domains section says each app build has its address built in.
- **CI runs the engine on Ubuntu only.** Windows paths, Credential Manager and process paths are checked by hand on Jordan's PC, and the next plan's Windows build adds a Windows CI job.
- **Three crates are pinned exactly** (`=0.14.0`, `=0.11.0`, `=1.0.151`): their newest releases were days old.

## Review Focus

1. Windows: `product.db` paths with `C:/` or `C:\`, `fs::rename` over an existing `data.lua`, Credential Manager, the game's process path, and writing under `C:\Program Files (x86)\World of Warcraft`. CI runs Ubuntu only; the reviewer reads these paths with Windows in mind.
2. A saved file read while the game writes it: the ten-second wait makes it unlikely; if it happens, the server refuses the half file, and the next change uploads again (Task 5's refused-file test covers the "problem, not stop" part).
3. Offline or the server down for hours: passes fail, the watcher waits a minute between tries, and nothing is lost (Task 6's run loop; the reviewer reads it).
4. A merged journey that isn't valid text, or over 32 MB: `download` refuses it (Task 4 covers a good download; the reviewer reads the limits).
5. The sync folder written while the game is running: the game reads `data.lua` only at login or `/reload`, and the rename means it never sees half a file (Task 3).

---

### Task 1: The addon records its roster key

**Files:**
- Modify: `apps/addon/RoadToSixty/Roster.lua`, `apps/addon/RoadToSixty/Core.lua` (header), `apps/addon/tests/roster_test.lua`

**Interfaces:**
- Produces: `RoadToSixtyCharDB.rosterKey`, the character's `Name-Realm` (`Roster:Key()`), set at every login after Sync.lua's handler.

- [ ] **Step 1: Cut the branch and write the failing test**

```bash
git switch dev && git switch -c sync-engine
```

Apply this to `apps/addon/tests/roster_test.lua`:

```diff
diff --git a/apps/addon/tests/roster_test.lua b/apps/addon/tests/roster_test.lua
index a2b208f..e2dd69e 100644
--- a/apps/addon/tests/roster_test.lua
+++ b/apps/addon/tests/roster_test.lua
@@ -99,6 +99,7 @@ Fire("PLAYER_LOGIN")
 local e = ns.db.roster["Eagin-Test"]
 check(e.class == "MAGE" and e.level == 12 and e.zone == 1436, "entry has class, level and zone")
 check(ns.char.rosterBuilt == 3, "journey copied on first login")
+check(ns.char.rosterKey == "Eagin-Test", "the journey records its roster key, for the app")
 check(e.path == nil and e.journey ~= nil, "old coarse path replaced by the journey copy")
 check(e.journey.events == ns.char.events and e.journey.kills == ns.char.kills, "copy shares the journey's tables")
 check(e.journey.rosterBuilt == nil, "copy leaves out the roster's own flag")
```

Run: `cd apps/addon && luajit tests/roster_test.lua; cd ../..`
Expected: `FAIL: the journey records its roster key, for the app`.

- [ ] **Step 2: Record it**

Apply this to `apps/addon/RoadToSixty/Roster.lua` and `apps/addon/RoadToSixty/Core.lua`:

```diff
diff --git a/apps/addon/RoadToSixty/Core.lua b/apps/addon/RoadToSixty/Core.lua
index 920465a..3192e62 100644
--- a/apps/addon/RoadToSixty/Core.lua
+++ b/apps/addon/RoadToSixty/Core.lua
@@ -24,6 +24,9 @@ local addonName, ns = ...
 --   clockFrom  when a journey begun before layout 2 moved to the realm's
 --              clock (see DATA_VERSION)
 --   syncedVersion  the sync folder version last brought in (Sync.lua)
+--   rosterKey  Name-Realm, set at each login after the sync (Roster.lua): the
+--              app reads it, since the game's folder names don't give the
+--              realm the addon uses
 -- addon is the addon version that last loaded the file (the toc's version
 -- placeholder, unfilled, in a developer install), so whatever reads it
 -- knows what wrote it. Never write the placeholder itself in a .lua file:
diff --git a/apps/addon/RoadToSixty/Roster.lua b/apps/addon/RoadToSixty/Roster.lua
index 823b3b9..137c109 100644
--- a/apps/addon/RoadToSixty/Roster.lua
+++ b/apps/addon/RoadToSixty/Roster.lua
@@ -135,6 +135,7 @@ ns.On("PLAYER_LOGIN", function()
     local key = Roster:Key()
     entry = ns.db.roster[key] or {}
     ns.db.roster[key] = entry
+    ns.char.rosterKey = key
     entry.name, entry.realm = UnitName("player"), GetRealmName()
     entry.class = select(2, UnitClass("player"))
     entry.level = UnitLevel("player")
```

Roster.lua loads after Sync.lua, so its PLAYER_LOGIN handler runs after a sync folder's journey has replaced `ns.char`, and the key survives a restore.

Run: `cd apps/addon && bun scripts/test.ts; cd ../..`
Expected: `luajit: 21 test files`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add apps/addon/RoadToSixty/Roster.lua apps/addon/RoadToSixty/Core.lua apps/addon/tests/roster_test.lua
git commit -m "Roster: keep the character's roster key in its journey, for the app (#1)

Forever's WTF folders don't give the realm the addon uses, so the app
names each character by this key instead.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The engine crate, and finding installs and characters

**Files:**
- Create: `apps/desktop/Cargo.toml`, `apps/desktop/rust-toolchain.toml`, `apps/desktop/rustfmt.toml`, `apps/desktop/package.json`, `apps/desktop/engine/Cargo.toml`, `apps/desktop/engine/src/lib.rs`, `apps/desktop/engine/src/installs.rs`, `apps/desktop/Cargo.lock` (by cargo)
- Modify: `.gitignore`, `bun.lock` (by `bun install`)

**Interfaces:**
- Produces: `installs::{GameFolder { path, name }, SavedFile { game, path }, product_db(), default_installs(), installs_in_product_db(&[u8]) -> Vec<PathBuf>, find_installs(&[PathBuf]) -> Vec<PathBuf>, game_folders(&Path) -> Vec<GameFolder>, addon_toc(&Path) -> PathBuf, addon_version(&Path) -> Option<String>, saved_files(&GameFolder) -> Vec<SavedFile>}`.

- [ ] **Step 1: Rust and the workspace**

Rust comes from rustup (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal`; already on Jordan's Mac). Create `apps/desktop/Cargo.toml`:

```toml
[workspace]
resolver = "3"
members = ["engine"]
```

`apps/desktop/rust-toolchain.toml`:

```toml
[toolchain]
channel = "1.99.0"
components = ["clippy", "rustfmt"]
profile = "minimal"
```

`apps/desktop/rustfmt.toml`:

```toml
max_width = 140
```

`apps/desktop/package.json`, so `bun run test` and `bun run check` include the engine:

```json
{
  "name": "@road-to-sixty/desktop",
  "private": true,
  "scripts": {
    "test": "cargo test",
    "check": "cargo clippy --all-targets -- -D warnings && cargo fmt --check"
  }
}
```

`apps/desktop/engine/Cargo.toml`, with every library the engine uses:

```toml
[package]
name = "rts-sync"
version = "0.1.0"
edition = "2024"

[dependencies]
dirs = "7.0.0"
hex = "0.4.3"
keyring = "4.2.0"
notify = "8.2.0"
serde = { version = "1.0.229", features = ["derive"] }
serde_json = "=1.0.151"
sha2 = "=0.11.0"
sysinfo = "0.39.6"
ureq = { version = "3.4.2", features = ["json"] }
zstd = "=0.14.0"

[dev-dependencies]
tempfile = "3.27.0"
tiny_http = "0.12.0"
```

Apply this to `.gitignore`:

```diff
diff --git a/.gitignore b/.gitignore
index 1edea78..f071b9c 100644
--- a/.gitignore
+++ b/.gitignore
@@ -6,6 +6,9 @@ dist/
 node_modules/
 .turbo/
 
+# Rust build output (apps/desktop)
+target/
+
 # Local settings with secrets (apps/server/.env.example lists them)
 .env
 
```

`apps/desktop/engine/src/lib.rs`:

```rust
//! The Road to Sixty app's sync engine (#1), with no window: it finds WoW
//! installs and the characters that use the addon, uploads their saved
//! journeys, and delivers the merged journeys back through the
//! RoadToSixty_Sync addon folder. The Tauri app (apps/desktop) wraps it;
//! `rts-sync` (src/bin) runs it from a terminal.

pub mod installs;
```

- [ ] **Step 2: Write the failing tests**

Create `apps/desktop/engine/src/installs.rs` holding only its tests for now:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn touch(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    #[test]
    fn product_db_paths_are_the_absolute_text_runs() {
        // A path of 32 to 126 characters has a length byte that reads as a
        // letter, so the run of text starts one character early.
        let mut bytes =
            b"\x0a\x03wow\x12\x1f/Applications/World of Warcraft\x1a\x02en\x12J/Users/x/Games/World of Warcraft Classic Stuff Here\x00"
                .to_vec();
        bytes.extend(b"\x00\x01C:/Program Files (x86)/World of Warcraft\x00");
        let found = installs_in_product_db(&bytes);
        assert_eq!(
            found,
            vec![
                PathBuf::from("/Applications/World of Warcraft"),
                PathBuf::from("/Users/x/Games/World of Warcraft Classic Stuff Here"),
                PathBuf::from("C:/Program Files (x86)/World of Warcraft")
            ]
        );
    }

    #[test]
    fn game_folders_are_the_underscored_ones_with_the_addon() {
        let install = tempfile::tempdir().unwrap();
        touch(&addon_toc(&install.path().join("_classic_beta_")), "## Interface: 16001\n");
        touch(&addon_toc(&install.path().join("_retail_")).with_file_name("Other.toc"), "");
        fs::create_dir_all(install.path().join("Data")).unwrap();
        let found = game_folders(install.path());
        assert_eq!(found.iter().map(|g| g.name.as_str()).collect::<Vec<_>>(), ["_classic_beta_"]);
    }

    #[test]
    fn saved_files_are_per_character_and_skip_the_account_file() {
        let game = tempfile::tempdir().unwrap();
        let account = game.path().join("WTF").join("Account").join("ACCOUNT1");
        touch(
            &account
                .join("70")
                .join("Ann-Stormfist")
                .join("SavedVariables")
                .join("RoadToSixty.lua"),
            "RoadToSixtyCharDB = {}",
        );
        touch(
            &account.join("70").join("Bob-Stormfist").join("SavedVariables").join("Other.lua"),
            "",
        );
        touch(&account.join("SavedVariables").join("RoadToSixty.lua"), "RoadToSixtyDB = {}");
        let folder = GameFolder {
            path: game.path().to_path_buf(),
            name: "_classic_beta_".into(),
        };
        let found = saved_files(&folder);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].game, "_classic_beta_");
        assert!(found[0].path.ends_with("70/Ann-Stormfist/SavedVariables/RoadToSixty.lua"));
    }

    #[test]
    fn addon_version_skips_the_unfilled_placeholder() {
        let game = tempfile::tempdir().unwrap();
        touch(&addon_toc(game.path()), "## Interface: 16001\n## Version: 1.9.0\n");
        assert_eq!(addon_version(game.path()).as_deref(), Some("1.9.0"));
        touch(&addon_toc(game.path()), "## Version: @project-version@\n");
        assert_eq!(addon_version(game.path()), None);
    }
}
```

Run: `cd apps/desktop && cargo test; cd ../..`
Expected: compile errors, `cannot find function `installs_in_product_db`` and the other functions the tests call.

- [ ] **Step 3: Finding installs**

Put this above the tests in `apps/desktop/engine/src/installs.rs`:

```rust
//! Finding WoW installs, their game folders, and the characters that use the
//! addon (spec, "First run").

use std::fs;
use std::path::{Path, PathBuf};

/// A game folder inside an install, such as `_classic_beta_`, that has the
/// addon. Its name is the `game` the server keeps characters under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameFolder {
    pub path: PathBuf,
    pub name: String,
}

/// One character's saved journey, two folders below the account:
/// `WTF/Account/<account>/<two folders>/SavedVariables/RoadToSixty.lua`.
/// Which folders depends on the client (Forever's are `70/Name-Something`),
/// so the character's name and realm come from the file (sync::roster_key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedFile {
    pub game: String,
    pub path: PathBuf,
}

/// Where Battle.net keeps its list of installed games.
pub fn product_db() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(r"C:\ProgramData\Battle.net\Agent\product.db")
    } else {
        PathBuf::from("/Users/Shared/Battle.net/Agent/product.db")
    }
}

/// Where WoW installs itself when nobody picks a folder.
pub fn default_installs() -> Vec<PathBuf> {
    if cfg!(windows) {
        vec![PathBuf::from(r"C:\Program Files (x86)\World of Warcraft")]
    } else {
        vec![PathBuf::from("/Applications/World of Warcraft")]
    }
}

/// The install folders named in Battle.net's product.db. It is a protobuf
/// file; rather than decode it, this takes every absolute path in its runs
/// of text, and the caller keeps those that exist.
pub fn installs_in_product_db(bytes: &[u8]) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = Vec::new();
    for run in bytes.split(|b| !(0x20..0x7f).contains(b)) {
        // A length byte before the text can itself read as a letter, so the
        // path may start one character into the run.
        let text = String::from_utf8_lossy(run);
        let drive = (0..text.len().saturating_sub(2))
            .find(|&i| run[i].is_ascii_alphabetic() && (&text[i + 1..i + 3] == ":/" || &text[i + 1..i + 3] == ":\\"));
        let Some(start) = drive.or_else(|| text.find('/')) else { continue };
        let path = PathBuf::from(&text[start..]);
        if !found.contains(&path) {
            found.push(path);
        }
    }
    found
}

/// Every install that exists: Battle.net's list, the default locations, and
/// folders the player picked, without repeats.
pub fn find_installs(picked: &[PathBuf]) -> Vec<PathBuf> {
    let mut all: Vec<PathBuf> = fs::read(product_db()).map(|b| installs_in_product_db(&b)).unwrap_or_default();
    all.extend(default_installs());
    all.extend(picked.iter().cloned());
    let mut found: Vec<PathBuf> = Vec::new();
    for path in all {
        if path.is_dir() && !found.contains(&path) {
            found.push(path);
        }
    }
    found
}

/// The game folders in an install that have the addon. Every folder named
/// like `_classic_` counts, so the name Forever launches with doesn't matter.
pub fn game_folders(install: &Path) -> Vec<GameFolder> {
    let mut found = Vec::new();
    for entry in fs::read_dir(install).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        if name.len() > 2 && name.starts_with('_') && name.ends_with('_') && addon_toc(&path).is_file() {
            found.push(GameFolder { path, name });
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

pub fn addon_toc(game: &Path) -> PathBuf {
    game.join("Interface").join("AddOns").join("RoadToSixty").join("RoadToSixty.toc")
}

/// The addon version the game folder has, from its toc; None for a
/// developer install, whose toc still holds the release build's placeholder.
pub fn addon_version(game: &Path) -> Option<String> {
    let toc = fs::read_to_string(addon_toc(game)).ok()?;
    let version = toc.lines().find_map(|l| l.strip_prefix("## Version:"))?.trim().to_string();
    (!version.is_empty() && !version.starts_with('@')).then_some(version)
}

/// Every character in a game folder with a saved journey.
pub fn saved_files(game: &GameFolder) -> Vec<SavedFile> {
    let mut found = Vec::new();
    let accounts = game.path.join("WTF").join("Account");
    for account in dirs_in(&accounts) {
        for outer in dirs_in(&account) {
            for character in dirs_in(&outer) {
                let path = character.join("SavedVariables").join("RoadToSixty.lua");
                if path.is_file() {
                    found.push(SavedFile {
                        game: game.name.clone(),
                        path,
                    });
                }
            }
        }
    }
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
}

fn dirs_in(path: &Path) -> Vec<PathBuf> {
    fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect()
}
```

Run: `cd apps/desktop && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check; cd ../.. && bun install`
Expected: `test result: ok. 4 passed`, no clippy warnings, no formatting changes. `bun install` adds `@road-to-sixty/desktop` to `bun.lock`.

- [ ] **Step 4: Commit**

```bash
git add .gitignore bun.lock apps/desktop
git commit -m "Desktop: the sync engine crate, finding WoW installs and saved journeys (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The sync folder

**Files:**
- Create: `apps/desktop/engine/src/inbox.rs`
- Modify: `apps/desktop/engine/src/lib.rs`

**Interfaces:**
- Consumes: `installs::addon_toc`.
- Produces: `inbox::{Delivery { key, version: i64, replace, journey }, sync_folder(&Path) -> PathBuf, lua_quote(&str) -> String, data_lua(pc, &[Delivery]) -> String, write(game: &Path, pc, &[Delivery]) -> io::Result<bool>}`.

- [ ] **Step 1: Write the failing tests**

Add `pub mod inbox;` above `pub mod installs;` in `lib.rs`, and create `apps/desktop/engine/src/inbox.rs` holding only its tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn game_with_addon() -> tempfile::TempDir {
        let game = tempfile::tempdir().unwrap();
        let toc = addon_toc(game.path());
        fs::create_dir_all(toc.parent().unwrap()).unwrap();
        fs::write(&toc, "## Interface: 16001\n## Title: Road to Sixty\n").unwrap();
        game
    }

    // The journey text is what can break the file: quotes, backslashes, line
    // breaks, a zero byte before a digit, and UTF-8 in names.
    const TRICKY: &str = "{[\"name\"]=\"Zoë \\\"Q\\\"\",\n[\"note\"]=\"a\\\\b\r\nc\",[\"z\"]=\"\u{0}1\",}";

    #[test]
    fn writes_the_toc_and_data_and_says_when_nothing_changed() {
        let game = game_with_addon();
        let d = vec![Delivery {
            key: "Ann-Test Realm".into(),
            version: 42,
            replace: false,
            journey: "{}".into(),
        }];
        assert!(write(game.path(), "pc-1", &d).unwrap());
        let toc = fs::read_to_string(sync_folder(game.path()).join("RoadToSixty_Sync.toc")).unwrap();
        assert!(toc.starts_with("## Interface: 16001\n"));
        assert!(toc.ends_with("data.lua\n"));
        assert!(!write(game.path(), "pc-1", &d).unwrap());
        assert!(!sync_folder(game.path()).join("data.tmp").exists());
    }

    // The game's own Lua must read every journey back byte for byte.
    #[test]
    fn luajit_reads_the_journey_back_unchanged() {
        let game = game_with_addon();
        let d = vec![
            Delivery {
                key: "Zoë-Test Realm".into(),
                version: 7,
                replace: true,
                journey: TRICKY.into(),
            },
            Delivery {
                key: "Ann-Test Realm".into(),
                version: 8,
                replace: false,
                journey: "{}".into(),
            },
        ];
        write(game.path(), "pc-1", &d).unwrap();
        let data = sync_folder(game.path()).join("data.lua");
        let script = format!(
            "dofile({}) local e = RoadToSixtySync.chars['Zo\\195\\171-Test Realm'] \
             io.write(RoadToSixtySync.pc, '|', e.version, '|', tostring(e.replace), '|', e.journey)",
            lua_quote(&data.to_string_lossy())
        );
        let out = Command::new("luajit")
            .args(["-e", &script])
            .output()
            .expect("luajit must be on the path");
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        assert_eq!(out.stdout, format!("pc-1|7|true|{TRICKY}").into_bytes());
    }
}
```

Run: `cd apps/desktop && cargo test inbox; cd ../..`
Expected: compile errors for `Delivery`, `write`, `sync_folder` and `lua_quote`.

- [ ] **Step 2: Writing the folder**

Put this above the tests in `inbox.rs`:

```rust
//! The sync folder: `Interface/AddOns/RoadToSixty_Sync`, which the app owns
//! and the addon reads at login (Sync.lua's header has the format). The app
//! never writes the game's SavedVariables.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::installs::addon_toc;

/// One character's merged journey for the addon to bring in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    /// `Name-Realm`, as the addon's Roster:Key() makes it.
    pub key: String,
    /// The server's version id; the addon takes it when it is higher than
    /// the one it last brought in.
    pub version: i64,
    /// A restore: the addon replaces its copy instead of merging.
    pub replace: bool,
    /// The journey as Parse.Write text.
    pub journey: String,
}

pub fn sync_folder(game: &Path) -> PathBuf {
    game.join("Interface").join("AddOns").join("RoadToSixty_Sync")
}

/// A Lua string literal the game's Lua 5.1 reads back byte for byte. Bytes
/// above 127 (UTF-8 in names) stay as they are; `\0` becomes `\000` so a
/// digit after it can't change its meaning.
pub fn lua_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\0' => out.push_str("\\000"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// data.lua: one global with this PC's ID and each character's journey.
pub fn data_lua(pc: &str, deliveries: &[Delivery]) -> String {
    let mut out = format!("RoadToSixtySync = {{\n    pc = {},\n    chars = {{\n", lua_quote(pc));
    for d in deliveries {
        out.push_str(&format!(
            "        [{}] = {{ version = {}, replace = {}, journey = {} }},\n",
            lua_quote(&d.key),
            d.version,
            d.replace,
            lua_quote(&d.journey)
        ));
    }
    out.push_str("    },\n}\n");
    out
}

/// Makes or updates the sync folder in a game folder. The toc copies the
/// addon's Interface number, so the game never marks it out of date.
/// data.lua is written to a temporary file beside it and renamed over the
/// old one, so the game never reads half a file. Returns whether anything
/// changed.
pub fn write(game: &Path, pc: &str, deliveries: &[Delivery]) -> io::Result<bool> {
    let folder = sync_folder(game);
    fs::create_dir_all(&folder)?;
    let addon = fs::read_to_string(addon_toc(game))?;
    let interface = addon
        .lines()
        .find_map(|l| l.strip_prefix("## Interface:"))
        .map(str::trim)
        .unwrap_or("0");
    let toc = format!(
        "## Interface: {interface}\n## Title: Road to Sixty Sync\n## Notes: Journeys from your other PCs, written by the Road to Sixty app\ndata.lua\n"
    );
    let mut changed = replace_if_different(&folder.join("RoadToSixty_Sync.toc"), &toc)?;
    changed |= replace_if_different(&folder.join("data.lua"), &data_lua(pc, deliveries))?;
    Ok(changed)
}

fn replace_if_different(path: &Path, text: &str) -> io::Result<bool> {
    if fs::read(path).is_ok_and(|old| old == text.as_bytes()) {
        return Ok(false);
    }
    let temp = path.with_extension("tmp");
    fs::write(&temp, text)?;
    fs::rename(&temp, path)?;
    Ok(true)
}
```

Run: `cd apps/desktop && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check; cd ../..`
Expected: `test result: ok. 6 passed`. The LuaJIT test needs `luajit` on the path; it reads back a journey holding quotes, backslashes, line breaks, a zero byte before a digit and UTF-8, byte for byte.

- [ ] **Step 3: Commit**

```bash
git add apps/desktop/engine/src
git commit -m "Desktop: write the RoadToSixty_Sync folder the addon reads at login (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The server's API, and linking

**Files:**
- Create: `apps/desktop/engine/src/api.rs`, `apps/desktop/engine/src/link.rs`
- Modify: `apps/desktop/engine/src/lib.rs`

**Interfaces:**
- Produces: `api::{APP_CLIENT_ID, UploadResponse, CheckEntry, CheckResponse, LinkResponse, DeviceCode, DevicePoll, ApiError { Unauthorized, Status(u16, String), Network(String) }, Client::new(server, token: Option<String>), Client::{upload, check, download, device_code, device_token, link}}`; test-only `api::fake::serve(reply) -> Fake { url, seen }`; `link::{link(client, pc_name, open, sleep) -> Result<LinkResponse, ApiError>, platform()}`.

- [ ] **Step 1: Write the failing tests**

Add `pub mod api;` and `pub mod link;` to `lib.rs` (keep the list in alphabetical order). Create `apps/desktop/engine/src/api.rs` holding only its fake server and tests:

```rust
#[cfg(test)]
pub mod fake {
    //! A stand-in sync server for tests: answers from a list of canned
    //! replies and keeps what each request sent.

    use std::sync::{Arc, Mutex};
    use std::thread;

    #[derive(Debug, Clone)]
    pub struct Seen {
        pub method: String,
        pub url: String,
        pub authorization: String,
        pub body: Vec<u8>,
    }

    pub struct Fake {
        pub url: String,
        pub seen: Arc<Mutex<Vec<Seen>>>,
    }

    /// Serves `reply(method, url)` -> (status, body) until the test ends.
    pub fn serve(reply: impl Fn(&str, &str) -> (u16, Vec<u8>) + Send + 'static) -> Fake {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        thread::spawn(move || {
            for mut request in server.incoming_requests() {
                let mut body = Vec::new();
                request.as_reader().read_to_end(&mut body).unwrap();
                let authorization = request
                    .headers()
                    .iter()
                    .find(|h| h.field.equiv("authorization"))
                    .map(|h| h.value.to_string())
                    .unwrap_or_default();
                let (method, url) = (request.method().to_string(), request.url().to_string());
                let (status, answer) = reply(&method, &url);
                log.lock().unwrap().push(Seen {
                    method,
                    url,
                    authorization,
                    body,
                });
                request
                    .respond(tiny_http::Response::from_data(answer).with_status_code(status))
                    .unwrap();
            }
        });
        Fake { url, seen }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_sends_the_file_compressed_with_who_and_what_was_received() {
        let fake = fake::serve(|_, _| (200, br#"{"version":5,"status":"queued"}"#.to_vec()));
        let client = Client::new(&fake.url, Some("pc-token".into()));
        let answer = client
            .upload(
                "_classic_beta_",
                "Test Realm",
                "Zoë",
                Some("1.9.0"),
                Some(42),
                b"RoadToSixtyCharDB = {}",
            )
            .unwrap();
        assert_eq!(
            answer,
            UploadResponse {
                version: 5,
                status: "queued".into()
            }
        );
        let seen = fake.seen.lock().unwrap()[0].clone();
        assert_eq!(seen.method, "POST");
        assert_eq!(
            seen.url,
            "/v1/upload?game=_classic_beta_&realm=Test%20Realm&name=Zo%C3%AB&addon=1.9.0&received=42"
        );
        assert_eq!(seen.authorization, "Bearer pc-token");
        assert_eq!(zstd::decode_all(&seen.body[..]).unwrap(), b"RoadToSixtyCharDB = {}");
    }

    #[test]
    fn check_reads_every_character_and_a_401_means_unlinked() {
        let fake = fake::serve(|_, _| {
            (200, br#"{"characters":[{"game":"_classic_beta_","realm":"Test Realm","name":"Ann","version":null,"fingerprint":"ab","replace":false,"updateAddon":true}]}"#.to_vec())
        });
        let entry = &Client::new(&fake.url, Some("t".into())).check().unwrap().characters[0];
        assert_eq!((entry.version, entry.update_addon), (None, true));
        let refused = fake::serve(|_, _| (401, br#"{"error":"unknown or unlinked PC"}"#.to_vec()));
        assert_eq!(Client::new(&refused.url, None).check(), Err(ApiError::Unauthorized));
    }

    #[test]
    fn download_unpacks_the_journey() {
        let fake = fake::serve(|_, _| (200, zstd::encode_all(&b"{[\"version\"]=3,}"[..], 3).unwrap()));
        assert_eq!(Client::new(&fake.url, Some("t".into())).download(9).unwrap(), "{[\"version\"]=3,}");
        assert_eq!(fake.seen.lock().unwrap()[0].url, "/v1/versions/9");
    }

    #[test]
    fn no_server_is_a_network_error() {
        let client = Client::new("http://127.0.0.1:9", Some("t".into()));
        assert!(matches!(client.check(), Err(ApiError::Network(_))));
    }

    #[test]
    fn device_polls_read_pending_slow_down_and_the_token() {
        let replies = std::sync::Mutex::new(vec![
            r#"{"access_token":"session-1","token_type":"Bearer"}"#,
            r#"{"error":"slow_down"}"#,
            r#"{"error":"authorization_pending"}"#,
        ]);
        let fake = fake::serve(move |_, _| (400, replies.lock().unwrap().pop().unwrap().as_bytes().to_vec()));
        let client = Client::new(&fake.url, None);
        assert_eq!(client.device_token("dc").unwrap(), DevicePoll::Pending);
        assert_eq!(client.device_token("dc").unwrap(), DevicePoll::SlowDown);
        assert_eq!(client.device_token("dc").unwrap(), DevicePoll::Approved("session-1".into()));
        let body: serde_json::Value = serde_json::from_slice(&fake.seen.lock().unwrap()[0].body).unwrap();
        assert_eq!(body["client_id"], APP_CLIENT_ID);
    }
}
```

and `apps/desktop/engine/src/link.rs` holding only its tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::fake;
    use std::cell::RefCell;
    use std::sync::Mutex;

    #[test]
    fn opens_the_page_polls_until_approved_then_links() {
        let polls = Mutex::new(vec![r#"{"access_token":"session-1"}"#, r#"{"error":"authorization_pending"}"#]);
        let fake = fake::serve(move |_, url| {
            match url {
            "/api/auth/device/code" => (
                200,
                br#"{"device_code":"dc","user_code":"ABCD1234","verification_uri":"x","verification_uri_complete":"https://api/link?user_code=ABCD1234","interval":5,"expires_in":1800}"#.to_vec(),
            ),
            "/api/auth/device/token" => (400, polls.lock().unwrap().pop().unwrap().as_bytes().to_vec()),
            _ => (200, br#"{"token":"pc-token","pc":"pc-1","battletag":"Ann#1234"}"#.to_vec()),
        }
        });
        let opened = RefCell::new(String::new());
        let waits = RefCell::new(0);
        let linked = link(
            &Client::new(&fake.url, None),
            "Desk",
            |url, code| *opened.borrow_mut() = format!("{url} {code}"),
            |_| *waits.borrow_mut() += 1,
        )
        .unwrap();
        assert_eq!(linked.battletag, "Ann#1234");
        assert_eq!(*opened.borrow(), "https://api/link?user_code=ABCD1234 ABCD1234");
        assert_eq!(*waits.borrow(), 2);
        let last = fake.seen.lock().unwrap().last().unwrap().clone();
        assert!(last.url.starts_with("/v1/link?name=Desk&platform="), "{}", last.url);
        assert_eq!(last.authorization, "Bearer session-1");
    }

    #[test]
    fn a_denied_code_stops() {
        let fake = fake::serve(|_, url| match url {
            "/api/auth/device/code" => (
                200,
                br#"{"device_code":"dc","user_code":"U","verification_uri_complete":"x","interval":5,"expires_in":1800}"#.to_vec(),
            ),
            _ => (400, br#"{"error":"access_denied","error_description":"denied"}"#.to_vec()),
        });
        let result = link(&Client::new(&fake.url, None), "Desk", |_, _| {}, |_| {});
        assert_eq!(result, Err(ApiError::Status(400, "denied".into())));
    }
}
```

Run: `cd apps/desktop && cargo test; cd ../..`
Expected: compile errors for `Client`, `ApiError`, `link` and the response types.

- [ ] **Step 2: The client**

Put this above the fake server in `api.rs`:

```rust
//! The sync server's API, as the app calls it. The shapes mirror
//! packages/api/src/index.ts; keep the two in step.

use std::io::Read;
use std::time::Duration;

use serde::Deserialize;

/// The app's client ID for Better Auth's device sign-in (APP_CLIENT_ID).
pub const APP_CLIENT_ID: &str = "road-to-sixty-app";

/// The most a merged journey may unpack to; the server refuses more.
const MAX_JOURNEY: u64 = 32 * 1024 * 1024;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct UploadResponse {
    pub version: i64,
    /// "queued", or "known" when this exact file was uploaded before.
    pub status: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct CheckEntry {
    pub game: String,
    pub realm: String,
    pub name: String,
    /// None when it needs a newer addon than this PC has.
    pub version: Option<i64>,
    pub fingerprint: String,
    pub replace: bool,
    #[serde(rename = "updateAddon")]
    pub update_addon: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct CheckResponse {
    pub characters: Vec<CheckEntry>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct LinkResponse {
    /// The PC token, for every /v1 call.
    pub token: String,
    /// This PC's ID, which the addon keeps its counts under.
    pub pc: String,
    /// Who the PC is linked to.
    pub battletag: String,
}

/// Better Auth's answer to /api/auth/device/code (RFC 8628).
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri_complete: String,
    /// Seconds to wait between polls.
    pub interval: u64,
    pub expires_in: u64,
}

/// One poll of /api/auth/device/token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DevicePoll {
    /// Approved: the session token to trade at /v1/link.
    Approved(String),
    Pending,
    SlowDown,
    /// Denied, expired, or anything else that ends the attempt.
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    /// The PC token is missing, unknown or revoked: link the PC again.
    Unauthorized,
    Status(u16, String),
    /// No answer: offline, or the server is down. Try again later.
    Network(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Unauthorized => write!(f, "this PC isn't linked"),
            ApiError::Status(code, body) => write!(f, "the server answered {code}: {body}"),
            ApiError::Network(why) => write!(f, "couldn't reach the server: {why}"),
        }
    }
}

impl std::error::Error for ApiError {}

pub struct Client {
    agent: ureq::Agent,
    server: String,
    token: Option<String>,
}

type Reply = ureq::http::Response<ureq::Body>;

impl Client {
    pub fn new(server: &str, token: Option<String>) -> Self {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(120)))
            .build()
            .into();
        Client {
            agent,
            server: server.trim_end_matches('/').to_string(),
            token,
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.server)
    }

    fn bearer(&self) -> String {
        format!("Bearer {}", self.token.as_deref().unwrap_or(""))
    }

    /// A character's SavedVariables file, compressed with zstd on the way.
    /// `received` is the version the addon last brought in (syncedVersion).
    pub fn upload(
        &self,
        game: &str,
        realm: &str,
        name: &str,
        addon: Option<&str>,
        received: Option<i64>,
        file: &[u8],
    ) -> Result<UploadResponse, ApiError> {
        let packed = zstd::encode_all(file, 3).map_err(|e| ApiError::Network(e.to_string()))?;
        let mut request = self
            .agent
            .post(self.url("/v1/upload"))
            .header("authorization", self.bearer())
            .query("game", game)
            .query("realm", realm)
            .query("name", name);
        if let Some(addon) = addon {
            request = request.query("addon", addon);
        }
        if let Some(received) = received {
            request = request.query("received", received.to_string());
        }
        json(request.send(&packed[..]))
    }

    pub fn check(&self) -> Result<CheckResponse, ApiError> {
        json(self.agent.get(self.url("/v1/check")).header("authorization", self.bearer()).call())
    }

    /// One merged or restored version, as Parse.Write text.
    pub fn download(&self, version: i64) -> Result<String, ApiError> {
        let mut reply = ok(self
            .agent
            .get(self.url(&format!("/v1/versions/{version}")))
            .header("authorization", self.bearer())
            .call())?;
        let packed = reply
            .body_mut()
            .with_config()
            .limit(MAX_JOURNEY)
            .read_to_vec()
            .map_err(|e| ApiError::Network(e.to_string()))?;
        let mut text = Vec::new();
        zstd::Decoder::new(&packed[..])
            .and_then(|d| d.take(MAX_JOURNEY + 1).read_to_end(&mut text))
            .map_err(|e| ApiError::Status(200, format!("not a journey: {e}")))?;
        if text.len() as u64 > MAX_JOURNEY {
            return Err(ApiError::Status(200, "the journey is over 32 MB".into()));
        }
        String::from_utf8(text).map_err(|_| ApiError::Status(200, "the journey isn't text".into()))
    }

    pub fn device_code(&self) -> Result<DeviceCode, ApiError> {
        json(
            self.agent
                .post(self.url("/api/auth/device/code"))
                .send_json(serde_json::json!({ "client_id": APP_CLIENT_ID })),
        )
    }

    pub fn device_token(&self, device_code: &str) -> Result<DevicePoll, ApiError> {
        let body = serde_json::json!({
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": device_code,
            "client_id": APP_CLIENT_ID,
        });
        let mut reply = self
            .agent
            .post(self.url("/api/auth/device/token"))
            .send_json(body)
            .map_err(network)?;
        let answer: serde_json::Value = reply.body_mut().read_json().map_err(network)?;
        if let Some(token) = answer["access_token"].as_str() {
            return Ok(DevicePoll::Approved(token.to_string()));
        }
        Ok(match answer["error"].as_str() {
            Some("authorization_pending") => DevicePoll::Pending,
            Some("slow_down") => DevicePoll::SlowDown,
            other => DevicePoll::Failed(answer["error_description"].as_str().or(other).unwrap_or("no answer").to_string()),
        })
    }

    /// Trades the device sign-in's session for this PC's own token.
    pub fn link(&self, session: &str, name: &str, platform: &str) -> Result<LinkResponse, ApiError> {
        json(
            self.agent
                .post(self.url("/v1/link"))
                .header("authorization", format!("Bearer {session}"))
                .query("name", name)
                .query("platform", platform)
                .send_empty(),
        )
    }
}

fn network(e: ureq::Error) -> ApiError {
    ApiError::Network(e.to_string())
}

fn ok(reply: Result<Reply, ureq::Error>) -> Result<Reply, ApiError> {
    let mut reply = reply.map_err(network)?;
    match reply.status().as_u16() {
        200..=299 => Ok(reply),
        401 => Err(ApiError::Unauthorized),
        code => Err(ApiError::Status(code, reply.body_mut().read_to_string().unwrap_or_default())),
    }
}

fn json<T: serde::de::DeserializeOwned>(reply: Result<Reply, ureq::Error>) -> Result<T, ApiError> {
    ok(reply)?.body_mut().read_json().map_err(network)
}
```

- [ ] **Step 3: Linking**

Put this above the tests in `link.rs`:

```rust
//! Linking this PC (spec, "Linking the app"): the server gives a code, the
//! player signs in with Battle.net on the page the app opens and approves
//! it, and the app trades the sign-in for its own PC token.

use std::time::Duration;

use crate::api::{ApiError, Client, DevicePoll, LinkResponse};

/// Links this PC. `open` shows the player the page to approve on (the app
/// opens their browser); `sleep` waits between polls (tests pass a no-op).
pub fn link(client: &Client, pc_name: &str, open: impl FnOnce(&str, &str), sleep: impl Fn(Duration)) -> Result<LinkResponse, ApiError> {
    let code = client.device_code()?;
    open(&code.verification_uri_complete, &code.user_code);
    let mut interval = code.interval.max(1);
    let polls = code.expires_in / interval + 1;
    for _ in 0..polls {
        sleep(Duration::from_secs(interval));
        match client.device_token(&code.device_code)? {
            DevicePoll::Approved(session) => return client.link(&session, pc_name, platform()),
            DevicePoll::Pending => {}
            DevicePoll::SlowDown => interval += 5,
            DevicePoll::Failed(why) => return Err(ApiError::Status(400, why)),
        }
    }
    Err(ApiError::Status(400, "the code expired before it was approved".into()))
}

pub fn platform() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    }
}
```

Run: `cd apps/desktop && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check; cd ../..`
Expected: `test result: ok. 13 passed`.

- [ ] **Step 4: Commit**

```bash
git add apps/desktop/engine/src
git commit -m "Desktop: the sync API client, and linking a PC through the browser (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Saved state and the sync pass

**Files:**
- Create: `apps/desktop/engine/src/state.rs`, `apps/desktop/engine/src/sync.rs`
- Modify: `apps/desktop/engine/src/lib.rs`

**Interfaces:**
- Consumes: Tasks 2 to 4.
- Produces: `state::{State { pc, battletag, picked, uploaded }, State::load(&Path), State::save(&Path), data_dir(), Tokens (get, set, clear), Keychain, MemoryTokens}`; `sync::{Report { uploaded, delivered, update_addon, problems }, synced_version(&[u8]) -> Option<i64>, roster_key(&[u8]) -> Option<(String, String)>, fingerprint(&[u8]) -> String, upload(..) -> Result<Option<String>, ApiError>, deliver(..), pass(client, state, state_path, games, cache, ready) -> Result<Report, ApiError>, games(&State), watched(&[GameFolder])}`.

- [ ] **Step 1: Write the failing tests**

Add `pub mod state;` and `pub mod sync;` to `lib.rs`. Create `apps/desktop/engine/src/state.rs` holding only its tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_saves_and_loads_and_starts_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("state.json");
        assert_eq!(State::load(&path).unwrap(), State::default());
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        state.uploaded.insert(PathBuf::from("/wow/x.lua"), "ab".into());
        state.save(&path).unwrap();
        assert_eq!(State::load(&path).unwrap(), state);
        assert!(!path.with_extension("tmp").exists());
    }

    #[test]
    fn a_damaged_state_file_is_an_error_not_a_fresh_start() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        fs::write(&path, "{ not json").unwrap();
        assert!(State::load(&path).is_err());
    }
}
```

and `apps/desktop/engine/src/sync.rs` holding only its tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::fake;
    use crate::inbox::sync_folder;
    use crate::installs::addon_toc;

    // As Forever writes it: no indentation, and the character's folder
    // doesn't name the realm the addon uses.
    const FILE: &str =
        "\r\nRoadToSixtyCharDB = {\r\n[\"syncedVersion\"] = 7,\r\n[\"rosterKey\"] = \"Ann-Test Realm\",\r\n[\"version\"] = 3,\r\n}\r\n";

    fn game() -> (tempfile::TempDir, GameFolder) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("_classic_beta_");
        fs::create_dir_all(addon_toc(&path).parent().unwrap()).unwrap();
        fs::write(addon_toc(&path), "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        let saved = path.join("WTF/Account/ACCOUNT1/70/Ann-Stormfist/SavedVariables");
        fs::create_dir_all(&saved).unwrap();
        fs::write(saved.join("RoadToSixty.lua"), FILE).unwrap();
        (
            dir,
            GameFolder {
                path,
                name: "_classic_beta_".into(),
            },
        )
    }

    #[test]
    fn roster_key_splits_at_the_first_hyphen() {
        assert_eq!(roster_key(FILE.as_bytes()), Some(("Ann".into(), "Test Realm".into())));
        assert_eq!(
            roster_key(b"[\"rosterKey\"] = \"Zo\xc3\xab-Azjol-Nerub\","),
            Some(("Zoë".into(), "Azjol-Nerub".into()))
        );
        assert_eq!(roster_key(b"[\"rosterKey\"] = \"NoRealm\","), None);
        assert_eq!(roster_key(b"RoadToSixtyCharDB = {}"), None);
    }

    #[test]
    fn synced_version_reads_the_number_the_addon_saved() {
        assert_eq!(synced_version(FILE.as_bytes()), Some(7));
        assert_eq!(synced_version(b"RoadToSixtyCharDB = {}"), None);
    }

    #[test]
    fn a_pass_uploads_a_changed_file_once_and_delivers_each_version_once() {
        let (dir, game) = game();
        let fake = fake::serve(|_, url| {
            if url.starts_with("/v1/upload") {
                (200, br#"{"version":8,"status":"queued"}"#.to_vec())
            } else if url == "/v1/check" {
                (200, br#"{"characters":[
                    {"game":"_classic_beta_","realm":"Test Realm","name":"Ann","version":9,"fingerprint":"f","replace":false,"updateAddon":false},
                    {"game":"_classic_era_","realm":"Other","name":"Elsewhere","version":4,"fingerprint":"g","replace":false,"updateAddon":false},
                    {"game":"_classic_beta_","realm":"Test Realm","name":"Old","version":null,"fingerprint":"h","replace":false,"updateAddon":true}]}"#.to_vec())
            } else {
                (200, zstd::encode_all(&b"{[\"version\"]=3,}"[..], 3).unwrap())
            }
        });
        let client = Client::new(&fake.url, Some("t".into()));
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let (state_path, cache) = (dir.path().join("state.json"), dir.path().join("journeys"));

        let report = pass(&client, &mut state, &state_path, std::slice::from_ref(&game), &cache, |_| true).unwrap();
        assert_eq!(report.uploaded, ["Ann-Test Realm"]);
        assert_eq!(report.delivered, ["_classic_beta_"]);
        assert_eq!(report.update_addon, ["Old-Test Realm"]);
        let data = fs::read_to_string(sync_folder(&game.path).join("data.lua")).unwrap();
        assert!(
            data.contains(r#"["Ann-Test Realm"] = { version = 9, replace = false, journey = "{[\"version\"]=3,}" }"#),
            "{data}"
        );
        assert!(!data.contains("Elsewhere"));
        let upload = fake.seen.lock().unwrap()[0].url.clone();
        assert_eq!(
            upload,
            "/v1/upload?game=_classic_beta_&realm=Test%20Realm&name=Ann&addon=1.9.0&received=7"
        );

        let again = pass(&client, &mut state, &state_path, &[game], &cache, |_| true).unwrap();
        assert_eq!((again.uploaded.len(), again.delivered.len()), (0, 0));
        let urls: Vec<String> = fake.seen.lock().unwrap().iter().map(|s| s.url.clone()).collect();
        assert_eq!(urls.iter().filter(|u| u.starts_with("/v1/upload")).count(), 1);
        assert_eq!(urls.iter().filter(|u| u.starts_with("/v1/versions/")).count(), 1);
        assert_eq!(State::load(&state_path).unwrap().uploaded.len(), 1);
    }

    #[test]
    fn a_file_from_an_older_addon_is_a_problem_and_not_sent() {
        let (dir, game) = game();
        let file = installs::saved_files(&game).remove(0);
        fs::write(&file.path, "RoadToSixtyCharDB = {}").unwrap();
        let fake = fake::serve(|_, _| (200, br#"{"characters":[]}"#.to_vec()));
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let report = pass(
            &Client::new(&fake.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            &[game],
            &dir.path().join("j"),
            |_| true,
        )
        .unwrap();
        assert!(
            report.problems[0].contains("log in once with the updated addon"),
            "{:?}",
            report.problems
        );
        assert!(fake.seen.lock().unwrap().iter().all(|s| !s.url.starts_with("/v1/upload")));
    }

    #[test]
    fn a_refused_file_is_a_problem_but_unlinked_stops_the_pass() {
        let (dir, game) = game();
        let refused = fake::serve(|_, url| {
            if url.starts_with("/v1/upload") {
                (413, b"too big".to_vec())
            } else {
                (200, br#"{"characters":[]}"#.to_vec())
            }
        });
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let report = pass(
            &Client::new(&refused.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            std::slice::from_ref(&game),
            &dir.path().join("j"),
            |_| true,
        )
        .unwrap();
        assert_eq!(report.problems.len(), 1);
        assert!(state.uploaded.is_empty());

        let unlinked = fake::serve(|_, _| (401, b"{}".to_vec()));
        let result = pass(
            &Client::new(&unlinked.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            &[game],
            &dir.path().join("j"),
            |_| true,
        );
        assert_eq!(result, Err(ApiError::Unauthorized));
    }
}
```

Run: `cd apps/desktop && cargo test; cd ../..`
Expected: compile errors for `State`, `pass`, `roster_key` and `synced_version`.

- [ ] **Step 2: State and the token**

Put this above the tests in `state.rs`:

```rust
//! What the app remembers between runs, in a JSON file in its data folder,
//! and the PC token, which lives in the Mac Keychain or Windows Credential
//! Manager instead (spec, "First run").

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct State {
    /// This PC's ID from linking; the addon keeps its counts under it.
    pub pc: Option<String>,
    /// Who the PC is linked to, to show.
    pub battletag: Option<String>,
    /// Install folders the player picked by hand.
    #[serde(default)]
    pub picked: Vec<PathBuf>,
    /// The fingerprint of the last upload of each saved file, by path, so an
    /// unchanged file isn't sent again.
    #[serde(default)]
    pub uploaded: BTreeMap<PathBuf, String>,
}

impl State {
    /// The saved state, or a fresh one when there is none yet.
    pub fn load(path: &Path) -> io::Result<State> {
        match fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(io::Error::other),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(e),
        }
    }

    /// Written beside the old file and renamed over it, so a crash never
    /// leaves half a file.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
        let temp = path.with_extension("tmp");
        fs::write(&temp, serde_json::to_vec_pretty(self).map_err(io::Error::other)?)?;
        fs::rename(&temp, path)
    }
}

/// The app's own folder for its state and downloaded journeys.
pub fn data_dir() -> PathBuf {
    dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("Road to Sixty")
}

/// Where the PC token is kept. Tests use `MemoryTokens`, so they never touch
/// the real Keychain.
pub trait Tokens {
    fn get(&self) -> Option<String>;
    fn set(&self, token: &str) -> Result<(), String>;
    fn clear(&self) -> Result<(), String>;
}

/// The system's secure store: the Mac Keychain, Windows Credential Manager,
/// or the Secret Service on Linux.
pub struct Keychain;

const SERVICE: &str = "Road to Sixty";
const ACCOUNT: &str = "PC token";

impl Tokens for Keychain {
    fn get(&self) -> Option<String> {
        keyring::Entry::new(SERVICE, ACCOUNT).ok()?.get_password().ok()
    }

    fn set(&self, token: &str) -> Result<(), String> {
        keyring::Entry::new(SERVICE, ACCOUNT)
            .and_then(|e| e.set_password(token))
            .map_err(|e| e.to_string())
    }

    fn clear(&self) -> Result<(), String> {
        match keyring::Entry::new(SERVICE, ACCOUNT).and_then(|e| e.delete_credential()) {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

#[derive(Default)]
pub struct MemoryTokens(pub std::sync::Mutex<Option<String>>);

impl Tokens for MemoryTokens {
    fn get(&self) -> Option<String> {
        self.0.lock().unwrap().clone()
    }

    fn set(&self, token: &str) -> Result<(), String> {
        *self.0.lock().unwrap() = Some(token.to_string());
        Ok(())
    }

    fn clear(&self) -> Result<(), String> {
        *self.0.lock().unwrap() = None;
        Ok(())
    }
}
```

- [ ] **Step 3: The pass**

Put this above the tests in `sync.rs`:

```rust
//! One sync pass (spec, "While running"): upload the saved journeys that
//! changed, ask the server for every character's newest merged version,
//! download the ones not already here, and write each game folder's sync
//! folder. The watcher (watch.rs) decides when a file is ready.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::api::{ApiError, Client};
use crate::inbox::{self, Delivery};
use crate::installs::{self, GameFolder, SavedFile};
use crate::state::State;

/// What a pass did, for the app to show.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// `Name-Realm` of each character uploaded.
    pub uploaded: Vec<String>,
    /// Game folders whose sync folder changed.
    pub delivered: Vec<String>,
    /// Characters whose newest version needs a newer addon on this PC.
    pub update_addon: Vec<String>,
    /// Files the server refused, with why. The rest of the pass goes on.
    pub problems: Vec<String>,
}

/// The version the addon last brought in from the sync folder, which the
/// character file records as `syncedVersion`. Sent with an upload as
/// `received`, so the server knows whether this PC has taken in a restore.
pub fn synced_version(file: &[u8]) -> Option<i64> {
    const KEY: &[u8] = b"[\"syncedVersion\"] = ";
    let at = file.windows(KEY.len()).position(|w| w == KEY)? + KEY.len();
    let digits: Vec<u8> = file[at..].iter().copied().take_while(u8::is_ascii_digit).collect();
    std::str::from_utf8(&digits).ok()?.parse().ok()
}

/// The character's name and realm from the `rosterKey` the addon saves
/// (`Name-Realm`, from UnitName and GetRealmName). Names can't hold a
/// hyphen, so the first one splits them; realms can ("Azjol-Nerub").
pub fn roster_key(file: &[u8]) -> Option<(String, String)> {
    const KEY: &[u8] = b"[\"rosterKey\"] = \"";
    let at = file.windows(KEY.len()).position(|w| w == KEY)? + KEY.len();
    let mut value = Vec::new();
    let mut bytes = file[at..].iter();
    while let Some(&b) = bytes.next() {
        match b {
            b'"' => break,
            b'\\' => value.push(*bytes.next()?),
            b'\n' | b'\r' => return None,
            b => value.push(b),
        }
    }
    let text = String::from_utf8(value).ok()?;
    let (name, realm) = text.split_once('-')?;
    (!name.is_empty() && !realm.is_empty()).then(|| (name.to_string(), realm.to_string()))
}

pub fn fingerprint(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn key(name: &str, realm: &str) -> String {
    format!("{name}-{realm}")
}

/// Uploads one saved file unless this exact file was uploaded before.
/// Returns the character's `Name-Realm` when it was sent.
pub fn upload(client: &Client, state: &mut State, file: &SavedFile, addon: Option<&str>) -> Result<Option<String>, ApiError> {
    let bytes = fs::read(&file.path).map_err(|e| ApiError::Status(0, format!("couldn't read {}: {e}", file.path.display())))?;
    let print = fingerprint(&bytes);
    if state.uploaded.get(&file.path) == Some(&print) {
        return Ok(None);
    }
    let Some((name, realm)) = roster_key(&bytes) else {
        return Err(ApiError::Status(
            0,
            format!("{} has no rosterKey: log in once with the updated addon", file.path.display()),
        ));
    };
    client.upload(&file.game, &realm, &name, addon, synced_version(&bytes), &bytes)?;
    state.uploaded.insert(file.path.clone(), print);
    Ok(Some(key(&name, &realm)))
}

/// Asks for every character's newest version and writes it into the sync
/// folder of each game folder here. Journeys are kept in `cache` by version,
/// so each is downloaded once.
pub fn deliver(client: &Client, pc: &str, games: &[GameFolder], cache: &Path, report: &mut Report) -> Result<(), ApiError> {
    let check = client.check()?;
    let mut by_game: BTreeMap<&str, Vec<Delivery>> = BTreeMap::new();
    let mut kept = BTreeSet::new();
    for entry in &check.characters {
        if entry.update_addon {
            report.update_addon.push(key(&entry.name, &entry.realm));
        }
        let Some(version) = entry.version else { continue };
        if !games.iter().any(|g| g.name == entry.game) {
            continue;
        }
        let path = cache.join(format!("{version}.lua"));
        let journey = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(_) => {
                let text = client.download(version)?;
                fs::create_dir_all(cache)
                    .and_then(|()| fs::write(&path, &text))
                    .map_err(|e| ApiError::Status(0, e.to_string()))?;
                text
            }
        };
        kept.insert(path);
        by_game.entry(&entry.game).or_default().push(Delivery {
            key: key(&entry.name, &entry.realm),
            version,
            replace: entry.replace,
            journey,
        });
    }
    for game in games {
        let mut deliveries = by_game.remove(game.name.as_str()).unwrap_or_default();
        deliveries.sort_by(|a, b| a.key.cmp(&b.key));
        match inbox::write(&game.path, pc, &deliveries) {
            Ok(true) => report.delivered.push(game.name.clone()),
            Ok(false) => {}
            Err(e) => report
                .problems
                .push(format!("couldn't write the sync folder in {}: {e}", game.path.display())),
        }
    }
    for old in fs::read_dir(cache).into_iter().flatten().flatten().map(|e| e.path()) {
        if !kept.contains(&old) {
            let _ = fs::remove_file(old);
        }
    }
    Ok(())
}

/// One whole pass. `ready` says which changed files to upload now (the
/// watcher's settle and rate rules); the state is saved after each upload.
/// A 401 or no answer stops the pass: link again, or try later.
pub fn pass(
    client: &Client,
    state: &mut State,
    state_path: &Path,
    games: &[GameFolder],
    cache: &Path,
    ready: impl Fn(&SavedFile) -> bool,
) -> Result<Report, ApiError> {
    let mut report = Report::default();
    for game in games {
        let addon = installs::addon_version(&game.path);
        for file in installs::saved_files(game).iter().filter(|f| ready(f)) {
            match upload(client, state, file, addon.as_deref()) {
                Ok(Some(sent)) => {
                    report.uploaded.push(sent);
                    state.save(state_path).map_err(|e| ApiError::Status(0, e.to_string()))?;
                }
                Ok(None) => {}
                Err(e @ (ApiError::Unauthorized | ApiError::Network(_))) => return Err(e),
                Err(e) => report.problems.push(e.to_string()),
            }
        }
    }
    let pc = state.pc.clone().ok_or(ApiError::Unauthorized)?;
    deliver(client, &pc, games, cache, &mut report)?;
    Ok(report)
}

/// Every game folder with the addon, in every install found.
pub fn games(state: &State) -> Vec<GameFolder> {
    installs::find_installs(&state.picked)
        .iter()
        .flat_map(|i| installs::game_folders(i))
        .collect()
}

/// The paths a pass looks at, for the watcher: each game folder's WTF.
pub fn watched(games: &[GameFolder]) -> Vec<PathBuf> {
    games.iter().map(|g| g.path.join("WTF")).filter(|p| p.is_dir()).collect()
}
```

Run: `cd apps/desktop && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check; cd ../..`
Expected: `test result: ok. 20 passed`.

- [ ] **Step 4: Commit**

```bash
git add apps/desktop/engine/src
git commit -m "Desktop: one sync pass: upload what changed, deliver what's new (#1)

Characters are named by the rosterKey in their saved file, and the
syncedVersion there is sent as what this PC has received.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The watcher, the terminal tool, CI and docs, and the live run

**Files:**
- Create: `apps/desktop/engine/src/watch.rs`, `apps/desktop/engine/src/bin/rts-sync.rs`
- Modify: `apps/desktop/engine/src/lib.rs`, `.github/workflows/ci.yml`, `CLAUDE.md`, `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`

**Interfaces:**
- Consumes: Tasks 2 to 5.
- Produces: `watch::{SETTLE, WHILE_PLAYING, CHECK_EVERY, RETRY, game_running(&Path, &[PathBuf]) -> bool, running_programs(&mut System), Schedule::{changed, due, sent}, run(client, state, state_path, cache, stop, report)}`; the `rts-sync` binary (`status`, `link [name]`, `once`, `run`, `unlink`).

- [ ] **Step 1: Write the failing tests**

Add `pub mod watch;` to `lib.rs`; it now lists `api`, `inbox`, `installs`, `link`, `state`, `sync`, `watch`. Create `apps/desktop/engine/src/watch.rs` holding only its tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn at(start: Instant, secs: u64) -> Instant {
        start + Duration::from_secs(secs)
    }

    #[test]
    fn a_file_waits_until_it_has_settled() {
        let (t0, mut s) = (Instant::now(), Schedule::default());
        s.changed(PathBuf::from("a"), t0);
        assert!(s.due(at(t0, 9), |_| false).is_empty());
        assert_eq!(s.due(at(t0, 10), |_| false), [PathBuf::from("a")]);
        s.changed(PathBuf::from("a"), at(t0, 8));
        assert!(s.due(at(t0, 10), |_| false).is_empty(), "a change restarts the wait");
    }

    #[test]
    fn while_the_game_runs_a_file_goes_up_at_most_every_15_minutes() {
        let (t0, mut s) = (Instant::now(), Schedule::default());
        let a = PathBuf::from("a");
        s.changed(a.clone(), t0);
        assert_eq!(s.due(at(t0, 10), |_| true), vec![a.clone()], "the first upload doesn't wait");
        s.sent(std::slice::from_ref(&a), at(t0, 10));
        s.changed(a.clone(), at(t0, 60));
        assert!(s.due(at(t0, 300), |_| true).is_empty());
        assert_eq!(s.due(at(t0, 910), |_| true), vec![a.clone()]);
        assert_eq!(s.due(at(t0, 300), |_| false), [a], "once the game closes, straight away");
    }

    #[test]
    fn the_game_runs_when_a_program_inside_its_folder_does() {
        let game = Path::new("/Applications/World of Warcraft/_classic_beta_");
        let mac = PathBuf::from(
            "/Applications/World of Warcraft/_classic_beta_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic",
        );
        assert!(game_running(game, &[PathBuf::from("/usr/bin/zsh"), mac]));
        assert!(!game_running(
            game,
            &[PathBuf::from("/Applications/World of Warcraft/_retail_/Wow.app/Contents/MacOS/Wow")]
        ));
    }
}
```

Run: `cd apps/desktop && cargo test watch; cd ../..`
Expected: compile errors for `Schedule` and `game_running`.

- [ ] **Step 2: The watcher**

Put this above the tests in `watch.rs`:

```rust
//! When to upload (spec, "While running"): a saved file is sent once it has
//! been unchanged for 10 seconds; while its game runs, at most once every
//! 15 minutes, so repeated /reloads don't flood the server; when the game
//! closes, straight away. The server is also asked for new versions every
//! few minutes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use notify::{RecursiveMode, Watcher};

use crate::api::{ApiError, Client};
use crate::installs;
use crate::state::State;
use crate::sync::{self, Report};

pub const SETTLE: Duration = Duration::from_secs(10);
pub const WHILE_PLAYING: Duration = Duration::from_secs(15 * 60);
pub const CHECK_EVERY: Duration = Duration::from_secs(5 * 60);
/// After a failed pass (offline, server down), wait this long to try again.
pub const RETRY: Duration = Duration::from_secs(60);

/// Whether the game in `game` is running: some process's program file is
/// inside it. Process names differ by version and processor, and on a Mac
/// the program is inside the .app in the game folder.
pub fn game_running(game: &Path, programs: &[PathBuf]) -> bool {
    programs.iter().any(|p| p.starts_with(game))
}

pub fn running_programs(system: &mut sysinfo::System) -> Vec<PathBuf> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, UpdateKind};
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
    );
    system.processes().values().filter_map(|p| p.exe().map(Path::to_path_buf)).collect()
}

/// The files waiting to be uploaded, and when each last changed and was
/// last sent.
#[derive(Debug, Default)]
pub struct Schedule {
    changed: BTreeMap<PathBuf, Instant>,
    sent: BTreeMap<PathBuf, Instant>,
}

impl Schedule {
    pub fn changed(&mut self, path: PathBuf, now: Instant) {
        self.changed.insert(path, now);
    }

    /// The files to upload now. `playing` says whether a file's game runs.
    pub fn due(&self, now: Instant, playing: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
        self.changed
            .iter()
            .filter(|(path, at)| {
                let settled = now.duration_since(**at) >= SETTLE;
                let rested = !playing(path) || self.sent.get(*path).is_none_or(|t| now.duration_since(*t) >= WHILE_PLAYING);
                settled && rested
            })
            .map(|(p, _)| p.clone())
            .collect()
    }

    pub fn sent(&mut self, paths: &[PathBuf], now: Instant) {
        for path in paths {
            self.changed.remove(path);
            self.sent.insert(path.clone(), now);
        }
    }
}

/// Watches every game folder's WTF and syncs until `stop` is set, calling
/// `report` after each pass. Every saved journey counts as changed at the
/// start, so anything new since the app last ran goes up first (an
/// unchanged file is skipped by its fingerprint).
pub fn run(
    client: &Client,
    state: &mut State,
    state_path: &Path,
    cache: &Path,
    stop: &AtomicBool,
    mut report: impl FnMut(&Result<Report, ApiError>),
) -> notify::Result<()> {
    let games = sync::games(state);
    let (tx, rx) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if let Ok(event) = event {
            for path in event.paths {
                if path.file_name().is_some_and(|n| n == "RoadToSixty.lua") {
                    let _ = tx.send(path);
                }
            }
        }
    })?;
    for wtf in sync::watched(&games) {
        watcher.watch(&wtf, RecursiveMode::Recursive)?;
    }

    let mut schedule = Schedule::default();
    let start = Instant::now();
    for file in games.iter().flat_map(installs::saved_files) {
        schedule.changed(file.path, start.checked_sub(SETTLE).unwrap_or(start));
    }
    let mut system = sysinfo::System::new();
    let mut last_pass: Option<Instant> = None;
    let mut wait_until = start;
    while !stop.load(Ordering::Relaxed) {
        let now = Instant::now();
        for path in rx.try_iter() {
            schedule.changed(path, now);
        }
        let programs = running_programs(&mut system);
        let playing = |file: &Path| games.iter().any(|g| file.starts_with(&g.path) && game_running(&g.path, &programs));
        let due = schedule.due(now, playing);
        let check_due = last_pass.is_none_or(|t| now.duration_since(t) >= CHECK_EVERY);
        if now >= wait_until && (!due.is_empty() || check_due) {
            let result = sync::pass(client, state, state_path, &games, cache, |f| due.contains(&f.path));
            match &result {
                Ok(_) => {
                    schedule.sent(&due, now);
                    last_pass = Some(now);
                }
                Err(_) => wait_until = now + RETRY,
            }
            report(&result);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    Ok(())
}
```

Run: `cd apps/desktop && cargo test; cd ../..`
Expected: `test result: ok. 23 passed`.

- [ ] **Step 3: The terminal tool**

Create `apps/desktop/engine/src/bin/rts-sync.rs`:

```rust
//! Runs the sync engine from a terminal, until the app's window exists and
//! for trying it out:
//!
//!   rts-sync status     the installs, game folders and characters found
//!   rts-sync link       link this PC (opens the browser to approve)
//!   rts-sync once       one sync pass
//!   rts-sync run        watch and sync until stopped
//!   rts-sync unlink     forget this PC's token
//!
//! RTS_SERVER picks the server (default: the test server) and RTS_DATA_DIR
//! the folder for the app's state and downloaded journeys.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;

use rts_sync::api::{ApiError, Client};
use rts_sync::state::{self, Keychain, State, Tokens};
use rts_sync::sync::Report;
use rts_sync::{installs, link, sync, watch};

const DEFAULT_SERVER: &str = "https://api.rts.everhold.online";

fn main() -> ExitCode {
    let server = std::env::var("RTS_SERVER").unwrap_or_else(|_| DEFAULT_SERVER.to_string());
    let data = std::env::var_os("RTS_DATA_DIR").map(PathBuf::from).unwrap_or_else(state::data_dir);
    let state_path = data.join("state.json");
    let cache = data.join("journeys");
    let mut state = match State::load(&state_path) {
        Ok(state) => state,
        Err(e) => return fail(&format!("couldn't read {}: {e}", state_path.display())),
    };
    let tokens = Keychain;
    let client = Client::new(&server, tokens.get());

    match std::env::args().nth(1).as_deref() {
        Some("status") => {
            println!(
                "server {server}; {}",
                match (&state.battletag, tokens.get()) {
                    (Some(tag), Some(_)) => format!("linked to {tag}"),
                    _ => "not linked".into(),
                }
            );
            for game in sync::games(&state) {
                println!(
                    "{} (addon {})",
                    game.path.display(),
                    installs::addon_version(&game.path).unwrap_or_else(|| "developer".into())
                );
                for file in installs::saved_files(&game) {
                    match std::fs::read(&file.path).ok().as_deref().and_then(sync::roster_key) {
                        Some((name, realm)) => println!("  {name}-{realm}"),
                        None => println!("  {} (log in once with the updated addon)", file.path.display()),
                    }
                }
            }
            ExitCode::SUCCESS
        }
        Some("link") => {
            let name = std::env::args().nth(2).unwrap_or_else(|| "This PC".into());
            let linked = link::link(
                &client,
                &name,
                |url, code| {
                    println!("Approve code {code} at {url}");
                    let _ = open(url);
                },
                std::thread::sleep,
            );
            match linked {
                Ok(linked) => {
                    if let Err(e) = tokens.set(&linked.token) {
                        return fail(&format!("couldn't keep the token: {e}"));
                    }
                    state.pc = Some(linked.pc);
                    state.battletag = Some(linked.battletag.clone());
                    state.uploaded.clear();
                    if let Err(e) = state.save(&state_path) {
                        return fail(&e.to_string());
                    }
                    println!("Linked to {}.", linked.battletag);
                    ExitCode::SUCCESS
                }
                Err(e) => fail(&e.to_string()),
            }
        }
        Some("once") => {
            let games = sync::games(&state);
            let result = sync::pass(&client, &mut state, &state_path, &games, &cache, |_| true);
            show(&result);
            if result.is_ok() { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        Some("run") => {
            let stop = AtomicBool::new(false);
            match watch::run(&client, &mut state, &state_path, &cache, &stop, show) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e.to_string()),
            }
        }
        Some("unlink") => {
            let _ = tokens.clear();
            state = State {
                picked: state.picked,
                ..State::default()
            };
            match state.save(&state_path) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e.to_string()),
            }
        }
        _ => fail("usage: rts-sync status | link [PC name] | once | run | unlink"),
    }
}

fn show(result: &Result<Report, ApiError>) {
    match result {
        Ok(r) => {
            for key in &r.uploaded {
                println!("uploaded {key}");
            }
            for game in &r.delivered {
                println!("delivered to {game}");
            }
            for key in &r.update_addon {
                println!("{key}: update the addon on this PC");
            }
            for problem in &r.problems {
                println!("problem: {problem}");
            }
        }
        Err(ApiError::Unauthorized) => println!("This PC isn't linked: run rts-sync link."),
        Err(e) => println!("{e}"),
    }
}

fn open(url: &str) -> std::io::Result<std::process::Child> {
    let opener = if cfg!(windows) {
        "explorer"
    } else if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    std::process::Command::new(opener).arg(url).spawn()
}

fn fail(message: &str) -> ExitCode {
    eprintln!("{message}");
    ExitCode::FAILURE
}
```

Run: `cd apps/desktop && cargo clippy --all-targets -- -D warnings && cargo fmt --check && cargo run -q --bin rts-sync -- status; cd ../..`
Expected: no warnings; `status` prints the server, whether this PC is linked, and each game folder with the addon and its characters by `Name-Realm`.

- [ ] **Step 4: CI, docs and the spec**

Apply this to `.github/workflows/ci.yml`, `CLAUDE.md` and the spec:

```diff
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index 0df6538..066aa83 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -27,7 +27,7 @@ jobs:
         run: bun install --frozen-lockfile
 
       - name: Checks
-        run: bun run check
+        run: bun run check --filter=@road-to-sixty/addon
 
       - name: Tests under LuaJIT and Lua 5.1
         run: bun run test --filter=@road-to-sixty/addon
@@ -82,3 +82,23 @@ jobs:
           -e BETTER_AUTH_URL=unused -e BETTER_AUTH_SECRET=unused -e ACCOUNT_HASH_KEY=unused
           -e BATTLENET_CLIENT_ID=unused -e BATTLENET_CLIENT_SECRET=unused
           rts-server bun apps/server/scripts/smoke.ts
+
+  # The desktop app's sync engine: its tests (one has LuaJIT read back the
+  # sync folder it writes), clippy and formatting. rust-toolchain.toml picks
+  # the Rust version.
+  desktop:
+    runs-on: ubuntu-latest
+    defaults:
+      run:
+        working-directory: apps/desktop
+    steps:
+      - uses: actions/checkout@v4
+
+      - name: Install LuaJIT
+        run: sudo apt-get update && sudo apt-get install -y luajit
+
+      - name: Tests
+        run: cargo test
+
+      - name: Clippy and formatting
+        run: cargo clippy --all-targets -- -D warnings && cargo fmt --check
diff --git a/CLAUDE.md b/CLAUDE.md
index 2bc8dbd..af5f91a 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -51,6 +51,14 @@ calls, `src/auth.ts` is sign-in (Better Auth with Battle.net), `src/link.ts`
 and `src/link.html` link a PC, `src/worker.ts` runs the merge jobs, `src/runner.lua` merges under
 standard Lua 5.1 with the addon's pure files, and `src/schema.ts` holds the
 tables (migrations in `drizzle/`, made by `bun run db:generate`).
+`apps/desktop/` is the desktop app (#1). `engine/` is its sync engine in
+Rust, with no window: `installs.rs` finds WoW installs and saved journeys,
+`inbox.rs` writes the `RoadToSixty_Sync` folder, `api.rs` and `link.rs` talk
+to the server, `state.rs` keeps what it remembers (the PC token is in the
+Keychain or Credential Manager), `sync.rs` is one sync pass and `watch.rs`
+decides when to upload. `src/bin/rts-sync.rs` runs it from a terminal. A
+character is named by the `rosterKey` its saved file holds, never by the
+game's folder names, which don't give the realm the addon uses.
 `packages/api/` holds the request and response types the server, website
 and app share.
 
@@ -82,6 +90,10 @@ bun test                            # server tests; LUA51 names Lua 5.1 if lua5.
 bun run dev                         # the server on port 3000, with .env (copied from .env.example)
 bun scripts/link-pc.ts <server> [name]   # link this machine as the app will: approve the code on <server>/link
 bun scripts/try-upload.ts <server> <token>   # upload a made-up journey as that PC and wait for the merge
+
+# From apps/desktop (Rust from rustup; rust-toolchain.toml picks the version)
+cargo test                          # engine tests (one needs luajit on the path)
+cargo run --bin rts-sync -- status  # installs and characters found; also link, once, run, unlink
 ```
 
 Run the addon commands from `apps/addon/`. `check.ps1` currently reports three old
diff --git a/docs/superpowers/specs/2026-10-12-sync-and-backup-design.md b/docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
index 4e6757f..c09f60d 100644
--- a/docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
+++ b/docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
@@ -247,6 +247,7 @@ Tauri v2 in `apps/desktop`. It lives in the Mac menu bar and the Windows tray, w
 ### While running
 
 - Watch each `WTF` folder. When a character's `RoadToSixty.lua` changes, wait until it has been unchanged for about ten seconds, then upload it. Reading while the game runs is safe.
+- Name each character by the `rosterKey` in its saved file (`Name-Realm`, which the addon writes at every login), never by folder names: Forever saves characters under `WTF/Account/<account>/70/<Name>-<other>/`, and the folders don't give the realm the addon uses (seen 2026-10-14). The upload's `realm` and `name` come from it, and so does the sync folder's key.
 - While the game runs, upload each character at most once every 15 minutes, so repeated `/reload`s don't flood the server. When the game closes, upload straight away.
 - Upload the account file at most once a day. Fingerprint WTF account folder names before they leave the PC.
 - Remember the fingerprint of everything uploaded and received. Queue uploads while offline.
@@ -339,7 +340,9 @@ road-to-sixty/
 │   │   └── lib/              auth-client.ts, api.ts
 │   └── desktop/
 │       ├── src/              the window (Vite and React, from packages/ui)
-│       └── src-tauri/src/    main.rs, installs.rs, watch.rs, link.rs, sync.rs, inbox.rs, state.rs
+│       ├── engine/           the sync engine, a Rust library with no window: installs.rs, watch.rs,
+│       │                     link.rs, sync.rs, inbox.rs, state.rs, api.rs, and the rts-sync CLI
+│       └── src-tauri/src/    main.rs, the window and tray around the engine
 ├── packages/
 │   ├── ui/                   shadcn components, colours, Geist, the icon
 │   └── api/                  request and response types for server, web and the app's window
```

Run: `bun run test && bun run check --filter=@road-to-sixty/desktop`
Expected: the addon's 21 test files, the server's 29 tests and the engine's 23, and the engine's check passing.

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/engine/src .github/workflows/ci.yml CLAUDE.md docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
git commit -m "Desktop: the watcher and the rts-sync terminal tool; CI runs the engine (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: After the final review: merge, push, and the live run**

Merge `sync-engine` into `dev`, run `bun run test`, push `dev` (never `main`), and watch CI (`build`, `server` and `desktop` pass).

Check that the game's dev link, `/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/RoadToSixty`, points at this checkout's `apps/addon/RoadToSixty` (`readlink`), so the game runs the addon with `rosterKey`.

Then, from `apps/desktop`:

```bash
cargo run -q --bin rts-sync -- status
cargo run -q --bin rts-sync -- link "Jordan's Mac"   # Jordan approves in the browser
cargo run -q --bin rts-sync -- once
```
Expected: `status` lists the character by its `rosterKey`; `link` prints `Linked to <BattleTag>.`; `once` prints `uploaded <Name-Realm>` and `delivered to _classic_beta_`. Jordan then logs in that character and runs `/rts check`: "Sync: version N was brought in" (or "already brought in" on the next login). Nothing from the real saved files goes into the repo, the ledger or the issue.

- [ ] **Step 7: Record it**

Comment on #1: the engine is on `dev`, what the live install showed (the folder layout and `rosterKey`), the decisions above, and that the next plan is the app around it (tray, first-run window, account screens, start at login, updates, Mac and Windows builds), after mockups.

---

## Notes for later steps

- **The app (next plan)** depends on `rts-sync` by path from `apps/desktop/src-tauri`, runs `watch::run` on a background thread with a stop flag, and shows `Report` and `ApiError` (unlinked, offline, "update the addon on this PC", problems) in the tray and window. Linking opens `verification_uri_complete` with the system browser and shows "Linked to <BattleTag>".
- **Windows:** the next plan's CI builds and tests the engine on Windows too; Jordan's PC checks `product.db`, Credential Manager and the game's process path by hand.
- **The account file's daily backup** waits for a server endpoint.
- **New installs while running:** `watch::run` finds game folders when it starts; the app restarts it when the player adds a folder.
