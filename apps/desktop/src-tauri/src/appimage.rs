//! What running as an AppImage on Linux changes: programs the app starts,
//! such as the browser, must not inherit the AppImage's own libraries, and
//! start at login must name the AppImage file in a way the desktop reads
//! back.

use std::fs;
use std::path::PathBuf;

/// The environment for a program the app starts: the AppImage's start
/// script puts its own folders first in PATH, LD_LIBRARY_PATH and the like,
/// and the host's programs (xdg-open, the browser) fail to load against its
/// older libraries. None when not running from an AppImage.
pub fn host_env(vars: impl IntoIterator<Item = (String, String)>) -> Option<Vec<(String, String)>> {
    let vars: Vec<(String, String)> = vars.into_iter().collect();
    let appdir = vars
        .iter()
        .find(|(k, _)| k == "APPDIR")
        .map(|(_, v)| v.clone())
        .filter(|v| !v.is_empty())?;
    let mut env = Vec::new();
    for (key, value) in vars {
        if key == "APPDIR" {
            continue;
        }
        let kept: Vec<&str> = value.split(':').filter(|part| !part.starts_with(&appdir)).collect();
        if !kept.is_empty() {
            env.push((key, kept.join(":")));
        }
    }
    Some(env)
}

/// Starts the browser at `url` with the host's own environment. False when
/// not running from an AppImage, or when xdg-open couldn't start.
pub fn open_outside(url: &str) -> bool {
    let vars = std::env::vars_os().map(|(k, v)| (k.to_string_lossy().into_owned(), v.to_string_lossy().into_owned()));
    let Some(env) = host_env(vars) else { return false };
    match std::process::Command::new("xdg-open").arg(url).env_clear().envs(env).spawn() {
        Ok(mut child) => {
            std::thread::spawn(move || child.wait());
            true
        }
        Err(_) => false,
    }
}

/// The autostart entry's Exec line for the AppImage at `appimage`, quoted
/// as the desktop entry spec asks, so a path with a space still starts.
/// `--hidden` matches the arguments main.rs gives the autostart plugin.
pub fn exec_line(appimage: &str) -> String {
    let quoted: String = appimage
        .chars()
        .map(|c| match c {
            '"' | '`' | '$' | '\\' => format!("\\{c}"),
            _ => c.to_string(),
        })
        .collect();
    format!("Exec=\"{}\" --hidden", quoted.replace('\\', "\\\\").replace('%', "%%"))
}

/// `entry` with its Exec line replaced by `line`.
pub fn with_exec(entry: &str, line: &str) -> String {
    entry
        .split_inclusive('\n')
        .map(|l| {
            if l.starts_with("Exec=") {
                format!("{line}{}", if l.ends_with('\n') { "\n" } else { "" })
            } else {
                l.to_string()
            }
        })
        .collect()
}

/// Writes the autostart entry's Exec line again, quoted, with the AppImage's
/// path now: the plugin writes it unquoted, and the file may have moved.
pub fn fix_autostart(app_name: &str) {
    let (Some(appimage), Some(home)) = (std::env::var_os("APPIMAGE"), std::env::var_os("HOME")) else {
        return;
    };
    let file = PathBuf::from(home).join(".config/autostart").join(format!("{app_name}.desktop"));
    let Ok(entry) = fs::read_to_string(&file) else { return };
    let fixed = with_exec(&entry, &exec_line(&appimage.to_string_lossy()));
    if fixed != entry {
        let _ = fs::write(&file, fixed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars(list: &[(&str, &str)]) -> Vec<(String, String)> {
        list.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn programs_the_app_starts_leave_the_appimages_folders_behind() {
        let env = host_env(vars(&[
            ("APPDIR", "/tmp/.mount_RoadXy"),
            ("APPIMAGE", "/home/deck/Road-to-Sixty.AppImage"),
            ("PATH", "/tmp/.mount_RoadXy/usr/bin:/usr/local/bin:/usr/bin"),
            (
                "LD_LIBRARY_PATH",
                "/tmp/.mount_RoadXy/usr/lib/:/tmp/.mount_RoadXy/usr/lib/x86_64-linux-gnu",
            ),
            ("XDG_DATA_DIRS", "/tmp/.mount_RoadXy/usr/share/:/usr/local/share:/usr/share"),
            ("GIO_MODULE_DIR", "/tmp/.mount_RoadXy/usr/lib/gio/modules"),
            ("HOME", "/home/deck"),
        ]))
        .unwrap();
        assert_eq!(
            env,
            vars(&[
                ("APPIMAGE", "/home/deck/Road-to-Sixty.AppImage"),
                ("PATH", "/usr/local/bin:/usr/bin"),
                ("XDG_DATA_DIRS", "/usr/local/share:/usr/share"),
                ("HOME", "/home/deck"),
            ])
        );
        assert_eq!(host_env(vars(&[("PATH", "/usr/bin")])), None, "not an AppImage");
        assert_eq!(host_env(vars(&[("APPDIR", ""), ("PATH", "/usr/bin")])), None);
    }

    #[test]
    fn start_at_login_quotes_the_appimage_path() {
        assert_eq!(
            exec_line("/home/deck/Road-to-Sixty.AppImage"),
            "Exec=\"/home/deck/Road-to-Sixty.AppImage\" --hidden"
        );
        assert_eq!(
            exec_line("/home/deck/Downloads/Road-to-Sixty (1).AppImage"),
            "Exec=\"/home/deck/Downloads/Road-to-Sixty (1).AppImage\" --hidden"
        );
        // Quoting escapes " ` $ and \, then the string rules double every \,
        // and % starts a field code.
        assert_eq!(exec_line("/a\"b$c%d"), "Exec=\"/a\\\\\"b\\\\$c%%d\" --hidden");
    }

    #[test]
    fn only_the_exec_line_changes() {
        let entry = "[Desktop Entry]\nType=Application\nName=Road to Sixty\nExec=/home/deck/Road to Sixty.AppImage --hidden\nX-GNOME-Autostart-enabled=true\n";
        assert_eq!(
            with_exec(entry, "Exec=\"/x\" --hidden"),
            "[Desktop Entry]\nType=Application\nName=Road to Sixty\nExec=\"/x\" --hidden\nX-GNOME-Autostart-enabled=true\n"
        );
    }
}
