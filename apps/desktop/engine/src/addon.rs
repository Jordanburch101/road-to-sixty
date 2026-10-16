//! The addon release the app installs (spec 2026-10-16, addon updates):
//! the bucket's latest.json, its signature, which game it fits, and putting
//! it into a game's AddOns folder without the game ever seeing half of it.

use std::time::Duration;

use base64::Engine;
use serde::{Deserialize, Serialize};

pub const LATEST: &str = "https://dl.roadtosixty.online/addon/latest.json";

/// What `addon/latest.json` says: the newest full release.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Latest {
    pub version: String,
    /// The toc's `## Interface`, which names the client it is built for.
    pub interface: u32,
    pub zip: String,
    /// The `.sig` file's text: base64 of a minisign signature.
    pub signature: String,
}

/// A version's numbers; `1.11.0-beta` counts as 1.11.0.
pub fn numbers(version: &str) -> Option<(u32, u32, u32)> {
    let mut parts = version.split(['.', '-']);
    Some((
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
    ))
}

/// Whether a is newer than b. Anything unreadable is never newer, so a
/// copy whose version can't be read is never replaced by mistake.
pub fn newer(a: &str, b: &str) -> bool {
    matches!((numbers(a), numbers(b)), (Some(a), Some(b)) if a > b)
}

/// Whether a release built for `interface` loads in a client: 16001 is 1.60.
pub fn fits(client: (u32, u32), interface: u32) -> bool {
    client == (interface / 10000, interface / 100 % 100)
}

/// Checks a download against the app updater's public key, as the updater
/// checks the app's own updates. Both come as base64 of minisign's text.
pub fn verify(data: &[u8], signature: &str, key: &str) -> Result<(), String> {
    let text = |b64: &str| {
        base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
    };
    let key = text(key)
        .and_then(|t| minisign_verify::PublicKey::decode(&t).ok())
        .ok_or("the app's key can't be read")?;
    let signature = text(signature)
        .and_then(|t| minisign_verify::Signature::decode(&t).ok())
        .ok_or("the download's signature can't be read")?;
    key.verify(data, &signature, true)
        .map_err(|_| "the download isn't signed by Road to Sixty".to_string())
}

/// A file from the downloads bucket, up to 32 MB (a release is under 1 MB).
pub fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(60)))
        .build()
        .new_agent();
    agent
        .get(url)
        .call()
        .map_err(|e| e.to_string())?
        .body_mut()
        .with_config()
        .limit(32 * 1024 * 1024)
        .read_to_vec()
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const ZIP: &[u8] = include_bytes!("../tests/fixtures/addon/RoadToSixty-1.10.1.zip");
    pub(crate) const SIG: &str = include_str!("../tests/fixtures/addon/RoadToSixty-1.10.1.zip.sig");
    pub(crate) const KEY: &str = include_str!("../tests/fixtures/addon/test.key.pub");

    #[test]
    fn versions_compare_by_their_numbers() {
        assert_eq!(numbers("1.10.0"), Some((1, 10, 0)));
        assert_eq!(numbers("1.11.0-beta"), Some((1, 11, 0)));
        assert_eq!(numbers("@project-version@"), None);
        assert!(newer("1.10.0", "1.9.0"));
        assert!(
            !newer("1.10.1", "1.11.0-beta"),
            "a beta of a later version is newer than the release"
        );
        assert!(!newer("1.10.0", "1.10.0"));
        assert!(!newer("1.10.0", "not a version"));
    }

    #[test]
    fn a_release_fits_the_client_its_interface_names() {
        assert!(fits((1, 60), 16001));
        assert!(!fits((1, 15), 16001));
        assert!(!fits((5, 5), 16001));
    }

    #[test]
    fn latest_json_reads_as_the_bucket_writes_it() {
        let text = r#"{"version":"1.10.1","interface":16001,"zip":"https://dl.roadtosixty.online/addon/RoadToSixty-1.10.1.zip","signature":"c2ln"}"#;
        let latest: Latest = serde_json::from_str(text).unwrap();
        assert_eq!((latest.version.as_str(), latest.interface), ("1.10.1", 16001));
    }

    #[test]
    fn only_a_zip_signed_with_the_key_passes() {
        assert_eq!(verify(ZIP, SIG, KEY), Ok(()));
        let mut changed = ZIP.to_vec();
        *changed.last_mut().unwrap() ^= 1;
        assert_eq!(verify(&changed, SIG, KEY), Err("the download isn't signed by Road to Sixty".into()));
        assert!(verify(ZIP, "not a signature", KEY).is_err());
        assert!(verify(ZIP, SIG, "not a key").is_err());
    }
}
