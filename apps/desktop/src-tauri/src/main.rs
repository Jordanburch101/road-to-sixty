// No console window behind the app on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! The Road to Sixty app (#1): the sync engine with a menu bar or tray icon
//! and a small window for setup and status. Started at login with
//! --hidden, it stays out of sight until the player opens it.

mod account;
mod commands;
mod runner;
mod status;
mod tray;
mod update;
mod window;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use rts_sync::state::data_dir;
use tauri::{Emitter, Manager, RunEvent, WindowEvent};

use runner::{Notifier, Runner};

/// This build's version, which the server shows in the player's PC list.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The server this build talks to, set at build time for player builds.
pub const SERVER: &str = match option_env!("RTS_SERVER") {
    Some(server) => server,
    None => rts_sync::api::DEFAULT_SERVER,
};

fn main() {
    tauri::Builder::default()
        // Must come first: a second copy only shows this one's window.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| window::show(app)))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--hidden"]),
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_positioner::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            app.manage(window::Popover::default());
            let tray = tray::build(app.handle())?;
            app.manage(tray.clone());
            let handle = app.handle().clone();
            let notifier = Notifier::new(move |status| {
                tray.show(status);
                let _ = handle.emit("status", status);
            });
            let mut runner = Runner::new(SERVER, &data_dir(), Arc::new(rts_sync::sync::games), notifier.clone());
            app.manage(update::Busy(runner.busy()));
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
            runner.start()?;
            app.manage(notifier.clone());
            app.manage(account::Account::new(SERVER, &data_dir()));
            app.manage(runner::Links::default());
            app.manage(Mutex::new(runner));

            // "Synced 2 min ago" has to keep counting between passes, and
            // while nothing syncs (not linked, or no WoW yet) the app looks
            // for WoW again.
            let ticker = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(30));
                    notifier.update(|_| {});
                    commands::with_runner(ticker.clone(), |r| r.rescan());
                }
            });

            // A check at start and every six hours; what it finds installs itself.
            let app_handle = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    let _ = update::run(&app_handle);
                    std::thread::sleep(Duration::from_secs(6 * 3600));
                }
            });

            if !updated && !std::env::args().any(|a| a == "--hidden") {
                window::show(app.handle());
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window only hides it; syncing goes on.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
            if let WindowEvent::Focused(false) = event {
                window::blurred(window);
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::status,
            commands::link,
            commands::pick_folder,
            commands::host_name,
            account::characters,
            account::versions,
            account::restore,
            account::devices,
            account::rename_device,
            account::unlink_device,
            account::export_data,
            account::delete_account,
            commands::set_paused,
            commands::unlink,
            update::check_update,
            update::install_update,
        ])
        .build(tauri::generate_context!())
        .expect("the app failed to start")
        // Only the Mac's reopen uses the app handle, hence the underscore.
        .run(|_app, event| match event {
            // Only Quit in the tray menu ends the app (it passes an exit code).
            RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
            // Opening the app again on a Mac (say, from Applications while it
            // started at login) only wakes this copy; show its window.
            #[cfg(target_os = "macos")]
            RunEvent::Reopen { .. } => window::show(_app),
            _ => {}
        });
}
