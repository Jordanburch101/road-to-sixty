//! When to upload (spec, "While running"): a saved file is sent once it has
//! been unchanged for 10 seconds; while its game runs, at most once every
//! 15 minutes, so repeated /reloads don't flood the server; when the game
//! closes, straight away. The server is also asked for new versions every
//! few minutes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use notify::{RecursiveMode, Watcher};

use crate::api::{ApiError, Client};
use crate::installs;
use crate::state::State;
use crate::sync::{self, Report};

pub const SETTLE: Duration = Duration::from_secs(10);
pub const WHILE_PLAYING: Duration = Duration::from_secs(15 * 60);
pub const CHECK_EVERY: Duration = Duration::from_secs(5 * 60);
/// After a failed pass (offline, server down), wait this long to try again.
pub const RETRY: Duration = Duration::from_secs(60);

/// Whether the game in `game` is running: some process's program file is
/// inside it. Process names differ by version and processor, and on a Mac
/// the program is inside the .app in the game folder.
pub fn game_running(game: &Path, programs: &[PathBuf]) -> bool {
    programs.iter().any(|p| p.starts_with(game))
}

pub fn running_programs(system: &mut sysinfo::System) -> Vec<PathBuf> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, UpdateKind};
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
    );
    system.processes().values().filter_map(|p| p.exe().map(Path::to_path_buf)).collect()
}

/// The files waiting to be uploaded, and when each last changed and was
/// last sent.
#[derive(Debug, Default)]
pub struct Schedule {
    changed: BTreeMap<PathBuf, Instant>,
    sent: BTreeMap<PathBuf, Instant>,
}

impl Schedule {
    pub fn changed(&mut self, path: PathBuf, now: Instant) {
        self.changed.insert(path, now);
    }

    /// The files to upload now. `playing` says whether a file's game runs.
    pub fn due(&self, now: Instant, playing: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
        self.changed
            .iter()
            .filter(|(path, at)| {
                let settled = now.duration_since(**at) >= SETTLE;
                let rested = !playing(path) || self.sent.get(*path).is_none_or(|t| now.duration_since(*t) >= WHILE_PLAYING);
                settled && rested
            })
            .map(|(p, _)| p.clone())
            .collect()
    }

    /// Whether any file has waited out its settle time, so it's worth
    /// looking for the game before deciding (that looks at every program).
    pub fn settled(&self, now: Instant) -> bool {
        self.changed.values().any(|at| now.duration_since(*at) >= SETTLE)
    }

    pub fn sent(&mut self, paths: &[PathBuf], now: Instant) {
        for path in paths {
            self.changed.remove(path);
            self.sent.insert(path.clone(), now);
        }
    }
}

/// Watches every game folder's WTF and syncs until `stop` is set, calling
/// `report` after each pass. Every saved journey counts as changed at the
/// start, so anything new since the app last ran goes up first (an
/// unchanged file is skipped by its fingerprint).
pub fn run(
    client: &Client,
    state: &mut State,
    state_path: &Path,
    cache: &Path,
    stop: &AtomicBool,
    mut report: impl FnMut(&Result<Report, ApiError>),
) -> notify::Result<()> {
    let games = sync::games(state);
    let (tx, rx) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if let Ok(event) = event {
            for path in event.paths {
                if path.file_name().is_some_and(|n| n == "RoadToSixty.lua") {
                    let _ = tx.send(path);
                }
            }
        }
    })?;
    for wtf in sync::watched(&games) {
        watcher.watch(&wtf, RecursiveMode::Recursive)?;
    }

    let mut schedule = Schedule::default();
    let start = Instant::now();
    for file in games.iter().flat_map(installs::saved_files) {
        schedule.changed(file.path, start.checked_sub(SETTLE).unwrap_or(start));
    }
    let mut system = sysinfo::System::new();
    let mut last_pass: Option<Instant> = None;
    let mut wait_until = start;
    while !stop.load(Ordering::Relaxed) {
        let now = Instant::now();
        for path in rx.try_iter() {
            schedule.changed(path, now);
        }
        let programs = if schedule.settled(now) {
            running_programs(&mut system)
        } else {
            Vec::new()
        };
        let playing = |file: &Path| games.iter().any(|g| file.starts_with(&g.path) && game_running(&g.path, &programs));
        let due = schedule.due(now, playing);
        let check_due = last_pass.is_none_or(|t| now.duration_since(t) >= CHECK_EVERY);
        if now >= wait_until && (!due.is_empty() || check_due) {
            let result = sync::pass(client, state, state_path, &games, cache, |f| due.contains(&f.path));
            match &result {
                Ok(_) => {
                    schedule.sent(&due, now);
                    last_pass = Some(now);
                }
                Err(_) => wait_until = now + RETRY,
            }
            report(&result);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(start: Instant, secs: u64) -> Instant {
        start + Duration::from_secs(secs)
    }

    #[test]
    fn a_file_waits_until_it_has_settled() {
        let (t0, mut s) = (Instant::now(), Schedule::default());
        s.changed(PathBuf::from("a"), t0);
        assert!(s.due(at(t0, 9), |_| false).is_empty());
        assert_eq!(s.due(at(t0, 10), |_| false), [PathBuf::from("a")]);
        s.changed(PathBuf::from("a"), at(t0, 8));
        assert!(s.due(at(t0, 10), |_| false).is_empty(), "a change restarts the wait");
    }

    #[test]
    fn while_the_game_runs_a_file_goes_up_at_most_every_15_minutes() {
        let (t0, mut s) = (Instant::now(), Schedule::default());
        let a = PathBuf::from("a");
        s.changed(a.clone(), t0);
        assert_eq!(s.due(at(t0, 10), |_| true), vec![a.clone()], "the first upload doesn't wait");
        s.sent(std::slice::from_ref(&a), at(t0, 10));
        s.changed(a.clone(), at(t0, 60));
        assert!(s.due(at(t0, 300), |_| true).is_empty());
        assert_eq!(s.due(at(t0, 910), |_| true), vec![a.clone()]);
        assert_eq!(s.due(at(t0, 300), |_| false), [a], "once the game closes, straight away");
    }

    #[test]
    fn only_a_settled_file_is_worth_looking_for_the_game() {
        let (t0, mut s) = (Instant::now(), Schedule::default());
        assert!(!s.settled(t0));
        s.changed(PathBuf::from("a"), t0);
        assert!(!s.settled(at(t0, 5)));
        assert!(s.settled(at(t0, 10)));
    }

    #[test]
    fn the_game_runs_when_a_program_inside_its_folder_does() {
        let game = Path::new("/Applications/World of Warcraft/_classic_beta_");
        let mac = PathBuf::from(
            "/Applications/World of Warcraft/_classic_beta_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic",
        );
        assert!(game_running(game, &[PathBuf::from("/usr/bin/zsh"), mac]));
        assert!(!game_running(
            game,
            &[PathBuf::from("/Applications/World of Warcraft/_retail_/Wow.app/Contents/MacOS/Wow")]
        ));
    }
}
