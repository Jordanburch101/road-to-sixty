//! The account screens' calls to the server (spec, "Account API"). They are
//! made here because only the app holds the PC token; the window never sees
//! it. Answers pass through as the server sent them, and the window reads
//! them with packages/api's types.

use std::path::{Path, PathBuf};

use rts_sync::api::{ApiError, Client};
use rts_sync::state::TokenFile;
use serde_json::{Value, json};
use tauri::{AppHandle, State};
use tauri_plugin_dialog::DialogExt;

pub struct Account {
    server: String,
    token: PathBuf,
}

impl Account {
    pub fn new(server: &str, data: &Path) -> Account {
        Account {
            server: server.to_string(),
            token: data.join("token"),
        }
    }

    fn client(&self) -> Result<Client, String> {
        let token = TokenFile::new(self.token.clone()).get().ok_or("this PC isn't linked")?;
        Ok(Client::new(&self.server, Some(token)).app(crate::VERSION))
    }

    /// Off the main thread: the window waits for the answer, the app doesn't.
    async fn call(&self, method: &'static str, path: String, body: Option<Value>) -> Result<Value, String> {
        let client = self.client()?;
        tauri::async_runtime::spawn_blocking(move || client.account(method, &path, body))
            .await
            .map_err(|e| e.to_string())?
            .map_err(words)
    }
}

/// The server's own reason when it gave one ({ "error": ... }), else the
/// error as the app words it.
fn words(e: ApiError) -> String {
    if let ApiError::Status(_, body) = &e
        && let Some(why) = serde_json::from_str::<Value>(body)
            .ok()
            .and_then(|v| v["error"].as_str().map(str::to_string))
    {
        return why;
    }
    e.to_string()
}

/// A PC id from the window, as one part of a path.
fn segment(id: &str) -> Result<&str, String> {
    if !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        Ok(id)
    } else {
        Err("no such PC".into())
    }
}

#[tauri::command]
pub async fn characters(account: State<'_, Account>) -> Result<Value, String> {
    account.call("GET", "/v1/characters".into(), None).await
}

#[tauri::command]
pub async fn versions(account: State<'_, Account>, id: i64) -> Result<Value, String> {
    account.call("GET", format!("/v1/characters/{id}/versions"), None).await
}

#[tauri::command]
pub async fn restore(account: State<'_, Account>, id: i64, version: i64) -> Result<Value, String> {
    account
        .call("POST", format!("/v1/characters/{id}/restore"), Some(json!({ "version": version })))
        .await
}

/// Removes one journey from the backup. A 409 while its merge runs comes
/// back as the server's own words.
#[tauri::command]
pub async fn remove_character(account: State<'_, Account>, id: i64) -> Result<Value, String> {
    account.call("DELETE", format!("/v1/characters/{id}"), None).await
}

#[tauri::command]
pub async fn devices(account: State<'_, Account>) -> Result<Value, String> {
    account.call("GET", "/v1/devices".into(), None).await
}

#[tauri::command]
pub async fn rename_device(account: State<'_, Account>, id: String, name: String) -> Result<Value, String> {
    let path = format!("/v1/devices/{}", segment(&id)?);
    account.call("PATCH", path, Some(json!({ "name": name }))).await
}

#[tauri::command]
pub async fn unlink_device(account: State<'_, Account>, id: String) -> Result<Value, String> {
    let path = format!("/v1/devices/{}", segment(&id)?);
    account.call("DELETE", path, None).await
}

/// Asks where to save, then saves every character's journey there as a
/// zip. False when the player cancelled.
#[tauri::command]
pub async fn export_data(app: AppHandle, account: State<'_, Account>) -> Result<bool, String> {
    let client = account.client()?;
    tauri::async_runtime::spawn_blocking(move || {
        let picked = crate::window::holding(&app, || app.dialog().file().set_file_name("road-to-sixty.zip").blocking_save_file());
        let Some(path) = picked.and_then(|p| p.into_path().ok()) else {
            return Ok(false);
        };
        std::fs::write(&path, client.export().map_err(words)?).map_err(|e| e.to_string())?;
        Ok(true)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Deletes the account on the server, then unlinks here: the server keeps
/// the asking PC linked until the very end, so a failure can be retried.
#[tauri::command]
pub async fn delete_account(app: AppHandle, account: State<'_, Account>) -> Result<(), String> {
    account.call("DELETE", "/v1/account".into(), None).await?;
    crate::commands::with_runner(app, |r| r.unlink());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_read_as_the_servers_own_words() {
        assert_eq!(
            words(ApiError::Status(400, r#"{"error":"a PC needs a name"}"#.into())),
            "a PC needs a name"
        );
        assert_eq!(words(ApiError::Status(413, "too big".into())), "the server answered 413: too big");
        assert_eq!(words(ApiError::Unauthorized), "this PC isn't linked");
    }

    #[test]
    fn a_pc_id_must_be_one_plain_path_part() {
        assert_eq!(segment("pc_2-a"), Ok("pc_2-a"));
        assert!(segment("../account").is_err());
        assert!(segment("").is_err());
    }
}
