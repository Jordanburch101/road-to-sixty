# Linux App for Steam Deck Desktop Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An early AppImage of the desktop app that finds WoW inside Wine prefixes on a Steam Deck in Desktop Mode, built and smoke-tested in CI, released beside the Mac and Windows builds and offered on the website.

**Architecture:** The engine gains a Linux-only finder (`engine/src/wine.rs`) that lists Wine prefixes under the home folder and the installs inside them; `installs::find_installs` uses it on Linux instead of the Mac and Windows spots. `watch::game_running` also matches a Wine command line by its last folder names. CI builds the AppImage on Ubuntu 22.04 and starts it in an Arch container; the release workflow adds it to the bucket and `latest.json`; the website gets a Linux download.

**Tech Stack:** Rust 1.99 (engine `rts-sync`, app `road-to-sixty-app`, Tauri 2.12), sysinfo 0.39, GitHub Actions, Docker `archlinux`, Bun tests, Astro.

**Spec:** `docs/superpowers/specs/2026-10-15-linux-steam-deck-design.md` (issue #47)

## Global Constraints

- Desktop Mode only: no Game Mode, background service, Flatpak, ARM, .deb or .rpm.
- Build on `ubuntu-22.04`, never `ubuntu-latest`, for the AppImage (the oldest base we support).
- AppImage only: `bunx tauri build --bundles appimage` on Linux.
- Release file names: `Road-to-Sixty_<v>_amd64.AppImage` and `.sig`; fixed website name `app/Road-to-Sixty.AppImage`; updater key `linux-x86_64`.
- Download label: "Download for Linux (early)"; the page says early until a Deck player reports back.
- The public repo: no personal paths, emails or secrets in code, tests, comments or issues.
- Comments: plain sentences that say why, British spelling, density like the surrounding code. Commit subjects `Area: what changed (#47)`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Each app's `AGENTS.md` changes in the same commit as the code it describes.
- Work in the worktree `<worktree>` on branch `linux-app` (from `dev`). If `cargo` isn't found, run `. ~/.cargo/env` first.

## Review Focus

1. A Steam library on an SD card that isn't inserted (its path in `libraryfolders.vdf` doesn't exist): skipped quietly, other installs still found. Test in Task 1.
2. A prefix whose `dosdevices` link for the drive letter is missing: that Battle.net path is skipped, the default install in `drive_c` is still found. Test in Task 1.
3. The same prefix reached twice (the vdf lists the main Steam folder, which is also scanned directly): listed once. Test in Task 1.
4. A Wine command line in other letter case (`world of warcraft\_CLASSIC_BETA_\wowclassic.EXE`) still counts; a non-.exe argument or another game folder's program doesn't. Test in Task 2.
5. No home folder known (`HOME` unset): no Wine installs, picked folders still work. Covered by `find_installs` keeping `picked` regardless (Task 1 code; `a_linked_install_is_kept_by_its_real_path` still passes).

---

### Task 1: Find WoW inside Wine prefixes

**Files:**
- Create: `apps/desktop/engine/src/wine.rs`
- Modify: `apps/desktop/engine/src/lib.rs` (add the module)
- Modify: `apps/desktop/engine/src/installs.rs:24-41` (doc comments), `:67-71` (`find_installs`)
- Modify: `apps/desktop/AGENTS.md` (installs line)
- Test: inside `wine.rs` (`#[cfg(test)] mod tests`)

**Interfaces:**
- Produces: `rts_sync::wine::installs(home: &Path) -> Vec<PathBuf>` (unix only), plus `prefixes(home)`, `steam_libraries(vdf: &str)`, `windows_path(prefix, path: &str) -> Option<PathBuf>`, `installs_in_prefix(prefix)`.
- `installs::find_installs(picked)` keeps its signature.

The module is `#[cfg(unix)]` because a path joined with `c:` on Windows replaces the whole path, so its tests can't run there; Mac and Linux CI run them.

- [ ] **Step 1: Write the module with its failing tests**

Create `apps/desktop/engine/src/wine.rs`:

```rust
//! Finding WoW on Linux, where it runs inside a Wine prefix: a folder with
//! `drive_c` and `dosdevices`, made by Steam's Proton, Lutris, Bottles or
//! plain Wine (spec 2026-10-15-linux-steam-deck-design.md, "Finding WoW").

use std::fs;
use std::path::{Path, PathBuf};

use crate::installs;

/// Every WoW install in the prefixes under `home`: Battle.net's list in
/// each prefix and its default install folder. The caller keeps those
/// that exist.
pub fn installs(home: &Path) -> Vec<PathBuf> {
    prefixes(home).iter().flat_map(|p| installs_in_prefix(p)).collect()
}

/// The Wine prefixes under `home`: Proton's in every Steam library (an SD
/// card's included), Lutris's `~/Games`, Bottles' and `~/.wine`.
pub fn prefixes(home: &Path) -> Vec<PathBuf> {
    let steams = [
        home.join(".local/share/Steam"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ];
    let mut libraries: Vec<PathBuf> = Vec::new();
    for steam in &steams {
        libraries.push(steam.clone());
        let vdf = fs::read_to_string(steam.join("steamapps/libraryfolders.vdf")).unwrap_or_default();
        libraries.extend(steam_libraries(&vdf));
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    for library in &libraries {
        candidates.extend(dirs_in(&library.join("steamapps/compatdata")).into_iter().map(|d| d.join("pfx")));
    }
    candidates.extend(dirs_in(&home.join("Games")));
    candidates.extend(dirs_in(&home.join(".var/app/com.usebottles.bottles/data/bottles/bottles")));
    candidates.push(home.join(".wine"));
    let mut found: Vec<PathBuf> = Vec::new();
    for prefix in candidates {
        if prefix.join("drive_c").is_dir() && !found.contains(&prefix) {
            found.push(prefix);
        }
    }
    found
}

/// The library folders in Steam's `libraryfolders.vdf`, from its `"path"`
/// lines; nothing else in the file is needed.
pub fn steam_libraries(vdf: &str) -> Vec<PathBuf> {
    vdf.lines()
        .filter_map(|line| {
            // `"path"		"/run/media/mmcblk0p1"` splits into "", path, tabs, the path, "".
            let mut parts = line.trim().split('"').skip(1);
            match (parts.next(), parts.nth(1)) {
                (Some("path"), Some(path)) => Some(PathBuf::from(path)),
                _ => None,
            }
        })
        .collect()
}

/// A Windows path from inside a prefix (`C:/Program Files (x86)/...` or
/// with backslashes) as a real path, through the prefix's drive letter
/// links, so an install on any drive (an SD card's included) resolves.
pub fn windows_path(prefix: &Path, path: &str) -> Option<PathBuf> {
    let path = path.replace('\\', "/");
    let (drive, rest) = path.split_once(":/")?;
    if drive.len() != 1 || !drive.chars().all(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    Some(prefix.join("dosdevices").join(format!("{}:", drive.to_ascii_lowercase())).join(rest))
}

/// The installs a prefix holds: Battle.net's list and the default folder.
pub fn installs_in_prefix(prefix: &Path) -> Vec<PathBuf> {
    let db = prefix.join("drive_c/ProgramData/Battle.net/Agent/product.db");
    let mut found: Vec<PathBuf> = fs::read(db)
        .map(|b| installs::installs_in_product_db(&b))
        .unwrap_or_default()
        .iter()
        .filter_map(|p| windows_path(prefix, &p.to_string_lossy()))
        .collect();
    found.push(prefix.join("drive_c/Program Files (x86)/World of Warcraft"));
    found
}

fn dirs_in(path: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn prefix(at: &Path) -> PathBuf {
        fs::create_dir_all(at.join("drive_c")).unwrap();
        fs::create_dir_all(at.join("dosdevices")).unwrap();
        symlink("../drive_c", at.join("dosdevices/c:")).unwrap();
        at.to_path_buf()
    }

    fn product_db(prefix: &Path, paths: &[&str]) {
        let mut bytes = Vec::new();
        for p in paths {
            bytes.extend(b"\x12\x00");
            bytes.extend(p.as_bytes());
        }
        let db = prefix.join("drive_c/ProgramData/Battle.net/Agent/product.db");
        fs::create_dir_all(db.parent().unwrap()).unwrap();
        fs::write(db, bytes).unwrap();
    }

    #[test]
    fn libraries_are_the_path_lines_of_libraryfolders_vdf() {
        let vdf = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/home/deck/.local/share/Steam\"\n\t\t\"label\"\t\t\"\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"/run/media/mmcblk0p1\"\n\t\t\"apps\"\n\t\t{\n\t\t}\n\t}\n}\n";
        assert_eq!(
            steam_libraries(vdf),
            [PathBuf::from("/home/deck/.local/share/Steam"), PathBuf::from("/run/media/mmcblk0p1")]
        );
        assert!(steam_libraries("").is_empty());
    }

    #[test]
    fn windows_paths_go_through_the_drive_letter_links() {
        let p = Path::new("/pfx");
        assert_eq!(
            windows_path(p, "C:/Program Files (x86)/World of Warcraft"),
            Some(PathBuf::from("/pfx/dosdevices/c:/Program Files (x86)/World of Warcraft"))
        );
        assert_eq!(windows_path(p, "d:\\Games\\WoW"), Some(PathBuf::from("/pfx/dosdevices/d:/Games/WoW")));
        assert_eq!(windows_path(p, "/home/deck/WoW"), None);
        assert_eq!(windows_path(p, "ab:/x"), None);
    }

    #[test]
    fn prefixes_are_found_in_every_steam_library_lutris_bottles_and_wine() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let card = h.join("card");
        let steam = h.join(".local/share/Steam");
        fs::create_dir_all(steam.join("steamapps")).unwrap();
        // The vdf lists the main Steam folder too, and a card that isn't inserted.
        fs::write(
            steam.join("steamapps/libraryfolders.vdf"),
            format!(
                "\"path\" \"{}\"\n\"path\" \"{}\"\n\"path\" \"{}\"\n",
                steam.display(),
                card.display(),
                h.join("not-inserted").display()
            ),
        )
        .unwrap();
        let shortcut = prefix(&steam.join("steamapps/compatdata/3141592653/pfx"));
        let on_card = prefix(&card.join("steamapps/compatdata/2718281828/pfx"));
        let flatpak = prefix(&h.join(".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata/NonSteamLaunchers/pfx"));
        let lutris = prefix(&h.join("Games/world-of-warcraft"));
        let bottle = prefix(&h.join(".var/app/com.usebottles.bottles/data/bottles/bottles/WoW"));
        let wine = prefix(&h.join(".wine"));
        fs::create_dir_all(h.join("Games/not-a-prefix")).unwrap();
        let found = prefixes(h);
        for p in [&shortcut, &on_card, &flatpak, &lutris, &bottle, &wine] {
            assert_eq!(found.iter().filter(|f| f == &p).count(), 1, "{} once", p.display());
        }
        assert_eq!(found.len(), 6, "no folder without drive_c: {found:?}");
    }

    #[test]
    fn a_prefix_gives_battle_nets_installs_and_the_default_folder() {
        let dir = tempfile::tempdir().unwrap();
        let p = prefix(&dir.path().join("pfx"));
        let card = dir.path().join("card");
        fs::create_dir_all(&card).unwrap();
        symlink(&card, p.join("dosdevices/d:")).unwrap();
        // E: has no link, so its path is dropped rather than guessed.
        product_db(&p, &["D:/Games/World of Warcraft", "E:/Elsewhere/World of Warcraft"]);
        assert_eq!(
            installs_in_prefix(&p),
            [
                p.join("dosdevices/d:/Games/World of Warcraft"),
                p.join("dosdevices/e:/Elsewhere/World of Warcraft"),
                p.join("drive_c/Program Files (x86)/World of Warcraft"),
            ]
        );
        // find_installs keeps only those that exist, by their real path.
        fs::create_dir_all(card.join("Games/World of Warcraft")).unwrap();
        let real: Vec<PathBuf> = installs_in_prefix(&p)
            .into_iter()
            .filter(|i| i.is_dir())
            .map(|i| fs::canonicalize(i).unwrap())
            .collect();
        assert_eq!(real, [fs::canonicalize(card.join("Games/World of Warcraft")).unwrap()]);
    }

    #[test]
    fn installs_under_a_made_up_home_include_the_default_proton_folder() {
        let home = tempfile::tempdir().unwrap();
        let p = prefix(&home.path().join(".local/share/Steam/steamapps/compatdata/1/pfx"));
        assert!(installs(home.path()).contains(&p.join("drive_c/Program Files (x86)/World of Warcraft")));
    }
}
```

Add to `apps/desktop/engine/src/lib.rs` after `pub mod watch;`:

```rust
#[cfg(unix)]
pub mod wine;
```

- [ ] **Step 2: Run the tests**

Run (from `apps/desktop`): `cargo test -p rts-sync wine`
Expected: the five `wine::tests` pass (the module is new, so they pass at once; check each one's assertions really ran by the count in the output: `5 passed`).

- [ ] **Step 3: Use it in `find_installs` on Linux**

In `apps/desktop/engine/src/installs.rs`, replace the first line of `find_installs`:

```rust
    let mut all: Vec<PathBuf> = fs::read(product_db()).map(|b| installs_in_product_db(&b)).unwrap_or_default();
    all.extend(default_installs());
    all.extend(picked.iter().cloned());
```

with:

```rust
    let mut all: Vec<PathBuf> = Vec::new();
    // dirs reads $HOME; without one, only the picked folders count.
    #[cfg(target_os = "linux")]
    all.extend(dirs::home_dir().map(|home| crate::wine::installs(&home)).unwrap_or_default());
    #[cfg(not(target_os = "linux"))]
    {
        all.extend(fs::read(product_db()).map(|b| installs_in_product_db(&b)).unwrap_or_default());
        all.extend(default_installs());
    }
    all.extend(picked.iter().cloned());
```

Update the doc comment above `find_installs` to: `/// Every install that exists: Battle.net's list and the default locations (on Linux, those inside each Wine prefix), and folders the player picked, without repeats.`

Update `product_db` and `default_installs` doc comments to start with `/// On a Mac or Windows,` (they aren't used on Linux).

- [ ] **Step 4: Run the engine's tests, clippy and fmt**

Run (from `apps/desktop`): `cargo test -p rts-sync && cargo clippy -p rts-sync --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass (the LuaJIT test needs `luajit` on the path; it is on Jordan's Mac).

Then the Linux branch for real, in Docker (Jordan's Mac is arm64, so this is native):

Run: `docker run --rm -v <worktree>:/w -w /w/apps/desktop rust:1.99 bash -c 'apt-get update -qq && apt-get install -y -qq luajit >/dev/null && cargo test -p rts-sync'`
Expected: all pass, including `wine::tests`.

- [ ] **Step 5: AGENTS.md**

In `apps/desktop/AGENTS.md`, replace `  - \`installs.rs\` finds WoW installs, game folders and saved journeys.` with:

```
  - `installs.rs` finds WoW installs, game folders and saved journeys. On
    Linux the installs come from `wine.rs`: every Wine prefix under the
    home folder (Proton's in each Steam library from `libraryfolders.vdf`,
    SD cards included, Lutris's `~/Games`, Bottles, `~/.wine`), Battle.net's
    list in each with drive letters turned into paths through `dosdevices`,
    and the default folder. `wine.rs` is unix-only: a path joined with `c:`
    on Windows replaces the whole path.
```

- [ ] **Step 6: Commit**

```bash
cd <worktree>
git add apps/desktop/engine/src/wine.rs apps/desktop/engine/src/lib.rs apps/desktop/engine/src/installs.rs apps/desktop/AGENTS.md
git commit -m "App: find WoW inside Wine prefixes on Linux (#47)

Proton's prefixes in every Steam library, SD cards included, Lutris,
Bottles and plain Wine; Battle.net's list in each, with drive letters
turned into real paths through dosdevices.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Notice the game starting under Wine

**Files:**
- Modify: `apps/desktop/engine/src/watch.rs:45-60` (`game_running`, `running_programs`), tests near `:300`
- Modify: `apps/desktop/engine/src/bin/rts-sync.rs` (`status` and the header comment)
- Modify: `apps/desktop/AGENTS.md` (watch.rs line)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `watch::game_running(game: &Path, programs: &[PathBuf]) -> bool` (same signature, now also true for a Wine command line); `watch::running_programs(&mut sysinfo::System) -> Vec<PathBuf>` (same signature, on Linux also returns `.exe` command line arguments with backslashes turned into slashes). `rts-sync status` prints `, running` after a game folder's line when its game runs, e.g. `/…/World of Warcraft/_classic_beta_ (addon developer), running`; Task 3's Wine check greps for `_classic_beta_ (addon developer), running`.

- [ ] **Step 1: Write the failing test**

In `apps/desktop/engine/src/watch.rs`, after `the_game_runs_when_a_program_inside_its_folder_does`, add:

```rust
    #[test]
    fn under_wine_the_game_is_known_by_its_last_folder_names() {
        let game = Path::new("/home/deck/.local/share/Steam/steamapps/compatdata/1/pfx/drive_c/Program Files (x86)/World of Warcraft/_classic_beta_");
        let wine = |arg: &str| vec![PathBuf::from("/usr/bin/wine64-preloader"), PathBuf::from(arg)];
        assert!(game_running(game, &wine("C:/Program Files (x86)/World of Warcraft/_classic_beta_/WowClassic.exe")));
        assert!(game_running(game, &wine("Z:/run/media/card/world of warcraft/_CLASSIC_BETA_/wowclassic.EXE")), "any case, any drive");
        assert!(!game_running(game, &wine("C:/Program Files (x86)/World of Warcraft/_retail_/Wow.exe")), "another game folder");
        assert!(!game_running(game, &wine("C:/Program Files (x86)/World of Warcraft/_classic_beta_/Data")), "not a program");
        assert!(!game_running(game, &wine("C:/Program Files (x86)/Other/_classic_beta_/WowClassic.exe")), "another install's name");
    }
```

- [ ] **Step 2: Run it to see it fail**

Run (from `apps/desktop`): `cargo test -p rts-sync under_wine`
Expected: FAIL on the first `assert!`.

- [ ] **Step 3: Implement**

Replace `game_running` and `running_programs` in `watch.rs` with:

```rust
/// Whether the game in `game` is running: some process's program file is
/// inside it. Process names differ by version and processor, and on a Mac
/// the program is inside the .app in the game folder. Under Wine the program
/// file is Wine's own and the game shows only as a Windows path in the
/// command line, so a program there counts when its install and game folder
/// names match ours. Two prefixes with the same names could fool it; that
/// costs one sync.
pub fn game_running(game: &Path, programs: &[PathBuf]) -> bool {
    let last_two = |p: &Path| -> Vec<String> { p.iter().rev().take(2).map(|c| c.to_string_lossy().to_lowercase()).collect() };
    programs.iter().any(|p| {
        p.starts_with(game)
            || (p.extension().is_some_and(|e| e.eq_ignore_ascii_case("exe"))
                && p.parent().is_some_and(|dir| last_two(dir) == last_two(game)))
    })
}

pub fn running_programs(system: &mut sysinfo::System) -> Vec<PathBuf> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, UpdateKind};
    let kind = ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet);
    #[cfg(target_os = "linux")]
    let kind = kind.with_cmd(UpdateKind::OnlyIfNotSet);
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, kind);
    let mut programs = Vec::new();
    for process in system.processes().values() {
        programs.extend(process.exe().map(Path::to_path_buf));
        // Wine starts the game as `C:\...\_classic_beta_\WowClassic.exe`.
        #[cfg(target_os = "linux")]
        programs.extend(
            process
                .cmd()
                .iter()
                .filter_map(|a| a.to_str())
                .filter(|a| a.to_ascii_lowercase().ends_with(".exe"))
                .map(|a| PathBuf::from(a.replace('\\', "/"))),
        );
    }
    programs
}
```

- [ ] **Step 4: Run the tests**

Run (from `apps/desktop`): `cargo test -p rts-sync watch`
Expected: PASS, including the existing Mac test.

- [ ] **Step 5: `rts-sync status` says when a game runs**

In `apps/desktop/engine/src/bin/rts-sync.rs`, in the `Some("status")` arm, before `for game in sync::games(&state) {` add:

```rust
            let programs = watch::running_programs(&mut sysinfo::System::new());
```

and replace the game line's `println!` with:

```rust
                println!(
                    "{} (addon {}){}",
                    game.path.display(),
                    installs::addon_version(&game.path).unwrap_or_else(|| "developer".into()),
                    if watch::game_running(&game.path, &programs) { ", running" } else { "" }
                );
```

In the header comment change `//!   rts-sync status     the installs, game folders and characters found` to `//!   rts-sync status     the installs, game folders (and whether each runs) and characters found`.

- [ ] **Step 6: Check, then the Linux build in Docker**

Run (from `apps/desktop`): `cargo test -p rts-sync && cargo clippy -p rts-sync --all-targets -- -D warnings && cargo fmt --check && cargo run -q --bin rts-sync -- status`
Expected: tests pass, no warnings, and `status` prints this Mac's installs as before.

Run: `docker run --rm -v <worktree>:/w -w /w/apps/desktop rust:1.99 bash -c 'apt-get update -qq && apt-get install -y -qq luajit >/dev/null && cargo test -p rts-sync && cargo clippy -p rts-sync --all-targets -- -D warnings'`
Expected: pass with the Linux `cmd` branch compiled.

- [ ] **Step 7: AGENTS.md**

In `apps/desktop/AGENTS.md`, after `It also looks for a game starting every five seconds and syncs at once when one does,` insert ` (under Wine, by the game's Windows path in the process's command line, since the program file is Wine's own),`.

- [ ] **Step 8: Commit**

```bash
cd <worktree>
git add apps/desktop/engine/src/watch.rs apps/desktop/engine/src/bin/rts-sync.rs apps/desktop/AGENTS.md
git commit -m "App: notice the game starting under Wine, and say so in rts-sync status (#47)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Build and smoke-test the AppImage in CI

**Files:**
- Create: `apps/desktop/scripts/linux-smoke.sh`
- Create: `apps/desktop/scripts/wine-check.sh`
- Modify: `.github/workflows/ci.yml` (replace the `desktop` job with `desktop-linux`)
- Modify: `apps/desktop/src-tauri/src/commands.rs:73-85` (picker opens in the home folder on Linux)
- Modify: `apps/desktop/AGENTS.md` (Commands and the CI note)

**Interfaces:**
- Consumes: `rts-sync status` printing `, running` (Task 2); `wine::installs` finding `~/Games/<prefix>/drive_c/Program Files (x86)/World of Warcraft` (Task 1).
- Produces: `scripts/linux-smoke.sh <AppImage> <out dir>` (exit 0 when the app is still running after 20 s; writes `<out dir>/screenshot.png`), used again by Task 4.

- [ ] **Step 1: The folder picker opens in the home folder on Linux**

In `apps/desktop/src-tauri/src/commands.rs`, replace the dialog chain in `pick_folder`:

```rust
        let picked = crate::window::holding(&app, || {
            let dialog = app.dialog().file().set_title("Pick your World of Warcraft folder");
            // WoW is somewhere under the home folder, inside a Wine prefix.
            #[cfg(target_os = "linux")]
            let dialog = match std::env::var_os("HOME") {
                Some(home) => dialog.set_directory(home),
                None => dialog,
            };
            dialog.blocking_pick_folder()
        });
```

- [ ] **Step 2: The start check**

Create `apps/desktop/scripts/linux-smoke.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
# Starts the AppImage in a bare Arch Linux, the base SteamOS is built on,
# with a fake screen and nothing else a desktop would add: no WebKitGTK,
# no GTK and no tray library, so anything the AppImage forgot to carry
# fails here. Run inside the archlinux image:
#
#   docker run --rm -v "$PWD":/w archlinux bash /w/apps/desktop/scripts/linux-smoke.sh /w/<AppImage> /w/smoke
#
# Leaves screenshot.png in the out folder, to see the window drew.
set -euo pipefail
appimage=$1
out=$2
mkdir -p "$out"

# What any Linux desktop has, and the AppImage leaves to it (fonts, X,
# OpenGL): linuxdeploy's exclude list.
pacman -Sy --noconfirm --needed xorg-server-xvfb imagemagick mesa libx11 libxcb fontconfig ttf-dejavu >/dev/null

home=$(mktemp -d)
cd "$(mktemp -d)"
# No FUSE in a container: unpack instead of mounting.
cp "$appimage" app.AppImage
chmod +x app.AppImage
./app.AppImage --appimage-extract >/dev/null
# With the AppImage's own library folders, as its AppRun sets them, so only
# what it really lacks shows.
echo "Libraries not found:"
LD_LIBRARY_PATH=$(find "$PWD/squashfs-root/usr/lib" -type d | paste -sd:) \
  find squashfs-root/usr/bin -type f -executable -exec ldd {} \; | grep "not found" | sort -u || echo "  none"

Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
sleep 2
HOME=$home squashfs-root/AppRun >"$out/app.log" 2>&1 &
app=$!
sleep 20
import -window root "$out/screenshot.png" || true
if ! kill -0 "$app" 2>/dev/null; then
  echo "The app quit or crashed:"
  cat "$out/app.log"
  exit 1
fi
echo "The app is still running after 20 seconds."
kill "$app"
```

- [ ] **Step 3: The Wine check**

Create `apps/desktop/scripts/wine-check.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
# Starts a stand-in WowClassic.exe through Wine inside a made-up Lutris
# prefix, and checks rts-sync finds the install and sees the game running:
# under Wine the program file is Wine's own, so this is the only way to
# know the command line check works. Needs Wine, the mingw compiler and
# Xvfb (CI installs them).
#
#   scripts/wine-check.sh <rts-sync binary>
set -euo pipefail
rts=$(realpath "$1")
home=$(mktemp -d)
export HOME=$home WINEPREFIX=$home/Games/wow WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="

work=$(mktemp -d)
printf '#include <windows.h>\nint main(void) { Sleep(120000); return 0; }\n' >"$work/wait.c"
x86_64-w64-mingw32-gcc -o "$work/WowClassic.exe" "$work/wait.c"

xvfb-run -a wine wineboot --init
game="$WINEPREFIX/drive_c/Program Files (x86)/World of Warcraft/_classic_beta_"
mkdir -p "$game/Interface/AddOns/RoadToSixty"
echo "## Interface: 16001" >"$game/Interface/AddOns/RoadToSixty/RoadToSixty.toc"
cp "$work/WowClassic.exe" "$game/"

xvfb-run -a wine "C:\\Program Files (x86)\\World of Warcraft\\_classic_beta_\\WowClassic.exe" &
sleep 10
status=$(RTS_DATA_DIR="$work/data" "$rts" status)
echo "$status"
wineserver -k || true
grep -q "_classic_beta_ (addon developer), running" <<<"$status" || { echo "rts-sync didn't see the game running"; exit 1; }
echo "rts-sync saw the game running under Wine."
```

- [ ] **Step 4: The CI job**

In `.github/workflows/ci.yml`, replace the whole `desktop:` job (from its comment `# The desktop app's sync engine: its tests...` to the end of its `Clippy and formatting` step) with:

```yaml
  # The desktop app on Linux: every Rust test (one has LuaJIT read back the
  # sync folder it writes), clippy and formatting, then the AppImage, started
  # in a bare Arch Linux like SteamOS, and the game-start check under Wine.
  # Ubuntu 22.04, the oldest base the AppImage supports. The screenshot and
  # the AppImage are kept with the run.
  desktop-linux:
    runs-on: ubuntu-22.04
    defaults:
      run:
        working-directory: apps/desktop
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: 1.4.2

      - name: Install the build libraries, LuaJIT and Wine
        run: >
          sudo apt-get update && sudo apt-get install -y
          libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libssl-dev patchelf file
          luajit wine wine64 gcc-mingw-w64-x86-64 xvfb

      - name: Install
        run: bun install --frozen-lockfile

      - name: Window
        run: bun run build

      - name: Tests
        run: cargo test --workspace

      - name: Clippy and formatting
        run: cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check

      # No signing key on pull requests, so no updater files.
      - name: AppImage
        run: bunx tauri build --bundles appimage -c '{"bundle":{"createUpdaterArtifacts":false}}'

      - name: It starts on a bare Arch Linux
        working-directory: .
        run: >
          docker run --rm -v "$PWD":/w archlinux bash /w/apps/desktop/scripts/linux-smoke.sh
          "/w/$(ls apps/desktop/target/release/bundle/appimage/*.AppImage | head -1)" /w/smoke

      - name: Wine
        run: cargo build --bin rts-sync && scripts/wine-check.sh target/debug/rts-sync

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: linux
          path: |
            smoke/
            apps/desktop/target/release/bundle/appimage/*.AppImage
```

In the `desktop-app` job's comment, `(LuaJIT's is left to the Linux job)` stays true; leave it.

- [ ] **Step 5: Local checks**

Run (from `apps/desktop`): `bash -n scripts/linux-smoke.sh && bash -n scripts/wine-check.sh && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
Expected: no output from `bash -n`, clippy and fmt clean (the Linux-only picker code is checked in CI).

Run (from the worktree root): `bunx js-yaml .github/workflows/ci.yml >/dev/null && echo ok`
Expected: `ok` (the file parses).

- [ ] **Step 6: AGENTS.md**

In `apps/desktop/AGENTS.md`, add to the Layout list after the `scripts/latest-json.ts` paragraph:

```
- `scripts/linux-smoke.sh` starts the AppImage in a bare Arch Linux
  container (no WebKitGTK, GTK or tray library, as SteamOS may lack them)
  and saves a screenshot; `scripts/wine-check.sh` starts a stand-in
  `WowClassic.exe` through Wine and checks `rts-sync status` sees it
  running. CI's `desktop-linux` job runs both (#47).
```

In Commands, add: `bunx tauri build --bundles appimage   # the Linux AppImage (on Linux, with the libraries in ci.yml's desktop-linux job)`.

- [ ] **Step 7: Commit**

```bash
cd <worktree>
git add .github/workflows/ci.yml apps/desktop/scripts/linux-smoke.sh apps/desktop/scripts/wine-check.sh apps/desktop/src-tauri/src/commands.rs apps/desktop/AGENTS.md
git commit -m "App: build the Linux AppImage in CI and start it on a bare Arch Linux (#47)

The folder picker opens in the home folder on Linux, where the Wine
prefixes are.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Release the AppImage

**Files:**
- Modify: `apps/desktop/scripts/latest-json.ts`
- Modify: `apps/desktop/scripts/latest-json.test.ts`
- Modify: `.github/workflows/desktop-release.yml`
- Modify: `apps/desktop/AGENTS.md` (release line, start at login line)

**Interfaces:**
- Consumes: `scripts/linux-smoke.sh <AppImage> <out dir>` (Task 3).
- Produces: bucket files `app/<v>/Road-to-Sixty_<v>_amd64.AppImage` (+ `.sig`), fixed `app/Road-to-Sixty.AppImage`, and `latest.json` key `linux-x86_64`. Task 5 links `${DOWNLOADS}/app/Road-to-Sixty.AppImage`.

- [ ] **Step 1: Write the failing test**

In `apps/desktop/scripts/latest-json.test.ts`, change the test to:

```ts
test("both Mac processors get the universal build, Windows its installer, Linux its AppImage", () => {
  const json = latestJson({
    version: "0.1.0",
    base: "https://dl.example",
    pubDate: "2026-10-14T00:00:00Z",
    mac: { file: "Road-to-Sixty.app.tar.gz", signature: "m" },
    windows: { file: "Road-to-Sixty_0.1.0_x64-setup.exe", signature: "w" },
    linux: { file: "Road-to-Sixty_0.1.0_amd64.AppImage", signature: "l" },
  });
  expect(json.platforms["darwin-aarch64"]).toEqual({ url: "https://dl.example/app/0.1.0/Road-to-Sixty.app.tar.gz", signature: "m" });
  expect(json.platforms["darwin-x86_64"]).toEqual(json.platforms["darwin-aarch64"]);
  expect(json.platforms["windows-x86_64"]).toEqual({ url: "https://dl.example/app/0.1.0/Road-to-Sixty_0.1.0_x64-setup.exe", signature: "w" });
  expect(json.platforms["linux-x86_64"]).toEqual({ url: "https://dl.example/app/0.1.0/Road-to-Sixty_0.1.0_amd64.AppImage", signature: "l" });
  expect(json.version).toBe("0.1.0");
});
```

- [ ] **Step 2: Run it to see it fail**

Run (from `apps/desktop`): `bun test scripts`
Expected: FAIL (a TypeScript excess property is ignored at runtime by Bun, so the failure is `linux-x86_64` being `undefined`).

- [ ] **Step 3: Implement**

In `apps/desktop/scripts/latest-json.ts`:

```ts
export function latestJson(o: { version: string; base: string; pubDate: string; mac: Built; windows: Built; linux: Built }) {
  const at = (b: Built) => ({ url: `${o.base}/app/${o.version}/${b.file}`, signature: b.signature });
  return {
    version: o.version,
    notes: `Road to Sixty ${o.version}`,
    pub_date: o.pubDate,
    platforms: {
      "darwin-aarch64": at(o.mac),
      "darwin-x86_64": at(o.mac),
      "windows-x86_64": at(o.windows),
      "linux-x86_64": at(o.linux),
    },
  };
}
```

and in the `import.meta.main` block add after the `windows:` line:

```ts
    linux: await built(`Road-to-Sixty_${version}_amd64.AppImage`),
```

- [ ] **Step 4: Run the tests**

Run (from `apps/desktop`): `bun test scripts && bun run typecheck`
Expected: PASS.

- [ ] **Step 5: The release workflow**

In `.github/workflows/desktop-release.yml`:

1. Header comment: change the first two lines to
   `# The app's releases: an app-v* tag builds the universal Mac app, the`
   `# Windows installer and the Linux AppImage, signed for the updater, then`
   and `Nothing is uploaded unless both builds` to `Nothing is uploaded unless every build`.
2. Add to the matrix `include:`:

```yaml
          - os: ubuntu-22.04
            args: --bundles appimage
            bundle: target/release/bundle
```

3. After the `Both Mac processors` step add:

```yaml
      - name: Linux build libraries
        if: runner.os == 'Linux'
        run: >
          sudo apt-get update && sudo apt-get install -y
          libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libssl-dev patchelf file
```

4. After the `Build` step add:

```yaml
      - name: The AppImage starts on a bare Arch Linux
        if: runner.os == 'Linux'
        run: >
          docker run --rm -v "$PWD":/w archlinux bash /w/apps/desktop/scripts/linux-smoke.sh
          "/w/$(ls apps/desktop/target/release/bundle/appimage/*.AppImage | head -1)" /w/smoke
```

5. In `Collect`, replace the `if ... else ... fi` with:

```bash
          if [ "$RUNNER_OS" = macOS ]; then
            cp "$b"/dmg/*.dmg "out/Road-to-Sixty_${v}_universal.dmg"
            cp "$b"/macos/*.app.tar.gz out/Road-to-Sixty.app.tar.gz
            cp "$b"/macos/*.app.tar.gz.sig out/Road-to-Sixty.app.tar.gz.sig
          elif [ "$RUNNER_OS" = Linux ]; then
            cp "$b"/appimage/*.AppImage "out/Road-to-Sixty_${v}_amd64.AppImage"
            cp "$b"/appimage/*.AppImage.sig "out/Road-to-Sixty_${v}_amd64.AppImage.sig"
          else
            cp "$b"/nsis/*-setup.exe "out/Road-to-Sixty_${v}_x64-setup.exe"
            cp "$b"/nsis/*-setup.exe.sig "out/Road-to-Sixty_${v}_x64-setup.exe.sig"
          fi
```

6. In `Upload`, after the `Road-to-Sixty-Setup.exe` line add:

```bash
          s3 cp "out/Road-to-Sixty_${v}_amd64.AppImage" "s3://$BUCKET/app/Road-to-Sixty.AppImage" --cache-control no-cache
```

- [ ] **Step 6: Check the workflow parses**

Run (from the worktree root): `bunx js-yaml .github/workflows/desktop-release.yml >/dev/null && echo ok`
Expected: `ok`.

- [ ] **Step 7: AGENTS.md**

In `apps/desktop/AGENTS.md`:
- `Start at login is tauri-plugin-autostart (a LaunchAgent on the Mac, the per-user Run key on Windows)` becomes `Start at login is tauri-plugin-autostart (a LaunchAgent on the Mac, the per-user Run key on Windows, \`~/.config/autostart\` on Linux, pointing at the AppImage file itself, so moving the file breaks it)`.
- The `scripts/latest-json.ts` paragraph: after `which uploads the builds` add ` (the Mac app, the Windows installer and, on Ubuntu 22.04, the Linux AppImage after \`linux-smoke.sh\` passes)`.

- [ ] **Step 8: Commit**

```bash
cd <worktree>
git add apps/desktop/scripts/latest-json.ts apps/desktop/scripts/latest-json.test.ts .github/workflows/desktop-release.yml apps/desktop/AGENTS.md
git commit -m "App: release the Linux AppImage beside the Mac and Windows builds (#47)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Offer the Linux download on the website

**Files:**
- Modify: `apps/web/src/download.ts`
- Modify: `apps/web/src/download.test.ts`
- Modify: `apps/web/src/config.ts` (`fileUrl`)
- Modify: `apps/web/src/config.test.ts`
- Modify: `apps/web/src/pages/download/[platform].astro`
- Modify: `apps/web/src/pages/download/index.astro`
- Modify: `apps/web/AGENTS.md`

**Interfaces:**
- Consumes: the fixed bucket name `app/Road-to-Sixty.AppImage` (Task 4).
- Produces: `Choice` includes `"linux"`; `fileUrl(platform: "mac" | "windows" | "linux")`; page `/download/linux`.

- [ ] **Step 1: Write the failing tests**

In `apps/web/src/download.test.ts`, replace the second test with:

```ts
test("a Linux computer gets the Linux download", () => {
  expect(pick({ userAgent: linux })).toBe("linux");
  expect(pick({ userAgent: "", platform: "Linux x86_64" })).toBe("linux");
});

test("phones, tablets and anything unknown are offered every download", () => {
  expect(pick({ userAgent: iphone })).toBe("choose");
  expect(pick({ userAgent: android })).toBe("choose");
  expect(pick({ userAgent: "" })).toBe("choose");
});
```

In `apps/web/src/config.test.ts`, change the import to `import { fileUrl, link, need } from "./config";` and add:

```ts
test("each computer's download has the fixed name the release uploads", () => {
  expect(fileUrl("mac")).toBe("https://dl.roadtosixty.online/app/Road-to-Sixty.dmg");
  expect(fileUrl("windows")).toBe("https://dl.roadtosixty.online/app/Road-to-Sixty-Setup.exe");
  expect(fileUrl("linux")).toBe("https://dl.roadtosixty.online/app/Road-to-Sixty.AppImage");
});
```

(Bun's tests run without `PUBLIC_DOWNLOADS`, so `DOWNLOADS` is the default address. If a local `.env` sets it, run with `PUBLIC_DOWNLOADS= bun test`.)

- [ ] **Step 2: Run them to see them fail**

Run (from `apps/web`): `bun test src/download.test.ts src/config.test.ts`
Expected: FAIL: `pick` returns `"choose"` for Linux; `fileUrl("linux")` gives the Windows file.

- [ ] **Step 3: Implement `download.ts` and `config.ts`**

`apps/web/src/download.ts`, top comment and types:

```ts
// Which download to offer: the visitor's own computer when it is a Mac,
// Windows or Linux, every one otherwise. iPads report a Mac browser, so a
// touch screen counts against it, and Android reports Linux, so phones
// are ruled out first.
export type Choice = "mac" | "windows" | "linux" | "choose";

export function pick(nav: { userAgent: string; platform?: string; maxTouchPoints?: number }): Choice {
  const ua = nav.userAgent;
  const platform = nav.platform ?? "";
  if (/iPhone|iPad|iPod|Android/i.test(ua)) return "choose";
  if (/Windows/i.test(ua) || /^Win/i.test(platform)) return "windows";
  if (/Macintosh/i.test(ua) || /^Mac/i.test(platform)) return (nav.maxTouchPoints ?? 0) > 1 ? "choose" : "mac";
  if (/Linux/i.test(ua) || /^Linux/i.test(platform)) return "linux";
  return "choose";
}

export const LABEL: Record<Choice, string> = {
  mac: "Download for macOS",
  windows: "Download for Windows",
  linux: "Download for Linux (early)",
  choose: "Download for Mac or Windows",
};

export const PAGE: Record<Choice, string> = { mac: "/download/mac", windows: "/download/windows", linux: "/download/linux", choose: "/download" };
```

In `wireDownloads`, replace the body of the `[data-also]` loop:

```ts
  for (const line of document.querySelectorAll<HTMLElement>("[data-also]")) {
    if (choice === "choose") continue;
    // Linux points at the page with every download.
    const other: Choice = choice === "mac" ? "windows" : choice === "windows" ? "mac" : "choose";
    const link = line.querySelector<HTMLAnchorElement>("a")!;
    link.href = PAGE[other];
    link.textContent = { mac: "Mac", windows: "Windows", linux: "Linux", choose: "Mac or Windows" }[other];
    line.hidden = false;
  }
```

`apps/web/src/config.ts`, replace `fileUrl`:

```ts
// The fixed names the app's release workflow uploads (desktop-release.yml).
const FILES = { mac: "Road-to-Sixty.dmg", windows: "Road-to-Sixty-Setup.exe", linux: "Road-to-Sixty.AppImage" };
export function fileUrl(platform: keyof typeof FILES): string {
  return `${DOWNLOADS}/app/${FILES[platform]}`;
}
```

- [ ] **Step 4: Run the tests**

Run (from `apps/web`): `bun test && bun run typecheck`
Expected: PASS.

- [ ] **Step 5: The Linux download page**

Replace the frontmatter and template of `apps/web/src/pages/download/[platform].astro` with:

```astro
---
import Layout from "../../layouts/Layout.astro";
import { addonUrl, fileUrl } from "../../config";

export function getStaticPaths() {
  return [{ params: { platform: "mac" } }, { params: { platform: "windows" } }, { params: { platform: "linux" } }];
}

type Platform = "mac" | "windows" | "linux";
const platform = Astro.params.platform as Platform;
const file = fileUrl(platform);
const pages = {
  mac: {
    name: "macOS",
    heading: "Opening it the first time on a Mac",
    intro: "The app isn't signed by Apple yet, so your computer asks once before it opens it.",
    steps: [
      "Open Road-to-Sixty.dmg and drag the app into Applications.",
      "Open it. When macOS says it can't check the app, click Done.",
      "Open System Settings, then Privacy & Security, scroll down and click Open Anyway.",
      "Click Open Anyway once more and enter your password.",
    ],
    note: "On macOS 14 or earlier, right-click the app in Applications, choose Open, then click Open again.",
    other: { text: "On Windows?", href: "/download/windows", link: "Get it for Windows" },
  },
  windows: {
    name: "Windows",
    heading: "Opening it the first time on Windows",
    intro: "The app isn't signed by Microsoft yet, so your computer asks once before it opens it.",
    steps: [
      "Run Road-to-Sixty-Setup.exe.",
      "When Windows says it protected your PC, click More info.",
      "Click Run anyway. It installs for you only and needs no admin rights.",
    ],
    note: "If your browser says the file isn't commonly downloaded, choose Keep first.",
    other: { text: "On a Mac?", href: "/download/mac", link: "Get it for macOS" },
  },
  linux: {
    name: "Linux",
    heading: "Setting it up on a Steam Deck or Linux",
    intro: "The Linux app is early: it runs in Desktop Mode, and we'd love to hear how it goes on your Deck.",
    steps: [
      "On a Steam Deck, switch to Desktop Mode.",
      "Keep Road-to-Sixty.AppImage in your home folder. If you move it later, it stops opening at login.",
      "Right-click it, choose Properties, then Permissions, and tick Allow executing as program.",
      "Open it.",
      "If it doesn't find WoW, click Add a folder and pick the World of Warcraft folder inside your Proton or Lutris folder.",
      "If no icon shows by the clock, open the file again to bring the window back.",
    ],
    note: "Play in Game Mode is backed up too: the app uploads it the next time you're in Desktop Mode.",
    other: { text: "On a Mac or Windows?", href: "/download", link: "Get it here" },
  },
} satisfies Record<Platform, unknown>;
const page = pages[platform];
---
<Layout title={`Download for ${page.name} · Road to Sixty`}>
  <meta slot="head" http-equiv="refresh" content={`1; url=${file}`} />
  <meta slot="head" name="robots" content="noindex" />
  <main class="mx-auto flex max-w-xl flex-col gap-8 px-4 py-20">
    <div class="flex flex-col gap-3">
      <h1 class="text-4xl font-medium tracking-tight">Your download has started</h1>
      <p class="text-muted">If it didn't, <a href={file} class="text-text underline underline-offset-2">download it again</a>.</p>
    </div>
    <section class="flex flex-col gap-4 rounded-xl border border-line bg-panel p-6">
      <h2 class="text-lg font-medium">{page.heading}</h2>
      <p class="text-[15px] text-muted">{page.intro}</p>
      <ol class="flex list-decimal flex-col gap-2 pl-5 text-[15px] leading-relaxed text-muted">
        {page.steps.map((s) => <li>{s}</li>)}
      </ol>
      <p class="text-[15px] text-muted">{page.note}</p>
    </section>
    <p class="text-[15px] leading-relaxed text-muted">Then give this PC a name, link it with Battle.net, and restart WoW once. The app does the rest.</p>
    <p class="text-sm text-muted">
      {page.other.text} <a href={page.other.href} class="text-text underline underline-offset-2">{page.other.link}</a>.
      Just the addon? <a href={addonUrl()} class="text-text underline underline-offset-2">It works on its own</a>.
    </p>
  </main>
</Layout>
```

In `apps/web/src/pages/download/index.astro`, change the paragraph to `<p class="text-muted">The app runs on a Mac, a Windows PC, or Linux, Steam Deck included (in Desktop Mode, early).</p>` and add a third link after `For Windows`:

```astro
      <a href="/download/linux" class="inline-flex h-11 items-center justify-center rounded-[10px] bg-cream px-[18px] text-[15px] font-medium text-ink">For Linux (early)</a>
```

- [ ] **Step 6: Build the site**

Run (from `apps/web`): `PUBLIC_ADDON_URL=https://example.test PUBLIC_CONTACT_EMAIL=x@example.test bun run build && ls dist/download/linux/index.html && grep -c "Road-to-Sixty.AppImage" dist/download/linux/index.html`
Expected: the build passes, the file exists, the count is at least 1.

- [ ] **Step 7: AGENTS.md**

In `apps/web/AGENTS.md`, change the first paragraph's `the app's download for the visitor's computer with the unsigned-app steps` to `the app's download for the visitor's computer (Mac, Windows, or Linux for the Steam Deck in Desktop Mode, early, #47) with the first-run steps`.

- [ ] **Step 8: Commit**

```bash
cd <worktree>
git add apps/web
git commit -m "Website: a Linux download with the Steam Deck Desktop Mode steps (#47)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Run CI on the branch

- [ ] **Step 1: Whole-repo checks locally**

Run (from the worktree root): `bun install && bun run typecheck && (cd apps/desktop && bun run build && bun run test) && (cd apps/web && bun test)`
Expected: all pass.

- [ ] **Step 2: Push and open a draft PR into `dev`**

CI's `pull_request` trigger is what runs `desktop-linux` on a branch. Draft the PR description with the `writing-pr-descriptions` skill, show it to Jordan, and only open the PR after Jordan's go-ahead (global instructions). Then `git push -u origin linux-app` and `gh pr create --draft --base dev`.

- [ ] **Step 3: Watch `desktop-linux` to the end**

Run: `gh run watch <id> --exit-status`. Download the `linux` artifact and look at `smoke/screenshot.png`: the first-run window should be drawn, not white. If the smoke step fails with a missing library that SteamOS's desktop certainly has (fonts, X, OpenGL), add it to the `pacman` line in `linux-smoke.sh`; if it is WebKitGTK, GTK or the tray library, the AppImage must carry it, so fix the build, not the container.

- [ ] **Step 4: Post on #47**

Comment on issue #47 with what CI proved (starts on bare Arch, screenshot, Wine check) and the tester checklist from the spec's "What only a Deck can confirm".
