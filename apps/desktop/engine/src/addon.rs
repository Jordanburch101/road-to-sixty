//! The addon release the app installs (spec 2026-10-16, addon updates):
//! the bucket's latest.json, its signature, which game it fits, and putting
//! it into a game's AddOns folder without the game ever seeing half of it.

use std::fs;
use std::io;
use std::path::{Component, Path};
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

const NAME: &str = "RoadToSixty";
const NEW: &str = ".RoadToSixty-new";
const OLD: &str = ".RoadToSixty-old";

/// Whether a folder is a link, as the developer copy is (a junction on
/// Windows counts too).
pub fn is_link(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink())
}

/// Puts a verified release into a game's AddOns folder.
pub fn install(addons: &Path, zip: &[u8]) -> Result<(), String> {
    install_with(addons, zip, |from, to| fs::rename(from, to))
}

/// The release is unpacked beside the old copy and swapped in by renaming,
/// so the game never sees half of it; a failed swap puts the old one back.
/// WoW loads neither leftover name: an addon folder loads only when its toc
/// has the folder's own name.
pub fn install_with(addons: &Path, zip: &[u8], mut rename: impl FnMut(&Path, &Path) -> io::Result<()>) -> Result<(), String> {
    let target = crate::installs::child(addons, NAME);
    if is_link(&target) {
        return Err("the addon folder is a link to a developer copy".into());
    }
    let (new, old) = (addons.join(NEW), addons.join(OLD));
    for leftover in [&new, &old] {
        if leftover.exists() {
            fs::remove_dir_all(leftover).map_err(words)?;
        }
    }
    fs::create_dir_all(addons).map_err(words)?;
    if let Err(e) = unpack(zip, &new) {
        let _ = fs::remove_dir_all(&new);
        return Err(e);
    }
    let had = target.exists();
    if had && let Err(e) = rename(&target, &old) {
        let _ = fs::remove_dir_all(&new);
        return Err(words(e));
    }
    if let Err(e) = rename(&new.join(NAME), &target) {
        if had {
            let _ = rename(&old, &target);
        }
        let _ = fs::remove_dir_all(&new);
        return Err(words(e));
    }
    let _ = fs::remove_dir_all(&new);
    if had {
        let _ = fs::remove_dir_all(&old);
    }
    Ok(())
}

/// Every entry must be a plain file or folder under `RoadToSixty/`; one
/// that isn't refuses the whole zip, so nothing lands anywhere else.
fn unpack(zip: &[u8], into: &Path) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(io::Cursor::new(zip)).map_err(|e| format!("the download isn't a zip ({e})"))?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let path = entry
            .enclosed_name()
            .filter(|p| !entry.is_symlink() && p.components().next() == Some(Component::Normal(NAME.as_ref())))
            .ok_or("the download has a file outside the addon's folder")?;
        let out = into.join(path);
        if entry.is_dir() {
            fs::create_dir_all(&out).map_err(words)?;
        } else {
            fs::create_dir_all(out.parent().unwrap_or(into)).map_err(words)?;
            let mut file = fs::File::create(&out).map_err(words)?;
            io::copy(&mut entry, &mut file).map_err(words)?;
        }
    }
    if !into.join(NAME).join("RoadToSixty.toc").is_file() {
        return Err("the download isn't the addon".into());
    }
    Ok(())
}

/// A file error in words a player can read.
fn words(e: io::Error) -> String {
    match e.kind() {
        io::ErrorKind::PermissionDenied | io::ErrorKind::ReadOnlyFilesystem => "the folder can't be written to".into(),
        io::ErrorKind::StorageFull => "the disk is full".into(),
        _ => e.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const ZIP: &[u8] = include_bytes!("../tests/fixtures/addon/RoadToSixty-1.10.1.zip");
    pub(crate) const SIG: &str = include_str!("../tests/fixtures/addon/RoadToSixty-1.10.1.zip.sig");
    pub(crate) const KEY: &str = include_str!("../tests/fixtures/addon/test.key.pub");
    use std::fs;
    use std::io::Write;
    use std::path::Path;

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    // A zip with these entries, as a hostile or broken download might be.
    fn zip_of(entries: &[(&str, &str)]) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut zip = zip::ZipWriter::new(&mut out);
        for (name, text) in entries {
            zip.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
        out.into_inner()
    }

    fn old_copy(addons: &Path) {
        fs::create_dir_all(addons.join("RoadToSixty")).unwrap();
        fs::write(addons.join("RoadToSixty/RoadToSixty.toc"), "## Version: 1.9.0\n").unwrap();
        fs::write(addons.join("RoadToSixty/Gone.lua"), "-- only in the old version\n").unwrap();
    }

    #[test]
    fn a_release_replaces_the_old_copy_whole() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        fs::create_dir_all(addons.join("RoadToSixty_Sync")).unwrap();
        install(&addons, ZIP).unwrap();
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.10.1"));
        assert!(addons.join("RoadToSixty/ZoneMasks/a.lua").is_file());
        assert!(
            !addons.join("RoadToSixty/Gone.lua").exists(),
            "nothing of the old version is left in it"
        );
        assert!(addons.join("RoadToSixty_Sync").is_dir(), "the sync folder is left alone");
        assert!(!addons.join(".RoadToSixty-new").exists() && !addons.join(".RoadToSixty-old").exists());
    }

    #[test]
    fn a_first_install_makes_the_folder() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        install(&addons, ZIP).unwrap();
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.10.1"));
    }

    #[test]
    fn an_entry_outside_the_folder_refuses_the_whole_zip() {
        for bad in ["../evil.lua", "/tmp/evil.lua", "Other/evil.lua", "RoadToSixty/../../evil.lua"] {
            let game = tempfile::tempdir().unwrap();
            let addons = game.path().join("Interface/AddOns");
            old_copy(&addons);
            let zip = zip_of(&[("RoadToSixty/RoadToSixty.toc", "## Version: 1.10.1\n"), (bad, "-- no")]);
            assert!(install(&addons, &zip).is_err(), "{bad} is refused");
            assert!(
                read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.9.0"),
                "{bad}: the old copy stays"
            );
            assert!(!game.path().join("evil.lua").exists() && !addons.join("evil.lua").exists());
            assert!(!addons.join(".RoadToSixty-new").exists());
        }
    }

    #[test]
    fn a_zip_without_the_addons_toc_is_refused() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        assert!(install(&addons, &zip_of(&[("RoadToSixty/Core.lua", "--")])).is_err());
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.9.0"));
    }

    #[test]
    fn a_failed_swap_puts_the_old_copy_back() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        let mut calls = 0;
        let result = install_with(&addons, ZIP, |from, to| {
            calls += 1;
            if calls == 2 {
                Err(std::io::Error::other("locked"))
            } else {
                fs::rename(from, to)
            }
        });
        assert!(result.is_err());
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.9.0"));
        assert!(!addons.join(".RoadToSixty-old").exists() && !addons.join(".RoadToSixty-new").exists());
    }

    #[test]
    fn leftovers_from_a_crash_are_cleared_first() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        fs::create_dir_all(addons.join(".RoadToSixty-new/RoadToSixty")).unwrap();
        fs::create_dir_all(addons.join(".RoadToSixty-old")).unwrap();
        install(&addons, ZIP).unwrap();
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.10.1"));
        assert!(!addons.join(".RoadToSixty-new").exists() && !addons.join(".RoadToSixty-old").exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_addon_folder_is_never_written() {
        let game = tempfile::tempdir().unwrap();
        let repo = tempfile::tempdir().unwrap();
        fs::write(repo.path().join("RoadToSixty.toc"), "## Version: @project-version@\n").unwrap();
        let addons = game.path().join("Interface/AddOns");
        fs::create_dir_all(&addons).unwrap();
        std::os::unix::fs::symlink(repo.path(), addons.join("RoadToSixty")).unwrap();
        assert!(is_link(&addons.join("RoadToSixty")));
        assert!(install(&addons, ZIP).is_err());
        assert!(read(&repo.path().join("RoadToSixty.toc")).contains("@project-version@"));
    }

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
