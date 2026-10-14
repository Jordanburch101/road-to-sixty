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
