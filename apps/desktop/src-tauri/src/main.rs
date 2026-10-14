// No console window behind the app on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! The Road to Sixty app (#1): the sync engine with a menu bar or tray icon
//! and a small window for setup and status. Started at login with
//! --hidden, it stays out of sight until the player opens it.

mod commands;
mod runner;
mod status;
mod tray;
mod update;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use rts_sync::state::data_dir;
use tauri::{Emitter, Manager, RunEvent, WindowEvent};

use runner::{Notifier, Runner};

/// The server this build talks to, set at build time for player builds.
pub const SERVER: &str = match option_env!("RTS_SERVER") {
    Some(server) => server,
    None => rts_sync::api::TEST_SERVER,
};

fn main() {
    tauri::Builder::default()
        // Must come first: a second copy only shows this one's window.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| tray::show_window(app)))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--hidden"]),
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let tray = tray::build(app.handle())?;
            app.manage(tray.clone());
            let handle = app.handle().clone();
            let notifier = Notifier::new(move |status| {
                tray.show(status);
                let _ = handle.emit("status", status);
            });
            let mut runner = Runner::new(SERVER, &data_dir(), Arc::new(rts_sync::sync::games), notifier.clone());
            runner.start()?;
            app.manage(notifier.clone());
            app.manage(runner::Links::default());
            app.manage(Mutex::new(runner));

            // "Synced 2 min ago" has to keep counting between passes.
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(30));
                    notifier.update(|_| {});
                }
            });

            // A quiet check at start and every six hours; the tray offers what it finds.
            let app_handle = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    if let Ok(Some(version)) = tauri::async_runtime::block_on(update::check(&app_handle)) {
                        let _ = app_handle
                            .state::<tray::Tray>()
                            .update
                            .set_text(format!("Restart to update to {version}"));
                    }
                    std::thread::sleep(Duration::from_secs(6 * 3600));
                }
            });

            if !std::env::args().any(|a| a == "--hidden") {
                tray::show_window(app.handle());
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window only hides it; syncing goes on.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::status,
            commands::link,
            commands::add_folder,
            commands::set_paused,
            commands::unlink,
            update::check_update,
            update::install_update,
        ])
        .build(tauri::generate_context!())
        .expect("the app failed to start")
        .run(|app, event| match event {
            // Only Quit in the tray menu ends the app (it passes an exit code).
            RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
            // Opening the app again on a Mac (say, from Applications while it
            // started at login) only wakes this copy; show its window.
            #[cfg(target_os = "macos")]
            RunEvent::Reopen { .. } => tray::show_window(app),
            _ => {}
        });
}
