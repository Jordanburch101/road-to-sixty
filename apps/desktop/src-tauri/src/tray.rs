//! The menu bar (Mac) or tray (Windows) icon and its menu.

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

use crate::commands::with_runner;
use crate::runner::Notifier;
use crate::status::Status;

pub struct Tray {
    line: MenuItem<Wry>,
    pause: MenuItem<Wry>,
}

pub fn build(app: &AppHandle) -> tauri::Result<Tray> {
    let line = MenuItem::with_id(app, "line", "Starting…", false, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Open Road to Sixty", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause syncing", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Road to Sixty", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&line, &PredefinedMenuItem::separator(app)?, &open, &pause, &quit])?;
    TrayIconBuilder::with_id("main")
        .icon(Image::from_bytes(include_bytes!("../icons/32x32.png"))?)
        .tooltip("Road to Sixty")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_window(app),
            "pause" => {
                let paused = app.state::<Notifier>().get().paused;
                with_runner(app.clone(), move |r| r.set_paused(!paused));
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(Tray { line, pause })
}

impl Tray {
    pub fn show(&self, status: &Status) {
        // A lone & would underline the next letter in the menu.
        let _ = self.line.set_text(status.line.replace('&', "&&"));
        let _ = self.pause.set_text(if status.paused { "Resume syncing" } else { "Pause syncing" });
        let _ = self.pause.set_enabled(status.linked_to.is_some());
    }
}

pub fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}
