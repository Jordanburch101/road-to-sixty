//! The menu bar (Mac) or tray (Windows) icon and its menu.

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};

use crate::commands::with_runner;
use crate::runner::Notifier;
use crate::status::Status;

#[derive(Clone)]
pub struct Tray {
    line: MenuItem<Wry>,
    pause: MenuItem<Wry>,
    pub(crate) update: MenuItem<Wry>,
}

pub fn build(app: &AppHandle) -> tauri::Result<Tray> {
    let line = MenuItem::with_id(app, "line", "Starting…", false, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Open Road to Sixty", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause syncing", true, None::<&str>)?;
    let update = MenuItem::with_id(app, "update", "Check for updates", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Road to Sixty", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&line, &PredefinedMenuItem::separator(app)?, &open, &pause, &update, &quit])?;
    TrayIconBuilder::with_id("main")
        .icon(Image::from_bytes(include_bytes!("../icons/32x32.png"))?)
        .tooltip("Road to Sixty")
        .menu(&menu)
        .show_menu_on_left_click(false)
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
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => crate::window::show(app),
            "pause" => {
                let paused = app.state::<Notifier>().get().paused;
                with_runner(app.clone(), move |r| r.set_paused(!paused));
            }
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
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(Tray { line, pause, update })
}

impl Tray {
    pub fn show(&self, status: &Status) {
        // A lone & would underline the next letter in the menu.
        let _ = self.line.set_text(status.line.replace('&', "&&"));
        let _ = self.pause.set_text(if status.paused { "Resume syncing" } else { "Pause syncing" });
        let _ = self.pause.set_enabled(status.linked_to.is_some());
        if let Some(text) = crate::status::update_line(&status.update) {
            let _ = self.update.set_text(text);
        }
    }
}
