# App Account Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The desktop app gets the screens Jordan picked on #39 (Characters with class icons and history, the one-tab Account screen, naming the PC when linking), opens under its menu bar or tray icon, updates itself without asking, fetches other PCs' sessions when the game starts, and tells the server its version.

**Architecture:** The window never holds the PC token: every account call goes through a Tauri command (`src-tauri/src/account.rs`) that calls the server with the engine's `Client`, and the window reads the answers with `packages/api`'s types. The engine gains an app version on `/v1/check`, a generic account call, a busy flag around each pass, and a check when a game starts. The app gains a popover window (`tauri-plugin-positioner`), a self-update loop that restarts only while the window is hidden and no pass runs, and a status that carries the PC id, the app version and the update's state. The screens are React, with every word and number worked out in plain tested functions (`src/format.ts`).

**Tech Stack:** Rust (engine `rts-sync`, app `road-to-sixty-app`, Tauri 2.12.3), tauri-plugin-positioner 2.4.0 (new), React 19 with Tailwind 4, Bun tests.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md` ("Account API", "The desktop app", "Start at login and updates"), issue #39 (Jordan's picks), and the mockups canvas https://claude.ai/artifact/M1btBtHDuiExpSuHU7Pg8Z (artboards A-Characters-2, A-History, A-Account).

## Global Constraints

- Branch `app-account` from `dev`; merged into `dev` locally at the end. Never push `main`.
- Commits: `Area: what changed (#N)` (#39 for screens, #1 otherwise), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- British spelling; comments are plain sentences that say why.
- The PC token never reaches the window (spec, "First run"). The window's CSP stays `default-src 'self'`.
- Updates restart the app only while the window is hidden and no upload or delivery is under way; debug builds never check or install (spec).
- Never regenerate the updater key; never touch `~/.config/road-to-sixty/`.
- Tests use made-up characters and folders only (`api::fake`, temporary dirs), never a real install, link or saved file.
- Before each commit that touches Rust: `cargo fmt --check` and `cargo clippy --workspace --all-targets -- -D warnings` in `apps/desktop`.
- Every `AGENTS.md` change goes in the same commit as what it describes.
- Exact versions for new dependencies (`=2.4.0`).

Commands (from `apps/desktop`, after `. ~/.cargo/env`):

- `bun run build` (the window into `dist/`; Tauri's build needs it before `cargo test`)
- `cargo test --workspace` (one test needs `luajit`)
- `bun test src scripts`
- `bun run typecheck`
- `cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`

## Decisions made while planning

- **Account calls go through Rust commands, one per route,** sharing one engine call, `Client::account(method, path, body) -> serde_json::Value`. Answers pass straight through; the window types them with `@road-to-sixty/api`. Ids are numbers, or a PC id checked to be letters, digits, `-` and `_`.
- **The app's version goes on `/v1/check` only.** Every pass calls it, and the server stores `?app=` on any PC route.
- **"Busy" is an `AtomicBool` the watcher sets around each pass;** the update gate reads it directly. Restarting also stops the sync thread first, which waits for a pass that started meanwhile.
- **The update is downloaded first and installed only at restart** (`Update::download`, then `Update::install`): on Windows installing ends the app, so installing early would cut a sync short.
- **"Updated to X" comes from a `version` file in the data folder:** a different version there at start means the app has just updated, so it starts hidden and the menu says so for an hour.
- **Hide on blur, except while one of our dialogs is open** (the folder picker, the save dialog). Both run from Rust so the window knows. Confirmations are inline, as in the A-History mockup, not native dialogs.
- **Unlinking this PC revokes it on the server first;** offline, it still unlinks here, and the server's list keeps it until it is unlinked from another PC.
- **Class icons are game art** from `UI-Classes-Circles` (file 237669), cut by a committed script, as Jordan picked.

## Review Focus

1. An update ready while an upload is under way: the restart waits for the pass to end (busy flag, then `Runner::stop`, which joins the thread). Task 5's `may_restart` test and Task 2's busy test cover the parts; the reviewer reads the join.
2. The folder picker or save dialog opened from the popover: the window must not hide behind it. Task 3's `should_show`/`holding` test.
3. A Windows taskbar on the top, left or right: `TrayCenter` goes below the icon when there's no room above, and `move_window_constrained` keeps it on screen. Checked by hand on Windows (noted for Jordan).
4. A PC unlinked from another PC's list: its next pass gets 401 and shows "Not linked"; its account calls say "This PC isn't linked." Task 4's `words` test.
5. The updater end to end on the unsigned Mac app, 0.1.2 to the next version: only a real release proves it. Noted for Jordan after the merge.

---

### Task 1: The engine's client sends the app version and makes account calls

**Files:**
- Modify: `apps/desktop/engine/src/api.rs`

**Interfaces:**
- Produces: `Client::app(self, version: &str) -> Client` (builder; `/v1/check` then carries `?app=<version>`). `Client::account(&self, method: &str, path: &str, body: Option<serde_json::Value>) -> Result<serde_json::Value, ApiError>` for `GET`, `POST`, `PATCH`, `DELETE`. `Client::export(&self) -> Result<Vec<u8>, ApiError>` (the zip from `GET /v1/export`).

- [ ] **Step 1: Write the failing tests**

Add to `mod tests` in `engine/src/api.rs`:

```rust
    #[test]
    fn check_tells_the_server_the_app_version() {
        let fake = fake::serve(|_, _| (200, br#"{"characters":[]}"#.to_vec()));
        Client::new(&fake.url, Some("t".into())).app("0.1.2").check().unwrap();
        Client::new(&fake.url, Some("t".into())).check().unwrap();
        let seen = fake.seen.lock().unwrap();
        assert_eq!(seen[0].url, "/v1/check?app=0.1.2");
        assert_eq!(seen[1].url, "/v1/check", "the terminal tool has no app version");
    }

    #[test]
    fn account_calls_pass_the_answer_through_with_the_pc_token() {
        let fake = fake::serve(|method, _| match method {
            "GET" => (200, br#"[{"id":1,"name":"Ann"}]"#.to_vec()),
            "DELETE" => (404, br#"{"error":"no such PC"}"#.to_vec()),
            _ => (200, br#"{"ok":true}"#.to_vec()),
        });
        let client = Client::new(&fake.url, Some("pc-token".into()));
        assert_eq!(client.account("GET", "/v1/characters", None).unwrap()[0]["name"], "Ann");
        client
            .account("PATCH", "/v1/devices/pc-2", Some(serde_json::json!({ "name": "Desk" })))
            .unwrap();
        assert_eq!(
            client.account("DELETE", "/v1/devices/pc-9", None),
            Err(ApiError::Status(404, r#"{"error":"no such PC"}"#.into()))
        );
        assert!(client.account("PUT", "/v1/x", None).is_err());
        let seen = fake.seen.lock().unwrap();
        assert_eq!((seen[0].method.as_str(), seen[0].authorization.as_str()), ("GET", "Bearer pc-token"));
        assert_eq!((seen[1].method.as_str(), seen[1].url.as_str()), ("PATCH", "/v1/devices/pc-2"));
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&seen[1].body).unwrap()["name"], "Desk");
        assert_eq!(seen.len(), 3, "an unknown method never reaches the server");
    }

    #[test]
    fn export_brings_back_the_zip() {
        let fake = fake::serve(|_, _| (200, b"PK\x03\x04zip".to_vec()));
        assert_eq!(Client::new(&fake.url, Some("t".into())).export().unwrap(), b"PK\x03\x04zip");
        assert_eq!(fake.seen.lock().unwrap()[0].url, "/v1/export");
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && cargo test -p rts-sync api::`
Expected: compile errors, no method `app`, `account` or `export` on `Client`.

- [ ] **Step 3: Write the code**

In `engine/src/api.rs`, after `const MAX_JOURNEY`:

```rust
/// The most an export may be: every character's journey in one zip.
const MAX_EXPORT: u64 = 1024 * 1024 * 1024;
```

`Client` gains a field, set to `None` in `Client::new`:

```rust
pub struct Client {
    agent: ureq::Agent,
    server: String,
    token: Option<String>,
    /// The app's version, which the server shows in the player's PC list.
    app: Option<String>,
}
```

In `impl Client`, after `new`:

```rust
    pub fn app(mut self, version: &str) -> Self {
        self.app = Some(version.to_string());
        self
    }
```

Replace `check` with:

```rust
    pub fn check(&self) -> Result<CheckResponse, ApiError> {
        let mut request = self.agent.get(self.url("/v1/check")).header("authorization", self.bearer());
        if let Some(app) = &self.app {
            request = request.query("app", app);
        }
        json(request.call())
    }
```

After `download`, add:

```rust
    /// One account API call from the app's window (spec, "Account API").
    /// The answer passes through as it came; the window reads it with
    /// packages/api's types.
    pub fn account(&self, method: &str, path: &str, body: Option<serde_json::Value>) -> Result<serde_json::Value, ApiError> {
        let (url, auth) = (self.url(path), self.bearer());
        let body = body.unwrap_or_else(|| serde_json::json!({}));
        let reply = match method {
            "GET" => self.agent.get(&url).header("authorization", &auth).call(),
            "DELETE" => self.agent.delete(&url).header("authorization", &auth).call(),
            "POST" => self.agent.post(&url).header("authorization", &auth).send_json(body),
            "PATCH" => self.agent.patch(&url).header("authorization", &auth).send_json(body),
            _ => return Err(ApiError::Status(0, format!("the app can't make a {method} call"))),
        };
        json(reply)
    }

    /// Every character's current journey as one zip.
    pub fn export(&self) -> Result<Vec<u8>, ApiError> {
        ok(self.agent.get(self.url("/v1/export")).header("authorization", self.bearer()).call())?
            .body_mut()
            .with_config()
            .limit(MAX_EXPORT)
            .read_to_vec()
            .map_err(|e| ApiError::Network(e.to_string()))
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd apps/desktop && cargo test -p rts-sync`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/engine/src/api.rs
git commit -m "Engine: the app version on check, and account calls for the window (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The watcher says when it is busy, and checks when a game starts

**Files:**
- Modify: `apps/desktop/engine/src/watch.rs`, `apps/desktop/engine/src/bin/rts-sync.rs`, `apps/desktop/src-tauri/src/runner.rs` (the call only)

**Interfaces:**
- Produces: `watch::run(client, state, state_path, cache, find, stop, busy: &AtomicBool, report)`; `busy` is true while a pass runs. `watch::Starts` with `fn saw(&mut self, running: BTreeSet<PathBuf>) -> bool`. `pub const LOOK_FOR_GAME: Duration` (5 s).

- [ ] **Step 1: Write the failing tests**

Add to `mod tests` in `engine/src/watch.rs`:

```rust
    #[test]
    fn a_game_starting_is_noticed_once() {
        let mut s = Starts::default();
        let beta = PathBuf::from("/wow/_classic_beta_");
        assert!(!s.saw(BTreeSet::new()));
        assert!(s.saw([beta.clone()].into()), "the game started");
        assert!(!s.saw([beta.clone()].into()), "still running is not a start");
        assert!(!s.saw(BTreeSet::new()));
        assert!(s.saw([beta].into()), "started again");
    }

    #[test]
    fn a_pass_shows_as_busy_while_it_runs() {
        use crate::api::fake;
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("wow/_classic_beta_");
        let toc = installs::addon_toc(&game);
        std::fs::create_dir_all(toc.parent().unwrap()).unwrap();
        std::fs::write(&toc, "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        let fake = fake::serve(|_, _| {
            std::thread::sleep(Duration::from_millis(800));
            (200, br#"{"characters":[]}"#.to_vec())
        });
        let (stop, busy) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
        let thread = {
            let (stop, busy, url, data) = (stop.clone(), busy.clone(), fake.url.clone(), dir.path().join("data"));
            std::thread::spawn(move || {
                let mut state = State {
                    pc: Some("pc-1".into()),
                    ..State::default()
                };
                let find = || {
                    vec![GameFolder {
                        path: game.clone(),
                        name: "_classic_beta_".into(),
                    }]
                };
                run(
                    &Client::new(&url, Some("t".into())),
                    &mut state,
                    &data.join("s.json"),
                    &data.join("j"),
                    &find,
                    &stop,
                    &busy,
                    |_| {},
                )
            })
        };
        let until = Instant::now() + Duration::from_secs(5);
        while !busy.load(Ordering::SeqCst) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(busy.load(Ordering::SeqCst), "busy while the check is out");
        stop.store(true, Ordering::Relaxed);
        thread.join().unwrap().unwrap();
        assert!(!busy.load(Ordering::SeqCst), "not busy once the pass ended");
    }
```

In the existing test `a_wtf_folder_made_after_the_start_is_watched_and_its_file_goes_up`, pass `&AtomicBool::new(false),` after `&stop,` in the `run(...)` call.

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && cargo test -p rts-sync watch::`
Expected: compile errors: no `Starts`, and `run` takes 7 arguments.

- [ ] **Step 3: Write the code**

In `engine/src/watch.rs`, change the `use std::collections::BTreeMap;` line to `use std::collections::{BTreeMap, BTreeSet};`, and update the header's last sentence to: "The server is also asked for new versions every few minutes, and as soon as a game starts, so the newest journey is there before the player logs in."

After `pub const RETRY`:

```rust
/// How often to look for a game starting.
pub const LOOK_FOR_GAME: Duration = Duration::from_secs(5);

/// Notices a game starting, so other PCs' play is fetched before the player
/// logs in rather than up to five minutes later.
#[derive(Debug, Default)]
pub struct Starts {
    running: BTreeSet<PathBuf>,
}

impl Starts {
    /// Takes the game folders running now; true when one of them wasn't before.
    pub fn saw(&mut self, running: BTreeSet<PathBuf>) -> bool {
        let started = running.iter().any(|g| !self.running.contains(g));
        self.running = running;
        started
    }
}
```

`run` gains `busy: &AtomicBool,` after `stop: &AtomicBool,`; its doc comment gains: "`busy` is true while a pass runs, so the app never restarts in the middle of one." In the body, after `let mut wait_until = start;` add:

```rust
    let mut starts = Starts::default();
    let mut looked: Option<Instant> = None;
```

Replace

```rust
        let programs = if schedule.settled(now) {
            running_programs(&mut system)
        } else {
            Vec::new()
        };
```

with

```rust
        let look = schedule.settled(now) || looked.is_none_or(|t| now.duration_since(t) >= LOOK_FOR_GAME);
        let programs = if look {
            looked = Some(now);
            running_programs(&mut system)
        } else {
            Vec::new()
        };
        let started = look && starts.saw(games.iter().filter(|g| game_running(&g.path, &programs)).map(|g| g.path.clone()).collect());
```

Change `if now >= wait_until && (!due.is_empty() || check_due) {` to `if now >= wait_until && (!due.is_empty() || check_due || started) {`, and wrap the pass:

```rust
            busy.store(true, Ordering::SeqCst);
            let result = sync::pass(client, state, state_path, &games, cache, |f| due.contains(&f.path)).map(|mut r| {
                r.problems.extend(watch_problems.iter().cloned());
                r
            });
            busy.store(false, Ordering::SeqCst);
```

In `engine/src/bin/rts-sync.rs`, pass `&AtomicBool::new(false),` after `&stop,` in the `watch::run` call (import `AtomicBool` if it isn't already).

In `src-tauri/src/runner.rs`, `Runner` gains a field `busy: Arc<AtomicBool>` (set to `Arc::default()` in `new`) and a method:

```rust
    /// True while a pass runs, for the update to wait on.
    pub fn busy(&self) -> Arc<AtomicBool> {
        self.busy.clone()
    }
```

In `start`, add `self.busy.clone()` to the values moved into the thread (as `busy`) and pass `&busy` after `&stop` to `watch::run`.

- [ ] **Step 4: Run the tests**

Run: `cd apps/desktop && bun run build && cargo test --workspace`
Expected: all pass.

- [ ] **Step 5: AGENTS.md and commit**

In `apps/desktop/AGENTS.md`, in the `sync.rs`/`watch.rs` bullet, after "so WoW making its WTF folder after the app started is noticed.", add: "It also looks for a game starting every five seconds and syncs at once when one does, so other PCs' play is in the sync folder before the player logs in, and it sets `busy` while a pass runs."

```bash
git add apps/desktop
git commit -m "Engine: sync as soon as a game starts, and say when a pass is running (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The window opens under the menu bar or tray icon

**Files:**
- Create: `apps/desktop/src-tauri/src/window.rs`
- Modify: `apps/desktop/src-tauri/Cargo.toml`, `apps/desktop/src-tauri/src/main.rs`, `apps/desktop/src-tauri/src/tray.rs`, `apps/desktop/src-tauri/src/commands.rs`, `apps/desktop/src-tauri/tauri.conf.json`, `apps/desktop/src-tauri/capabilities/default.json`, `apps/desktop/src/FirstRun.tsx`, `apps/desktop/src/Characters.tsx`, `apps/desktop/AGENTS.md`

**Interfaces:**
- Produces: `window::show(app: &AppHandle)`, `window::toggle(app: &AppHandle)`, `window::holding<T>(app: &AppHandle, dialog: impl FnOnce() -> T) -> T`, managed state `window::Popover`. `tray::show_window` is gone; everything that showed the window calls `window::show`.

- [ ] **Step 1: Write the failing test**

Create `src-tauri/src/window.rs` with only its test module first:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_click_on_the_icon_right_after_the_window_hid_leaves_it_hidden() {
        // Clicking the icon takes focus from the window first, which hides
        // it; the click itself must not bring it straight back.
        assert!(!should_show(true, None), "open: the click hides it");
        assert!(!should_show(false, Some(Duration::from_millis(100))));
        assert!(should_show(false, Some(Duration::from_secs(2))));
        assert!(should_show(false, None));
    }

    #[test]
    fn the_window_stays_while_one_of_our_dialogs_is_open() {
        let popover = Popover::default();
        assert!(!popover.held());
        let inside = popover.hold(|| popover.held());
        assert!(inside, "held while the dialog runs");
        assert!(!popover.held(), "let go after");
    }
}
```

Add `mod window;` to `main.rs`.

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/desktop && bun run build && cargo test -p road-to-sixty-app window::`
Expected: compile errors: no `should_show`, no `Popover`.

- [ ] **Step 3: Write the code**

`src-tauri/Cargo.toml`, under `[dependencies]`:

```toml
tauri-plugin-positioner = { version = "=2.4.0", features = ["tray-icon"] }
```

The top of `src-tauri/src/window.rs`, above the tests:

```rust
//! The window opens under the menu bar or tray icon, like a menu bar app's
//! popover, and hides when the player clicks elsewhere (spec, "The desktop
//! app"). Our own dialogs (the folder picker, the save dialog) take focus
//! from it, so it stays while one is open.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager, Window};
use tauri_plugin_positioner::{Position, WindowExt};

#[derive(Default)]
pub struct Popover {
    holding: AtomicBool,
    hidden_at: Mutex<Option<Instant>>,
}

impl Popover {
    fn held(&self) -> bool {
        self.holding.load(Ordering::SeqCst)
    }

    fn hold<T>(&self, dialog: impl FnOnce() -> T) -> T {
        self.holding.store(true, Ordering::SeqCst);
        let out = dialog();
        self.holding.store(false, Ordering::SeqCst);
        out
    }
}

/// Whether a click on the icon should show the window: not when it's open
/// (the click closes it), nor when losing focus to that same click has
/// just hidden it.
fn should_show(visible: bool, hidden_ago: Option<Duration>) -> bool {
    !visible && hidden_ago.is_none_or(|d| d > Duration::from_millis(300))
}

pub fn show(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else { return };
    // Until the icon has been clicked or hovered, its place isn't known.
    if window.move_window_constrained(Position::TrayCenter).is_err() {
        let _ = window.move_window(if cfg!(windows) { Position::BottomRight } else { Position::TopRight });
    }
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
}

pub fn toggle(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else { return };
    let popover = app.state::<Popover>();
    let hidden_ago = popover.hidden_at.lock().unwrap().map(|t| t.elapsed());
    if should_show(window.is_visible().unwrap_or(false), hidden_ago) {
        show(app);
    } else {
        let _ = window.hide();
    }
}

/// The window lost focus: hide it, unless one of our dialogs took it.
pub fn blurred(window: &Window) {
    let popover = window.app_handle().state::<Popover>();
    if !popover.held() {
        *popover.hidden_at.lock().unwrap() = Some(Instant::now());
        let _ = window.hide();
    }
}

/// Runs one of our dialogs without the window hiding behind it.
pub fn holding<T>(app: &AppHandle, dialog: impl FnOnce() -> T) -> T {
    app.state::<Popover>().hold(dialog)
}
```

`src-tauri/src/tray.rs`:
- Imports: add `use tauri::tray::{MouseButton, MouseButtonState, TrayIconEvent};`.
- Change `.show_menu_on_left_click(true)` to `.show_menu_on_left_click(false)` and add, before `.on_menu_event`:

```rust
        // A left click opens the window under the icon; the menu is on a right click.
        .on_tray_icon_event(|tray, event| {
            tauri_plugin_positioner::on_tray_event(tray.app_handle(), &event);
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                crate::window::toggle(tray.app_handle());
            }
        })
```

- `"open" => show_window(app),` becomes `"open" => crate::window::show(app),`; delete `pub fn show_window`.

`src-tauri/src/main.rs`:
- Add `.plugin(tauri_plugin_positioner::init())` after the dialog plugin, and `app.manage(window::Popover::default());` at the top of `setup` (before `tray::build`).
- Replace every `tray::show_window(` with `window::show(` (single instance, `RunEvent::Reopen`, the start).
- In `on_window_event`, add a second arm:

```rust
            if let WindowEvent::Focused(false) = event {
                window::blurred(window);
            }
```

`src-tauri/tauri.conf.json`, the `main` window: remove `"titleBarStyle": "Overlay"` and `"hiddenTitle": true`; add `"decorations": false`, `"alwaysOnTop": true`, `"skipTaskbar": true`.

`src-tauri/capabilities/default.json`: remove `"core:window:allow-start-dragging"` (nothing drags the window now).

`src/FirstRun.tsx` and `src/Characters.tsx`: delete the line `{isMac && <div data-tauri-drag-region className="h-9 shrink-0 border-b border-line-soft" />}` and drop `isMac` from their imports.

- [ ] **Step 4: Run the tests and look at it**

Run: `cd apps/desktop && bun run build && cargo test --workspace && bun run typecheck`
Expected: all pass.

Then `bunx tauri dev`: a left click on the menu bar icon opens the window under it, a click elsewhere hides it, a right click shows the menu. (Jordan checks the same on Windows, with the taskbar at the bottom and once at the top.)

- [ ] **Step 5: AGENTS.md and commit**

In `apps/desktop/AGENTS.md`, replace "`src/tray.rs` is the menu bar or tray icon," with "`src/tray.rs` is the menu bar or tray icon (a left click opens the window, a right click the menu), `src/window.rs` opens the window under it with tauri-plugin-positioner and hides it when it loses focus, except while one of our dialogs is open (so dialogs run from Rust, through `window::holding`, and confirmations are inline in the window),".

```bash
git add apps/desktop
git commit -m "App: the window opens under the menu bar or tray icon and hides on a click elsewhere (#39)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The app's account commands, PC naming and unlinking through the server

**Files:**
- Create: `apps/desktop/src-tauri/src/account.rs`
- Modify: `apps/desktop/src-tauri/src/status.rs`, `apps/desktop/src-tauri/src/runner.rs`, `apps/desktop/src-tauri/src/commands.rs`, `apps/desktop/src-tauri/src/main.rs`, `apps/desktop/AGENTS.md`

**Interfaces:**
- Consumes: `Client::app`, `Client::account`, `Client::export` (Task 1); `window::holding` (Task 3).
- Produces: `crate::VERSION: &str`. `Status` gains `pc: Option<String>` and `version: String`; `Game` gains `characters: usize`. Commands (window name, arguments): `host_name() -> string`, `link({ name })`, `pick_folder()`, `characters() -> CharacterInfo[]`, `versions({ id })`, `restore({ id, version }) -> RestoreResponse`, `devices() -> DeviceInfo[]`, `rename_device({ id, name }) -> DeviceInfo`, `unlink_device({ id })`, `export_data() -> boolean` (false when the player cancelled), `delete_account()`. Errors come back as plain words. `add_folder` is gone.

- [ ] **Step 1: Write the failing tests**

Create `src-tauri/src/account.rs` with its tests first:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_read_as_the_servers_own_words() {
        assert_eq!(words(ApiError::Status(400, r#"{"error":"a PC needs a name"}"#.into())), "a PC needs a name");
        assert_eq!(words(ApiError::Status(413, "too big".into())), "the server answered 413: too big");
        assert_eq!(words(ApiError::Unauthorized), "this PC isn't linked");
    }

    #[test]
    fn a_pc_id_must_be_one_plain_path_part() {
        assert_eq!(segment("pc_2-a"), Ok("pc_2-a"));
        assert!(segment("../account").is_err());
        assert!(segment("").is_err());
    }
}
```

Add to `mod tests` in `src-tauri/src/commands.rs` (create the module if it has none):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_suggested_pc_name_is_the_computers_without_its_network_suffix() {
        assert_eq!(pc_name(Some("Anns-MacBook-Pro.local".into())), "Anns-MacBook-Pro");
        assert_eq!(pc_name(Some("DESKTOP-7Q2".into())), "DESKTOP-7Q2");
        assert_eq!(pc_name(None), "This PC");
    }
}
```

In `src-tauri/src/runner.rs` tests:
- In `a_linked_pc_syncs_and_lists_its_characters`, add `assert_eq!(s.pc.as_deref(), Some("pc-1"));`.
- In `an_unlinked_pc_says_so_and_does_not_sync`, add `assert_eq!(s.games[0].characters, 1);`.
- Add:

```rust
    #[test]
    fn unlinking_revokes_this_pc_on_the_server_first() {
        let mut t = setup(true);
        t.runner.unlink().unwrap();
        let seen = t._fake.seen.lock().unwrap();
        assert!(seen.iter().any(|s| s.method == "DELETE" && s.url == "/v1/devices/pc-1" && s.authorization == "Bearer pc-token"));
    }

    #[test]
    fn unlinking_offline_still_unlinks_here() {
        let mut t = setup(true);
        let notifier = Notifier::new(|_| {});
        let mut offline = Runner::new("http://127.0.0.1:9", &t.dir.path().join("data"), t.runner.find.clone(), notifier);
        offline.unlink().unwrap();
        assert_eq!(t.tokens.get(), None);
        t.runner.stop();
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && bun run build && cargo test -p road-to-sixty-app`
Expected: compile errors: no `words`, `segment`, `pc_name`, `Status::pc`, `Game::characters`.

- [ ] **Step 3: Write the code**

`src-tauri/src/main.rs`: add `mod account;` and, beside `SERVER`:

```rust
/// This build's version, which the server shows in the player's PC list.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
```

In `setup`, after `app.manage(notifier.clone());`, add `app.manage(account::Account::new(SERVER, &data_dir()));` and set the version once, before `runner.start()?`: `notifier.update(|s| s.version = VERSION.into());`. Replace `commands::add_folder` in `generate_handler!` with `commands::pick_folder, commands::host_name, account::characters, account::versions, account::restore, account::devices, account::rename_device, account::unlink_device, account::export_data, account::delete_account`.

`src-tauri/src/status.rs`: `Status` gains, after `linked_to`:

```rust
    /// This PC's id, to mark it in the PC list.
    pub pc: Option<String>,
    /// This app's version.
    pub version: String,
```

`Game` gains `pub characters: usize,` (the characters with a saved file in it). Fix the `Game { ... }` in the status tests by adding `characters: 1,`.

`src-tauri/src/runner.rs`:
- In `start`, in the `notifier.update` closure, after `s.linked_to = ...`, add `s.pc = token.as_ref().and(state.pc.clone());`.
- The thread's client becomes `Client::new(&server, token).app(crate::VERSION)`.
- `shown` counts characters per game:

```rust
fn shown(games: &[GameFolder]) -> Vec<Game> {
    games
        .iter()
        .map(|g| Game {
            path: g.path.display().to_string(),
            name: g.name.clone(),
            addon: installs::addon_version(&g.path),
            characters: local_keys(std::slice::from_ref(g)).len(),
        })
        .collect()
}
```

- `unlink` starts with:

```rust
    pub fn unlink(&mut self) -> Result<(), String> {
        self.stop();
        // Revoked on the server first, so the token stops working there too.
        // Offline, this PC still unlinks; the player can remove it from
        // another PC's list.
        if let (Some(token), Ok(State { pc: Some(pc), .. })) = (self.tokens.get(), State::load(&self.state_path)) {
            let _ = Client::new(&self.server, Some(token)).account("DELETE", &format!("/v1/devices/{pc}"), None);
        }
        self.tokens.clear()?;
```

  (the rest unchanged), and its status update also clears `s.pc = None;`.

`src-tauri/src/commands.rs`:
- `link` takes the name: `pub fn link(app: AppHandle, name: String)`, and inside, replace the `let name = sysinfo::...` line with:

```rust
        let name = match name.trim() {
            "" => pc_name(sysinfo::System::host_name()),
            name => name.chars().take(40).collect(),
        };
```

- Replace `add_folder` with:

```rust
/// The folder picker, run here so the window knows not to hide behind it.
#[tauri::command]
pub fn pick_folder(app: AppHandle) {
    std::thread::spawn(move || {
        let picked = crate::window::holding(&app, || {
            app.dialog().file().set_title("Pick your World of Warcraft folder").blocking_pick_folder()
        });
        if let Some(path) = picked.and_then(|p| p.into_path().ok()) {
            with_runner(app, move |r| r.add_folder(path));
        }
    });
}

/// The name the link box starts with.
#[tauri::command]
pub fn host_name() -> String {
    pc_name(sysinfo::System::host_name())
}

fn pc_name(host: Option<String>) -> String {
    host.map(|h| h.trim_end_matches(".local").to_string())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "This PC".into())
}
```

  with `use tauri_plugin_dialog::DialogExt;` and `PathBuf` no longer imported if unused.

The top of `src-tauri/src/account.rs`, above the tests:

```rust
//! The account screens' calls to the server (spec, "Account API"). They are
//! made here because only the app holds the PC token; the window never sees
//! it. Answers pass through as the server sent them, and the window reads
//! them with packages/api's types.

use std::path::{Path, PathBuf};

use rts_sync::api::{ApiError, Client};
use rts_sync::state::TokenFile;
use serde_json::{Value, json};
use tauri::{AppHandle, State};
use tauri_plugin_dialog::DialogExt;

pub struct Account {
    server: String,
    token: PathBuf,
}

impl Account {
    pub fn new(server: &str, data: &Path) -> Account {
        Account {
            server: server.to_string(),
            token: data.join("token"),
        }
    }

    fn client(&self) -> Result<Client, String> {
        let token = TokenFile::new(self.token.clone()).get().ok_or("this PC isn't linked")?;
        Ok(Client::new(&self.server, Some(token)).app(crate::VERSION))
    }

    /// Off the main thread: the window waits for the answer, the app doesn't.
    async fn call(&self, method: &'static str, path: String, body: Option<Value>) -> Result<Value, String> {
        let client = self.client()?;
        tauri::async_runtime::spawn_blocking(move || client.account(method, &path, body))
            .await
            .map_err(|e| e.to_string())?
            .map_err(words)
    }
}

/// The server's own reason when it gave one ({ "error": ... }), else the
/// error as the app words it.
fn words(e: ApiError) -> String {
    if let ApiError::Status(_, body) = &e
        && let Some(why) = serde_json::from_str::<Value>(body).ok().and_then(|v| v["error"].as_str().map(str::to_string))
    {
        return why;
    }
    e.to_string()
}

/// A PC id from the window, as one part of a path.
fn segment(id: &str) -> Result<&str, String> {
    if !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        Ok(id)
    } else {
        Err("no such PC".into())
    }
}

#[tauri::command]
pub async fn characters(account: State<'_, Account>) -> Result<Value, String> {
    account.call("GET", "/v1/characters".into(), None).await
}

#[tauri::command]
pub async fn versions(account: State<'_, Account>, id: i64) -> Result<Value, String> {
    account.call("GET", format!("/v1/characters/{id}/versions"), None).await
}

#[tauri::command]
pub async fn restore(account: State<'_, Account>, id: i64, version: i64) -> Result<Value, String> {
    account.call("POST", format!("/v1/characters/{id}/restore"), Some(json!({ "version": version }))).await
}

#[tauri::command]
pub async fn devices(account: State<'_, Account>) -> Result<Value, String> {
    account.call("GET", "/v1/devices".into(), None).await
}

#[tauri::command]
pub async fn rename_device(account: State<'_, Account>, id: String, name: String) -> Result<Value, String> {
    let path = format!("/v1/devices/{}", segment(&id)?);
    account.call("PATCH", path, Some(json!({ "name": name }))).await
}

#[tauri::command]
pub async fn unlink_device(account: State<'_, Account>, id: String) -> Result<Value, String> {
    let path = format!("/v1/devices/{}", segment(&id)?);
    account.call("DELETE", path, None).await
}

/// Asks where to save, then saves every character's journey there as a
/// zip. False when the player cancelled.
#[tauri::command]
pub async fn export_data(app: AppHandle, account: State<'_, Account>) -> Result<bool, String> {
    let client = account.client()?;
    tauri::async_runtime::spawn_blocking(move || {
        let picked = crate::window::holding(&app, || app.dialog().file().set_file_name("road-to-sixty.zip").blocking_save_file());
        let Some(path) = picked.and_then(|p| p.into_path().ok()) else {
            return Ok(false);
        };
        std::fs::write(&path, client.export().map_err(words)?).map_err(|e| e.to_string())?;
        Ok(true)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Deletes the account on the server, then unlinks here: the server keeps
/// the asking PC linked until the very end, so a failure can be retried.
#[tauri::command]
pub async fn delete_account(app: AppHandle, account: State<'_, Account>) -> Result<(), String> {
    account.call("DELETE", "/v1/account".into(), None).await?;
    crate::commands::with_runner(app, |r| r.unlink());
    Ok(())
}
```

(The runner's tests are a child module, so they can read `t.runner.find`.)

- [ ] **Step 4: Run the tests**

Run: `cd apps/desktop && bun run build && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass, no warnings.

- [ ] **Step 5: AGENTS.md and commit**

In `apps/desktop/AGENTS.md`, after the `src/commands.rs` sentence, add: "`src/account.rs` holds the account screens' calls (characters, history, restore, PCs, export, delete everything): the window asks the app, which calls the server with the PC token, so the window never holds it. Answers pass through as JSON and the window reads them with `@road-to-sixty/api`'s types. Unlinking this PC revokes it on the server first, and still unlinks here when offline." Replace "The request and response shapes mirror `packages/api`; change them together with the server." with "The engine's request and response shapes mirror `packages/api` by hand; the window imports `@road-to-sixty/api` itself. Change them together with the server."

```bash
git add apps/desktop
git commit -m "App: account calls for the window, PC naming, and unlinking through the server (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Updates install themselves

**Files:**
- Modify: `apps/desktop/src-tauri/src/update.rs`, `apps/desktop/src-tauri/src/status.rs`, `apps/desktop/src-tauri/src/tray.rs`, `apps/desktop/src-tauri/src/main.rs`, `apps/desktop/AGENTS.md`

**Interfaces:**
- Consumes: `Runner::busy()` (Task 2), `Status::version` (Task 4).
- Produces: `status::UpdateState` (`None`, `Ready { version }`, `Updated { version, at }`, `Failed { why }`), serialised as `{ "state": "none" | "ready" | "updated" | "failed", ... }` in `Status.update`. `status::update_line(&UpdateState) -> Option<String>`. `update::Busy(Arc<AtomicBool>)` managed state. Commands `check_update() -> string | null` (the version found, now downloading) and `install_update()` (restart into a ready update now).

- [ ] **Step 1: Write the failing tests**

Add to `mod tests` in `src-tauri/src/status.rs`:

```rust
    #[test]
    fn the_update_item_says_what_the_update_is_doing() {
        assert_eq!(update_line(&UpdateState::None), None);
        assert_eq!(
            update_line(&UpdateState::Ready { version: "0.1.3".into() }).as_deref(),
            Some("Restart to update to 0.1.3")
        );
        assert_eq!(
            update_line(&UpdateState::Updated { version: "0.1.3".into(), at: 0 }).as_deref(),
            Some("Updated to 0.1.3")
        );
        assert_eq!(
            update_line(&UpdateState::Failed { why: "no network".into() }).as_deref(),
            Some("Couldn't update: no network")
        );
    }

    #[test]
    fn updated_to_shows_for_an_hour() {
        let mut s = linked();
        s.update = UpdateState::Updated { version: "0.1.3".into(), at: 1000 };
        refresh(&mut s, 1000 + 3599);
        assert_ne!(s.update, UpdateState::None);
        refresh(&mut s, 1000 + 3600);
        assert_eq!(s.update, UpdateState::None);
    }

    #[test]
    fn the_window_reads_the_update_by_its_state() {
        let ready = serde_json::to_value(UpdateState::Ready { version: "0.1.3".into() }).unwrap();
        assert_eq!(ready, serde_json::json!({ "state": "ready", "version": "0.1.3" }));
        assert_eq!(serde_json::to_value(UpdateState::None).unwrap(), serde_json::json!({ "state": "none" }));
    }
```

Add a test module to `src-tauri/src/update.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_restarts_only_while_the_window_is_closed_and_no_sync_runs() {
        assert!(may_restart(false, false));
        assert!(!may_restart(true, false), "the player is looking at it");
        assert!(!may_restart(false, true), "a sync is under way");
    }

    #[test]
    fn a_different_version_last_time_means_it_just_updated() {
        assert!(just_updated(Some("0.1.2\n"), "0.1.3"));
        assert!(!just_updated(Some("0.1.3"), "0.1.3"));
        assert!(!just_updated(None, "0.1.3"), "a first start isn't an update");
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && bun run build && cargo test -p road-to-sixty-app`
Expected: compile errors: no `UpdateState`, `update_line`, `may_restart`, `just_updated`.

- [ ] **Step 3: Write the code**

`src-tauri/src/status.rs`: `Status` gains `pub update: UpdateState,` after `version`. Add:

```rust
/// Where a self-update is (spec, "Start at login and updates").
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum UpdateState {
    #[default]
    None,
    /// Downloaded; it installs when the window is closed and no sync runs.
    Ready { version: String },
    /// This start was into a new version, at this time.
    Updated { version: String, at: u64 },
    /// The last try failed; the next check tries again.
    Failed { why: String },
}

/// The tray's update item, when an update has something to say.
pub fn update_line(update: &UpdateState) -> Option<String> {
    match update {
        UpdateState::None => None,
        UpdateState::Ready { version } => Some(format!("Restart to update to {version}")),
        UpdateState::Updated { version, .. } => Some(format!("Updated to {version}")),
        UpdateState::Failed { why } => Some(format!("Couldn't update: {why}")),
    }
}
```

and at the start of `refresh`:

```rust
    if let UpdateState::Updated { at, .. } = status.update
        && now.saturating_sub(at) >= 3600
    {
        status.update = UpdateState::None;
    }
```

`src-tauri/src/update.rs`, whole file above the tests:

```rust
//! Updates install themselves (spec, "Start at login and updates"). A newer
//! version is downloaded as soon as a check finds it and installed when the
//! app restarts, which it does only while the window is closed and no sync
//! runs, or when the player asks. Installing waits for the restart because
//! on Windows it ends the app. Debug builds never update: the updater would
//! replace the build folder.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tauri::{AppHandle, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};

use crate::runner::{Notifier, Runner};
use crate::status::UpdateState;

/// True while the sync thread is in a pass (an upload or a delivery).
pub struct Busy(pub Arc<AtomicBool>);

static UPDATING: AtomicBool = AtomicBool::new(false);
static RESTART_NOW: AtomicBool = AtomicBool::new(false);

pub fn may_restart(window_visible: bool, busy: bool) -> bool {
    !window_visible && !busy
}

/// Whether this start is into a new version: the one that ran last time,
/// kept in a file, is different.
pub fn just_updated(last: Option<&str>, now: &str) -> bool {
    last.is_some_and(|l| l.trim() != now)
}

fn check(app: &AppHandle) -> Result<Option<Update>, String> {
    if cfg!(debug_assertions) {
        return Ok(None);
    }
    tauri::async_runtime::block_on(async { app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string()) })
}

/// Checks, and with a newer version downloads it, waits until it may
/// restart, and restarts into it. Ok(None): this is the newest. Blocks, so
/// it runs on a thread of its own; one at a time.
pub fn run(app: &AppHandle) -> Result<Option<String>, String> {
    if UPDATING.swap(true, Ordering::SeqCst) {
        return Ok(None);
    }
    let result = install_when_idle(app);
    UPDATING.store(false, Ordering::SeqCst);
    if let Err(why) = &result {
        RESTART_NOW.store(false, Ordering::SeqCst);
        app.state::<Notifier>().update(|s| s.update = UpdateState::Failed { why: why.clone() });
    }
    result
}

fn install_when_idle(app: &AppHandle) -> Result<Option<String>, String> {
    let Some(update) = check(app)? else { return Ok(None) };
    let version = update.version.clone();
    let bytes = tauri::async_runtime::block_on(update.download(|_, _| {}, || {})).map_err(|e| e.to_string())?;
    app.state::<Notifier>().update(|s| s.update = UpdateState::Ready { version: version.clone() });
    let busy = app.state::<Busy>().0.clone();
    let visible = || app.get_webview_window("main").is_some_and(|w| w.is_visible().unwrap_or(false));
    while !(RESTART_NOW.load(Ordering::SeqCst) || may_restart(visible(), busy.load(Ordering::SeqCst))) {
        std::thread::sleep(Duration::from_secs(5));
    }
    // Stopping the sync thread waits for a pass that began meanwhile.
    app.state::<Mutex<Runner>>().lock().unwrap().stop();
    if let Err(e) = update.install(bytes) {
        crate::commands::with_runner(app.clone(), |r| r.start());
        return Err(e.to_string());
    }
    app.restart();
}

/// Restarts into a ready update now, or starts one if none is under way.
pub fn restart_now(app: &AppHandle) {
    RESTART_NOW.store(true, Ordering::SeqCst);
    let app = app.clone();
    std::thread::spawn(move || {
        let _ = run(&app);
    });
}

/// The version found, which then downloads and installs as above.
#[tauri::command]
pub async fn check_update(app: AppHandle) -> Result<Option<String>, String> {
    let found = {
        let app = app.clone();
        tauri::async_runtime::spawn_blocking(move || check(&app).map(|u| u.map(|u| u.version)))
            .await
            .map_err(|e| e.to_string())??
    };
    if found.is_some() {
        std::thread::spawn(move || {
            let _ = run(&app);
        });
    }
    Ok(found)
}

#[tauri::command]
pub fn install_update(app: AppHandle) {
    restart_now(&app);
}
```

`src-tauri/src/tray.rs`:
- `Tray::show` gains: `if let Some(text) = crate::status::update_line(&status.update) { let _ = self.update.set_text(text); }`.
- Replace the `"update"` arm with:

```rust
            "update" => {
                if matches!(app.state::<Notifier>().get().update, crate::status::UpdateState::Ready { .. }) {
                    crate::update::restart_now(app);
                } else {
                    let app = app.clone();
                    std::thread::spawn(move || {
                        if let Ok(None) = crate::update::run(&app) {
                            let _ = app.state::<Tray>().update.set_text("Up to date");
                        }
                    });
                }
            }
```

- Delete `fn offered`.

`src-tauri/src/main.rs`:
- After `let mut runner = Runner::new(...)`, add `app.manage(update::Busy(runner.busy()));`.
- Replace the single `notifier.update(|s| s.version = VERSION.into());` from Task 4 with:

```rust
            // A different version last time means this start is an update:
            // stay out of sight and say so in the menu for a while.
            let data = data_dir();
            let last = std::fs::read_to_string(data.join("version")).ok();
            let updated = update::just_updated(last.as_deref(), VERSION);
            let _ = std::fs::create_dir_all(&data);
            let _ = std::fs::write(data.join("version"), VERSION);
            notifier.update(|s| {
                s.version = VERSION.into();
                if updated {
                    s.update = status::UpdateState::Updated {
                        version: VERSION.into(),
                        at: runner::now(),
                    };
                }
            });
```

- Replace the six-hour thread's body with:

```rust
                loop {
                    let _ = update::run(&app_handle);
                    std::thread::sleep(Duration::from_secs(6 * 3600));
                }
```

- The start shows the window only when `!updated && !std::env::args().any(|a| a == "--hidden")`.

- [ ] **Step 4: Run the tests**

Run: `cd apps/desktop && bun run build && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass, no warnings.

- [ ] **Step 5: AGENTS.md and commit**

In `apps/desktop/AGENTS.md`, replace "`src/update.rs` checks the downloads bucket's `latest.json` at start and every six hours; the tray offers the update and a second click installs it." with "`src/update.rs` checks the downloads bucket's `latest.json` at start and every six hours (never in debug builds), downloads a newer version at once, and restarts into it only while the window is hidden and the sync thread isn't busy, or when the player asks (the tray item or Restart now). Installing waits for the restart, because on Windows it ends the app. A `version` file in the data folder tells a start after an update, which stays hidden and says \"Updated to X\" for an hour."

```bash
git add apps/desktop
git commit -m "App: updates install themselves while the window is closed and nothing syncs (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The window's words, class icons and calls

**Files:**
- Create: `apps/desktop/src/format.ts`, `apps/desktop/src/format.test.ts`, `apps/desktop/src/classes.ts`, `apps/desktop/src/classes/*.png` (9), `apps/desktop/scripts/class-icons.py`
- Modify: `apps/desktop/src/api.ts`, `apps/desktop/package.json`, `apps/desktop/tsconfig.json`, `apps/desktop/src-tauri/capabilities/default.json`, `packages/ui/theme.css`

**Interfaces:**
- Consumes: the commands of Tasks 4 and 5.
- Produces (window): `api.ts` exports `Status` (with `pc`, `version`, `update: Update`), `Game` (with `characters`), `Update`, `useLoad<T>(load, deps) -> { data, error, reload }`, `hostName`, `link(name)`, `unlink`, `pickFolder`, `characters`, `versions(id)`, `restore(id, version)`, `devices`, `renameDevice(id, name)`, `unlinkDevice(id)`, `exportData`, `deleteAccount`, `checkUpdate`, `installUpdate`, `startsAtLogin`, `setStartsAtLogin`, `setPaused`, `isMac`. `format.ts` exports `CLASSES`, `played`, `ago`, `when`, `levelClass`, `characterLine`, `versionLine`, `deviceLine`, `updateWords`. `classes.ts` exports `CLASS_ICONS: Record<string, string>`. Theme colours `danger` and `danger-line`.

- [ ] **Step 1: Write the failing tests**

Create `src/format.test.ts`:

```ts
import { expect, test } from "bun:test";
import type { CharacterInfo, DeviceInfo, VersionInfo } from "@road-to-sixty/api";
import { ago, characterLine, deviceLine, levelClass, played, updateWords, versionLine, when } from "./format";

const now = new Date(2026, 9, 15, 22, 0);
const at = (...parts: [number, number, number, number, number]) => new Date(...parts).toISOString();

test("time played reads as the biggest two units", () => {
  expect(played(9 * 86400 + 4 * 3600 + 59)).toBe("9d 4h");
  expect(played(4 * 3600 + 12 * 60)).toBe("4h 12m");
  expect(played(35 * 60)).toBe("35m");
  expect(played(null)).toBe("");
});

test("ago reads like the tray line", () => {
  expect(ago(at(2026, 9, 15, 21, 58), now)).toBe("2 min ago");
  expect(ago(at(2026, 9, 14, 20, 0), now)).toBe("yesterday");
  expect(ago(at(2026, 9, 12, 20, 0), now)).toBe("3 days ago");
});

test("a version's time says today, yesterday or the date", () => {
  expect(when(at(2026, 9, 15, 21, 44), now)).toBe("Today, 21:44");
  expect(when(at(2026, 9, 14, 22, 18), now)).toBe("Yesterday, 22:18");
  expect(when(at(2026, 9, 3, 20, 41), now)).toBe("3 Oct, 20:41");
  expect(when(at(2025, 9, 3, 20, 41), now)).toBe("3 Oct 2025, 20:41");
});

const ann: CharacterInfo = {
  id: 1, game: "_classic_beta_", realm: "Classic Beta PvE 2", name: "Ann", class: "WARRIOR", level: 42,
  played: 3600, lastPlayedAt: null, syncedAt: at(2026, 9, 14, 20, 0), syncedFrom: "Laptop",
};

test("a character's lines: level and class, then realm, PC and when", () => {
  expect(levelClass(ann)).toBe("Level 42 Warrior");
  expect(levelClass({ level: null, class: null })).toBe("");
  expect(characterLine(ann, now)).toBe("Classic Beta PvE 2 · Laptop, yesterday");
  expect(characterLine({ ...ann, syncedFrom: null }, now)).toBe("Classic Beta PvE 2 · restored yesterday");
});

test("a history entry says where it came from", () => {
  const v: VersionInfo = { id: 7, kind: "merged", createdAt: at(2026, 9, 15, 19, 2), level: 41, from: "Laptop", restoredFrom: null, current: false };
  expect(versionLine(v, now)).toBe("From Laptop · level 41");
  expect(versionLine({ ...v, kind: "restore", from: null, restoredFrom: { id: 3, createdAt: at(2026, 9, 2, 23, 5) } }, now)).toBe("Restored to 2 Oct, 23:05 · level 41");
});

test("a PC's line names its platform, versions and when it was seen", () => {
  const d: DeviceInfo = { id: "pc-1", name: "Desk", platform: "darwin", appVersion: "0.1.2", addonVersion: "1.9.0", lastSeenAt: now.toISOString() };
  expect(deviceLine(d, now)).toBe("Mac · app 0.1.2 · addon 1.9.0 · now");
  expect(deviceLine({ ...d, platform: "windows", appVersion: null, lastSeenAt: null }, now)).toBe("Windows · addon 1.9.0 · never seen");
});

test("the update row says what the update is doing", () => {
  expect(updateWords({ state: "ready", version: "0.1.3" }, undefined)).toBe("Version 0.1.3 is ready. It installs when you close this window.");
  expect(updateWords({ state: "none" }, null)).toBe("Up to date. Updates install by themselves while the window is closed.");
  expect(updateWords({ state: "none" }, "0.1.3")).toBe("Version 0.1.3 is downloading. It installs when you close this window.");
  expect(updateWords({ state: "failed", why: "no network" }, undefined)).toBe("Couldn't update: no network. It tries again in a few hours.");
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && bun test src`
Expected: FAIL, `Cannot find module './format'`.

- [ ] **Step 3: Write the code**

`package.json`: add `"@road-to-sixty/api": "workspace:*"` to `dependencies`, remove `"@tauri-apps/plugin-dialog"`, and change `"test"` to `"cargo test --workspace && bun test scripts src"`. Run `bun install` from the repo root.

`tsconfig.json`: `"types": ["vite/client", "bun"]`.

`src-tauri/capabilities/default.json`: remove `"dialog:default"` (the window no longer opens dialogs itself).

`packages/ui/theme.css`, after `--color-warn-line`:

```css
  --color-danger: #ff8a80;
  --color-danger-line: #4a2526;
```

`src/format.ts`:

```ts
// The words and numbers the screens show, as plain functions so they are
// tested without a window.
import type { CharacterInfo, DeviceInfo, VersionInfo } from "@road-to-sixty/api";
import type { Update } from "./api";

// The game's class colours (RAID_CLASS_COLORS).
export const CLASSES: Record<string, { name: string; colour: string }> = {
  WARRIOR: { name: "Warrior", colour: "#c69b6d" },
  PALADIN: { name: "Paladin", colour: "#f48cba" },
  HUNTER: { name: "Hunter", colour: "#aad372" },
  ROGUE: { name: "Rogue", colour: "#fff468" },
  PRIEST: { name: "Priest", colour: "#ffffff" },
  SHAMAN: { name: "Shaman", colour: "#0070dd" },
  MAGE: { name: "Mage", colour: "#3fc7eb" },
  WARLOCK: { name: "Warlock", colour: "#8788ee" },
  DRUID: { name: "Druid", colour: "#ff7c0a" },
};

// Time played in its two biggest units, as the game's /played does.
export function played(seconds: number | null): string {
  if (seconds === null) return "";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
}

// As the tray line says it (status.rs, ago).
export function ago(iso: string, now: Date): string {
  const s = Math.max(0, (now.getTime() - Date.parse(iso)) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 172800) return "yesterday";
  return `${Math.floor(s / 86400)} days ago`;
}

// A version's time in this PC's time zone: "Today, 21:44", "3 Oct, 20:41".
export function when(iso: string, now: Date): string {
  const t = new Date(iso);
  const time = t.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(now) - day(t)) / 86400000);
  if (days === 0) return `Today, ${time}`;
  if (days === 1) return `Yesterday, ${time}`;
  const year = t.getFullYear() === now.getFullYear() ? {} : { year: "numeric" as const };
  return `${t.toLocaleDateString("en-GB", { day: "numeric", month: "short", ...year })}, ${time}`;
}

export function levelClass(c: { level: number | null; class: string | null }): string {
  return [c.level !== null ? `Level ${c.level}` : "", c.class ? (CLASSES[c.class]?.name ?? "") : ""].filter(Boolean).join(" ");
}

// Under a character's name: its realm, and which PC last backed it up, when.
export function characterLine(c: CharacterInfo, now: Date): string {
  const by = c.syncedFrom ? `${c.syncedFrom}, ${ago(c.syncedAt, now)}` : `restored ${ago(c.syncedAt, now)}`;
  return `${c.realm} · ${by}`;
}

export function versionLine(v: VersionInfo, now: Date): string {
  const what =
    v.kind === "restore" ? (v.restoredFrom ? `Restored to ${when(v.restoredFrom.createdAt, now)}` : "Restored") : v.from ? `From ${v.from}` : "Merged";
  return v.level !== null ? `${what} · level ${v.level}` : what;
}

const PLATFORMS: Record<string, string> = { darwin: "Mac", windows: "Windows", linux: "Linux" };

export function deviceLine(d: DeviceInfo, now: Date): string {
  const seen = d.lastSeenAt ? ago(d.lastSeenAt, now).replace("just now", "now") : "never seen";
  return [d.platform ? (PLATFORMS[d.platform] ?? d.platform) : "", d.appVersion ? `app ${d.appVersion}` : "", d.addonVersion ? `addon ${d.addonVersion}` : "", seen]
    .filter(Boolean)
    .join(" · ");
}

// checked: what "Check now" found (undefined before it is pressed, null for nothing newer).
export function updateWords(update: Update, checked: string | null | undefined): string {
  if (update.state === "ready") return `Version ${update.version} is ready. It installs when you close this window.`;
  if (update.state === "failed") return `Couldn't update: ${update.why}. It tries again in a few hours.`;
  if (checked) return `Version ${checked} is downloading. It installs when you close this window.`;
  const auto = "Updates install by themselves while the window is closed.";
  if (update.state === "updated") return `Updated to ${update.version}. ${auto}`;
  return checked === null ? `Up to date. ${auto}` : auto;
}
```

`scripts/class-icons.py`:

```python
# Cuts the class icons the app shows from the game's UI-Classes-Circles
# texture (file 237669), a 4 by 4 grid in CLASS_ICON_TCOORDS order.
#   curl -o circles.blp "https://wago.tools/api/casc/237669?version=1.60.1.70245"
#   python scripts/class-icons.py circles.blp src/classes   (needs Pillow)
import sys
from PIL import Image

source, out = sys.argv[1], sys.argv[2]
sheet = Image.open(source).convert("RGBA")
grid = {"warrior": (0, 0), "mage": (1, 0), "rogue": (2, 0), "druid": (3, 0),
        "hunter": (0, 1), "shaman": (1, 1), "priest": (2, 1), "warlock": (3, 1), "paladin": (0, 2)}
size = sheet.size[0] // 4
for name, (x, y) in grid.items():
    sheet.crop((x * size, y * size, (x + 1) * size, (y + 1) * size)).save(f"{out}/{name}.png")
```

Run it as its header says (download into the scratchpad, not the repo); check by eye that the nine PNGs in `src/classes/` are the right classes.

`src/classes.ts`:

```ts
// Class icons from the game's UI-Classes-Circles (scripts/class-icons.py).
import druid from "./classes/druid.png";
import hunter from "./classes/hunter.png";
import mage from "./classes/mage.png";
import paladin from "./classes/paladin.png";
import priest from "./classes/priest.png";
import rogue from "./classes/rogue.png";
import shaman from "./classes/shaman.png";
import warlock from "./classes/warlock.png";
import warrior from "./classes/warrior.png";

export const CLASS_ICONS: Record<string, string> = {
  DRUID: druid, HUNTER: hunter, MAGE: mage, PALADIN: paladin, PRIEST: priest,
  ROGUE: rogue, SHAMAN: shaman, WARLOCK: warlock, WARRIOR: warrior,
};
```

`src/api.ts`, whole file:

```ts
// Everything the window asks of the app. The names and shapes match
// src-tauri/src/commands.rs, account.rs, update.rs and status.rs; the
// server's answers are typed by @road-to-sixty/api.
import type { CharacterInfo, DeviceInfo, RestoreResponse, VersionInfo } from "@road-to-sixty/api";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { disable, enable, isEnabled } from "@tauri-apps/plugin-autostart";
import { useEffect, useState } from "react";

export const isMac = navigator.userAgent.includes("Mac");

export type Game = { path: string; name: string; addon: string | null; characters: number };
export type Character = {
  key: string;
  here: boolean;
  updateAddon: boolean;
  uploaded: number | null;
  problem: string | null; // why it isn't backed up
  note: string;
};
export type Update =
  | { state: "none" }
  | { state: "ready"; version: string }
  | { state: "updated"; version: string; at: number }
  | { state: "failed"; why: string };
export type Status = {
  linkedTo: string | null;
  pc: string | null;
  version: string;
  games: Game[];
  characters: Character[];
  lastSynced: number | null;
  paused: boolean;
  offline: boolean;
  problems: string[];
  linkCode: string | null;
  line: string;
  update: Update;
};

export const getStatus = () => invoke<Status>("status");
export const onStatus = (show: (s: Status) => void) => listen<Status>("status", (e) => show(e.payload));
export const hostName = () => invoke<string>("host_name");
export const link = (name: string) => invoke("link", { name });
export const unlink = () => invoke("unlink");
export const setPaused = (paused: boolean) => invoke("set_paused", { paused });
export const pickFolder = () => invoke("pick_folder");

export const characters = () => invoke<CharacterInfo[]>("characters");
export const versions = (id: number) => invoke<VersionInfo[]>("versions", { id });
export const restore = (id: number, version: number) => invoke<RestoreResponse>("restore", { id, version });
export const devices = () => invoke<DeviceInfo[]>("devices");
export const renameDevice = (id: string, name: string) => invoke<DeviceInfo>("rename_device", { id, name });
export const unlinkDevice = (id: string) => invoke("unlink_device", { id });
export const exportData = () => invoke<boolean>("export_data");
export const deleteAccount = () => invoke("delete_account");

export const startsAtLogin = () => isEnabled();
export const setStartsAtLogin = (on: boolean) => (on ? enable() : disable());
export const checkUpdate = () => invoke<string | null>("check_update");
export const installUpdate = () => invoke("install_update");

// Loads from the server through the app, and again whenever deps change or
// reload is called. error is the reason, in words.
export function useLoad<T>(load: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [n, setN] = useState(0);
  useEffect(() => {
    let live = true;
    load().then(
      (d) => live && (setData(d), setError(null)),
      (e) => live && setError(String(e)),
    );
    return () => {
      live = false;
    };
  }, [...deps, n]);
  return { data, error, reload: () => setN((x) => x + 1) };
}
```

`src/FirstRun.tsx` and `src/Account.tsx` still call `addFolder` and `link()`: change their imports to `pickFolder` and call `link("")` for now, so the window builds; Tasks 7 to 9 replace them.

- [ ] **Step 4: Run the tests and types**

Run: `cd apps/desktop && bun test src && bun run typecheck && bun run build`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add apps/desktop packages/ui/theme.css bun.lock
git commit -m "App: the window's words, class icons and calls for the account screens (#39)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The Characters screen and a character's history

**Files:**
- Create: `apps/desktop/src/History.tsx`
- Modify: `apps/desktop/src/Characters.tsx`, `apps/desktop/src/App.tsx`

**Interfaces:**
- Consumes: `useLoad`, `characters`, `versions`, `restore`, `setPaused` (api.ts); `CLASSES`, `played`, `levelClass`, `characterLine`, `versionLine`, `when` (format.ts); `CLASS_ICONS` (classes.ts).
- Produces: `Characters({ status, onTab, onOpen })`, `History({ status, character, onBack })`, `Shell` unchanged in props.

The screens follow the A-Characters-2 and A-History mockups. Their logic is in `format.ts` (tested in Task 6); this task is layout, checked by building and by eye.

- [ ] **Step 1: The Characters screen**

`src/Characters.tsx`: replace the `Characters` function (keep `Shell` and `Tab` as they are, without the drag strip Task 3 removed) with:

```tsx
export function Characters({ status, onTab, onOpen }: { status: Status; onTab: (t: Tab) => void; onOpen: (c: CharacterInfo) => void }) {
  const server = useLoad(characters, [status.lastSynced]);
  const now = new Date();
  const info = new Map((server.data ?? []).map((c) => [`${c.name}-${c.realm}`, c]));
  return (
    <Shell status={status} tab="characters" onTab={onTab}>
      <ul className="flex flex-1 flex-col gap-2 overflow-y-auto px-4 py-3.5">
        {status.characters.length === 0 && (
          <li className="px-1 text-[13px] text-muted">No characters yet. Log in to a character with the addon, then log out or type /reload.</li>
        )}
        {status.characters.map((c) => {
          const i = info.get(c.key);
          const [name, ...realm] = c.key.split("-");
          const warn = c.updateAddon || c.problem !== null;
          const look = CLASSES[i?.class ?? ""];
          const icon = CLASS_ICONS[i?.class ?? ""];
          const box = `flex w-full items-center gap-2.5 rounded-[10px] border px-3.5 py-3 text-left ${warn ? "border-warn-line bg-[#0f0d0a]" : "border-line bg-panel"}`;
          const body = (
            <>
              {icon ? (
                <img src={icon} alt="" className="size-[34px] shrink-0 self-start rounded-full" />
              ) : (
                <span aria-hidden="true" className="size-[34px] shrink-0 self-start rounded-full border border-dashed border-[#3a3746]" />
              )}
              <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                <div className="flex items-baseline gap-2">
                  <span className="text-[15px] font-medium" style={{ color: look?.colour }}>
                    {name}
                  </span>
                  <span className="truncate text-[13px] text-muted">{(i && levelClass(i)) || realm.join("-")}</span>
                  {i?.played != null && <span className="ml-auto font-mono text-xs text-muted">{played(i.played)}</span>}
                </div>
                <div className={`text-xs leading-[1.45] ${warn ? "text-warn" : "text-faint"}`}>{warn || !i ? c.note : characterLine(i, now)}</div>
              </div>
              {i && (
                <span aria-hidden="true" className="text-base text-faint">
                  ›
                </span>
              )}
            </>
          );
          return (
            <li key={c.key}>
              {i ? (
                <button type="button" className={box} onClick={() => onOpen(i)}>
                  {body}
                </button>
              ) : (
                <div className={box}>{body}</div>
              )}
            </li>
          );
        })}
      </ul>
      {server.error && <p className="mx-5 mb-2 text-xs text-warn">Couldn't load from the server: {server.error}</p>}
      <footer className="flex gap-2 border-t border-line-soft px-4 py-3">
        <Button onClick={() => setPaused(!status.paused)}>{status.paused ? "Resume syncing" : "Pause syncing"}</Button>
      </footer>
    </Shell>
  );
}
```

Imports: `import type { CharacterInfo } from "@road-to-sixty/api";`, `characters, setPaused, useLoad, type Status` from `./api`, `CLASSES, characterLine, levelClass, played` from `./format`, `CLASS_ICONS` from `./classes`.

- [ ] **Step 2: The history screen**

Create `src/History.tsx`:

```tsx
import type { CharacterInfo } from "@road-to-sixty/api";
import { Button } from "@road-to-sixty/ui/Button";
import { useState } from "react";
import { restore, useLoad, versions, type Status } from "./api";
import { CLASS_ICONS } from "./classes";
import { CLASSES, levelClass, played, versionLine, when } from "./format";

// A character's merged and restored versions, newest first, after the
// A-History mockup. Restoring asks first, in the row itself.
export function History({ status, character, onBack }: { status: Status; character: CharacterInfo; onBack: () => void }) {
  const list = useLoad(() => versions(character.id), [character.id, status.lastSynced]);
  const [asking, setAsking] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const now = new Date();
  const icon = CLASS_ICONS[character.class ?? ""];

  async function pick(version: number) {
    setError(null);
    try {
      await restore(character.id, version);
      setAsking(null);
      list.reload();
    } catch (e) {
      setError(`Couldn't restore: ${String(e)}`);
    }
  }

  return (
    <main className="flex h-full flex-col">
      <div className="flex flex-col gap-3 px-5 pb-1 pt-3.5">
        <button type="button" onClick={onBack} className="self-start text-[13px] text-[#c9c4d6] hover:text-text">
          ‹ Characters
        </button>
        <div className="flex items-center gap-3">
          {icon && <img src={icon} alt="" className="size-11 rounded-full" />}
          <div className="flex flex-col gap-1">
            <div className="flex items-baseline gap-2">
              <h1 className="text-xl font-medium tracking-tight" style={{ color: CLASSES[character.class ?? ""]?.colour }}>
                {character.name}
              </h1>
              <span className="text-[13px] text-muted">{levelClass(character)}</span>
            </div>
            <div className="text-xs text-faint">
              {[character.realm, character.played !== null ? `${played(character.played)} played` : ""].filter(Boolean).join(" · ")}
            </div>
          </div>
        </div>
      </div>
      <h2 className="mx-5 mt-3.5 text-xs font-medium text-faint">History</h2>
      {(error || list.error) && <p className="mx-5 mt-2 text-xs text-warn">{error ?? `Couldn't load the history: ${list.error}`}</p>}
      <ol className="flex flex-1 flex-col gap-2 overflow-y-auto px-4 pb-4 pt-2">
        {list.data?.map((v) =>
          v.current ? (
            <li key={v.id} className="flex flex-col gap-1 rounded-[10px] border border-outline bg-panel px-3.5 py-3">
              <div className="flex items-baseline gap-2">
                <span className="text-sm font-medium">{when(v.createdAt, now)}</span>
                <span className="ml-auto flex h-5 items-center rounded-full bg-accent-soft px-2 text-[11px] text-accent">Current</span>
              </div>
              <div className="text-xs text-muted">{versionLine(v, now)}</div>
            </li>
          ) : asking === v.id ? (
            <li key={v.id} className="flex flex-col gap-2.5 rounded-[10px] border border-[#3a3746] bg-[#100f15] px-3.5 py-3">
              <div className="flex flex-col gap-1">
                <span className="text-sm font-medium">{when(v.createdAt, now)}</span>
                <span className="text-xs text-muted">{versionLine(v, now)}</span>
              </div>
              <p className="text-[13px] leading-[1.45] text-[#c9c4d6]">
                Go back to this version? {character.name}'s journey on each PC changes at its next login. The current version stays in this list, so you can
                switch back.
              </p>
              <div className="flex gap-2">
                <Button look="cream" onClick={() => pick(v.id)}>
                  Restore this version
                </Button>
                <Button onClick={() => setAsking(null)}>Cancel</Button>
              </div>
            </li>
          ) : (
            <li key={v.id} className="flex items-center gap-2.5 rounded-[10px] border border-line bg-panel px-3.5 py-3">
              <div className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">{when(v.createdAt, now)}</span>
                <span className="text-xs text-muted">{versionLine(v, now)}</span>
              </div>
              <Button className="h-[30px] rounded-lg px-3 text-xs" onClick={() => setAsking(v.id)}>
                Restore
              </Button>
            </li>
          ),
        )}
      </ol>
    </main>
  );
}
```

- [ ] **Step 3: App opens the history**

`src/App.tsx`: add `const [open, setOpen] = useState<CharacterInfo | null>(null);` and change the last line to:

```tsx
  if (open) return <History status={status} character={open} onBack={() => setOpen(null)} />;
  return tab === "characters" ? <Characters status={status} onTab={setTab} onOpen={setOpen} /> : <Account status={status} onTab={setTab} />;
```

with the imports for `CharacterInfo` and `History`. An unlinked status still goes to `FirstRun` first, before `open` is looked at.

- [ ] **Step 4: Build, check types and look at it**

Run: `cd apps/desktop && bun run typecheck && bun run build && bun test src`
Expected: all pass.

Then `bunx tauri dev`: the Characters tab shows class icons, coloured names, level and class, time played and "realm · PC, when"; a click opens the history; Restore asks in the row; Cancel closes it.

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/src
git commit -m "App: characters with class icons, and each one's history with restore (#39)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The Account screen in one tab

**Files:**
- Modify: `apps/desktop/src/Account.tsx`

**Interfaces:**
- Consumes: `useLoad`, `devices`, `renameDevice`, `unlinkDevice`, `unlink`, `pickFolder`, `exportData`, `deleteAccount`, `startsAtLogin`, `setStartsAtLogin`, `checkUpdate`, `installUpdate`, `isMac` (api.ts); `deviceLine`, `updateWords` (format.ts).
- Produces: `Account({ status, onTab })`.

After the A-Account mockup: Your PCs, Game folders, This PC (start at login switch, version and updates, linked to and Unlink), Your data (download, delete everything). Confirmations are inline.

- [ ] **Step 1: Write the screen**

`src/Account.tsx`, whole file:

```tsx
import { Button } from "@road-to-sixty/ui/Button";
import { useEffect, useState, type ReactNode } from "react";
import {
  checkUpdate, deleteAccount, devices, exportData, installUpdate, isMac, pickFolder, renameDevice,
  setStartsAtLogin, startsAtLogin, unlink, unlinkDevice, useLoad, type Status,
} from "./api";
import { Shell, type Tab } from "./Characters";
import { deviceLine, updateWords } from "./format";

const small = "h-[30px] whitespace-nowrap rounded-lg px-3 text-xs";

export function Account({ status, onTab }: { status: Status; onTab: (t: Tab) => void }) {
  const pcs = useLoad(devices, [status.lastSynced]);
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null);
  // Which inline question is open: a PC's id, "this PC" or "delete".
  const [asking, setAsking] = useState<string | null>(null);
  const [error, setError] = useState<{ at: string; why: string } | null>(null);
  const [atLogin, setAtLogin] = useState(false);
  const [checked, setChecked] = useState<string | null | undefined>(undefined);
  const [saved, setSaved] = useState(false);
  const now = new Date();
  useEffect(() => void startsAtLogin().then(setAtLogin, () => {}), []);

  const act = (at: string, job: () => Promise<unknown>) => async () => {
    setError(null);
    try {
      await job();
    } catch (e) {
      setError({ at, why: String(e) });
    }
  };
  const problem = (at: string) => error?.at === at && <p className="mx-1 text-xs text-warn">{error.why}</p>;

  return (
    <Shell status={status} tab="account" onTab={onTab}>
      <div className="flex flex-1 flex-col gap-[22px] overflow-y-auto px-4 pb-5 pt-4 text-[13px]">
        <Section title="Your PCs">
          <Card>
            {pcs.data?.map((d, n) => (
              <Row key={d.id} line={n > 0}>
                {renaming?.id === d.id ? (
                  <form
                    className="flex flex-1 flex-col gap-2"
                    onSubmit={(e) => {
                      e.preventDefault();
                      void act("pcs", async () => {
                        await renameDevice(d.id, renaming.name);
                        setRenaming(null);
                        pcs.reload();
                      })();
                    }}
                  >
                    <label htmlFor={`name-${d.id}`} className="sr-only">
                      PC name
                    </label>
                    <div className="flex gap-2">
                      <input
                        id={`name-${d.id}`}
                        value={renaming.name}
                        maxLength={40}
                        autoFocus
                        autoComplete="off"
                        onChange={(e) => setRenaming({ id: d.id, name: e.target.value })}
                        className="h-8 min-w-0 flex-1 rounded-lg border border-accent bg-ground px-2.5 text-sm text-text outline-none"
                      />
                      <Button look="cream" type="submit" className="h-8 rounded-lg px-3 text-xs">
                        Save
                      </Button>
                    </div>
                    <div className="text-xs text-muted">{deviceLine(d, now)}</div>
                  </form>
                ) : asking === d.id ? (
                  <Ask
                    question={`Unlink ${d.name}? It stops syncing at once. Its journeys stay on it and on the server.`}
                    yes="Unlink"
                    onYes={act("pcs", async () => {
                      await unlinkDevice(d.id);
                      setAsking(null);
                      pcs.reload();
                    })}
                    onNo={() => setAsking(null)}
                  />
                ) : (
                  <>
                    <div className="flex min-w-0 flex-1 flex-col gap-1">
                      <div className="flex items-baseline gap-2">
                        <span className="truncate text-sm font-medium">{d.name}</span>
                        {d.id === status.pc && <span className="text-xs text-accent">This PC</span>}
                      </div>
                      <div className="text-xs text-muted">{deviceLine(d, now)}</div>
                    </div>
                    <button type="button" onClick={() => setRenaming({ id: d.id, name: d.name })} className="px-1 py-1.5 text-xs text-[#c9c4d6] hover:text-text">
                      Rename
                    </button>
                    {d.id !== status.pc && (
                      <Button className={small} onClick={() => setAsking(d.id)}>
                        Unlink
                      </Button>
                    )}
                  </>
                )}
              </Row>
            ))}
            {!pcs.data && <Row>{pcs.error ? <span className="text-xs text-warn">Couldn't load your PCs: {pcs.error}</span> : <span className="text-xs text-faint">Loading…</span>}</Row>}
          </Card>
          {problem("pcs")}
          <p className="mx-1 text-xs leading-[1.45] text-faint">Unlinking a PC stops it syncing at once. Its journeys stay on it and on the server.</p>
        </Section>

        <Section title="Game folders">
          {status.games.map((g) => (
            <Card key={g.path}>
              <Row>
                <div className="flex min-w-0 flex-col gap-1">
                  <div className="font-mono text-xs leading-normal text-[#c9c4d6] [overflow-wrap:anywhere]">{g.path}</div>
                  <div className="text-xs text-muted">
                    {["Road to Sixty", g.addon].filter(Boolean).join(" ")} · {g.characters === 1 ? "1 character" : `${g.characters} characters`}
                  </div>
                </div>
              </Row>
            </Card>
          ))}
          <button type="button" onClick={pickFolder} className="mx-1 self-start text-[#c9c4d6] hover:text-text">
            Add a game folder…
          </button>
        </Section>

        <Section title="This PC">
          <Card>
            <Row>
              <label htmlFor="atlogin" className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Start at login</span>
                <span className="text-xs leading-[1.45] text-muted">Opens hidden in the {isMac ? "menu bar" : "tray"}, so every session is backed up.</span>
              </label>
              <button
                id="atlogin"
                type="button"
                role="switch"
                aria-checked={atLogin}
                onClick={act("login", async () => {
                  await setStartsAtLogin(!atLogin);
                  setAtLogin(await startsAtLogin());
                })}
                className={`flex h-6 w-10 shrink-0 rounded-full p-[3px] ${atLogin ? "justify-end bg-accent" : "justify-start bg-outline"}`}
              >
                <span className="size-[18px] rounded-full bg-cream" />
              </button>
            </Row>
            {error?.at === "login" && <p className="px-3.5 pb-3 text-xs text-warn">Couldn't change it: {error.why}</p>}
            <Row line>
              <div className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Road to Sixty {status.version}</span>
                <span className="text-xs leading-[1.45] text-muted">{updateWords(status.update, checked)}</span>
              </div>
              {status.update.state === "ready" ? (
                <Button className={small} onClick={act("update", installUpdate)}>
                  Restart now
                </Button>
              ) : (
                <Button className={small} onClick={act("update", async () => setChecked(await checkUpdate()))}>
                  Check now
                </Button>
              )}
            </Row>
            {error?.at === "update" && <p className="px-3.5 pb-3 text-xs text-warn">Couldn't check: {error.why}</p>}
            <Row line>
              {asking === "this PC" ? (
                <Ask
                  question="Unlink this PC? Syncing stops here. Your journeys stay on this PC and on the server."
                  yes="Unlink"
                  onYes={act("unlink", unlink)}
                  onNo={() => setAsking(null)}
                />
              ) : (
                <>
                  <div className="flex flex-1 flex-col gap-1">
                    <span className="text-sm font-medium">Linked to {status.linkedTo}</span>
                    <span className="text-xs leading-[1.45] text-muted">Unlink to stop syncing here.</span>
                  </div>
                  <Button className={small} onClick={() => setAsking("this PC")}>
                    Unlink
                  </Button>
                </>
              )}
            </Row>
          </Card>
          {problem("unlink")}
        </Section>

        <Section title="Your data">
          <Card>
            <Row>
              <div className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Download all my data</span>
                <span className="text-xs leading-[1.45] text-muted">{saved ? "Saved." : "A zip with each character's newest journey."}</span>
              </div>
              <Button className={small} onClick={act("data", async () => setSaved(await exportData()))}>
                Download
              </Button>
            </Row>
            <Row line>
              {asking === "delete" ? (
                <Ask
                  question="Delete your account and every journey on the server? This can't be undone. Journeys on your PCs stay, and every PC stops syncing."
                  yes="Delete everything"
                  danger
                  onYes={act("data", deleteAccount)}
                  onNo={() => setAsking(null)}
                />
              ) : (
                <>
                  <div className="flex flex-1 flex-col gap-1">
                    <span className="text-sm font-medium">Delete everything</span>
                    <span className="text-xs leading-[1.45] text-muted">Removes your account and every journey from the server. Journeys on your PCs stay.</span>
                  </div>
                  <Button className={`${small} border-danger-line text-danger`} onClick={() => setAsking("delete")}>
                    Delete
                  </Button>
                </>
              )}
            </Row>
          </Card>
          {problem("data")}
        </Section>
      </div>
    </Shell>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="mx-1 text-xs font-medium text-faint">{title}</h2>
      {children}
    </section>
  );
}

function Card({ children }: { children: ReactNode }) {
  return <div className="flex flex-col rounded-[10px] border border-line bg-panel">{children}</div>;
}

// One row of a card; line draws the divider above it.
function Row({ line = false, children }: { line?: boolean; children: ReactNode }) {
  return (
    <>
      {line && <div className="mx-3.5 h-px bg-line-soft" />}
      <div className="flex items-center gap-3 px-3.5 py-3">{children}</div>
    </>
  );
}

// A question asked in the row itself, instead of a dialog the window would hide behind.
function Ask({ question, yes, danger = false, onYes, onNo }: { question: string; yes: string; danger?: boolean; onYes: () => void; onNo: () => void }) {
  return (
    <div className="flex flex-1 flex-col gap-2.5">
      <p className="text-[13px] leading-[1.45] text-[#c9c4d6]">{question}</p>
      <div className="flex gap-2">
        <Button look={danger ? "outline" : "cream"} className={danger ? "border-danger-line text-danger" : ""} onClick={onYes}>
          {yes}
        </Button>
        <Button onClick={onNo}>Cancel</Button>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Build, check types and look at it**

Run: `cd apps/desktop && bun run typecheck && bun run build && bun test src`
Expected: all pass.

Then `bunx tauri dev`: the PC list marks this PC, Rename edits in place and saves, Unlink asks in the row; the folder path wraps; the switch turns on and off (and a failure shows under it); Check now says what it found; Download asks where to save without the window hiding; Delete asks in the row. Don't press "Delete everything" on the live account.

- [ ] **Step 3: Commit**

```bash
git add apps/desktop/src
git commit -m "App: the Account screen in one tab, with PCs, folders, updates and your data (#39)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Naming the PC at first run, version 0.1.2, and the docs

**Files:**
- Modify: `apps/desktop/src/FirstRun.tsx`, `apps/desktop/src-tauri/tauri.conf.json`, `apps/desktop/src-tauri/Cargo.toml`, `apps/desktop/AGENTS.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`

**Interfaces:**
- Consumes: `hostName`, `link(name)`, `pickFolder`, `setStartsAtLogin` (api.ts).

- [ ] **Step 1: The PC name box**

`src/FirstRun.tsx`:
- Imports: `useEffect, useState` from react; `hostName, link, pickFolder, setStartsAtLogin, type Status` from `./api` (no `addFolder`, no `isMac`).
- At the top of `FirstRun`:

```tsx
  const [name, setName] = useState("");
  useEffect(() => void hostName().then((n) => setName((typed) => typed || n)), []);
```

- Step 2's text becomes: "Give this PC a name you'll recognise, sign in with Battle.net in your browser, check the code matches, and click Link."
- Inside `{found && !linked && (<>`, before the button:

```tsx
              {!status.linkCode && (
                <label className="flex flex-col gap-1.5 text-xs text-muted">
                  This PC's name
                  <input
                    value={name}
                    maxLength={40}
                    autoComplete="off"
                    onChange={(e) => setName(e.target.value)}
                    className="h-9 rounded-lg border border-outline bg-ground px-2.5 text-sm text-text outline-none focus:border-accent"
                  />
                </label>
              )}
```

- The button's `onClick={link}` becomes `onClick={() => link(name)}`.
- The footer's `onClick={addFolder}` becomes `onClick={pickFolder}`.
- The Done button: `onClick={() => setStartsAtLogin(true).catch(() => {}).then(onDone)}` (start at login failing here shows on the Account switch later; it mustn't leave the player stuck on step 3).

- [ ] **Step 2: Version 0.1.2**

Set `"version": "0.1.2"` in `src-tauri/tauri.conf.json` and `version = "0.1.2"` in `src-tauri/Cargo.toml`.

- [ ] **Step 3: Run everything**

Run: `cd apps/desktop && bun run typecheck && bun run build && cargo test --workspace && bun test src scripts && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass, no warnings; `Cargo.lock` now says 0.1.2 for `road-to-sixty-app`.

The name box shows only while unlinked, so it isn't tried on Jordan's live link; the final review reads it, and Jordan sees it at his next link.

- [ ] **Step 4: Docs**

`apps/desktop/AGENTS.md`: replace "`FirstRun.tsx`, `Characters.tsx` and `Account.tsx` are the screens, after the mockups' \"A · First run\" and \"A · Characters\"." with "`FirstRun.tsx` (with the PC's name), `Characters.tsx`, `History.tsx` and `Account.tsx` are the screens, after the mockups' A-Characters-2, A-History and A-Account (#39). `format.ts` works out every word and number they show and is tested (`bun test src`); `classes.ts` holds the class icons, cut from the game's art by `scripts/class-icons.py`."

`CLAUDE.md` (repo root), in the `src-tauri/` sentence: replace "`commands.rs` is what the window can ask, `update.rs` is self-update." with "`commands.rs` and `account.rs` are what the window can ask (the account screens' server calls go through `account.rs`, so the window never holds the token), `window.rs` opens the window under the icon, `update.rs` is self-update."

Spec, "The desktop app": replace "Also asked for, 2026-10-14 (plan 2, the app): on the Mac the window opens anchored under the menu bar icon" up to the end of that paragraph's "Windows gets the same near the tray icon." with "The window opens under the menu bar icon (Mac) or beside the tray icon (Windows), like a menu bar app's popover: a left click on the icon opens it, a click elsewhere hides it, and a right click shows the menu. Questions (restore, unlink, delete everything) are asked inside the window, since a dialog would take its focus. The account screens call the server through the app, which holds the PC token; the window never sees it. The app checks for new versions as soon as a game starts, as well as every few minutes, so other PCs' play is in the sync folder before the player logs in." Replace "The app's screens from these mockups (...) are plan 2." with "The app's screens from these mockups are built (plan `docs/superpowers/plans/2026-10-15-app-account.md`)."

- [ ] **Step 5: Commit**

```bash
git add apps/desktop CLAUDE.md docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
git commit -m "App: name the PC when linking; version 0.1.2 (#39)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

After the final review: merge `app-account` into `dev`, push, watch CI, and comment on #1 and #39. Tagging `app-v0.1.2` publishes to every installed copy: ask Jordan before tagging. After it is out, Jordan tries the update once from 0.1.1 and checks the window on Windows (Review Focus 3 and 5).
