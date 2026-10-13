//! The Road to Sixty app's sync engine (#1), with no window: it finds WoW
//! installs and the characters that use the addon, uploads their saved
//! journeys, and delivers the merged journeys back through the
//! RoadToSixty_Sync addon folder. The Tauri app (apps/desktop) wraps it;
//! `rts-sync` (src/bin) runs it from a terminal.

pub mod api;
pub mod inbox;
pub mod installs;
pub mod link;
