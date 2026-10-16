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

/// On a Mac or Windows, where Battle.net keeps its list of installed games.
pub fn product_db() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(r"C:\ProgramData\Battle.net\Agent\product.db")
    } else {
        PathBuf::from("/Users/Shared/Battle.net/Agent/product.db")
    }
}

/// On a Mac or Windows, where WoW installs itself when nobody picks a folder.
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
    // Text runs end at control bytes; UTF-8 letters (é is two bytes over
    // 0x7f) stay in the run.
    for run in bytes.split(|b| *b < 0x20 || *b == 0x7f) {
        // A length byte before the text can itself read as a letter, or as
        // an invalid character, so the path may start a little way in.
        let text = String::from_utf8_lossy(run);
        let drive = text
            .char_indices()
            .find(|&(i, c)| c.is_ascii_alphabetic() && (text[i + 1..].starts_with(":/") || text[i + 1..].starts_with(":\\")))
            .map(|(i, _)| i);
        let Some(start) = drive.or_else(|| text.find('/')) else { continue };
        let path = PathBuf::from(text[start..].trim_end_matches('\u{FFFD}'));
        if !found.contains(&path) {
            found.push(path);
        }
    }
    found
}

/// Every install that exists: Battle.net's list and the default locations
/// (on Linux, those inside each Wine prefix), and folders the player picked,
/// without repeats.
pub fn find_installs(picked: &[PathBuf]) -> Vec<PathBuf> {
    let mut all: Vec<PathBuf> = Vec::new();
    #[cfg(target_os = "linux")]
    all.extend(dirs::home_dir().map(|home| crate::wine::installs(&home)).unwrap_or_default());
    #[cfg(not(target_os = "linux"))]
    {
        all.extend(fs::read(product_db()).map(|b| installs_in_product_db(&b)).unwrap_or_default());
        all.extend(default_installs());
    }
    all.extend(picked.iter().cloned());
    let mut found: Vec<PathBuf> = Vec::new();
    for path in all {
        if !path.is_dir() {
            continue;
        }
        // By its real path: file watching reports real paths, so an install
        // reached through a link would never match. Not on Windows, where
        // the real path gains a \\?\ prefix the game's process path lacks.
        let path = if cfg!(windows) {
            path
        } else {
            fs::canonicalize(&path).unwrap_or(path)
        };
        if !found.contains(&path) {
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

/// A game folder of any client, with or without the addon, and the client
/// version it runs (major, minor) when the game's own files say.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameDir {
    pub path: PathBuf,
    pub name: String,
    pub client: Option<(u32, u32)>,
}

/// Every game folder in an install. Its `.flavor.info` names its product,
/// and the install's `.build.info` gives each product's version: the name
/// of the folder doesn't say which client it is.
pub fn game_dirs(install: &Path) -> Vec<GameDir> {
    let builds = fs::read_to_string(install.join(".build.info"))
        .map(|t| build_versions(&t))
        .unwrap_or_default();
    let mut found = Vec::new();
    for entry in fs::read_dir(install).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        if name.len() > 2 && name.starts_with('_') && name.ends_with('_') && path.is_dir() {
            let client = fs::read_to_string(path.join(".flavor.info"))
                .ok()
                .and_then(|t| flavor(&t))
                .and_then(|product| builds.iter().find(|(p, _)| *p == product).map(|(_, v)| v.clone()))
                .and_then(|v| major_minor(&v));
            found.push(GameDir { path, name, client });
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

/// `.build.info`: a header row of `Name!TYPE:n` columns, then a row per
/// product, split by `|`. Each product with its version.
pub fn build_versions(text: &str) -> Vec<(String, String)> {
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let Some(header) = lines.next() else { return Vec::new() };
    let columns: Vec<&str> = header.split('|').map(|c| c.split('!').next().unwrap_or("")).collect();
    let (Some(version), Some(product)) = (
        columns.iter().position(|c| *c == "Version"),
        columns.iter().position(|c| *c == "Product"),
    ) else {
        return Vec::new();
    };
    lines
        .filter_map(|l| {
            let fields: Vec<&str> = l.split('|').collect();
            Some((fields.get(product)?.trim().to_string(), fields.get(version)?.trim().to_string()))
        })
        .collect()
}

/// `.flavor.info`: a header line, then the product, such as `wow_classic_beta`.
pub fn flavor(text: &str) -> Option<String> {
    text.lines().map(str::trim).filter(|l| !l.is_empty()).nth(1).map(str::to_string)
}

fn major_minor(version: &str) -> Option<(u32, u32)> {
    let mut parts = version.split('.');
    Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?))
}

/// The game's AddOns folder, whatever the case of its name: Wine loads
/// `Interface/Addons` too, and Linux's disks care about case.
pub fn addons_folder(game: &Path) -> PathBuf {
    child(&child(game, "Interface"), "AddOns")
}

pub fn addon_toc(game: &Path) -> PathBuf {
    child(&child(&addons_folder(game), "RoadToSixty"), "RoadToSixty.toc")
}

/// `name` in `dir` matched without regard to case, or the game's own
/// spelling while there's nothing there yet.
pub(crate) fn child(dir: &Path, name: &str) -> PathBuf {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .find(|e| e.file_name().to_string_lossy().eq_ignore_ascii_case(name))
        .map(|e| e.path())
        .unwrap_or_else(|| dir.join(name))
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

pub(crate) fn dirs_in(path: &Path) -> Vec<PathBuf> {
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

    // Made up in the format the game writes: a header of Name!TYPE:n
    // columns, then a row per product.
    const BUILD_INFO: &str = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0\r\n\
        us|1|aa|1.60.1.70374|wow_classic_beta\r\n\
        us|1|bb|1.15.8.65000|wow_classic_era\r\n";

    #[test]
    fn the_build_info_gives_each_products_version() {
        assert_eq!(
            build_versions(BUILD_INFO),
            vec![
                ("wow_classic_beta".to_string(), "1.60.1.70374".to_string()),
                ("wow_classic_era".to_string(), "1.15.8.65000".to_string())
            ]
        );
        assert_eq!(build_versions("not a table"), vec![]);
        assert_eq!(
            flavor("Product Flavor!STRING:0\nwow_classic_beta\n"),
            Some("wow_classic_beta".to_string())
        );
        assert_eq!(flavor(""), None);
    }

    #[test]
    fn each_game_folder_carries_its_client_version_with_or_without_the_addon() {
        let install = tempfile::tempdir().unwrap();
        touch(&install.path().join(".build.info"), BUILD_INFO);
        touch(
            &install.path().join("_classic_beta_/.flavor.info"),
            "Product Flavor!STRING:0\nwow_classic_beta\n",
        );
        touch(
            &install.path().join("_classic_era_/.flavor.info"),
            "Product Flavor!STRING:0\nwow_classic_era\n",
        );
        fs::create_dir_all(install.path().join("_retail_")).unwrap();
        fs::create_dir_all(install.path().join("Utils")).unwrap();
        let dirs = game_dirs(install.path());
        let seen: Vec<(&str, Option<(u32, u32)>)> = dirs.iter().map(|d| (d.name.as_str(), d.client)).collect();
        assert_eq!(
            seen,
            vec![
                ("_classic_beta_", Some((1, 60))),
                ("_classic_era_", Some((1, 15))),
                ("_retail_", None)
            ]
        );
    }

    #[test]
    fn product_db_paths_may_have_accents() {
        let mut bytes = b"\x0a\x22".to_vec();
        bytes.extend_from_slice("D:/Jeux vidéo/World of Warcraft".as_bytes());
        bytes.extend_from_slice(b"\x12\x05other");
        assert!(installs_in_product_db(&bytes).contains(&PathBuf::from("D:/Jeux vidéo/World of Warcraft")));
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

    // Wine loads addons from Interface/Addons as well, but Linux's disks care
    // about case, so the folder is looked up whatever its spelling.
    #[test]
    fn the_addon_is_found_whatever_the_case_of_its_folders() {
        let install = tempfile::tempdir().unwrap();
        let game = install.path().join("_classic_beta_");
        touch(&game.join("interface/Addons/RoadToSixty/RoadToSixty.toc"), "## Interface: 16001\n");
        assert!(addon_toc(&game).ends_with("interface/Addons/RoadToSixty/RoadToSixty.toc"));
        assert_eq!(addons_folder(&game), game.join("interface/Addons"));
        assert_eq!(game_folders(install.path()).len(), 1);
        // Nothing there yet: the game's own spelling.
        let empty = install.path().join("_classic_");
        assert_eq!(addons_folder(&empty), empty.join("Interface/AddOns"));
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
