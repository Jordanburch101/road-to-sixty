//! Finding WoW installs, their game folders, and the characters that use the
//! addon (spec, "First run").

use std::fs;
use std::path::{Path, PathBuf};

/// A game folder inside an install, such as `_classic_beta_`, that has the
/// addon. Its name is the `game` the server keeps characters under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameFolder {
    pub path: PathBuf,
    pub name: String,
}

/// One character's saved journey, two folders below the account:
/// `WTF/Account/<account>/<two folders>/SavedVariables/RoadToSixty.lua`.
/// Which folders depends on the client (Forever's are `70/Name-Something`),
/// so the character's name and realm come from the file (sync::roster_key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedFile {
    pub game: String,
    pub path: PathBuf,
}

/// Where Battle.net keeps its list of installed games.
pub fn product_db() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(r"C:\ProgramData\Battle.net\Agent\product.db")
    } else {
        PathBuf::from("/Users/Shared/Battle.net/Agent/product.db")
    }
}

/// Where WoW installs itself when nobody picks a folder.
pub fn default_installs() -> Vec<PathBuf> {
    if cfg!(windows) {
        vec![PathBuf::from(r"C:\Program Files (x86)\World of Warcraft")]
    } else {
        vec![PathBuf::from("/Applications/World of Warcraft")]
    }
}

/// The install folders named in Battle.net's product.db. It is a protobuf
/// file; rather than decode it, this takes every absolute path in its runs
/// of text, and the caller keeps those that exist.
pub fn installs_in_product_db(bytes: &[u8]) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = Vec::new();
    for run in bytes.split(|b| !(0x20..0x7f).contains(b)) {
        // A length byte before the text can itself read as a letter, so the
        // path may start one character into the run.
        let text = String::from_utf8_lossy(run);
        let drive = (0..text.len().saturating_sub(2))
            .find(|&i| run[i].is_ascii_alphabetic() && (&text[i + 1..i + 3] == ":/" || &text[i + 1..i + 3] == ":\\"));
        let Some(start) = drive.or_else(|| text.find('/')) else { continue };
        let path = PathBuf::from(&text[start..]);
        if !found.contains(&path) {
            found.push(path);
        }
    }
    found
}

/// Every install that exists: Battle.net's list, the default locations, and
/// folders the player picked, without repeats.
pub fn find_installs(picked: &[PathBuf]) -> Vec<PathBuf> {
    let mut all: Vec<PathBuf> = fs::read(product_db()).map(|b| installs_in_product_db(&b)).unwrap_or_default();
    all.extend(default_installs());
    all.extend(picked.iter().cloned());
    let mut found: Vec<PathBuf> = Vec::new();
    for path in all {
        // By its real path: file watching reports real paths, so an install
        // reached through a link would never match. Not on Windows, where
        // the real path gains a \\?\ prefix the game's process path lacks.
        let path = if cfg!(windows) {
            path
        } else {
            fs::canonicalize(&path).unwrap_or(path)
        };
        if path.is_dir() && !found.contains(&path) {
            found.push(path);
        }
    }
    found
}

/// The game folders in an install that have the addon. Every folder named
/// like `_classic_` counts, so the name Forever launches with doesn't matter.
pub fn game_folders(install: &Path) -> Vec<GameFolder> {
    let mut found = Vec::new();
    for entry in fs::read_dir(install).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        if name.len() > 2 && name.starts_with('_') && name.ends_with('_') && addon_toc(&path).is_file() {
            found.push(GameFolder { path, name });
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

pub fn addon_toc(game: &Path) -> PathBuf {
    game.join("Interface").join("AddOns").join("RoadToSixty").join("RoadToSixty.toc")
}

/// The addon version the game folder has, from its toc; None for a
/// developer install, whose toc still holds the release build's placeholder.
pub fn addon_version(game: &Path) -> Option<String> {
    let toc = fs::read_to_string(addon_toc(game)).ok()?;
    let version = toc.lines().find_map(|l| l.strip_prefix("## Version:"))?.trim().to_string();
    (!version.is_empty() && !version.starts_with('@')).then_some(version)
}

/// Every character in a game folder with a saved journey.
pub fn saved_files(game: &GameFolder) -> Vec<SavedFile> {
    let mut found = Vec::new();
    let accounts = game.path.join("WTF").join("Account");
    for account in dirs_in(&accounts) {
        for outer in dirs_in(&account) {
            for character in dirs_in(&outer) {
                let path = character.join("SavedVariables").join("RoadToSixty.lua");
                if path.is_file() {
                    found.push(SavedFile {
                        game: game.name.clone(),
                        path,
                    });
                }
            }
        }
    }
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
}

fn dirs_in(path: &Path) -> Vec<PathBuf> {
    fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn touch(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    #[test]
    fn product_db_paths_are_the_absolute_text_runs() {
        // A path of 32 to 126 characters has a length byte that reads as a
        // letter, so the run of text starts one character early.
        let mut bytes =
            b"\x0a\x03wow\x12\x1f/Applications/World of Warcraft\x1a\x02en\x12J/Users/x/Games/World of Warcraft Classic Stuff Here\x00"
                .to_vec();
        bytes.extend(b"\x00\x01C:/Program Files (x86)/World of Warcraft\x00");
        let found = installs_in_product_db(&bytes);
        assert_eq!(
            found,
            vec![
                PathBuf::from("/Applications/World of Warcraft"),
                PathBuf::from("/Users/x/Games/World of Warcraft Classic Stuff Here"),
                PathBuf::from("C:/Program Files (x86)/World of Warcraft")
            ]
        );
    }

    #[test]
    fn game_folders_are_the_underscored_ones_with_the_addon() {
        let install = tempfile::tempdir().unwrap();
        touch(&addon_toc(&install.path().join("_classic_beta_")), "## Interface: 16001\n");
        touch(&addon_toc(&install.path().join("_retail_")).with_file_name("Other.toc"), "");
        fs::create_dir_all(install.path().join("Data")).unwrap();
        let found = game_folders(install.path());
        assert_eq!(found.iter().map(|g| g.name.as_str()).collect::<Vec<_>>(), ["_classic_beta_"]);
    }

    #[test]
    fn saved_files_are_per_character_and_skip_the_account_file() {
        let game = tempfile::tempdir().unwrap();
        let account = game.path().join("WTF").join("Account").join("ACCOUNT1");
        touch(
            &account
                .join("70")
                .join("Ann-Stormfist")
                .join("SavedVariables")
                .join("RoadToSixty.lua"),
            "RoadToSixtyCharDB = {}",
        );
        touch(
            &account.join("70").join("Bob-Stormfist").join("SavedVariables").join("Other.lua"),
            "",
        );
        touch(&account.join("SavedVariables").join("RoadToSixty.lua"), "RoadToSixtyDB = {}");
        let folder = GameFolder {
            path: game.path().to_path_buf(),
            name: "_classic_beta_".into(),
        };
        let found = saved_files(&folder);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].game, "_classic_beta_");
        assert!(found[0].path.ends_with("70/Ann-Stormfist/SavedVariables/RoadToSixty.lua"));
    }

    // File watching reports real paths, so an install reached through a link
    // (WoW moved to another drive) must be kept by its real path.
    #[cfg(unix)]
    #[test]
    fn a_linked_install_is_kept_by_its_real_path() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("Real WoW");
        fs::create_dir_all(&real).unwrap();
        let link = dir.path().join("Linked WoW");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let found = find_installs(&[link]);
        assert_eq!(found.last(), Some(&fs::canonicalize(&real).unwrap()));
    }

    #[test]
    fn addon_version_skips_the_unfilled_placeholder() {
        let game = tempfile::tempdir().unwrap();
        touch(&addon_toc(game.path()), "## Interface: 16001\n## Version: 1.9.0\n");
        assert_eq!(addon_version(game.path()).as_deref(), Some("1.9.0"));
        touch(&addon_toc(game.path()), "## Version: @project-version@\n");
        assert_eq!(addon_version(game.path()), None);
    }
}
