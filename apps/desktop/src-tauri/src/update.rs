//! Updates from the downloads bucket. The tray offers one when a check
//! finds it, and the window's Account tab can check by hand.

use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

/// The newer version on offer, if any.
pub async fn check(app: &AppHandle) -> Result<Option<String>, String> {
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?;
    Ok(update.map(|u| u.version))
}

/// Downloads and installs the newer version, then restarts into it.
pub async fn install(app: &AppHandle) -> Result<(), String> {
    let Some(update) = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())? else {
        return Ok(());
    };
    update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
    app.restart();
}

#[tauri::command]
pub async fn check_update(app: AppHandle) -> Result<Option<String>, String> {
    check(&app).await
}

#[tauri::command]
pub async fn install_update(app: AppHandle) -> Result<(), String> {
    install(&app).await
}
