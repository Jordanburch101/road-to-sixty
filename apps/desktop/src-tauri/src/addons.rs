//! The addon in each game (spec 2026-10-16, addon updates): what the window
//! says about each game folder, and, below, the check and the installs.

use std::path::Path;

use rts_sync::addon::{self, Latest};
use rts_sync::installs;
use serde::Serialize;

/// What a game folder holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Copy {
    None,
    /// A developer copy: its toc has no version filled in, or the folder is a link.
    Developer,
    Version(String),
}

pub fn copy_in(game: &Path) -> Copy {
    let toc = installs::addon_toc(game);
    if !toc.is_file() {
        return Copy::None;
    }
    if toc.parent().is_some_and(addon::is_link) {
        return Copy::Developer;
    }
    installs::addon_version(game).map_or(Copy::Developer, Copy::Version)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum FolderState {
    Current,
    /// A newer version goes in as soon as this game isn't running.
    Waiting {
        latest: String,
    },
    /// No addon yet, and the release fits this game.
    Missing {
        latest: String,
    },
    Developer,
    /// The last try failed; the next check clears it and tries again.
    Failed {
        why: String,
    },
    /// Updates are off and a newer version is out.
    Behind {
        latest: String,
    },
    /// It has the addon, but runs a client the release isn't built for.
    OtherClient,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub path: String,
    pub name: String,
    pub characters: usize,
    pub addon: Option<String>,
    /// When the app last put the addon in, Unix seconds.
    pub updated_at: Option<u64>,
    #[serde(flatten)]
    pub state: FolderState,
}

/// A game folder's state, or None when it isn't listed: one without the
/// addon is offered it only when the release fits its client.
pub fn state(
    copy: &Copy,
    client: Option<(u32, u32)>,
    latest: Option<&Latest>,
    failed: Option<&str>,
    updates: bool,
    asked: bool,
) -> Option<FolderState> {
    let fits = |l: &Latest| client.is_some_and(|c| addon::fits(c, l.interface));
    match copy {
        Copy::None => latest
            .filter(|l| fits(l))
            .map(|l| FolderState::Missing { latest: l.version.clone() }),
        Copy::Developer => Some(FolderState::Developer),
        Copy::Version(v) => Some(match latest {
            Some(l) if !fits(l) => FolderState::OtherClient,
            _ if failed.is_some() => FolderState::Failed {
                why: failed.unwrap_or_default().into(),
            },
            Some(l) if addon::newer(&l.version, v) && (updates || asked) => FolderState::Waiting { latest: l.version.clone() },
            Some(l) if addon::newer(&l.version, v) => FolderState::Behind { latest: l.version.clone() },
            _ => FolderState::Current,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn latest() -> Latest {
        Latest {
            version: "1.10.1".into(),
            interface: 16001,
            zip: String::new(),
            signature: String::new(),
        }
    }
    const FOREVER: Option<(u32, u32)> = Some((1, 60));
    const ERA: Option<(u32, u32)> = Some((1, 15));
    fn v(s: &str) -> Copy {
        Copy::Version(s.into())
    }

    #[test]
    fn a_folder_without_the_addon_is_offered_it_only_on_its_client() {
        let l = latest();
        assert_eq!(
            state(&Copy::None, FOREVER, Some(&l), None, true, false),
            Some(FolderState::Missing { latest: "1.10.1".into() })
        );
        assert_eq!(
            state(&Copy::None, ERA, Some(&l), None, true, false),
            None,
            "Classic Era isn't listed"
        );
        assert_eq!(
            state(&Copy::None, None, Some(&l), None, true, false),
            None,
            "no .flavor.info: not listed"
        );
        assert_eq!(state(&Copy::None, FOREVER, None, None, true, false), None, "nothing to install yet");
    }

    #[test]
    fn an_installed_copy_reads_as_current_waiting_behind_or_another_client() {
        let l = latest();
        assert_eq!(
            state(&v("1.10.1"), FOREVER, Some(&l), None, true, false),
            Some(FolderState::Current)
        );
        assert_eq!(
            state(&v("1.11.0-beta"), FOREVER, Some(&l), None, true, false),
            Some(FolderState::Current),
            "never backwards"
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), None, true, false),
            Some(FolderState::Waiting { latest: "1.10.1".into() })
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), None, false, false),
            Some(FolderState::Behind { latest: "1.10.1".into() })
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), None, false, true),
            Some(FolderState::Waiting { latest: "1.10.1".into() }),
            "Update was pressed"
        );
        assert_eq!(
            state(&v("1.10.0"), ERA, Some(&l), None, true, false),
            Some(FolderState::OtherClient)
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, None, None, true, false),
            Some(FolderState::Current),
            "offline: nothing newer known"
        );
        assert_eq!(
            state(&v("1.10.0"), FOREVER, Some(&l), Some("the disk is full"), true, false),
            Some(FolderState::Failed {
                why: "the disk is full".into()
            })
        );
        assert_eq!(
            state(&Copy::Developer, FOREVER, Some(&l), None, true, false),
            Some(FolderState::Developer)
        );
    }

    #[test]
    fn a_folder_reads_as_the_window_expects() {
        let f = Folder {
            path: "/wow/_classic_beta_".into(),
            name: "_classic_beta_".into(),
            characters: 2,
            addon: Some("1.10.0".into()),
            updated_at: None,
            state: FolderState::Waiting { latest: "1.10.1".into() },
        };
        let json = serde_json::to_value(&f).unwrap();
        assert_eq!(json["state"], "waiting");
        assert_eq!(json["latest"], "1.10.1");
        assert_eq!(json["updatedAt"], serde_json::Value::Null);
        assert_eq!(serde_json::to_value(FolderState::OtherClient).unwrap()["state"], "otherClient");
    }

    #[test]
    fn a_copy_is_read_from_its_toc() {
        let game = tempfile::tempdir().unwrap();
        assert_eq!(copy_in(game.path()), Copy::None);
        let dir = game.path().join("Interface/AddOns/RoadToSixty");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("RoadToSixty.toc"), "## Version: @project-version@\n").unwrap();
        assert_eq!(copy_in(game.path()), Copy::Developer);
        std::fs::write(dir.join("RoadToSixty.toc"), "## Version: 1.10.0\n").unwrap();
        assert_eq!(copy_in(game.path()), Copy::Version("1.10.0".into()));
    }
}
