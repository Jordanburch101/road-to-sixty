# Linux app for Steam Deck Desktop Mode

Issue #47. An early Linux build of the existing desktop app, for the Steam
Deck and other Linux handhelds, in Desktop Mode only.

## Why

Players with a Steam Deck or another handheld have asked for the app.
Windows handhelds (ROG Ally, Legion Go) already run the Windows build; the
gap is SteamOS and other Linux systems (Bazzite and the like), where WoW
runs through Proton or Lutris. Jordan has no Deck, so everything a
container can check is checked in CI, and the rest waits for a player.

Success: a Deck player downloads one file in Desktop Mode, links the PC,
and their characters back up and sync like on any other PC. Play in Game
Mode is backed up too: the save file stays on disk, the app starts with
the next Desktop Mode session, sees the changed file and uploads it.

Left out, until players ask: Game Mode (no tray there, and desktop
start-at-login items don't run), a background service, Flatpak, ARM builds,
.deb and .rpm packages.

## Packaging: AppImage

One file the player marks as runnable and opens. Tauri builds it without
extra tools, and the updater replaces it in place, so self-update keeps
working. SteamOS's system folders are read-only and wiped on each update,
so the AppImage has to carry what it needs; Tauri's carries the web view.
The tray library (libayatana-appindicator) may be missing on SteamOS, and
the app panics without it; Tauri's AppImage packs it whenever the app uses
a tray (tauri-cli 2.12.2), so nothing is added for it. If the tray still
doesn't show, opening the AppImage again shows the window, since
tauri-plugin-single-instance already brings the running copy forward.

Programs the app starts, the browser for linking above all, would inherit
the AppImage's own library folders and fail to load against its older
libraries, so on Linux the app starts `xdg-open` with every variable
pointing inside the AppImage (`APPDIR`) taken out (`appimage.rs`). The
window also shows the link page's address while linking, for when no
browser opens.

`tauri-plugin-autostart` 2.7.0 writes `~/.config/autostart` with the
AppImage's own path (`app.env().appimage`), not the temporary mount it
runs from, so start at login survives a reboot as long as the file isn't
moved. It doesn't quote that path, so a file named
`Road-to-Sixty (1).AppImage` would never start; the app writes the Exec
line again, quoted, whenever start at login is turned on and at every
start while it is on, which also follows a moved file once it's opened.

Flatpak was weighed and dropped: a manifest, its own CI and Flathub review,
the self-updater doesn't work in its sandbox, and the sandbox needs the
home folder to reach Steam's prefixes.

## Finding WoW (`installs.rs`)

On Linux, WoW lives inside a Wine prefix: a folder with `drive_c` and
`dosdevices` (links from drive letters to real folders: `c:` to `drive_c`,
`z:` to `/`). `find_installs` gains a Linux branch that takes the home
folder as an argument, so tests hand it a made-up home.

1. **Prefixes.** A prefix is a folder with a `drive_c`. Looked for in:
   - every Steam library's `steamapps/compatdata/*/pfx`. Libraries come
     from `libraryfolders.vdf` (only its `"path"` lines are read) in
     `~/.local/share/Steam/steamapps` and in Flatpak Steam's
     `~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps`,
     plus those two Steam folders themselves and `~/.steam/steam`, the
     link every native Steam keeps to its data (the only way to reach
     Debian's and Ubuntu's `~/.steam/debian-installation`). Non-Steam games (Battle.net
     added to Steam, NonSteamLaunchers' shared `NonSteamLaunchers` prefix)
     sit here under long random names, and on an SD card under
     `/run/media/<card>/steamapps/compatdata`.
   - `~/Games/*` (Lutris; its WoW installer defaults to
     `~/Games/world-of-warcraft`).
   - `~/.var/app/com.usebottles.bottles/data/bottles/bottles/*` (Bottles).
   - `~/.wine`.
2. **Installs in a prefix.** Battle.net's list at
   `drive_c/ProgramData/Battle.net/Agent/product.db`, read by the existing
   `installs_in_product_db`, and the default
   `drive_c/Program Files (x86)/World of Warcraft`.
3. **Drive letters.** A `X:/rest` path from the list becomes
   `<prefix>/dosdevices/x:/rest`, so an install on any drive letter (an SD
   card included) resolves without guessing. The existing
   `fs::canonicalize` then gives the real path, which also follows a prefix
   moved to the SD card and linked back.
4. **Anything else** (Heroic, a custom Lutris folder, an unknown tool) uses
   "Add a folder", which on Linux opens in the home folder.

Game folders, saved files, watching and the five-minute rescan are
unchanged once an install is found, except that the addon's folders are
matched without regard to case: Wine loads `Interface/Addons` too, and
Linux's disks care about case. The sync folder goes in the same spelling.

## Noticing the game start (`watch.rs`)

Under Wine, `/proc/<pid>/exe` is Wine's own program, so `game_running`'s
"program file inside the game folder" never matches. On Linux,
`running_programs` also reads each process's command line (sysinfo's
`cmd`). Wine starts the game with its Windows path there, e.g.
`C:\Program Files (x86)\World of Warcraft\_classic_beta_\WowClassic.exe`.
A process counts as the game when an argument, with backslashes turned
into slashes, ends in `<install folder name>/<game folder name>/<file>.exe`,
compared without case against the game folder's last two path parts.

Two prefixes holding the same folder names could fool it; the cost is one
unneeded sync. If it misses entirely, only the pull of other PCs' play
before login is lost: the upload after play comes from watching the save
file.

## Tray and window

- Linux tray icons report no left click, so the menu's existing "Open Road
  to Sixty" is the way in.
- `window::show` already falls back to the top-right corner when the tray
  icon's place is unknown. Under Wayland (newer KDE, Bazzite) the desktop
  places the window itself; that is fine.
- The touchscreen acts as a mouse in Desktop Mode; the window already fits
  1280×800.

## `rts-sync status`

Gains one line per game folder saying whether the game is running, so the
smoke test can check game-start detection. It is a developer tool, not in
the AppImage.

## CI (`ci.yml`, `ubuntu-22.04` in the `desktop-app` matrix)

On `ubuntu-22.04` (the oldest base we support, so the AppImage runs on
older and newer systems alike):

1. Install the Tauri Linux build packages (WebKitGTK 4.1, appindicator,
   librsvg, patchelf) and LuaJIT; run every Rust test, the app's included.
   The comment on the `desktop` job saying the app can't build on Linux
   goes.
2. Build the AppImage with the updater files switched off by a config
   override (`-c '{"bundle":{"createUpdaterArtifacts":false}}'`), since
   pull requests have no signing key.
3. `apps/desktop/scripts/linux-smoke.sh <AppImage> <out>` in an
   `archlinux` container with only Xvfb, ImageMagick (for the screenshot)
   and what any desktop has (fonts, X, OpenGL), deliberately not WebKitGTK,
   GTK or the tray library. It unpacks the AppImage with
   `--appimage-extract` (no FUSE in a container) and fails if any program
   or library inside needs one this system lacks. Then it runs `AppRun`
   under a made-up home, waits 20 seconds, fails if the app died or its log
   shows part of it couldn't load, and saves a screenshot.
4. `apps/desktop/scripts/wine-check.sh <rts-sync>` on the Ubuntu runner:
   it builds a stand-in `WowClassic.exe` with mingw, puts it in a made-up
   Lutris prefix (`<home>/Games/wow`) beside the addon's toc, starts it
   through Wine, and checks that `rts-sync status` finds the install and
   says the game is running.
5. Upload the screenshot and the AppImage as the run's artifacts.

## Release (`desktop-release.yml`)

- The build matrix gains `ubuntu-22.04` with the same packages. After the
  signed build it runs `linux-smoke.sh` on the AppImage, then collects
  `Road-to-Sixty_<v>_amd64.AppImage` and its `.sig`.
- Uploads still need every build to pass, so `latest.json` always lists
  every platform. A Linux failure holds up a Mac and Windows release; the
  pull request job catches nearly all of those first.
- The bucket also gets the fixed name `app/Road-to-Sixty.AppImage` for the
  website, never cached.
- `latest-json.ts` gains `linux-x86_64`, with its test.
- The header comment's "Mac app and the Windows installer" names Linux too.

## Website (`apps/web`)

- `download.ts`: `Choice` gains `linux`. A Linux computer that isn't a
  phone gets "Download for Linux (early)". Android, including big
  tablets that send a Linux desktop browser's name, and ARM Linux stay
  "choose": the AppImage is x86 only. Tests in
  `download.test.ts` follow.
- `/download/linux` (through `[platform].astro`): the steps.
  1. Switch to Desktop Mode.
  2. Download the file and keep it in your home folder (moving it later
     breaks start at login).
  3. Right-click it, Properties, "Allow executing as program".
  4. Open it and link it as on any other computer.
  5. If WoW isn't found, "Add a game folder" and pick the World of Warcraft
     folder inside your Proton or Lutris folder.
  6. No tray icon? Open the file again to bring up the window.
  7. Games played in Game Mode back up the next time you're in Desktop
     Mode.
- The "choose" page lists Linux as a third option.
- `apps/web/AGENTS.md` and `apps/desktop/AGENTS.md` describe the Linux
  build in the same commits.

## What only a Deck can confirm

Posted on #47 as a tester checklist once the first early build is out:

- Was WoW found, and through which tool (Steam's Proton, Flatpak Lutris,
  Bottles, other)?
- Did the tray icon show?
- Does the app start after a reboot?
- Did a sync start when the game launched?
- A screenshot of the app's character list.
- Does the window fit and work with touch and trackpads?

The download says "early" until a player reports back.
