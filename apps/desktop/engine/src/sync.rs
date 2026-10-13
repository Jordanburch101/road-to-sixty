//! One sync pass (spec, "While running"): upload the saved journeys that
//! changed, ask the server for every character's newest merged version,
//! download the ones not already here, and write each game folder's sync
//! folder. The watcher (watch.rs) decides when a file is ready.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::api::{ApiError, Client};
use crate::inbox::{self, Delivery};
use crate::installs::{self, GameFolder, SavedFile};
use crate::state::State;

/// What a pass did, for the app to show.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// `Name-Realm` of each character uploaded.
    pub uploaded: Vec<String>,
    /// Game folders whose sync folder changed.
    pub delivered: Vec<String>,
    /// Characters whose newest version needs a newer addon on this PC.
    pub update_addon: Vec<String>,
    /// Files the server refused, with why. The rest of the pass goes on.
    pub problems: Vec<String>,
}

/// The version the addon last brought in from the sync folder, which the
/// character file records as `syncedVersion`. Sent with an upload as
/// `received`, so the server knows whether this PC has taken in a restore.
pub fn synced_version(file: &[u8]) -> Option<i64> {
    const KEY: &[u8] = b"[\"syncedVersion\"] = ";
    let at = file.windows(KEY.len()).position(|w| w == KEY)? + KEY.len();
    let digits: Vec<u8> = file[at..].iter().copied().take_while(u8::is_ascii_digit).collect();
    std::str::from_utf8(&digits).ok()?.parse().ok()
}

/// The character's name and realm from the `rosterKey` the addon saves
/// (`Name-Realm`, from UnitName and GetRealmName). Names can't hold a
/// hyphen, so the first one splits them; realms can ("Azjol-Nerub").
pub fn roster_key(file: &[u8]) -> Option<(String, String)> {
    const KEY: &[u8] = b"[\"rosterKey\"] = \"";
    let at = file.windows(KEY.len()).position(|w| w == KEY)? + KEY.len();
    let mut value = Vec::new();
    let mut bytes = file[at..].iter();
    while let Some(&b) = bytes.next() {
        match b {
            b'"' => break,
            b'\\' => value.push(*bytes.next()?),
            b'\n' | b'\r' => return None,
            b => value.push(b),
        }
    }
    let text = String::from_utf8(value).ok()?;
    let (name, realm) = text.split_once('-')?;
    (!name.is_empty() && !realm.is_empty()).then(|| (name.to_string(), realm.to_string()))
}

pub fn fingerprint(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn key(name: &str, realm: &str) -> String {
    format!("{name}-{realm}")
}

/// Uploads one saved file unless this exact file was uploaded before.
/// Returns the character's `Name-Realm` when it was sent.
pub fn upload(client: &Client, state: &mut State, file: &SavedFile, addon: Option<&str>) -> Result<Option<String>, ApiError> {
    // The game may hold the file while it writes it: try again later.
    let bytes = fs::read(&file.path).map_err(|e| ApiError::Network(format!("couldn't read {}: {e}", file.path.display())))?;
    let print = fingerprint(&bytes);
    if state.uploaded.get(&file.path) == Some(&print) {
        return Ok(None);
    }
    let Some((name, realm)) = roster_key(&bytes) else {
        return Err(ApiError::Status(
            0,
            format!("{} has no rosterKey: log in once with the updated addon", file.path.display()),
        ));
    };
    client.upload(&file.game, &realm, &name, addon, synced_version(&bytes), &bytes)?;
    state.uploaded.insert(file.path.clone(), print);
    Ok(Some(key(&name, &realm)))
}

/// Asks for every character's newest version and writes it into the sync
/// folder of each game folder here. Journeys are kept in `cache` by version,
/// so each is downloaded once.
pub fn deliver(client: &Client, pc: &str, games: &[GameFolder], cache: &Path, report: &mut Report) -> Result<(), ApiError> {
    let check = client.check()?;
    let mut by_game: BTreeMap<&str, Vec<Delivery>> = BTreeMap::new();
    let mut kept = BTreeSet::new();
    for entry in &check.characters {
        if entry.update_addon {
            report.update_addon.push(key(&entry.name, &entry.realm));
        }
        let Some(version) = entry.version else { continue };
        if !games.iter().any(|g| g.name == entry.game) {
            continue;
        }
        let who = key(&entry.name, &entry.realm);
        match journey(client, cache, version, &entry.fingerprint) {
            Ok((path, journey)) => {
                kept.insert(path);
                by_game.entry(&entry.game).or_default().push(Delivery {
                    key: who,
                    version,
                    replace: entry.replace,
                    journey,
                });
            }
            Err(e @ (ApiError::Unauthorized | ApiError::Network(_))) => return Err(e),
            Err(e) => report.problems.push(format!("{who}: {e}")),
        }
    }
    for game in games {
        let mut deliveries = by_game.get(game.name.as_str()).cloned().unwrap_or_default();
        deliveries.sort_by(|a, b| a.key.cmp(&b.key));
        match inbox::write(&game.path, pc, &deliveries) {
            Ok(true) => report.delivered.push(game.name.clone()),
            Ok(false) => {}
            Err(e) => report
                .problems
                .push(format!("couldn't write the sync folder in {}: {e}", game.path.display())),
        }
    }
    for old in fs::read_dir(cache).into_iter().flatten().flatten().map(|e| e.path()) {
        if !kept.contains(&old) {
            let _ = fs::remove_file(old);
        }
    }
    Ok(())
}

/// One version's journey, from the cache when the cached copy is the one
/// the server means: version ids differ between servers, and a cache file
/// can be cut short. Otherwise downloaded, checked, and cached by writing a
/// temporary file and renaming it.
fn journey(client: &Client, cache: &Path, version: i64, print: &str) -> Result<(PathBuf, String), ApiError> {
    let path = cache.join(format!("{version}.lua"));
    if let Ok(text) = fs::read_to_string(&path)
        && fingerprint(text.as_bytes()) == print
    {
        return Ok((path, text));
    }
    let text = client.download(version)?;
    if fingerprint(text.as_bytes()) != print {
        return Err(ApiError::Status(
            200,
            format!("version {version} doesn't match the server's fingerprint"),
        ));
    }
    let temp = path.with_extension("tmp");
    fs::create_dir_all(cache)
        .and_then(|()| fs::write(&temp, &text))
        .and_then(|()| fs::rename(&temp, &path))
        .map_err(|e| ApiError::Status(0, format!("couldn't keep version {version}: {e}")))?;
    Ok((path, text))
}

/// One whole pass. `ready` says which changed files to upload now (the
/// watcher's settle and rate rules); the state is saved after each upload.
/// A 401 or no answer stops the pass: link again, or try later.
pub fn pass(
    client: &Client,
    state: &mut State,
    state_path: &Path,
    games: &[GameFolder],
    cache: &Path,
    ready: impl Fn(&SavedFile) -> bool,
) -> Result<Report, ApiError> {
    let mut report = Report::default();
    for game in games {
        let addon = installs::addon_version(&game.path);
        for file in installs::saved_files(game).iter().filter(|f| ready(f)) {
            match upload(client, state, file, addon.as_deref()) {
                Ok(Some(sent)) => {
                    report.uploaded.push(sent);
                    state.save(state_path).map_err(|e| ApiError::Status(0, e.to_string()))?;
                }
                Ok(None) => {}
                Err(e @ (ApiError::Unauthorized | ApiError::Network(_))) => return Err(e),
                Err(e) => report.problems.push(e.to_string()),
            }
        }
    }
    let pc = state.pc.clone().ok_or(ApiError::Unauthorized)?;
    deliver(client, &pc, games, cache, &mut report)?;
    Ok(report)
}

/// Every game folder with the addon, in every install found.
pub fn games(state: &State) -> Vec<GameFolder> {
    installs::find_installs(&state.picked)
        .iter()
        .flat_map(|i| installs::game_folders(i))
        .collect()
}

/// The paths a pass looks at, for the watcher: each game folder's WTF.
pub fn watched(games: &[GameFolder]) -> Vec<PathBuf> {
    games.iter().map(|g| g.path.join("WTF")).filter(|p| p.is_dir()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::fake;
    use crate::inbox::sync_folder;
    use crate::installs::addon_toc;

    // As Forever writes it: no indentation, and the character's folder
    // doesn't name the realm the addon uses.
    const FILE: &str =
        "\r\nRoadToSixtyCharDB = {\r\n[\"syncedVersion\"] = 7,\r\n[\"rosterKey\"] = \"Ann-Test Realm\",\r\n[\"version\"] = 3,\r\n}\r\n";

    fn game() -> (tempfile::TempDir, GameFolder) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("_classic_beta_");
        fs::create_dir_all(addon_toc(&path).parent().unwrap()).unwrap();
        fs::write(addon_toc(&path), "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        let saved = path.join("WTF/Account/ACCOUNT1/70/Ann-Stormfist/SavedVariables");
        fs::create_dir_all(&saved).unwrap();
        fs::write(saved.join("RoadToSixty.lua"), FILE).unwrap();
        (
            dir,
            GameFolder {
                path,
                name: "_classic_beta_".into(),
            },
        )
    }

    #[test]
    fn roster_key_splits_at_the_first_hyphen() {
        assert_eq!(roster_key(FILE.as_bytes()), Some(("Ann".into(), "Test Realm".into())));
        assert_eq!(
            roster_key(b"[\"rosterKey\"] = \"Zo\xc3\xab-Azjol-Nerub\","),
            Some(("Zoë".into(), "Azjol-Nerub".into()))
        );
        assert_eq!(roster_key(b"[\"rosterKey\"] = \"NoRealm\","), None);
        assert_eq!(roster_key(b"RoadToSixtyCharDB = {}"), None);
    }

    #[test]
    fn synced_version_reads_the_number_the_addon_saved() {
        assert_eq!(synced_version(FILE.as_bytes()), Some(7));
        assert_eq!(synced_version(b"RoadToSixtyCharDB = {}"), None);
    }

    #[test]
    fn a_pass_uploads_a_changed_file_once_and_delivers_each_version_once() {
        let (dir, game) = game();
        let ann = fingerprint(b"{[\"version\"]=3,}");
        let fake = fake::serve(move |_, url| {
            if url.starts_with("/v1/upload") {
                (200, br#"{"version":8,"status":"queued"}"#.to_vec())
            } else if url == "/v1/check" {
                (200, r#"{"characters":[
                    {"game":"_classic_beta_","realm":"Test Realm","name":"Ann","version":9,"fingerprint":"ANN","replace":false,"updateAddon":false},
                    {"game":"_classic_era_","realm":"Other","name":"Elsewhere","version":4,"fingerprint":"g","replace":false,"updateAddon":false},
                    {"game":"_classic_beta_","realm":"Test Realm","name":"Old","version":null,"fingerprint":"h","replace":false,"updateAddon":true}]}"#
                    .replace("ANN", &ann).into_bytes())
            } else {
                (200, zstd::encode_all(&b"{[\"version\"]=3,}"[..], 3).unwrap())
            }
        });
        let client = Client::new(&fake.url, Some("t".into()));
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let (state_path, cache) = (dir.path().join("state.json"), dir.path().join("journeys"));

        let report = pass(&client, &mut state, &state_path, std::slice::from_ref(&game), &cache, |_| true).unwrap();
        assert_eq!(report.uploaded, ["Ann-Test Realm"]);
        assert_eq!(report.delivered, ["_classic_beta_"]);
        assert_eq!(report.update_addon, ["Old-Test Realm"]);
        let data = fs::read_to_string(sync_folder(&game.path).join("data.lua")).unwrap();
        assert!(
            data.contains(r#"["Ann-Test Realm"] = { version = 9, replace = false, journey = "{[\"version\"]=3,}" }"#),
            "{data}"
        );
        assert!(!data.contains("Elsewhere"));
        let upload = fake.seen.lock().unwrap()[0].url.clone();
        assert_eq!(
            upload,
            "/v1/upload?game=_classic_beta_&realm=Test%20Realm&name=Ann&addon=1.9.0&received=7"
        );

        let again = pass(&client, &mut state, &state_path, &[game], &cache, |_| true).unwrap();
        assert_eq!((again.uploaded.len(), again.delivered.len()), (0, 0));
        let urls: Vec<String> = fake.seen.lock().unwrap().iter().map(|s| s.url.clone()).collect();
        assert_eq!(urls.iter().filter(|u| u.starts_with("/v1/upload")).count(), 1);
        assert_eq!(urls.iter().filter(|u| u.starts_with("/v1/versions/")).count(), 1);
        assert_eq!(State::load(&state_path).unwrap().uploaded.len(), 1);
    }

    #[test]
    fn a_file_from_an_older_addon_is_a_problem_and_not_sent() {
        let (dir, game) = game();
        let file = installs::saved_files(&game).remove(0);
        fs::write(&file.path, "RoadToSixtyCharDB = {}").unwrap();
        let fake = fake::serve(|_, _| (200, br#"{"characters":[]}"#.to_vec()));
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let report = pass(
            &Client::new(&fake.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            &[game],
            &dir.path().join("j"),
            |_| true,
        )
        .unwrap();
        assert!(
            report.problems[0].contains("log in once with the updated addon"),
            "{:?}",
            report.problems
        );
        assert!(fake.seen.lock().unwrap().iter().all(|s| !s.url.starts_with("/v1/upload")));
    }

    #[test]
    fn a_refused_file_is_a_problem_but_unlinked_stops_the_pass() {
        let (dir, game) = game();
        let refused = fake::serve(|_, url| {
            if url.starts_with("/v1/upload") {
                (413, b"too big".to_vec())
            } else {
                (200, br#"{"characters":[]}"#.to_vec())
            }
        });
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let report = pass(
            &Client::new(&refused.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            std::slice::from_ref(&game),
            &dir.path().join("j"),
            |_| true,
        )
        .unwrap();
        assert_eq!(report.problems.len(), 1);
        assert!(state.uploaded.is_empty());

        let unlinked = fake::serve(|_, _| (401, b"{}".to_vec()));
        let result = pass(
            &Client::new(&unlinked.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            &[game],
            &dir.path().join("j"),
            |_| true,
        );
        assert_eq!(result, Err(ApiError::Unauthorized));
    }

    // A check that offers each journey in `served` (name, version, text)
    // in the beta folder, with its real fingerprint; downloads answer from
    // the same list, except versions in `broken`, which answer `bad`.
    fn server(served: &'static [(&'static str, i64, &'static str)], bad: Option<(i64, Vec<u8>)>) -> fake::Fake {
        fake::serve(move |_, url| {
            if url == "/v1/check" {
                let list: Vec<String> = served
                    .iter()
                    .map(|(name, v, text)| {
                        format!(
                            r#"{{"game":"_classic_beta_","realm":"Test Realm","name":"{name}","version":{v},"fingerprint":"{}","replace":false,"updateAddon":false}}"#,
                            fingerprint(text.as_bytes())
                        )
                    })
                    .collect();
                return (200, format!(r#"{{"characters":[{}]}}"#, list.join(",")).into_bytes());
            }
            let version: i64 = url.trim_start_matches("/v1/versions/").parse().unwrap_or(-1);
            if let Some((v, body)) = &bad
                && *v == version
            {
                return (200, body.clone());
            }
            match served.iter().find(|(_, v, _)| *v == version) {
                Some((_, _, text)) => (200, zstd::encode_all(text.as_bytes(), 3).unwrap()),
                None => (404, b"no such version".to_vec()),
            }
        })
    }

    fn deliver_once(fake: &fake::Fake, games: &[GameFolder], cache: &Path) -> Report {
        let mut report = Report::default();
        deliver(&Client::new(&fake.url, Some("t".into())), "pc-1", games, cache, &mut report).unwrap();
        report
    }

    #[test]
    fn a_cached_journey_that_isnt_the_one_the_server_means_is_downloaded_again() {
        let (dir, game) = game();
        let cache = dir.path().join("journeys");
        fs::create_dir_all(&cache).unwrap();
        // From another server, or cut short by a full disk.
        fs::write(cache.join("9.lua"), "{[\"someone\"]=\"else\",}").unwrap();
        let fake = server(&[("Ann", 9, "{[\"ann\"]=true,}")], None);
        deliver_once(&fake, std::slice::from_ref(&game), &cache);
        let data = fs::read_to_string(sync_folder(&game.path).join("data.lua")).unwrap();
        assert!(data.contains(r#"journey = "{[\"ann\"]=true,}""#), "{data}");
        assert_eq!(fs::read_to_string(cache.join("9.lua")).unwrap(), "{[\"ann\"]=true,}");
    }

    #[test]
    fn one_bad_journey_is_a_problem_and_the_others_are_still_delivered() {
        let (dir, game) = game();
        let fake = server(
            &[("Ann", 9, "{[\"ann\"]=true,}"), ("Bob", 10, "{}")],
            Some((10, zstd::encode_all(&[0xff, 0xfe][..], 3).unwrap())),
        );
        let report = deliver_once(&fake, std::slice::from_ref(&game), &dir.path().join("journeys"));
        assert_eq!(report.problems.len(), 1, "{:?}", report.problems);
        let data = fs::read_to_string(sync_folder(&game.path).join("data.lua")).unwrap();
        assert!(data.contains("Ann-Test Realm") && !data.contains("Bob-Test Realm"), "{data}");
    }

    #[test]
    fn two_game_folders_with_one_name_both_get_the_journeys() {
        let (dir, game) = game();
        let other = tempfile::tempdir().unwrap();
        let second = GameFolder {
            path: other.path().join("_classic_beta_"),
            name: game.name.clone(),
        };
        fs::create_dir_all(addon_toc(&second.path).parent().unwrap()).unwrap();
        fs::write(addon_toc(&second.path), "## Interface: 16001\n").unwrap();
        let fake = server(&[("Ann", 9, "{}")], None);
        deliver_once(&fake, &[game.clone(), second.clone()], &dir.path().join("journeys"));
        for folder in [&game, &second] {
            let data = fs::read_to_string(sync_folder(&folder.path).join("data.lua")).unwrap();
            assert!(data.contains("Ann-Test Realm"), "{}: {data}", folder.path.display());
        }
    }

    #[test]
    fn a_server_error_on_upload_stops_the_pass_so_the_file_is_tried_again() {
        let (dir, game) = game();
        let down = fake::serve(|_, url| {
            if url.starts_with("/v1/upload") {
                (503, b"storage down".to_vec())
            } else {
                (200, br#"{"characters":[]}"#.to_vec())
            }
        });
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let result = pass(
            &Client::new(&down.url, Some("t".into())),
            &mut state,
            &dir.path().join("s.json"),
            &[game],
            &dir.path().join("j"),
            |_| true,
        );
        assert!(matches!(result, Err(ApiError::Network(_))), "{result:?}");
        assert!(state.uploaded.is_empty());
    }
}
