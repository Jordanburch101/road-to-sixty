//! Runs the sync engine on a thread of its own and keeps the status the
//! tray and window show. Linking, pausing, adding a game folder and
//! unlinking stop the thread, change the saved state, and start it again.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};

use rts_sync::api::{ApiError, Client, LinkResponse};
use rts_sync::installs::{self, GameFolder};
use rts_sync::state::{State, TokenFile};
use rts_sync::sync::{self, Report};
use rts_sync::watch;

use crate::status::{Character, Game, Status, apply, refresh};

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Holds the status and tells the tray and window each time it changes.
#[derive(Clone)]
pub struct Notifier {
    status: Arc<Mutex<Status>>,
    // Keeps the tray and window hearing changes in the order they happened.
    // Only update takes it; Tauri's main thread never does.
    in_order: Arc<Mutex<()>>,
    on_change: Arc<dyn Fn(&Status) + Send + Sync>,
}

impl Notifier {
    pub fn new(on_change: impl Fn(&Status) + Send + Sync + 'static) -> Notifier {
        Notifier {
            status: Arc::default(),
            in_order: Arc::default(),
            on_change: Arc::new(on_change),
        }
    }

    pub fn get(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    /// Changes the status, rewrites its clock-dependent words, and passes it on.
    /// The tray and window hear of it after the status is let go: the
    /// tray's menu calls wait for the main thread, which reads the status.
    pub fn update(&self, change: impl FnOnce(&mut Status)) {
        let _in_order = self.in_order.lock().unwrap();
        let now_shown = {
            let mut status = self.status.lock().unwrap();
            change(&mut status);
            refresh(&mut status, now());
            status.clone()
        };
        (self.on_change)(&now_shown);
    }
}

/// Numbers each press of Link, so pressing it again retires the attempt
/// before it: that one stops polling and its outcome is dropped.
#[derive(Default)]
pub struct Links(AtomicU64);

impl Links {
    pub fn begin(&self) -> u64 {
        self.0.fetch_add(1, Ordering::SeqCst) + 1
    }

    pub fn is_current(&self, n: u64) -> bool {
        self.0.load(Ordering::SeqCst) == n
    }
}

pub type Find = Arc<dyn Fn(&State) -> Vec<GameFolder> + Send + Sync>;

pub struct Runner {
    server: String,
    state_path: PathBuf,
    cache: PathBuf,
    tokens: TokenFile,
    find: Find,
    notifier: Notifier,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Runner {
    pub fn new(server: &str, data: &Path, find: Find, notifier: Notifier) -> Runner {
        Runner {
            server: server.to_string(),
            state_path: data.join("state.json"),
            cache: data.join("journeys"),
            tokens: TokenFile::new(data.join("token")),
            find,
            notifier,
            stop: Arc::default(),
            thread: None,
        }
    }

    pub fn is_running(&self) -> bool {
        self.thread.as_ref().is_some_and(|t| !t.is_finished())
    }

    /// Looks for game folders again when nothing is syncing (not linked, or
    /// no WoW found yet); a running sync looks for itself.
    pub fn rescan(&mut self) -> Result<(), String> {
        if self.is_running() { Ok(()) } else { self.start() }
    }

    /// Brings the status up to date, then syncs if this PC is linked and
    /// syncing isn't paused.
    pub fn start(&mut self) -> Result<(), String> {
        self.stop();
        let state = match State::load(&self.state_path) {
            Ok(state) => state,
            Err(e) => {
                self.notifier.update(|s| {
                    s.problems = vec![format!(
                        "The app's settings file is damaged ({e}). Unlink this PC on the Account tab and link it again to start fresh."
                    )]
                });
                return Ok(());
            }
        };
        let games = (self.find)(&state);
        let token = self.tokens.get();
        let local = local_keys(&games);
        let mut paused = false;
        self.notifier.update(|s| {
            s.linked_to = token.as_ref().and(state.battletag.clone());
            s.games = shown(&games);
            for key in &local {
                if !s.characters.iter().any(|c| &c.key == key) {
                    s.characters.push(Character {
                        key: key.clone(),
                        here: true,
                        update_addon: false,
                        uploaded: None,
                        problem: None,
                        note: String::new(),
                    });
                }
            }
            s.characters.sort_by(|a, b| a.key.cmp(&b.key));
            paused = s.paused;
        });
        if token.is_none() || state.pc.is_none() || paused || games.is_empty() {
            return Ok(());
        }

        let stop = Arc::new(AtomicBool::new(false));
        self.stop = stop.clone();
        let (server, state_path, cache, notifier, find) = (
            self.server.clone(),
            self.state_path.clone(),
            self.cache.clone(),
            self.notifier.clone(),
            self.find.clone(),
        );
        self.thread = Some(std::thread::spawn(move || {
            let client = Client::new(&server, token);
            let picked = state.picked.clone();
            let mut state = state;
            let lookup = || {
                find(&State {
                    picked: picked.clone(),
                    ..State::default()
                })
            };
            let report = |result: &Result<Report, ApiError>| {
                let games = result.as_ref().map(|r| r.games.clone()).unwrap_or_default();
                let local = local_keys(&games);
                notifier.update(|s| {
                    if result.is_ok() {
                        s.games = shown(&games);
                    }
                    apply(s, result, &local, now());
                });
            };
            if let Err(e) = watch::run(&client, &mut state, &state_path, &cache, &lookup, &stop, report) {
                notifier.update(|s| s.problems = vec![format!("Couldn't watch the game folders: {e}")]);
            }
        }));
        Ok(())
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    /// After the player approves on the link page: keep the new token,
    /// forget what was uploaded under any old link, and start again.
    pub fn linked(&mut self, linked: LinkResponse) -> Result<(), String> {
        self.stop();
        self.tokens.set(&linked.token)?;
        let mut state = State::load(&self.state_path).map_err(|e| e.to_string())?;
        state.pc = Some(linked.pc);
        state.battletag = Some(linked.battletag);
        state.uploaded.clear();
        // Another link's version ids mean other journeys.
        let _ = fs::remove_dir_all(&self.cache);
        state.save(&self.state_path).map_err(|e| e.to_string())?;
        self.notifier.update(|s| {
            s.link_code = None;
            s.problems.clear();
        });
        self.start()
    }

    pub fn unlink(&mut self) -> Result<(), String> {
        self.stop();
        self.tokens.clear()?;
        let _ = fs::remove_dir_all(&self.cache);
        // A damaged state file is replaced: unlinking is how to start fresh.
        let picked = State::load(&self.state_path).map(|s| s.picked).unwrap_or_default();
        State {
            picked,
            ..State::default()
        }
        .save(&self.state_path)
        .map_err(|e| e.to_string())?;
        self.notifier.update(|s| {
            s.characters.clear();
            s.last_synced = None;
            s.problems.clear();
        });
        self.start()
    }

    pub fn add_folder(&mut self, path: PathBuf) -> Result<(), String> {
        self.stop();
        let mut state = State::load(&self.state_path).map_err(|e| e.to_string())?;
        if !state.picked.contains(&path) {
            state.picked.push(path.clone());
            state.save(&self.state_path).map_err(|e| e.to_string())?;
        }
        let found = !installs::game_folders(&path).is_empty();
        self.start()?;
        if !found {
            self.notifier.update(|s| {
                s.problems = vec![format!(
                    "No WoW game folder with Road to Sixty in {}. Pick the World of Warcraft folder itself.",
                    path.display()
                )]
            });
        }
        Ok(())
    }

    pub fn set_paused(&mut self, paused: bool) -> Result<(), String> {
        self.stop();
        self.notifier.update(|s| s.paused = paused);
        self.start()
    }
}

fn shown(games: &[GameFolder]) -> Vec<Game> {
    games
        .iter()
        .map(|g| Game {
            path: g.path.display().to_string(),
            name: g.name.clone(),
            addon: installs::addon_version(&g.path),
        })
        .collect()
}

/// `Name-Realm` of every character with a saved file in these game folders.
pub fn local_keys(games: &[GameFolder]) -> Vec<String> {
    games
        .iter()
        .flat_map(installs::saved_files)
        .filter_map(|f| fs::read(&f.path).ok().as_deref().and_then(sync::roster_key))
        .map(|(name, realm)| format!("{name}-{realm}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rts_sync::api::fake;
    use rts_sync::installs::addon_toc;
    use std::time::{Duration, Instant};

    // A made-up character, as Forever writes the file.
    const FILE: &str = "RoadToSixtyCharDB = {\r\n[\"rosterKey\"] = \"Ann-Test Realm\",\r\n[\"version\"] = 3,\r\n}\r\n";
    const CHECK: &str = r#"{"characters":[
        {"game":"_classic_beta_","realm":"Test Realm","name":"Ann","version":null,"fingerprint":"a","replace":false,"updateAddon":false},
        {"game":"_classic_beta_","realm":"Test Realm","name":"Bob","version":null,"fingerprint":"b","replace":false,"updateAddon":false}]}"#;

    struct Setup {
        dir: tempfile::TempDir,
        runner: Runner,
        notifier: Notifier,
        tokens: TokenFile,
        _fake: fake::Fake,
    }

    fn setup(linked: bool) -> Setup {
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("wow/_classic_beta_");
        std::fs::create_dir_all(addon_toc(&game).parent().unwrap()).unwrap();
        std::fs::write(addon_toc(&game), "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        let saved = game.join("WTF/Account/ACCOUNT1/70/Ann-Stormfist/SavedVariables");
        std::fs::create_dir_all(&saved).unwrap();
        std::fs::write(saved.join("RoadToSixty.lua"), FILE).unwrap();
        let fake = fake::serve(|_, url| match url {
            "/v1/check" => (200, CHECK.as_bytes().to_vec()),
            _ => (200, br#"{"version":8,"status":"queued"}"#.to_vec()),
        });
        let data = dir.path().join("data");
        let tokens = TokenFile::new(data.join("token"));
        if linked {
            tokens.set("pc-token").unwrap();
            State {
                pc: Some("pc-1".into()),
                battletag: Some("Ann#1234".into()),
                ..State::default()
            }
            .save(&data.join("state.json"))
            .unwrap();
        }
        // Only the made-up install, never the real WoW on the machine running the tests.
        let only = GameFolder {
            path: game,
            name: "_classic_beta_".into(),
        };
        let find = Arc::new(move |state: &State| {
            let mut games = vec![only.clone()];
            for picked in &state.picked {
                games.extend(rts_sync::installs::game_folders(picked));
            }
            games
        });
        let notifier = Notifier::new(|_| {});
        let runner = Runner::new(&fake.url, &data, find, notifier.clone());
        Setup {
            dir,
            runner,
            notifier,
            tokens,
            _fake: fake,
        }
    }

    fn wait_for(notifier: &Notifier, done: impl Fn(&Status) -> bool) -> Status {
        let until = Instant::now() + Duration::from_secs(15);
        loop {
            let s = notifier.get();
            if done(&s) || Instant::now() > until {
                return s;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    #[test]
    fn the_tray_and_window_hear_of_a_change_without_the_status_held() {
        // The tray's menu calls wait for Tauri's main thread, which reads
        // the status: holding it while they run could freeze the app.
        let (tx, rx) = std::sync::mpsc::channel();
        let notifier = Arc::new(Mutex::new(None::<Notifier>));
        let inner = notifier.clone();
        let n = Notifier::new(move |_| {
            let other = inner.lock().unwrap().clone().unwrap();
            let reader = std::thread::spawn(move || other.get());
            tx.send(reader.join().is_ok()).unwrap();
        });
        *notifier.lock().unwrap() = Some(n.clone());
        std::thread::spawn(move || n.update(|s| s.paused = true));
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(2)),
            Ok(true),
            "another thread could read the status"
        );
    }

    #[test]
    fn starting_a_link_over_makes_the_older_one_stale() {
        let links = Links::default();
        let first = links.begin();
        assert!(links.is_current(first));
        let second = links.begin();
        assert!(!links.is_current(first));
        assert!(links.is_current(second));
    }

    #[test]
    fn an_unlinked_pc_says_so_and_does_not_sync() {
        let mut t = setup(false);
        t.runner.start().unwrap();
        let s = t.notifier.get();
        assert_eq!(s.line, "Not linked");
        assert_eq!(s.games.len(), 1);
        assert_eq!(s.characters[0].key, "Ann-Test Realm");
        assert!(!t.runner.is_running());
    }

    #[test]
    fn a_linked_pc_syncs_and_lists_its_characters() {
        let mut t = setup(true);
        t.runner.start().unwrap();
        let s = wait_for(&t.notifier, |s| s.last_synced.is_some());
        let rows: Vec<_> = s.characters.iter().map(|c| (c.key.as_str(), c.here)).collect();
        assert_eq!(rows, [("Ann-Test Realm", true), ("Bob-Test Realm", false)]);
        assert!(s.characters[0].uploaded.is_some());
        assert!(s.line.starts_with("Synced"), "{}", s.line);
        t.runner.stop();
        assert!(!t.runner.is_running());
    }

    #[test]
    fn starting_twice_keeps_one_sync_thread() {
        let mut t = setup(true);
        t.runner.start().unwrap();
        let first = t.runner.stop.clone();
        t.runner.start().unwrap();
        assert!(first.load(Ordering::Relaxed), "the first thread was told to stop");
        assert!(t.runner.is_running());
        t.runner.stop();
    }

    #[test]
    fn pausing_stops_syncing_until_resumed() {
        let mut t = setup(true);
        t.runner.start().unwrap();
        t.runner.set_paused(true).unwrap();
        assert!(!t.runner.is_running());
        assert_eq!(t.notifier.get().line, "Syncing paused");
        t.runner.set_paused(false).unwrap();
        assert!(t.runner.is_running());
        t.runner.stop();
    }

    #[test]
    fn linking_keeps_the_token_and_forgets_the_old_link() {
        let mut t = setup(false);
        let data = t.dir.path().join("data");
        std::fs::create_dir_all(data.join("journeys")).unwrap();
        State {
            uploaded: [(PathBuf::from("old"), "print".into())].into(),
            ..State::default()
        }
        .save(&data.join("state.json"))
        .unwrap();
        t.runner.start().unwrap();
        t.runner
            .linked(LinkResponse {
                token: "new-token".into(),
                pc: "pc-2".into(),
                battletag: "Ann#1234".into(),
            })
            .unwrap();
        assert_eq!(t.tokens.get().as_deref(), Some("new-token"));
        let state = State::load(&data.join("state.json")).unwrap();
        assert_eq!(state.pc.as_deref(), Some("pc-2"));
        assert!(state.uploaded.is_empty());
        assert!(!data.join("journeys").exists());
        assert_eq!(t.notifier.get().linked_to.as_deref(), Some("Ann#1234"));
        assert!(t.runner.is_running());
        t.runner.stop();
    }

    #[test]
    fn unlinking_forgets_the_token_but_keeps_picked_folders() {
        let mut t = setup(true);
        let data = t.dir.path().join("data");
        let mut state = State::load(&data.join("state.json")).unwrap();
        state.picked.push(PathBuf::from("/somewhere"));
        state.save(&data.join("state.json")).unwrap();
        t.runner.start().unwrap();
        t.runner.unlink().unwrap();
        assert_eq!(t.tokens.get(), None);
        let state = State::load(&data.join("state.json")).unwrap();
        assert_eq!((state.pc, state.picked), (None, vec![PathBuf::from("/somewhere")]));
        assert_eq!(t.notifier.get().line, "Not linked");
        assert!(!t.runner.is_running());
    }

    #[test]
    fn a_damaged_settings_file_is_a_problem_not_a_crash() {
        let mut t = setup(true);
        std::fs::write(t.dir.path().join("data/state.json"), "{ not json").unwrap();
        assert!(t.runner.start().is_ok());
        let problems = t.notifier.get().problems;
        assert!(problems[0].contains("settings file is damaged"), "{problems:?}");
        assert!(!t.runner.is_running());
        t.runner.unlink().unwrap();
        assert!(
            State::load(&t.dir.path().join("data/state.json")).is_ok(),
            "unlinking starts it fresh"
        );
    }

    #[test]
    fn looking_again_while_idle_finds_a_game_installed_since() {
        let t = setup(true);
        let installed = Arc::new(AtomicBool::new(false));
        let game = t.dir.path().join("wow/_classic_beta_");
        let find: Find = {
            let installed = installed.clone();
            Arc::new(move |_: &State| {
                if installed.load(Ordering::Relaxed) {
                    vec![GameFolder {
                        path: game.clone(),
                        name: "_classic_beta_".into(),
                    }]
                } else {
                    Vec::new()
                }
            })
        };
        let notifier = Notifier::new(|_| {});
        let mut runner = Runner::new(&t._fake.url, &t.dir.path().join("data"), find, notifier.clone());
        runner.start().unwrap();
        assert_eq!(notifier.get().line, "WoW not found");
        assert!(!runner.is_running());
        installed.store(true, Ordering::Relaxed);
        runner.rescan().unwrap();
        assert!(runner.is_running());
        assert_eq!(notifier.get().games.len(), 1);
        runner.stop();
    }

    #[test]
    fn a_picked_folder_without_the_addon_is_a_problem() {
        let mut t = setup(false);
        let empty = t.dir.path().join("not-wow");
        std::fs::create_dir_all(&empty).unwrap();
        t.runner.add_folder(empty.clone()).unwrap();
        t.runner.add_folder(empty.clone()).unwrap();
        let state = State::load(&t.dir.path().join("data/state.json")).unwrap();
        assert_eq!(state.picked, [empty], "kept once");
        assert!(
            t.notifier.get().problems[0].contains("No WoW game folder with Road to Sixty"),
            "{:?}",
            t.notifier.get().problems
        );
    }
}
