//! What the app shows: the line in the tray menu and the window's state,
//! worked out from the sync engine's reports. Plain functions, so the
//! wording is tested without a window.

use rts_sync::api::ApiError;
use rts_sync::sync::Report;
use serde::Serialize;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// The BattleTag this PC is linked to. None before linking, and after
    /// the server stops accepting the token.
    pub linked_to: Option<String>,
    /// This PC's id, to mark it in the PC list.
    pub pc: Option<String>,
    /// This app's version.
    pub version: String,
    pub update: UpdateState,
    pub games: Vec<Game>,
    pub characters: Vec<Character>,
    /// Unix seconds of the last pass that reached the server.
    pub last_synced: Option<u64>,
    pub paused: bool,
    /// The last pass couldn't reach the server; the engine tries again.
    pub offline: bool,
    /// Problems that aren't one character's, for the window.
    pub problems: Vec<String>,
    /// While linking, the code the link page shows, to compare.
    pub link_code: Option<String>,
    /// While linking, the link page's address, for when no browser opened.
    pub link_url: Option<String>,
    /// The tray's status line, also shown in the window.
    pub line: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Game {
    pub path: String,
    pub name: String,
    pub addon: Option<String>,
    /// The characters with a saved file in it.
    pub characters: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Character {
    /// `Name-Realm`, from the saved file's rosterKey or the server.
    pub key: String,
    /// Its saved file is on this PC.
    pub here: bool,
    pub update_addon: bool,
    /// When this run of the app last uploaded it, in Unix seconds.
    pub uploaded: Option<u64>,
    /// Why it isn't backed up, if it isn't.
    pub problem: Option<String>,
    /// The line under the name.
    pub note: String,
}

/// Where a self-update is (spec, "Start at login and updates").
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum UpdateState {
    #[default]
    None,
    /// Downloaded; it installs when the window is closed and no sync runs.
    Ready { version: String },
    /// This start was into a new version, at this time.
    Updated { version: String, at: u64 },
    /// The last try failed; the next check tries again.
    Failed { why: String },
}

/// The tray's update item.
pub fn update_line(update: &UpdateState) -> String {
    match update {
        UpdateState::None => "Check for updates".into(),
        UpdateState::Ready { version } => format!("Restart to update to {version}"),
        UpdateState::Updated { version, .. } => format!("Updated to {version}"),
        UpdateState::Failed { why } => format!("Couldn't update: {why}"),
    }
}

pub fn ago(secs: u64) -> String {
    match secs {
        0..60 => "just now".into(),
        60..3600 => format!("{} min ago", secs / 60),
        3600..86_400 => format!("{} h ago", secs / 3600),
        86_400..172_800 => "yesterday".into(),
        _ => format!("{} days ago", secs / 86_400),
    }
}

/// Folds one engine report into the status. `local` is every character
/// with a saved file on this PC.
pub fn apply(status: &mut Status, result: &Result<Report, ApiError>, local: &[String], now: u64) {
    match result {
        Ok(report) => {
            status.offline = false;
            status.last_synced = Some(now);
            status.problems = report.problems.iter().filter(|p| p.who.is_empty()).map(|p| p.why.clone()).collect();
            let problem = |key: &str| report.problems.iter().find(|p| p.who == key).map(|p| p.why.clone());
            // A character only named by a problem has a file here the server
            // doesn't know yet (one without a rosterKey, say).
            let only_named: Vec<String> = report
                .problems
                .iter()
                .filter(|p| !p.who.is_empty() && !report.characters.contains(&p.who))
                .map(|p| p.who.clone())
                .collect();
            let mut keys: Vec<String> = report.characters.iter().chain(local).chain(&only_named).cloned().collect();
            keys.sort();
            keys.dedup();
            let before = std::mem::take(&mut status.characters);
            status.characters = keys
                .into_iter()
                .map(|key| Character {
                    here: local.contains(&key) || only_named.contains(&key),
                    problem: problem(&key),
                    update_addon: report.update_addon.contains(&key),
                    uploaded: if report.uploaded.contains(&key) {
                        Some(now)
                    } else {
                        before.iter().find(|c| c.key == key).and_then(|c| c.uploaded)
                    },
                    note: String::new(),
                    key,
                })
                .collect();
        }
        Err(ApiError::Unauthorized) => status.linked_to = None,
        Err(ApiError::Network(_)) => status.offline = true,
        Err(e) => status.problems = vec![e.to_string()],
    }
}

/// Rewrites the words that depend on the clock: the tray line and each
/// character's note. Runs after every change and every half minute.
pub fn refresh(status: &mut Status, now: u64) {
    if let UpdateState::Updated { at, .. } = status.update
        && now.saturating_sub(at) >= 3600
    {
        status.update = UpdateState::None;
    }
    for c in &mut status.characters {
        c.note = if let Some(why) = &c.problem {
            why.clone()
        } else if c.update_addon {
            "Update the addon on this PC to get the newest journey".into()
        } else if !c.here {
            "Only on your other PCs so far".into()
        } else if let Some(t) = c.uploaded {
            format!("Backed up {}", ago(now.saturating_sub(t)))
        } else {
            "Up to date".into()
        };
    }
    status.line = if status.linked_to.is_none() {
        "Not linked".into()
    } else if status.paused {
        "Syncing paused".into()
    } else if status.games.is_empty() {
        "WoW not found".into()
    } else if status.characters.iter().any(|c| c.update_addon) {
        "Update the addon on this PC".into()
    } else if status.offline {
        "Can't reach the server, trying again".into()
    } else if let n @ 1.. = status.characters.iter().filter(|c| c.problem.is_some()).count() {
        if n == 1 {
            "1 character not backed up".into()
        } else {
            format!("{n} characters not backed up")
        }
    } else if !status.problems.is_empty() {
        "Needs a look: open Road to Sixty".into()
    } else if let Some(t) = status.last_synced {
        format!("Synced {}", ago(now.saturating_sub(t)))
    } else {
        "Syncing…".into()
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use rts_sync::api::ApiError;
    use rts_sync::sync::{Problem, Report};

    fn linked() -> Status {
        Status {
            linked_to: Some("Ann#1234".into()),
            games: vec![Game {
                path: "/wow/_classic_beta_".into(),
                name: "_classic_beta_".into(),
                addon: Some("1.9.0".into()),
                characters: 1,
            }],
            ..Status::default()
        }
    }

    fn report(characters: &[&str], uploaded: &[&str], update_addon: &[&str]) -> Result<Report, ApiError> {
        let own = |v: &[&str]| v.iter().map(|s| s.to_string()).collect();
        Ok(Report {
            characters: own(characters),
            uploaded: own(uploaded),
            update_addon: own(update_addon),
            ..Report::default()
        })
    }

    #[test]
    fn ago_reads_like_speech() {
        assert_eq!(ago(5), "just now");
        assert_eq!(ago(150), "2 min ago");
        assert_eq!(ago(7200), "2 h ago");
        assert_eq!(ago(90_000), "yesterday");
        assert_eq!(ago(3 * 86_400), "3 days ago");
    }

    #[test]
    fn a_pass_lists_characters_from_here_and_the_server_once_each() {
        let mut s = linked();
        apply(
            &mut s,
            &report(&["Ann-Test", "Bob-Test"], &["Ann-Test"], &[]),
            &["Ann-Test".into(), "Cy-Test".into()],
            1000,
        );
        refresh(&mut s, 1000);
        let keys: Vec<_> = s.characters.iter().map(|c| (c.key.as_str(), c.here, c.note.as_str())).collect();
        assert_eq!(
            keys,
            [
                ("Ann-Test", true, "Backed up just now"),
                ("Bob-Test", false, "Only on your other PCs so far"),
                ("Cy-Test", true, "Up to date"),
            ]
        );
        assert_eq!(s.line, "Synced just now");
    }

    #[test]
    fn an_upload_time_survives_later_passes_that_send_nothing() {
        let mut s = linked();
        apply(&mut s, &report(&["Ann-Test"], &["Ann-Test"], &[]), &["Ann-Test".into()], 1000);
        apply(&mut s, &report(&["Ann-Test"], &[], &[]), &["Ann-Test".into()], 1300);
        refresh(&mut s, 1300);
        assert_eq!(s.characters[0].note, "Backed up 5 min ago");
    }

    #[test]
    fn the_tray_line_puts_the_most_urgent_thing_first() {
        let mut s = linked();
        refresh(&mut s, 0);
        assert_eq!(s.line, "Syncing…");
        apply(&mut s, &report(&["Ann-Test"], &[], &["Ann-Test"]), &["Ann-Test".into()], 100);
        refresh(&mut s, 100);
        assert_eq!(s.line, "Update the addon on this PC");
        assert_eq!(s.characters[0].note, "Update the addon on this PC to get the newest journey");
        s.games.clear();
        refresh(&mut s, 100);
        assert_eq!(s.line, "WoW not found");
        s.paused = true;
        refresh(&mut s, 100);
        assert_eq!(s.line, "Syncing paused");
        s.linked_to = None;
        refresh(&mut s, 100);
        assert_eq!(s.line, "Not linked");
    }

    #[test]
    fn no_answer_keeps_the_last_sync_and_says_it_will_try_again() {
        let mut s = linked();
        apply(&mut s, &report(&[], &[], &[]), &[], 100);
        apply(&mut s, &Err(ApiError::Network("timed out".into())), &[], 200);
        refresh(&mut s, 200);
        assert_eq!((s.offline, s.last_synced), (true, Some(100)));
        assert_eq!(s.line, "Can't reach the server, trying again");
        apply(&mut s, &report(&[], &[], &[]), &[], 300);
        assert!(!s.offline);
    }

    #[test]
    fn a_refused_token_means_link_again() {
        let mut s = linked();
        apply(&mut s, &Err(ApiError::Unauthorized), &[], 100);
        refresh(&mut s, 100);
        assert_eq!(s.linked_to, None);
        assert_eq!(s.line, "Not linked");
    }

    #[test]
    fn a_character_that_isnt_backed_up_says_why_and_the_tray_counts_it() {
        let mut s = linked();
        let r = Report {
            characters: vec!["Ann-Test".into()],
            problems: vec![
                Problem {
                    who: "Ann-Test".into(),
                    why: "Too big to back up".into(),
                },
                Problem {
                    who: "Beagen".into(),
                    why: "Log in once with the updated addon".into(),
                },
                Problem::general("Couldn't write the sync folder in _classic_beta_"),
            ],
            ..Report::default()
        };
        apply(&mut s, &Ok(r), &["Ann-Test".into()], 100);
        refresh(&mut s, 100);
        let rows: Vec<_> = s.characters.iter().map(|c| (c.key.as_str(), c.here, c.note.as_str())).collect();
        assert_eq!(
            rows,
            [
                ("Ann-Test", true, "Too big to back up"),
                ("Beagen", true, "Log in once with the updated addon")
            ]
        );
        assert_eq!(s.problems, ["Couldn't write the sync folder in _classic_beta_"]);
        assert_eq!(s.line, "2 characters not backed up");
    }

    #[test]
    fn a_problem_that_isnt_a_characters_is_still_in_the_tray() {
        let mut s = linked();
        let r = Report {
            problems: vec![Problem::general("Couldn't watch for saved games")],
            ..Report::default()
        };
        apply(&mut s, &Ok(r), &[], 100);
        refresh(&mut s, 100);
        assert_eq!(s.line, "Needs a look: open Road to Sixty");
    }

    #[test]
    fn the_window_gets_camel_case() {
        let json = serde_json::to_string(&linked()).unwrap();
        assert!(json.contains(r#""linkedTo":"Ann#1234""#), "{json}");
        assert!(json.contains(r#""lastSynced":null"#), "{json}");
    }

    #[test]
    fn the_update_item_says_what_the_update_is_doing() {
        assert_eq!(update_line(&UpdateState::None), "Check for updates");
        assert_eq!(
            update_line(&UpdateState::Ready { version: "0.1.3".into() }),
            "Restart to update to 0.1.3"
        );
        assert_eq!(
            update_line(&UpdateState::Updated {
                version: "0.1.3".into(),
                at: 0
            }),
            "Updated to 0.1.3"
        );
        assert_eq!(
            update_line(&UpdateState::Failed { why: "no space".into() }),
            "Couldn't update: no space"
        );
    }

    #[test]
    fn updated_to_shows_for_an_hour() {
        let mut s = linked();
        s.update = UpdateState::Updated {
            version: "0.1.3".into(),
            at: 1000,
        };
        refresh(&mut s, 1000 + 3599);
        assert_ne!(s.update, UpdateState::None);
        refresh(&mut s, 1000 + 3600);
        assert_eq!(s.update, UpdateState::None);
    }

    #[test]
    fn the_window_reads_the_update_by_its_state() {
        let ready = serde_json::to_value(UpdateState::Ready { version: "0.1.3".into() }).unwrap();
        assert_eq!(ready, serde_json::json!({ "state": "ready", "version": "0.1.3" }));
        assert_eq!(
            serde_json::to_value(UpdateState::None).unwrap(),
            serde_json::json!({ "state": "none" })
        );
    }
}
