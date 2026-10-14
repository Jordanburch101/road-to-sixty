//! What the app remembers between runs, in a JSON file in its data folder,
//! and the PC token, in a file of its own beside it (spec, "First run").

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct State {
    /// This PC's ID from linking; the addon keeps its counts under it.
    pub pc: Option<String>,
    /// Who the PC is linked to, to show.
    pub battletag: Option<String>,
    /// Install folders the player picked by hand.
    #[serde(default)]
    pub picked: Vec<PathBuf>,
    /// The fingerprint of the last upload of each saved file, by path, so an
    /// unchanged file isn't sent again.
    #[serde(default)]
    pub uploaded: BTreeMap<PathBuf, String>,
    /// Saved files that were refused, by path. Each stays a problem, without
    /// being sent again, until the file changes and goes up.
    #[serde(default)]
    pub refused: BTreeMap<PathBuf, Refused>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Refused {
    pub fingerprint: String,
    /// The character, as the app shows it.
    pub who: String,
    /// Why, in words for the player.
    pub why: String,
}

impl State {
    /// The saved state, or a fresh one when there is none yet.
    pub fn load(path: &Path) -> io::Result<State> {
        match fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(io::Error::other),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(e),
        }
    }

    /// Written beside the old file and renamed over it, so a crash never
    /// leaves half a file.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
        let temp = path.with_extension("tmp");
        fs::write(&temp, serde_json::to_vec_pretty(self).map_err(io::Error::other)?)?;
        fs::rename(&temp, path)
    }
}

/// The app's own folder for its state and downloaded journeys.
pub fn data_dir() -> PathBuf {
    dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("Road to Sixty")
}

/// The PC token, in a file only this user can read. Not in the Mac
/// Keychain: an app without a paid Apple signature would be asked for it
/// after every update, and players wouldn't know why. Kept apart from
/// state.json, so that file can be shared when asking for help.
pub struct TokenFile(PathBuf);

impl TokenFile {
    pub fn new(path: PathBuf) -> TokenFile {
        TokenFile(path)
    }

    pub fn get(&self) -> Option<String> {
        let token = fs::read_to_string(&self.0).ok()?.trim().to_string();
        (!token.is_empty()).then_some(token)
    }

    /// Written beside the old file and renamed over it. On Windows the data
    /// folder is already private to this user.
    pub fn set(&self, token: &str) -> Result<(), String> {
        let write = || -> io::Result<()> {
            fs::create_dir_all(self.0.parent().unwrap_or(Path::new(".")))?;
            let temp = self.0.with_extension("tmp");
            // The mode only applies to a new file, so never reuse an old one.
            let _ = fs::remove_file(&temp);
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            options.open(&temp)?.write_all(token.as_bytes())?;
            fs::rename(&temp, &self.0)
        };
        write().map_err(|e| e.to_string())
    }

    pub fn clear(&self) -> Result<(), String> {
        match fs::remove_file(&self.0) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_saves_and_loads_and_starts_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("state.json");
        assert_eq!(State::load(&path).unwrap(), State::default());
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        state.uploaded.insert(PathBuf::from("/wow/x.lua"), "ab".into());
        state.save(&path).unwrap();
        assert_eq!(State::load(&path).unwrap(), state);
        assert!(!path.with_extension("tmp").exists());
    }

    #[test]
    fn a_damaged_state_file_is_an_error_not_a_fresh_start() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        fs::write(&path, "{ not json").unwrap();
        assert!(State::load(&path).is_err());
    }

    #[test]
    fn the_token_file_keeps_the_token_for_this_user_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("data").join("token");
        let tokens = TokenFile::new(path.clone());
        assert_eq!(tokens.get(), None);
        tokens.set("t-123").unwrap();
        tokens.set("t-456").unwrap();
        assert_eq!(tokens.get().as_deref(), Some("t-456"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        tokens.clear().unwrap();
        assert_eq!(tokens.get(), None);
        tokens.clear().unwrap();
    }
}
