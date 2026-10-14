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

/// Why an update didn't happen. A check that can't reach the server is
/// tried again quietly at the next one; a failed download or install shows.
enum Failure {
    Check(String),
    Install(String),
}

/// The update state to show after a try that began at `before`.
fn shown(before: UpdateState, result: &Result<Option<String>, Failure>) -> UpdateState {
    match result {
        Err(Failure::Install(why)) => UpdateState::Failed { why: why.clone() },
        Ok(None) if matches!(before, UpdateState::Failed { .. }) => UpdateState::None,
        _ => before,
    }
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
    if result.is_err() {
        RESTART_NOW.store(false, Ordering::SeqCst);
    }
    app.state::<Notifier>()
        .update(|s| s.update = shown(std::mem::take(&mut s.update), &result));
    result.map_err(|(Failure::Check(why) | Failure::Install(why))| why)
}

fn install_when_idle(app: &AppHandle) -> Result<Option<String>, Failure> {
    let Some(update) = check(app).map_err(Failure::Check)? else {
        return Ok(None);
    };
    let version = update.version.clone();
    let bytes = tauri::async_runtime::block_on(update.download(|_, _| {}, || {})).map_err(|e| Failure::Install(e.to_string()))?;
    app.state::<Notifier>()
        .update(|s| s.update = UpdateState::Ready { version: version.clone() });
    let busy = app.state::<Busy>().0.clone();
    let visible = || app.get_webview_window("main").is_some_and(|w| w.is_visible().unwrap_or(false));
    // A link waiting on the browser counts as busy: a restart would lose its code.
    let busy = || busy.load(Ordering::SeqCst) || app.state::<Notifier>().get().link_code.is_some();
    while !(RESTART_NOW.load(Ordering::SeqCst) || may_restart(visible(), busy())) {
        std::thread::sleep(Duration::from_secs(5));
    }
    // Stopping the sync thread waits for a pass that began meanwhile, and
    // holding it keeps a new one from starting before the restart.
    let runner = app.state::<Mutex<Runner>>();
    let mut runner = runner.lock().unwrap();
    runner.stop();
    if let Err(e) = update.install(bytes) {
        let _ = runner.start();
        return Err(Failure::Install(e.to_string()));
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
    } else {
        app.state::<Notifier>()
            .update(|s| s.update = shown(std::mem::take(&mut s.update), &Ok(None)));
    }
    Ok(found)
}

#[tauri::command]
pub fn install_update(app: AppHandle) {
    restart_now(&app);
}

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
    fn only_a_failed_download_or_install_shows_and_a_good_check_clears_it() {
        let failed = UpdateState::Failed { why: "no space".into() };
        let offline: Result<Option<String>, Failure> = Err(Failure::Check("no network".into()));
        assert_eq!(
            shown(UpdateState::None, &offline),
            UpdateState::None,
            "a check that can't reach the server is quiet"
        );
        assert_eq!(shown(UpdateState::None, &Err(Failure::Install("no space".into()))), failed);
        assert_eq!(
            shown(failed.clone(), &Ok(None)),
            UpdateState::None,
            "nothing newer: the old failure goes"
        );
        assert_eq!(shown(failed.clone(), &offline), failed);
    }

    #[test]
    fn a_different_version_last_time_means_it_just_updated() {
        assert!(just_updated(Some("0.1.2\n"), "0.1.3"));
        assert!(!just_updated(Some("0.1.3"), "0.1.3"));
        assert!(!just_updated(None, "0.1.3"), "a first start isn't an update");
    }
}
