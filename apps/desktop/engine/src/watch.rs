//! When to upload (spec, "While running"): a saved file is sent once it has
//! been unchanged for 10 seconds; while its game runs, at most once every
//! 15 minutes, so repeated /reloads don't flood the server; when the game
//! closes, straight away. The server is also asked for new versions every
//! few minutes, and as soon as a game starts, so the newest journey is
//! there before the player logs in.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant, SystemTime};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::api::{ApiError, Client};
use crate::installs::{self, GameFolder};
use crate::state::State;
use crate::sync::{self, Problem, Report};

pub const SETTLE: Duration = Duration::from_secs(10);
pub const WHILE_PLAYING: Duration = Duration::from_secs(15 * 60);
pub const CHECK_EVERY: Duration = Duration::from_secs(5 * 60);
/// After a failed pass (offline, server down), wait this long to try again.
pub const RETRY: Duration = Duration::from_secs(60);
/// How often to look for a game starting.
pub const LOOK_FOR_GAME: Duration = Duration::from_secs(5);

/// Notices a game starting, so other PCs' play is fetched before the player
/// logs in rather than up to five minutes later.
#[derive(Debug, Default)]
pub struct Starts {
    running: BTreeSet<PathBuf>,
}

impl Starts {
    /// Takes the game folders running now; true when one of them wasn't before.
    pub fn saw(&mut self, running: BTreeSet<PathBuf>) -> bool {
        let started = running.iter().any(|g| !self.running.contains(g));
        self.running = running;
        started
    }
}

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

/// Size and change time of each saved file, to notice changes the watcher missed.
fn stamps(games: &[GameFolder]) -> BTreeMap<PathBuf, (u64, Option<SystemTime>)> {
    games
        .iter()
        .flat_map(installs::saved_files)
        .map(|f| {
            let meta = std::fs::metadata(&f.path).ok();
            let stamp = (meta.as_ref().map_or(0, |m| m.len()), meta.and_then(|m| m.modified().ok()));
            (f.path, stamp)
        })
        .collect()
}

/// Watches each game folder's WTF for saved files, and each game folder and
/// install folder for new folders (WoW making WTF, a new game folder), which
/// set `lost` so the loop looks again. A folder that can't be watched is a
/// problem; the others are still watched.
fn watcher(games: &[GameFolder], tx: mpsc::Sender<PathBuf>, lost: Arc<AtomicBool>) -> (Option<RecommendedWatcher>, Vec<Problem>) {
    let handler = move |event: notify::Result<notify::Event>| match event {
        Ok(event) if event.need_rescan() => lost.store(true, Ordering::Relaxed),
        Ok(event) => {
            for path in event.paths {
                if path.file_name().is_some_and(|n| n == "RoadToSixty.lua") {
                    let _ = tx.send(path);
                } else if path.file_name().is_some_and(|n| n == "WTF") || !path.components().any(|c| c.as_os_str() == "WTF") {
                    lost.store(true, Ordering::Relaxed);
                }
            }
        }
        // A watcher error may mean missed events: look again.
        Err(_) => lost.store(true, Ordering::Relaxed),
    };
    let mut watcher = match notify::recommended_watcher(handler) {
        Ok(w) => w,
        Err(e) => return (None, vec![Problem::general(format!("Couldn't watch for saved games: {e}"))]),
    };
    let mut problems = Vec::new();
    for wtf in sync::watched(games) {
        if let Err(e) = watcher.watch(&wtf, RecursiveMode::Recursive) {
            problems.push(Problem::general(format!("Couldn't watch {}: {e}", wtf.display())));
        }
    }
    let mut folders: Vec<PathBuf> = games
        .iter()
        .flat_map(|g| [Some(g.path.clone()), g.path.parent().map(Path::to_path_buf)])
        .flatten()
        .collect();
    folders.sort();
    folders.dedup();
    for folder in folders {
        // Only for noticing new folders; the regular look again covers a miss.
        let _ = watcher.watch(&folder, RecursiveMode::NonRecursive);
    }
    (Some(watcher), problems)
}

/// Watches the WTF folders of the game folders `find` returns and syncs
/// until `stop` is set, calling `report` after each pass. It looks for game
/// folders and changed files again every few minutes and whenever a folder
/// appears or the watcher may have missed something, so WoW making its WTF
/// folder after the app started is noticed. Every saved journey counts as
/// changed at the start (an unchanged file is skipped by its fingerprint).
/// `busy` is true while a pass runs, so the app never restarts in the middle
/// of one.
#[allow(clippy::too_many_arguments)]
pub fn run(
    client: &Client,
    state: &mut State,
    state_path: &Path,
    cache: &Path,
    find: &dyn Fn() -> Vec<GameFolder>,
    stop: &AtomicBool,
    busy: &AtomicBool,
    mut report: impl FnMut(&Result<Report, ApiError>),
) -> notify::Result<()> {
    let (tx, rx) = mpsc::channel();
    let lost = Arc::new(AtomicBool::new(false));
    let mut games = find();
    let mut wtfs = sync::watched(&games);
    let (mut _watching, mut watch_problems) = watcher(&games, tx.clone(), lost.clone());
    let mut seen = stamps(&games);

    let mut schedule = Schedule::default();
    let start = Instant::now();
    for path in seen.keys() {
        schedule.changed(path.clone(), start.checked_sub(SETTLE).unwrap_or(start));
    }
    let mut system = sysinfo::System::new();
    let mut last_pass: Option<Instant> = None;
    let mut wait_until = start;
    let mut starts = Starts::default();
    let mut looked: Option<Instant> = None;
    while !stop.load(Ordering::Relaxed) {
        let now = Instant::now();
        let check_due = last_pass.is_none_or(|t| now.duration_since(t) >= CHECK_EVERY);
        if lost.swap(false, Ordering::Relaxed) || (check_due && last_pass.is_some()) {
            let found = find();
            let found_wtfs = sync::watched(&found);
            if found != games || found_wtfs != wtfs {
                (games, wtfs) = (found, found_wtfs);
                (_watching, watch_problems) = watcher(&games, tx.clone(), lost.clone());
            }
            let now_seen = stamps(&games);
            for (path, stamp) in &now_seen {
                if seen.get(path) != Some(stamp) {
                    schedule.changed(path.clone(), now);
                }
            }
            seen = now_seen;
        }
        for path in rx.try_iter() {
            schedule.changed(path, now);
        }
        let look = schedule.settled(now) || looked.is_none_or(|t| now.duration_since(t) >= LOOK_FOR_GAME);
        let programs = if look {
            looked = Some(now);
            running_programs(&mut system)
        } else {
            Vec::new()
        };
        let started = look
            && starts.saw(
                games
                    .iter()
                    .filter(|g| game_running(&g.path, &programs))
                    .map(|g| g.path.clone())
                    .collect(),
            );
        let playing = |file: &Path| games.iter().any(|g| file.starts_with(&g.path) && game_running(&g.path, &programs));
        let due = schedule.due(now, playing);
        if now >= wait_until && (!due.is_empty() || check_due || started) {
            busy.store(true, Ordering::SeqCst);
            let result = sync::pass(client, state, state_path, &games, cache, |f| due.contains(&f.path)).map(|mut r| {
                r.problems.extend(watch_problems.iter().cloned());
                r
            });
            busy.store(false, Ordering::SeqCst);
            match &result {
                Ok(r) => {
                    schedule.sent(&due, now);
                    // The game may hold a file while it writes it: try again
                    // after a minute instead of waiting for the next change.
                    for path in &r.unread {
                        schedule.changed(path.clone(), now + RETRY - SETTLE);
                    }
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

    #[test]
    fn a_game_starting_is_noticed_once() {
        let mut s = Starts::default();
        let beta = PathBuf::from("/wow/_classic_beta_");
        assert!(!s.saw(BTreeSet::new()));
        assert!(s.saw([beta.clone()].into()), "the game started");
        assert!(!s.saw([beta.clone()].into()), "still running is not a start");
        assert!(!s.saw(BTreeSet::new()));
        assert!(s.saw([beta].into()), "started again");
    }

    #[test]
    fn a_pass_shows_as_busy_while_it_runs() {
        use crate::api::fake;
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("wow/_classic_beta_");
        let toc = installs::addon_toc(&game);
        std::fs::create_dir_all(toc.parent().unwrap()).unwrap();
        std::fs::write(&toc, "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        let fake = fake::serve(|_, _| {
            std::thread::sleep(Duration::from_millis(800));
            (200, br#"{"characters":[]}"#.to_vec())
        });
        let (stop, busy) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
        let thread = {
            let (stop, busy, url, data) = (stop.clone(), busy.clone(), fake.url.clone(), dir.path().join("data"));
            std::thread::spawn(move || {
                let mut state = State {
                    pc: Some("pc-1".into()),
                    ..State::default()
                };
                let find = || {
                    vec![GameFolder {
                        path: game.clone(),
                        name: "_classic_beta_".into(),
                    }]
                };
                run(
                    &Client::new(&url, Some("t".into())),
                    &mut state,
                    &data.join("s.json"),
                    &data.join("j"),
                    &find,
                    &stop,
                    &busy,
                    |_| {},
                )
            })
        };
        let until = Instant::now() + Duration::from_secs(5);
        while !busy.load(Ordering::SeqCst) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(busy.load(Ordering::SeqCst), "busy while the check is out");
        stop.store(true, Ordering::Relaxed);
        thread.join().unwrap().unwrap();
        assert!(!busy.load(Ordering::SeqCst), "not busy once the pass ended");
    }

    #[test]
    fn a_wtf_folder_made_after_the_start_is_watched_and_its_file_goes_up() {
        use crate::api::fake;
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("wow/_classic_beta_");
        let toc = installs::addon_toc(&game);
        std::fs::create_dir_all(toc.parent().unwrap()).unwrap();
        std::fs::write(&toc, "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        // The watcher reports real paths (on a Mac /var is /private/var).
        let game = std::fs::canonicalize(&game).unwrap();
        let fake = fake::serve(|_, url| match url {
            "/v1/check" => (200, br#"{"characters":[]}"#.to_vec()),
            _ => (200, br#"{"version":8,"status":"queued"}"#.to_vec()),
        });
        let seen = fake.seen.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (stop, url, data, game) = (stop.clone(), fake.url.clone(), dir.path().join("data"), game.clone());
            std::thread::spawn(move || {
                let mut state = State {
                    pc: Some("pc-1".into()),
                    ..State::default()
                };
                let find = || {
                    vec![GameFolder {
                        path: game.clone(),
                        name: "_classic_beta_".into(),
                    }]
                };
                run(
                    &Client::new(&url, Some("t".into())),
                    &mut state,
                    &data.join("s.json"),
                    &data.join("j"),
                    &find,
                    &stop,
                    &AtomicBool::new(false),
                    |_| {},
                )
            })
        };
        std::thread::sleep(Duration::from_secs(2)); // started, with no WTF to watch
        let saved = game.join("WTF/Account/A1/70/Ann-Stormfist/SavedVariables");
        std::fs::create_dir_all(&saved).unwrap();
        std::fs::write(
            saved.join("RoadToSixty.lua"),
            "RoadToSixtyCharDB = {\r\n[\"rosterKey\"] = \"Ann-Test Realm\",\r\n}\r\n",
        )
        .unwrap();
        let until = Instant::now() + Duration::from_secs(30);
        let uploaded = || seen.lock().unwrap().iter().any(|s| s.url.starts_with("/v1/upload"));
        while !uploaded() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(200));
        }
        stop.store(true, Ordering::Relaxed);
        thread.join().unwrap().unwrap();
        assert!(uploaded(), "the file in the new WTF folder went up");
    }
}
