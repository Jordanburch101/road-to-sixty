//! Runs the sync engine on a thread of its own and keeps the status the
//! tray and window show. Linking, pausing, adding a game folder and
//! unlinking stop the thread, change the saved state, and start it again.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};

use rts_sync::api::{ApiError, Client, LinkResponse};
use rts_sync::installs::{self, GameFolder};
use rts_sync::state::{State, Tokens};
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
    on_change: Arc<dyn Fn(&Status) + Send + Sync>,
}

impl Notifier {
    pub fn new(on_change: impl Fn(&Status) + Send + Sync + 'static) -> Notifier {
        Notifier {
            status: Arc::default(),
            on_change: Arc::new(on_change),
        }
    }

    pub fn get(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    /// Changes the status, rewrites its clock-dependent words, and passes it on.
    pub fn update(&self, change: impl FnOnce(&mut Status)) {
        let mut status = self.status.lock().unwrap();
        change(&mut status);
        refresh(&mut status, now());
        (self.on_change)(&status);
    }
}

pub type Find = Arc<dyn Fn(&State) -> Vec<GameFolder> + Send + Sync>;

pub struct Runner {
    server: String,
    state_path: PathBuf,
    cache: PathBuf,
    tokens: Arc<dyn Tokens + Send + Sync>,
    find: Find,
    notifier: Notifier,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Runner {
    pub fn new(server: &str, data: &Path, tokens: Arc<dyn Tokens + Send + Sync>, find: Find, notifier: Notifier) -> Runner {
        Runner {
            server: server.to_string(),
            state_path: data.join("state.json"),
            cache: data.join("journeys"),
            tokens,
            find,
            notifier,
            stop: Arc::default(),
            thread: None,
        }
    }

    #[cfg(test)]
    pub fn is_running(&self) -> bool {
        self.thread.as_ref().is_some_and(|t| !t.is_finished())
    }

    /// Brings the status up to date, then syncs if this PC is linked and
    /// syncing isn't paused.
    pub fn start(&mut self) -> Result<(), String> {
        self.stop();
        let state = State::load(&self.state_path).map_err(|e| e.to_string())?;
        let games = (self.find)(&state);
        let token = self.tokens.get();
        let local = local_keys(&games);
        let mut paused = false;
        self.notifier.update(|s| {
            s.linked_to = token.as_ref().and(state.battletag.clone());
            s.games = games
                .iter()
                .map(|g| Game {
                    path: g.path.display().to_string(),
                    name: g.name.clone(),
                    addon: installs::addon_version(&g.path),
                })
                .collect();
            for key in &local {
                if !s.characters.iter().any(|c| &c.key == key) {
                    s.characters.push(Character {
                        key: key.clone(),
                        here: true,
                        update_addon: false,
                        uploaded: None,
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
        let (server, state_path, cache, notifier) = (
            self.server.clone(),
            self.state_path.clone(),
            self.cache.clone(),
            self.notifier.clone(),
        );
        self.thread = Some(std::thread::spawn(move || {
            let client = Client::new(&server, token);
            let mut state = state;
            let report = |result: &Result<Report, ApiError>| {
                let local = local_keys(&games);
                notifier.update(|s| apply(s, result, &local, now()));
            };
            if let Err(e) = watch::run(&client, &mut state, &state_path, &cache, &games, &stop, report) {
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
        let state = State::load(&self.state_path).map_err(|e| e.to_string())?;
        State {
            picked: state.picked,
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
    use rts_sync::state::MemoryTokens;
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
        tokens: Arc<MemoryTokens>,
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
        let tokens = Arc::new(MemoryTokens::default());
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
        let runner = Runner::new(&fake.url, &data, tokens.clone(), find, notifier.clone());
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
