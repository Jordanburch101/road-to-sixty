//! The sync folder: `Interface/AddOns/RoadToSixty_Sync`, which the app owns
//! and the addon reads at login (Sync.lua's header has the format). The app
//! never writes the game's SavedVariables.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::installs::{self, addon_toc};

/// One character's merged journey for the addon to bring in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    /// `Name-Realm`, as the addon's Roster:Name() makes it.
    pub key: String,
    /// The server's version id; the addon takes it when it is higher than
    /// the one it last brought in.
    pub version: i64,
    /// The restore this PC hasn't taken in yet (Sync.lua's header).
    pub restore: Option<i64>,
    /// The journey as Parse.Write text.
    pub journey: String,
}

pub fn sync_folder(game: &Path) -> PathBuf {
    installs::addons_folder(game).join("RoadToSixty_Sync")
}

/// A Lua string literal the game's Lua 5.1 reads back byte for byte. Bytes
/// above 127 (UTF-8 in names) stay as they are; `\0` becomes `\000` so a
/// digit after it can't change its meaning.
pub fn lua_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\0' => out.push_str("\\000"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// data.lua: one global with this PC's ID and each character's journey.
pub fn data_lua(pc: &str, deliveries: &[Delivery]) -> String {
    let mut out = format!("RoadToSixtySync = {{\n    pc = {},\n    chars = {{\n", lua_quote(pc));
    for d in deliveries {
        let restore = d.restore.map(|id| format!("restore = {id}, ")).unwrap_or_default();
        out.push_str(&format!(
            "        [{}] = {{ version = {}, {}journey = {} }},\n",
            lua_quote(&d.key),
            d.version,
            restore,
            lua_quote(&d.journey)
        ));
    }
    out.push_str("    },\n}\n");
    out
}

/// Makes or updates the sync folder in a game folder. The toc copies the
/// addon's Interface number, so the game never marks it out of date.
/// data.lua is written to a temporary file beside it and renamed over the
/// old one, so the game never reads half a file. Returns whether anything
/// changed.
pub fn write(game: &Path, pc: &str, deliveries: &[Delivery]) -> io::Result<bool> {
    let folder = sync_folder(game);
    fs::create_dir_all(&folder)?;
    let addon = fs::read_to_string(addon_toc(game))?;
    let interface = addon
        .lines()
        .find_map(|l| l.strip_prefix("## Interface:"))
        .map(str::trim)
        .unwrap_or("0");
    let toc = format!(
        "## Interface: {interface}\n## Title: Road to Sixty Sync\n## Notes: Journeys from your other PCs, written by the Road to Sixty app\ndata.lua\n"
    );
    let mut changed = replace_if_different(&folder.join("RoadToSixty_Sync.toc"), &toc)?;
    changed |= replace_if_different(&folder.join("data.lua"), &data_lua(pc, deliveries))?;
    Ok(changed)
}

fn replace_if_different(path: &Path, text: &str) -> io::Result<bool> {
    if fs::read(path).is_ok_and(|old| old == text.as_bytes()) {
        return Ok(false);
    }
    let temp = path.with_extension("tmp");
    fs::write(&temp, text)?;
    fs::rename(&temp, path)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn game_with_addon() -> tempfile::TempDir {
        let game = tempfile::tempdir().unwrap();
        let toc = addon_toc(game.path());
        fs::create_dir_all(toc.parent().unwrap()).unwrap();
        fs::write(&toc, "## Interface: 16001\n## Title: Road to Sixty\n").unwrap();
        game
    }

    // The journey text is what can break the file: quotes, backslashes, line
    // breaks, a zero byte before a digit, and UTF-8 in names.
    const TRICKY: &str = "{[\"name\"]=\"Zoë \\\"Q\\\"\",\n[\"note\"]=\"a\\\\b\r\nc\",[\"z\"]=\"\u{0}1\",}";

    #[test]
    fn writes_the_toc_and_data_and_says_when_nothing_changed() {
        let game = game_with_addon();
        let d = vec![Delivery {
            key: "Ann-Test Realm".into(),
            version: 42,
            restore: None,
            journey: "{}".into(),
        }];
        assert!(write(game.path(), "pc-1", &d).unwrap());
        let toc = fs::read_to_string(sync_folder(game.path()).join("RoadToSixty_Sync.toc")).unwrap();
        assert!(toc.starts_with("## Interface: 16001\n"));
        assert!(toc.ends_with("data.lua\n"));
        assert!(!write(game.path(), "pc-1", &d).unwrap());
        assert!(!sync_folder(game.path()).join("data.tmp").exists());
    }

    // The game's own Lua must read every journey back byte for byte.
    #[test]
    fn luajit_reads_the_journey_back_unchanged() {
        let game = game_with_addon();
        let d = vec![
            Delivery {
                key: "Zoë-Test Realm".into(),
                version: 7,
                restore: Some(6),
                journey: TRICKY.into(),
            },
            Delivery {
                key: "Ann-Test Realm".into(),
                version: 8,
                restore: None,
                journey: "{}".into(),
            },
        ];
        write(game.path(), "pc-1", &d).unwrap();
        let data = sync_folder(game.path()).join("data.lua");
        let script = format!(
            "dofile({}) local e = RoadToSixtySync.chars['Zo\\195\\171-Test Realm'] \
             io.write(RoadToSixtySync.pc, '|', e.version, '|', tostring(e.restore), '|', e.journey, '|', \
             tostring(RoadToSixtySync.chars['Ann-Test Realm'].restore))",
            lua_quote(&data.to_string_lossy())
        );
        let out = Command::new("luajit")
            .args(["-e", &script])
            .output()
            .expect("luajit must be on the path");
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        assert_eq!(out.stdout, format!("pc-1|7|6|{TRICKY}|nil").into_bytes());
    }
}
