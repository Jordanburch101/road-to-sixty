//! Finding WoW on Linux, where it runs inside a Wine prefix: a folder with
//! `drive_c` and `dosdevices`, made by Steam's Proton, Lutris, Bottles or
//! plain Wine (spec 2026-10-15-linux-steam-deck-design.md, "Finding WoW").

use std::fs;
use std::path::{Path, PathBuf};

use crate::installs;

/// Every WoW install in the prefixes under `home`: Battle.net's list in
/// each prefix and its default install folder. The caller keeps those
/// that exist.
pub fn installs(home: &Path) -> Vec<PathBuf> {
    prefixes(home).iter().flat_map(|p| installs_in_prefix(p)).collect()
}

/// The Wine prefixes under `home`: Proton's in every Steam library (an SD
/// card's included), Lutris's `~/Games`, Bottles' and `~/.wine`.
pub fn prefixes(home: &Path) -> Vec<PathBuf> {
    let steams = [
        home.join(".local/share/Steam"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ];
    let mut libraries: Vec<PathBuf> = Vec::new();
    for steam in &steams {
        libraries.push(steam.clone());
        let vdf = fs::read_to_string(steam.join("steamapps/libraryfolders.vdf")).unwrap_or_default();
        libraries.extend(steam_libraries(&vdf));
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    for library in &libraries {
        candidates.extend(dirs_in(&library.join("steamapps/compatdata")).into_iter().map(|d| d.join("pfx")));
    }
    candidates.extend(dirs_in(&home.join("Games")));
    candidates.extend(dirs_in(&home.join(".var/app/com.usebottles.bottles/data/bottles/bottles")));
    candidates.push(home.join(".wine"));
    let mut found: Vec<PathBuf> = Vec::new();
    for prefix in candidates {
        if prefix.join("drive_c").is_dir() && !found.contains(&prefix) {
            found.push(prefix);
        }
    }
    found
}

/// The library folders in Steam's `libraryfolders.vdf`, from its `"path"`
/// lines; nothing else in the file is needed.
pub fn steam_libraries(vdf: &str) -> Vec<PathBuf> {
    vdf.lines()
        .filter_map(|line| {
            // `"path"		"/run/media/mmcblk0p1"` splits into "", path, tabs, the path, "".
            let mut parts = line.trim().split('"').skip(1);
            match (parts.next(), parts.nth(1)) {
                (Some("path"), Some(path)) => Some(PathBuf::from(path)),
                _ => None,
            }
        })
        .collect()
}

/// A Windows path from inside a prefix (`C:/Program Files (x86)/...` or
/// with backslashes) as a real path, through the prefix's drive letter
/// links, so an install on any drive (an SD card's included) resolves.
pub fn windows_path(prefix: &Path, path: &str) -> Option<PathBuf> {
    let path = path.replace('\\', "/");
    let (drive, rest) = path.split_once(":/")?;
    if drive.len() != 1 || !drive.chars().all(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    Some(
        prefix
            .join("dosdevices")
            .join(format!("{}:", drive.to_ascii_lowercase()))
            .join(rest),
    )
}

/// The installs a prefix holds: Battle.net's list and the default folder.
pub fn installs_in_prefix(prefix: &Path) -> Vec<PathBuf> {
    let db = prefix.join("drive_c/ProgramData/Battle.net/Agent/product.db");
    let mut found: Vec<PathBuf> = fs::read(db)
        .map(|b| installs::installs_in_product_db(&b))
        .unwrap_or_default()
        .iter()
        .filter_map(|p| windows_path(prefix, &p.to_string_lossy()))
        .collect();
    found.push(prefix.join("drive_c/Program Files (x86)/World of Warcraft"));
    found
}

fn dirs_in(path: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn prefix(at: &Path) -> PathBuf {
        fs::create_dir_all(at.join("drive_c")).unwrap();
        fs::create_dir_all(at.join("dosdevices")).unwrap();
        symlink("../drive_c", at.join("dosdevices/c:")).unwrap();
        at.to_path_buf()
    }

    fn product_db(prefix: &Path, paths: &[&str]) {
        let mut bytes = Vec::new();
        for p in paths {
            bytes.extend(b"\x12\x00");
            bytes.extend(p.as_bytes());
        }
        let db = prefix.join("drive_c/ProgramData/Battle.net/Agent/product.db");
        fs::create_dir_all(db.parent().unwrap()).unwrap();
        fs::write(db, bytes).unwrap();
    }

    #[test]
    fn libraries_are_the_path_lines_of_libraryfolders_vdf() {
        let vdf = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/home/deck/.local/share/Steam\"\n\t\t\"label\"\t\t\"\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"/run/media/mmcblk0p1\"\n\t\t\"apps\"\n\t\t{\n\t\t}\n\t}\n}\n";
        assert_eq!(
            steam_libraries(vdf),
            [
                PathBuf::from("/home/deck/.local/share/Steam"),
                PathBuf::from("/run/media/mmcblk0p1")
            ]
        );
        assert!(steam_libraries("").is_empty());
    }

    #[test]
    fn windows_paths_go_through_the_drive_letter_links() {
        let p = Path::new("/pfx");
        assert_eq!(
            windows_path(p, "C:/Program Files (x86)/World of Warcraft"),
            Some(PathBuf::from("/pfx/dosdevices/c:/Program Files (x86)/World of Warcraft"))
        );
        assert_eq!(
            windows_path(p, "d:\\Games\\WoW"),
            Some(PathBuf::from("/pfx/dosdevices/d:/Games/WoW"))
        );
        assert_eq!(windows_path(p, "/home/deck/WoW"), None);
        assert_eq!(windows_path(p, "ab:/x"), None);
    }

    #[test]
    fn prefixes_are_found_in_every_steam_library_lutris_bottles_and_wine() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let card = h.join("card");
        let steam = h.join(".local/share/Steam");
        fs::create_dir_all(steam.join("steamapps")).unwrap();
        // The vdf lists the main Steam folder too, and a card that isn't inserted.
        fs::write(
            steam.join("steamapps/libraryfolders.vdf"),
            format!(
                "\"path\" \"{}\"\n\"path\" \"{}\"\n\"path\" \"{}\"\n",
                steam.display(),
                card.display(),
                h.join("not-inserted").display()
            ),
        )
        .unwrap();
        let shortcut = prefix(&steam.join("steamapps/compatdata/3141592653/pfx"));
        let on_card = prefix(&card.join("steamapps/compatdata/2718281828/pfx"));
        let flatpak = prefix(&h.join(".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata/NonSteamLaunchers/pfx"));
        let lutris = prefix(&h.join("Games/world-of-warcraft"));
        let bottle = prefix(&h.join(".var/app/com.usebottles.bottles/data/bottles/bottles/WoW"));
        let wine = prefix(&h.join(".wine"));
        fs::create_dir_all(h.join("Games/not-a-prefix")).unwrap();
        let found = prefixes(h);
        for p in [&shortcut, &on_card, &flatpak, &lutris, &bottle, &wine] {
            assert_eq!(found.iter().filter(|f| f == &p).count(), 1, "{} once", p.display());
        }
        assert_eq!(found.len(), 6, "no folder without drive_c: {found:?}");
    }

    #[test]
    fn a_prefix_gives_battle_nets_installs_and_the_default_folder() {
        let dir = tempfile::tempdir().unwrap();
        let p = prefix(&dir.path().join("pfx"));
        let card = dir.path().join("card");
        fs::create_dir_all(&card).unwrap();
        symlink(&card, p.join("dosdevices/d:")).unwrap();
        // E: has no link, so its path is dropped rather than guessed.
        product_db(&p, &["D:/Games/World of Warcraft", "E:/Elsewhere/World of Warcraft"]);
        assert_eq!(
            installs_in_prefix(&p),
            [
                p.join("dosdevices/d:/Games/World of Warcraft"),
                p.join("dosdevices/e:/Elsewhere/World of Warcraft"),
                p.join("drive_c/Program Files (x86)/World of Warcraft"),
            ]
        );
        // find_installs keeps only those that exist, by their real path.
        fs::create_dir_all(card.join("Games/World of Warcraft")).unwrap();
        let real: Vec<PathBuf> = installs_in_prefix(&p)
            .into_iter()
            .filter(|i| i.is_dir())
            .map(|i| fs::canonicalize(i).unwrap())
            .collect();
        assert_eq!(real, [fs::canonicalize(card.join("Games/World of Warcraft")).unwrap()]);
    }

    #[test]
    fn installs_under_a_made_up_home_include_the_default_proton_folder() {
        let home = tempfile::tempdir().unwrap();
        let p = prefix(&home.path().join(".local/share/Steam/steamapps/compatdata/1/pfx"));
        assert!(installs(home.path()).contains(&p.join("drive_c/Program Files (x86)/World of Warcraft")));
    }
}
