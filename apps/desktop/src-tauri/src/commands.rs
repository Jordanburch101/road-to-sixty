//! What the window can ask of the app. Anything that restarts the sync
//! thread runs on a thread of its own, so the window never waits on an
//! upload; it hears the outcome through the "status" event.

use std::sync::Mutex;

use rts_sync::api::Client;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

use crate::runner::{Links, Notifier, Runner};
use crate::status::Status;

#[tauri::command]
pub fn status(notifier: State<'_, Notifier>) -> Status {
    notifier.get()
}

/// Starts linking, or starts it over: an attempt already waiting on the
/// browser is retired, so a double click or a closed tab never leaves the
/// window stuck on the old code.
#[tauri::command]
pub fn link(app: AppHandle, name: String) {
    std::thread::spawn(move || {
        let notifier = app.state::<Notifier>().inner().clone();
        let links = app.state::<Links>();
        let this = links.begin();
        let name = match name.trim() {
            "" => pc_name(sysinfo::System::host_name()),
            name => name.chars().take(40).collect(),
        };
        let result = rts_sync::link::link(
            &Client::new(crate::SERVER, None),
            &name,
            |url, code| {
                notifier.update(|s| {
                    s.link_code = Some(code.to_string());
                    s.problems.clear();
                });
                let _ = app.opener().open_url(url, None::<&str>);
            },
            std::thread::sleep,
            || links.is_current(this),
        );
        if !links.is_current(this) {
            return;
        }
        match result {
            Ok(linked) => with_runner(app.clone(), move |r| r.linked(linked)),
            Err(e) => notifier.update(|s| {
                s.link_code = None;
                s.problems = vec![format!("Linking didn't finish: {e}")];
            }),
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

/// The folder picker, run here so the window knows not to hide behind it.
#[tauri::command]
pub fn pick_folder(app: AppHandle) {
    std::thread::spawn(move || {
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
        if let Some(path) = picked.and_then(|p| p.into_path().ok()) {
            with_runner(app, move |r| r.add_folder(path));
        }
    });
}

#[tauri::command]
pub fn set_paused(app: AppHandle, paused: bool) {
    with_runner(app, move |r| r.set_paused(paused));
}

#[tauri::command]
pub fn unlink(app: AppHandle) {
    with_runner(app, |r| r.unlink());
}

/// Runs a change to the runner on its own thread; a failure shows in the window.
pub fn with_runner(app: AppHandle, job: impl FnOnce(&mut Runner) -> Result<(), String> + Send + 'static) {
    std::thread::spawn(move || {
        let runner = app.state::<Mutex<Runner>>();
        let result = job(&mut runner.lock().unwrap());
        if let Err(e) = result {
            app.state::<Notifier>().update(|s| s.problems = vec![e]);
        }
    });
}

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
