//! What the app remembers between runs, in a JSON file in its data folder,
//! and the PC token, which lives in the Mac Keychain or Windows Credential
//! Manager instead (spec, "First run").

use std::collections::BTreeMap;
use std::fs;
use std::io;
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

/// Where the PC token is kept. Tests use `MemoryTokens`, so they never touch
/// the real Keychain.
pub trait Tokens {
    fn get(&self) -> Option<String>;
    fn set(&self, token: &str) -> Result<(), String>;
    fn clear(&self) -> Result<(), String>;
}

/// The system's secure store: the Mac Keychain, Windows Credential Manager,
/// or the Secret Service on Linux.
pub struct Keychain;

const SERVICE: &str = "Road to Sixty";
const ACCOUNT: &str = "PC token";

impl Tokens for Keychain {
    fn get(&self) -> Option<String> {
        keyring::Entry::new(SERVICE, ACCOUNT).ok()?.get_password().ok()
    }

    fn set(&self, token: &str) -> Result<(), String> {
        keyring::Entry::new(SERVICE, ACCOUNT)
            .and_then(|e| e.set_password(token))
            .map_err(|e| e.to_string())
    }

    fn clear(&self) -> Result<(), String> {
        match keyring::Entry::new(SERVICE, ACCOUNT).and_then(|e| e.delete_credential()) {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

#[derive(Default)]
pub struct MemoryTokens(pub std::sync::Mutex<Option<String>>);

impl Tokens for MemoryTokens {
    fn get(&self) -> Option<String> {
        self.0.lock().unwrap().clone()
    }

    fn set(&self, token: &str) -> Result<(), String> {
        *self.0.lock().unwrap() = Some(token.to_string());
        Ok(())
    }

    fn clear(&self) -> Result<(), String> {
        *self.0.lock().unwrap() = None;
        Ok(())
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
}
