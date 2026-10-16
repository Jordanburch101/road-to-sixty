//! The addon in each game (spec 2026-10-16, addon updates): what the window
//! says about each game folder, and, below, the check and the installs.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rts_sync::addon::{self, Latest};
use rts_sync::installs::{self, GameFolder};
use rts_sync::watch;
use serde::{Deserialize, Serialize};

use crate::runner::{Notifier, local_keys, now};
use crate::status::AddonUpdated;

/// What a game folder holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Copy {
    None,
    /// A developer copy: its toc has no version filled in, or the folder is a link.
    Developer,
    Version(String),
}

pub fn copy_in(game: &Path) -> Copy {
    let toc = installs::addon_toc(game);
    if !toc.is_file() {
        return Copy::None;
    }
    if toc.parent().is_some_and(addon::is_link) {
        return Copy::Developer;
    }
    installs::addon_version(game).map_or(Copy::Developer, Copy::Version)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum FolderState {
    Current,
    /// A newer version goes in as soon as this game isn't running.
    Waiting {
        latest: String,
    },
    /// No addon yet, and the release fits this game.
    Missing {
        latest: String,
    },
    Developer,
    /// The last try failed; the next check clears it and tries again.
    Failed {
        why: String,
    },
    /// Updates are off and a newer version is out.
    Behind {
        latest: String,
    },
    /// It has the addon, but runs a client the release isn't built for.
    OtherClient,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub path: String,
    pub name: String,
    pub characters: usize,
    pub addon: Option<String>,
    /// When the app last put the addon in, Unix seconds.
    pub updated_at: Option<u64>,
    #[serde(flatten)]
    pub state: FolderState,
}

/// A game folder's state, or None when it isn't listed: one without the
/// addon is offered it only when the release fits its client.
pub fn state(
    copy: &Copy,
    client: Option<(u32, u32)>,
    latest: Option<&Latest>,
    failed: Option<&str>,
    updates: bool,
    asked: bool,
) -> Option<FolderState> {
    let fits = |l: &Latest| client.is_some_and(|c| addon::fits(c, l.interface));
    match copy {
        Copy::None => latest
            .filter(|l| fits(l))
            .map(|l| FolderState::Missing { latest: l.version.clone() }),
        Copy::Developer => Some(FolderState::Developer),
        Copy::Version(v) => Some(match latest {
            Some(l) if !fits(l) => FolderState::OtherClient,
            _ if failed.is_some() => FolderState::Failed {
                why: failed.unwrap_or_default().into(),
            },
            Some(l) if addon::newer(&l.version, v) && (updates || asked) => FolderState::Waiting { latest: l.version.clone() },
            Some(l) if addon::newer(&l.version, v) => FolderState::Behind { latest: l.version.clone() },
            _ => FolderState::Current,
        }),
    }
}

/// What the app remembers, in `addon/addon.json` in its data folder: the
/// switch, and by game folder when it last put the addon in and the last
/// failure. Its own file, so it never races the sync thread's state.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Saved {
    #[serde(default = "on")]
    updates: bool,
    #[serde(default)]
    folders: BTreeMap<PathBuf, Record>,
}

fn on() -> bool {
    true
}

impl Default for Saved {
    fn default() -> Saved {
        Saved {
            updates: true,
            folders: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Record {
    updated_at: Option<u64>,
    failed: Option<String>,
}

#[derive(Default)]
struct Inner {
    latest: Option<Latest>,
    zip: Option<Vec<u8>>,
    saved: Saved,
    /// Folders whose Update button was pressed while updates are off.
    asked: BTreeSet<PathBuf>,
    /// Folders the last tick offered the addon to: the only ones Install may write.
    offered: BTreeSet<PathBuf>,
    updated: Option<AddonUpdated>,
}

pub struct Addons {
    dir: PathBuf,
    key: String,
    inner: Mutex<Inner>,
}

impl Addons {
    /// `key` is the updater's public key from tauri.conf.json. A release
    /// downloaded before, kept in the data folder, is used again if it
    /// still passes its signature, so a start without the network still knows it.
    pub fn new(data: &Path, key: &str) -> Addons {
        let dir = data.join("addon");
        let saved = fs::read(dir.join("addon.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let latest: Option<Latest> = fs::read(dir.join("latest.json")).ok().and_then(|b| serde_json::from_slice(&b).ok());
        let zip = fs::read(dir.join("RoadToSixty.zip")).ok();
        let (latest, zip) = match (latest, zip) {
            (Some(l), Some(z)) if addon::verify(&z, &l.signature, key).is_ok() => (Some(l), Some(z)),
            _ => (None, None),
        };
        Addons {
            dir,
            key: key.into(),
            inner: Mutex::new(Inner {
                latest,
                zip,
                saved,
                ..Inner::default()
            }),
        }
    }

    /// Reads latest.json and downloads a release not seen before. Failures
    /// from the last tries are cleared, so each folder gets another try.
    pub fn check(&self) -> Result<(), String> {
        self.inner.lock().unwrap().saved.folders.values_mut().for_each(|r| r.failed = None);
        let text = addon::fetch(addon::LATEST)?;
        let latest: Latest = serde_json::from_slice(&text).map_err(|e| e.to_string())?;
        if self.inner.lock().unwrap().latest.as_ref() == Some(&latest) {
            return Ok(());
        }
        let zip = addon::fetch(&latest.zip)?;
        fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        fs::write(self.dir.join("RoadToSixty.zip"), &zip).map_err(|e| e.to_string())?;
        fs::write(self.dir.join("latest.json"), &text).map_err(|e| e.to_string())?;
        self.put_latest(latest, zip);
        Ok(())
    }

    /// When to check again: with the app's own check every six hours, or
    /// in five minutes while no release is known yet (the network wasn't up
    /// at login, say), so a first run isn't left without its Install button.
    pub fn next_check(&self) -> std::time::Duration {
        let known = self.inner.lock().unwrap().latest.is_some();
        std::time::Duration::from_secs(if known { 6 * 3600 } else { 5 * 60 })
    }

    /// Takes a release in; the tick checks its signature before installing.
    pub fn put_latest(&self, latest: Latest, zip: Vec<u8>) {
        let mut inner = self.inner.lock().unwrap();
        inner.latest = Some(latest);
        inner.zip = Some(zip);
    }

    #[cfg(test)]
    pub fn updates_on(&self) -> bool {
        self.inner.lock().unwrap().saved.updates
    }

    pub fn set_updates(&self, on: bool) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        inner.saved.updates = on;
        self.save(&inner.saved)
    }

    /// The Update button: this folder updates as if updates were on.
    pub fn update(&self, game: &Path) {
        self.inner.lock().unwrap().asked.insert(game.to_path_buf());
    }

    /// The Install button: only into a folder the last tick offered it to,
    /// at once, even with the game running: a new folder is only read at
    /// the game's next start.
    pub fn install(&self, game: &Path) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        if !inner.offered.contains(game) {
            return Err("that game folder isn't offered the addon".into());
        }
        self.put(&mut inner, game)
    }

    /// Lists every game folder with its state and puts waiting updates into
    /// games that aren't running. Runs every 30 seconds, so an update goes
    /// in soon after the game closes.
    pub fn tick(&self, picked: &[PathBuf], notifier: &Notifier) {
        let programs = watch::running_programs(&mut sysinfo::System::new());
        self.tick_with(&installs::find_installs(picked), notifier, &|game| {
            watch::game_running(game, &programs)
        });
    }

    pub fn tick_with(&self, found: &[PathBuf], notifier: &Notifier, running: &dyn Fn(&Path) -> bool) {
        let mut inner = self.inner.lock().unwrap();
        let mut folders = Vec::new();
        inner.offered.clear();
        for install in found {
            for dir in installs::game_dirs(install) {
                // A copy left aside by a swap that failed half way goes back
                // first, so the game isn't left without the addon.
                addon::recover(&installs::addons_folder(&dir.path));
                let mut found = self.folder_state(&inner, &dir.path, dir.client);
                if matches!(found, Some(FolderState::Waiting { .. })) && !running(&dir.path) {
                    let _ = self.put(&mut inner, &dir.path);
                    found = self.folder_state(&inner, &dir.path, dir.client);
                }
                let Some(state) = found else { continue };
                if matches!(state, FolderState::Missing { .. }) {
                    inner.offered.insert(dir.path.clone());
                }
                let game = GameFolder {
                    path: dir.path.clone(),
                    name: dir.name.clone(),
                };
                folders.push(Folder {
                    path: dir.path.display().to_string(),
                    name: dir.name,
                    characters: local_keys(std::slice::from_ref(&game)).len(),
                    addon: match copy_in(&dir.path) {
                        Copy::Version(v) => Some(v),
                        _ => None,
                    },
                    updated_at: inner.saved.folders.get(&dir.path).and_then(|r| r.updated_at),
                    state,
                });
            }
        }
        let (updates, updated) = (inner.saved.updates, inner.updated.take());
        drop(inner);
        notifier.update(|s| {
            s.folders = folders;
            s.addon_updates = updates;
            if updated.is_some() {
                s.addon_updated = updated;
            }
        });
    }

    fn folder_state(&self, inner: &Inner, game: &Path, client: Option<(u32, u32)>) -> Option<FolderState> {
        let failed = inner.saved.folders.get(game).and_then(|r| r.failed.as_deref());
        state(
            &copy_in(game),
            client,
            inner.latest.as_ref(),
            failed,
            inner.saved.updates,
            inner.asked.contains(game),
        )
    }

    /// Checks the release's signature and puts it into one game, noting the
    /// result. Only RoadToSixty is written.
    fn put(&self, inner: &mut Inner, game: &Path) -> Result<(), String> {
        let (Some(latest), Some(zip)) = (inner.latest.clone(), inner.zip.as_ref()) else {
            return Err("the addon hasn't downloaded yet; try again in a minute".into());
        };
        let result = addon::verify(zip, &latest.signature, &self.key)
            .and_then(|()| addon::install(&installs::addons_folder(game), zip, &latest.version));
        let record = inner.saved.folders.entry(game.to_path_buf()).or_default();
        match &result {
            Ok(()) => {
                *record = Record {
                    updated_at: Some(now()),
                    failed: None,
                };
                inner.asked.remove(game);
                inner.updated = Some(AddonUpdated {
                    version: latest.version.clone(),
                    at: now(),
                });
            }
            Err(why) => record.failed = Some(why.clone()),
        }
        let _ = self.save(&inner.saved);
        result
    }

    fn save(&self, saved: &Saved) -> Result<(), String> {
        fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        fs::write(
            self.dir.join("addon.json"),
            serde_json::to_vec_pretty(saved).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())
    }
}

/// The folders the player picked by hand, from the sync's saved state.
pub fn picked(data: &Path) -> Vec<PathBuf> {
    rts_sync::state::State::load(&data.join("state.json"))
        .map(|s| s.picked)
        .unwrap_or_default()
}

fn with_addons(app: &tauri::AppHandle, job: impl FnOnce(&Addons) -> Result<(), String> + Send + 'static) -> Result<(), String> {
    use tauri::Manager;
    let addons = app.state::<std::sync::Arc<Addons>>().inner().clone();
    let result = job(&addons);
    addons.tick(&picked(&rts_sync::state::data_dir()), &app.state::<Notifier>());
    result
}

#[tauri::command]
pub async fn install_addon(app: tauri::AppHandle, path: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || with_addons(&app, move |a| a.install(Path::new(&path))))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn update_addon(app: tauri::AppHandle, path: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        with_addons(&app, move |a| {
            a.update(Path::new(&path));
            Ok(())
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn set_addon_updates(app: tauri::AppHandle, on: bool) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || with_addons(&app, move |a| a.set_updates(on)))
        .await
        .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;
    use std::path::PathBuf;

    const ZIP: &[u8] = include_bytes!("../../engine/tests/fixtures/addon/RoadToSixty-1.10.1.zip");
    const SIG: &str = include_str!("../../engine/tests/fixtures/addon/RoadToSixty-1.10.1.zip.sig");
    const KEY: &str = include_str!("../../engine/tests/fixtures/addon/test.key.pub");
    const BUILD_INFO: &str = "Version!STRING:0|Product!STRING:0\n1.60.1.70374|wow_classic_beta\n";

    // An install with one Forever game folder, holding the addon at `version`
    // or none: the temporary folder, the install as the tick sees it (its
    // real path, as find_installs gives it), and the game folder.
    fn install_with_game(version: Option<&str>) -> (tempfile::TempDir, Vec<PathBuf>, PathBuf) {
        let install = tempfile::tempdir().unwrap();
        fs::write(install.path().join(".build.info"), BUILD_INFO).unwrap();
        let game = install.path().join("_classic_beta_");
        fs::create_dir_all(&game).unwrap();
        fs::write(game.join(".flavor.info"), "Product Flavor!STRING:0\nwow_classic_beta\n").unwrap();
        if let Some(v) = version {
            let dir = game.join("Interface/AddOns/RoadToSixty");
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("RoadToSixty.toc"), format!("## Version: {v}\n")).unwrap();
        }
        let installs = vec![fs::canonicalize(install.path()).unwrap()];
        let game = installs[0].join("_classic_beta_");
        (install, installs, game)
    }

    fn addons(data: &Path, signature: &str) -> Addons {
        let a = Addons::new(data, KEY);
        a.put_latest(
            Latest {
                version: "1.10.1".into(),
                interface: 16001,
                zip: String::new(),
                signature: signature.into(),
            },
            ZIP.to_vec(),
        );
        a
    }

    fn installed(game: &Path) -> Copy {
        copy_in(game)
    }

    #[test]
    fn the_tick_updates_a_folder_whose_game_isnt_running() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()));
        let s = notifier.get();
        assert_eq!(s.folders[0].state, FolderState::Current);
        assert_eq!(s.addon_updated.map(|u| u.version), Some("1.10.1".into()));
        assert!(s.addon_updates);
    }

    #[test]
    fn a_copy_left_aside_by_a_failed_swap_is_put_back_not_offered_again() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let addons_dir = game.join("Interface/AddOns");
        fs::rename(addons_dir.join("RoadToSixty"), addons_dir.join(".RoadToSixty-old")).unwrap();
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.tick_with(&installs, &notifier, &|_| true);
        assert_eq!(
            installed(&game),
            Copy::Version("1.10.0".into()),
            "the old copy is back, even with the game running"
        );
        assert_eq!(notifier.get().folders[0].state, FolderState::Waiting { latest: "1.10.1".into() });
    }

    #[test]
    fn without_a_release_known_the_check_comes_back_in_minutes() {
        let data = tempfile::tempdir().unwrap();
        let a = Addons::new(data.path(), KEY);
        assert_eq!(
            a.next_check(),
            std::time::Duration::from_secs(5 * 60),
            "offline at first run: try again soon"
        );
        a.put_latest(
            Latest {
                version: "1.10.1".into(),
                interface: 16001,
                zip: String::new(),
                signature: SIG.into(),
            },
            ZIP.to_vec(),
        );
        assert_eq!(a.next_check(), std::time::Duration::from_secs(6 * 3600));
    }

    #[test]
    fn the_tick_waits_for_a_running_game() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.tick_with(&installs, &notifier, &|_| true);
        assert_eq!(installed(&game), Copy::Version("1.10.0".into()), "nothing changes while it runs");
        assert_eq!(notifier.get().folders[0].state, FolderState::Waiting { latest: "1.10.1".into() });
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()), "then it goes in");
    }

    #[test]
    fn a_download_with_a_bad_signature_installs_nothing() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), "bm90IGEgc2lnbmF0dXJl");
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.0".into()));
        assert!(matches!(&notifier.get().folders[0].state, FolderState::Failed { .. }));
    }

    #[test]
    fn with_updates_off_a_copy_waits_for_its_update_button() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.set_updates(false).unwrap();
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.0".into()));
        assert_eq!(notifier.get().folders[0].state, FolderState::Behind { latest: "1.10.1".into() });
        a.update(&game);
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()));
        assert!(!Addons::new(data.path(), KEY).updates_on(), "the switch is remembered");
    }

    #[test]
    fn install_puts_the_addon_only_into_a_folder_offered_it() {
        let (_keep, installs, game) = install_with_game(None);
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        assert!(a.install(&game).is_err(), "not offered before a tick listed it");
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(notifier.get().folders[0].state, FolderState::Missing { latest: "1.10.1".into() });
        a.install(&game).unwrap();
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()));
        assert!(a.install(Path::new("/somewhere/else")).is_err());
    }

    fn latest() -> Latest {
        Latest {
            version: "1.10.1".into(),
            interface: 16001,
            zip: String::new(),
            signature: String::new(),
        }
    }
    const FOREVER: Option<(u32, u32)> = Some((1, 60));
    const ERA: Option<(u32, u32)> = Some((1, 15));
    fn v(s: &str) -> Copy {
        Copy::Version(s.into())
    }

    #[test]
    fn a_folder_without_the_addon_is_offered_it_only_on_its_client() {
        let l = latest();
        assert_eq!(
            state(&Copy::None, FOREVER, Some(&l), None, true, false),
            Some(FolderState::Missing { latest: "1.10.1".into() })
        );
        assert_eq!(
            state(&Copy::None, ERA, Some(&l), None, true, false),
            None,
            "Classic Era isn't listed"
        );
        assert_eq!(
            state(&Copy::None, None, Some(&l), None, true, false),
            None,
            "no .flavor.info: not listed"
        );
        assert_eq!(state(&Copy::None, FOREVER, None, None, true, false), None, "nothing to install yet");
    }

    #[test]
    fn an_installed_copy_reads_as_current_waiting_behind_or_another_client() {
        let l = latest();
        assert_eq!(
            state(&v("1.10.1"), FOREVER, Some(&l), None, true, false),
            Some(FolderState::Current)
        );
        assert_eq!(
            state(&v("1.11.0-beta"), FOREVER, Some(&l), None, true, false),
            Some(FolderState::Current),
            "never backwards"
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), None, true, false),
            Some(FolderState::Waiting { latest: "1.10.1".into() })
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), None, false, false),
            Some(FolderState::Behind { latest: "1.10.1".into() })
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), None, false, true),
            Some(FolderState::Waiting { latest: "1.10.1".into() }),
            "Update was pressed"
        );
        assert_eq!(
            state(&v("1.10.0"), ERA, Some(&l), None, true, false),
            Some(FolderState::OtherClient)
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, None, None, true, false),
            Some(FolderState::Current),
            "offline: nothing newer known"
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), Some("the disk is full"), true, false),
            Some(FolderState::Failed {
                why: "the disk is full".into()
            })
        );
        assert_eq!(
            state(&Copy::Developer, FOREVER, Some(&l), None, true, false),
            Some(FolderState::Developer)
        );
    }

    #[test]
    fn a_folder_reads_as_the_window_expects() {
        let f = Folder {
            path: "/wow/_classic_beta_".into(),
            name: "_classic_beta_".into(),
            characters: 2,
            addon: Some("1.10.0".into()),
            updated_at: None,
            state: FolderState::Waiting { latest: "1.10.1".into() },
        };
        let json = serde_json::to_value(&f).unwrap();
        assert_eq!(json["state"], "waiting");
        assert_eq!(json["latest"], "1.10.1");
        assert_eq!(json["updatedAt"], serde_json::Value::Null);
        assert_eq!(serde_json::to_value(FolderState::OtherClient).unwrap()["state"], "otherClient");
    }

    #[test]
    fn a_copy_is_read_from_its_toc() {
        let game = tempfile::tempdir().unwrap();
        assert_eq!(copy_in(game.path()), Copy::None);
        let dir = game.path().join("Interface/AddOns/RoadToSixty");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("RoadToSixty.toc"), "## Version: @project-version@\n").unwrap();
        assert_eq!(copy_in(game.path()), Copy::Developer);
        std::fs::write(dir.join("RoadToSixty.toc"), "## Version: 1.10.0\n").unwrap();
        assert_eq!(copy_in(game.path()), Copy::Version("1.10.0".into()));
    }
}
