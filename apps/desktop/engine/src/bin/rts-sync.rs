//! Runs the sync engine from a terminal, until the app's window exists and
//! for trying it out:
//!
//!   rts-sync status     the installs, game folders and characters found
//!   rts-sync link       link this PC (opens the browser to approve)
//!   rts-sync once       one sync pass
//!   rts-sync run        watch and sync until stopped
//!   rts-sync unlink     forget this PC's token
//!
//! RTS_SERVER picks the server (default: the test server) and RTS_DATA_DIR
//! the folder for the app's state and downloaded journeys.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;

use rts_sync::api::{ApiError, Client};
use rts_sync::state::{self, State, TokenFile};
use rts_sync::sync::Report;
use rts_sync::{installs, link, sync, watch};

fn main() -> ExitCode {
    let server = std::env::var("RTS_SERVER").unwrap_or_else(|_| rts_sync::api::DEFAULT_SERVER.to_string());
    let data = std::env::var_os("RTS_DATA_DIR").map(PathBuf::from).unwrap_or_else(state::data_dir);
    let state_path = data.join("state.json");
    let cache = data.join("journeys");
    let mut state = match State::load(&state_path) {
        Ok(state) => state,
        Err(e) => return fail(&format!("couldn't read {}: {e}", state_path.display())),
    };
    let tokens = TokenFile::new(data.join("token"));
    let client = Client::new(&server, tokens.get());

    match std::env::args().nth(1).as_deref() {
        Some("status") => {
            println!(
                "server {server}; {}",
                match (&state.battletag, tokens.get()) {
                    (Some(tag), Some(_)) => format!("linked to {tag}"),
                    _ => "not linked".into(),
                }
            );
            for game in sync::games(&state) {
                println!(
                    "{} (addon {})",
                    game.path.display(),
                    installs::addon_version(&game.path).unwrap_or_else(|| "developer".into())
                );
                for file in installs::saved_files(&game) {
                    match std::fs::read(&file.path).ok().as_deref().and_then(sync::roster_key) {
                        Some((name, realm)) => println!("  {name}-{realm}"),
                        None => println!("  {} (log in once with the updated addon)", file.path.display()),
                    }
                }
            }
            ExitCode::SUCCESS
        }
        Some("link") => {
            let name = std::env::args().nth(2).unwrap_or_else(|| "This PC".into());
            let linked = link::link(
                &client,
                &name,
                |url, code| {
                    println!("Approve code {code} at {url}");
                    let _ = open(url);
                },
                std::thread::sleep,
                || true,
            );
            match linked {
                Ok(linked) => {
                    if let Err(e) = tokens.set(&linked.token) {
                        return fail(&format!("couldn't keep the token: {e}"));
                    }
                    state.pc = Some(linked.pc);
                    state.battletag = Some(linked.battletag.clone());
                    state.uploaded.clear();
                    // Another server's version ids mean other journeys.
                    let _ = std::fs::remove_dir_all(&cache);
                    if let Err(e) = state.save(&state_path) {
                        return fail(&e.to_string());
                    }
                    println!("Linked to {}.", linked.battletag);
                    ExitCode::SUCCESS
                }
                Err(e) => fail(&e.to_string()),
            }
        }
        Some("once") => {
            let games = sync::games(&state);
            let result = sync::pass(&client, &mut state, &state_path, &games, &cache, |_| true);
            show(&result);
            if result.is_ok() { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        Some("run") => {
            let stop = AtomicBool::new(false);
            let picked = state.picked.clone();
            let find = || {
                sync::games(&State {
                    picked: picked.clone(),
                    ..State::default()
                })
            };
            match watch::run(
                &client,
                &mut state,
                &state_path,
                &cache,
                &find,
                &stop,
                &AtomicBool::new(false),
                show,
            ) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e.to_string()),
            }
        }
        Some("unlink") => {
            let _ = tokens.clear();
            let _ = std::fs::remove_dir_all(&cache);
            state = State {
                picked: state.picked,
                ..State::default()
            };
            match state.save(&state_path) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e.to_string()),
            }
        }
        _ => fail("usage: rts-sync status | link [PC name] | once | run | unlink"),
    }
}

fn show(result: &Result<Report, ApiError>) {
    match result {
        Ok(r) => {
            for key in &r.uploaded {
                println!("uploaded {key}");
            }
            for game in &r.delivered {
                println!("delivered to {game}");
            }
            for key in &r.update_addon {
                println!("{key}: update the addon on this PC");
            }
            for problem in &r.problems {
                match problem.who.as_str() {
                    "" => println!("problem: {}", problem.why),
                    who => println!("problem: {who}: {}", problem.why),
                }
            }
        }
        Err(ApiError::Unauthorized) => println!("This PC isn't linked: run rts-sync link."),
        Err(e) => println!("{e}"),
    }
}

fn open(url: &str) -> std::io::Result<std::process::Child> {
    let opener = if cfg!(windows) {
        "explorer"
    } else if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    std::process::Command::new(opener).arg(url).spawn()
}

fn fail(message: &str) -> ExitCode {
    eprintln!("{message}");
    ExitCode::FAILURE
}
