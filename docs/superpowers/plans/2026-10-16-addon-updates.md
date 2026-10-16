# The app installs the addon and keeps it up to date: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The desktop app offers to install the Road to Sixty addon into every game that runs its client, and keeps installed copies up to date from signed releases in the downloads bucket (#54).

**Architecture:** The addon Release workflow signs its zip with the app updater's key and puts it, then `addon/latest.json`, in the bucket. The engine gains `addon.rs` (reading `latest.json`, checking signatures, comparing versions, unpacking and swapping folders) and `installs::game_dirs` (each game folder's client version from the game's own `.flavor.info` and `.build.info`). The app gains `addons.rs`: a check every 6 hours on its own thread, a tick every 30 seconds that puts waiting updates into games that aren't running, the per-folder state the window shows, and three commands.

**Tech Stack:** Rust (engine `rts-sync`, Tauri 2 app), `minisign-verify` 0.3.0, `zip` 4.6.1, `base64` 0.22.1 (all already in `Cargo.lock`), React window, GitHub Actions with Bun and the Tauri CLI, Cloudflare R2.

**Spec:** `docs/superpowers/specs/2026-10-16-addon-updates-design.md` (mockups: `2026-10-16-addon-updates-mockup.html` beside it).

**Worktree:** `/Users/jordan/personal/road-to-sixty-addon-updates`, branch `addon-updates` (from `dev`). `bun install` has been run there.

## Global Constraints

- Bucket paths: `addon/RoadToSixty-<version>.zip`, `.zip.sig` beside it, and `addon/latest.json`, written last and only for a tag without `alpha` or `beta`. Public URL `https://dl.roadtosixty.online/addon/latest.json`.
- `latest.json`: `{ "version": "1.10.1", "interface": 16001, "zip": "https://dl.roadtosixty.online/addon/RoadToSixty-1.10.1.zip", "signature": "<the .sig file's text>" }`.
- Signing key: the app updater's (`TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`); public key: `plugins.updater.pubkey` in `apps/desktop/src-tauri/tauri.conf.json` (base64 of the minisign public key text).
- A game folder qualifies when its client's major and minor equal the release interface's (`interface / 10000`, `interface / 100 % 100`); 16001 is client 1.60.
- Only `RoadToSixty` in a game's AddOns folder is ever written, through `.RoadToSixty-new` and `.RoadToSixty-old`. Never `RoadToSixty_Sync`, never `WTF`.
- Never touched: a copy whose toc has no version filled in, an addon folder that is a link, a copy at or above the release's version.
- Window words, verbatim: "No addon yet", "Install the addon", "Install Road to Sixty <version>", "Puts the addon in this game's AddOns folder. It keeps itself up to date after that.", "Addon <v>", " · updated today", "Addon <v> · <latest> installs when WoW closes", "Developer addon · the app leaves it alone", "Couldn't update the addon: <why>. Trying again in a few hours.", "Addon <v> · <latest> is out", "Update", "Addon <v> · not for this version of WoW", "Keep the addon up to date", "New versions install while WoW is closed. A developer copy is never changed.", "Addon updated to <v>", "Its newest journey comes in when you next log in to <Name>.", "Update the addon on this PC to get the newest journey (Account, Game folders)."
- App version 0.1.9 in `apps/desktop/src-tauri/tauri.conf.json` and `apps/desktop/src-tauri/Cargo.toml`.
- Test data is made up. The test signing key's private half is never committed.
- Comments in plain words, explaining why; British spelling. Commits `Area: what (#54)`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Each app's `AGENTS.md` updated in the commit that changes what it describes.
- Rust: from `apps/desktop`, `. ~/.cargo/env && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings` before each Rust commit.

## Review Focus

1. A zip whose entries try to land outside `RoadToSixty/` (`../`, an absolute path, a link entry): nothing written outside, the old copy untouched (Task 4 tests "an entry outside the folder…", "a link entry…").
2. The rename into place failing after the old copy moved aside (antivirus, a lock): the old copy back as `RoadToSixty`, nothing left half-done (Task 4 test "a failed swap puts the old copy back").
3. A game running while an update waits: no files change until it closes; then they do within 30 seconds (Task 6 test "the tick waits for a running game" uses an injected running check).
4. A folder on another client (Classic Era 1.15, or no `.flavor.info`) with or without the addon: never offered, never updated (Task 5 tests).
5. A download that fails its signature: nothing installed, the folder shows why (Task 6 test "a download with a bad signature installs nothing").

---

### Task 1: Publishing the addon to the bucket

**Files:**
- Create: `apps/addon/scripts/publish.sh`
- Modify: `.github/workflows/release.yml` (after "GitHub release")
- Create: `.github/workflows/addon-publish.yml`
- Modify: `CLAUDE.md` (Release section)

**Interfaces:**
- Produces: `bash apps/addon/scripts/publish.sh <absolute zip path> <version> <release|beta|alpha>`; bucket files and `latest.json` as in Global Constraints.

- [ ] **Step 1: Write the script**

`apps/addon/scripts/publish.sh`:

```bash
#!/usr/bin/env bash
# Puts a release zip in the downloads bucket for the app to install
# (spec 2026-10-16, addon updates): signed with the app updater's key,
# checked with minisign against the app's public key, and latest.json
# written last, only for a full release, then read back.
#
#   publish.sh <absolute path of the zip> <version> <release|beta|alpha>
#
# Needs bun (the repo's packages installed), minisign, jq, unzip and the
# aws CLI, with TAURI_SIGNING_PRIVATE_KEY, TAURI_SIGNING_PRIVATE_KEY_PASSWORD,
# R2_ENDPOINT and the AWS_* settings in the environment.
set -euo pipefail

zip=$1 version=$2 type=$3
root=$(cd "$(dirname "$0")/../../.." && pwd)
bucket=road-to-sixty-downloads
downloads=https://dl.roadtosixty.online
name=$(basename "$zip")
work=$(mktemp -d)

# From the zip itself, so a re-publish of an old tag names that tag's client.
interface=$(unzip -p "$zip" RoadToSixty/RoadToSixty.toc | sed -n 's/^## Interface: *\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$interface" ] || { echo "the zip's toc has no Interface line" >&2; exit 1; }

(cd "$root/apps/desktop" && bunx tauri signer sign "$zip" >/dev/null)

# A zip signed with another key would be refused by every app, so it never
# reaches the bucket.
jq -r '.plugins.updater.pubkey' "$root/apps/desktop/src-tauri/tauri.conf.json" | base64 -d > "$work/updater.pub"
base64 -d "$zip.sig" > "$work/check.sig"
minisign -V -q -p "$work/updater.pub" -x "$work/check.sig" -m "$zip"

s3() { aws s3 --endpoint-url "$R2_ENDPOINT" "$@"; }
s3 cp "$zip" "s3://$bucket/addon/$name"
s3 cp "$zip.sig" "s3://$bucket/addon/$name.sig"

if [ "$type" != release ]; then
  echo "A $type: latest.json stays as it is."
  exit 0
fi
jq -n --arg v "$version" --argjson i "$interface" --arg z "$downloads/addon/$name" --rawfile s "$zip.sig" \
  '{version: $v, interface: $i, zip: $z, signature: ($s | rtrimstr("\n"))}' > "$work/latest.json"
s3 cp "$work/latest.json" "s3://$bucket/addon/latest.json" --cache-control no-cache --content-type application/json
curl -fsS "$downloads/addon/latest.json" | jq -e --arg v "$version" '.version == $v' >/dev/null
echo "Published $version to $downloads/addon/."
```

Run: `chmod +x apps/addon/scripts/publish.sh && bash -n apps/addon/scripts/publish.sh && echo ok`
Expected: `ok`.

- [ ] **Step 2: Check the signing and latest.json lines with a test key, without uploading**

```bash
D=$(mktemp -d) && mkdir -p $D/RoadToSixty && printf '## Interface: 16001\n## Version: 1.10.1\n' > $D/RoadToSixty/RoadToSixty.toc \
  && (cd $D && zip -q -X -r addon.zip RoadToSixty) \
  && (cd apps/desktop && bunx tauri signer generate --ci -p "" -w $D/test.key >/dev/null) \
  && (cd apps/desktop && TAURI_SIGNING_PRIVATE_KEY="$(cat $D/test.key)" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" bunx tauri signer sign $D/addon.zip >/dev/null) \
  && unzip -p $D/addon.zip RoadToSixty/RoadToSixty.toc | sed -n 's/^## Interface: *\([0-9][0-9]*\).*/\1/p' \
  && jq -n --arg v 1.10.1 --argjson i 16001 --arg z https://x/addon.zip --rawfile s $D/addon.zip.sig '{version: $v, interface: $i, zip: $z, signature: ($s | rtrimstr("\n"))}' | jq -c 'keys'; rm -rf $D
```

Expected: `16001`, then `["interface","signature","version","zip"]`.

- [ ] **Step 3: Call it from the Release workflow**

In `.github/workflows/release.yml`, add to the header comment, after the CurseForge paragraph:

```yaml
# The zip also goes to the downloads bucket for the desktop app
# (apps/addon/scripts/publish.sh): signed with the app updater's key, and
# for a full release latest.json moves to it. Run "Addon publish" by hand
# to redo it for an existing tag.
```

After the "GitHub release" step, before "CurseForge upload":

```yaml
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: 1.4.2

      - name: Downloads bucket
        env:
          TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
          TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_DOWNLOADS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_DOWNLOADS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: auto
          # R2 rejects the newer checksums the aws CLI sends by default.
          AWS_REQUEST_CHECKSUM_CALCULATION: when_required
          AWS_RESPONSE_CHECKSUM_VALIDATION: when_required
          R2_ENDPOINT: ${{ secrets.R2_ENDPOINT }}
        run: |
          bun install --frozen-lockfile
          sudo apt-get install -y minisign
          bash apps/addon/scripts/publish.sh "$PWD/apps/addon/${{ steps.package.outputs.zip }}" \
            "${{ steps.package.outputs.version }}" "${{ steps.type.outputs.type }}"
```

Check what `steps.package.outputs.zip` holds: `grep -n "zip=" apps/addon/scripts/package.ps1`. If it is already an absolute path, use `"${{ steps.package.outputs.zip }}"` as it is instead of prefixing `$PWD/apps/addon/`.

- [ ] **Step 4: The manual workflow**

`.github/workflows/addon-publish.yml`:

```yaml
# Run by hand (Actions > Addon publish > Run workflow) to put an existing
# release's zip in the downloads bucket for the desktop app: once for
# v1.10.0, the release before publishing was automatic, and to redo a
# publish that failed in the Release workflow.
name: Addon publish

on:
  workflow_dispatch:
    inputs:
      tag:
        description: "The release to publish (e.g. v1.10.0)"
        required: true

permissions:
  contents: read

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: 1.4.2
      - name: Publish
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ inputs.tag }}
          TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
          TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_DOWNLOADS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_DOWNLOADS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: auto
          AWS_REQUEST_CHECKSUM_CALCULATION: when_required
          AWS_RESPONSE_CHECKSUM_VALIDATION: when_required
          R2_ENDPOINT: ${{ secrets.R2_ENDPOINT }}
        run: |
          version="${TAG#v}"
          case "$TAG" in
            *alpha*) type=alpha ;;
            *beta*)  type=beta ;;
            *)       type=release ;;
          esac
          bun install --frozen-lockfile
          sudo apt-get update -qq && sudo apt-get install -y minisign
          gh release download "$TAG" --pattern "RoadToSixty-$version.zip" --dir dist
          bash apps/addon/scripts/publish.sh "$PWD/dist/RoadToSixty-$version.zip" "$version" "$type"
```

Run: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('ok')" .github/workflows/release.yml .github/workflows/addon-publish.yml`
Expected: `ok`.

- [ ] **Step 5: CLAUDE.md**

In the root `CLAUDE.md`, Release section, step 4 ("The Release workflow fails at once…"), change "and uploads to CurseForge." to "puts the zip in the downloads bucket for the app (`apps/addon/scripts/publish.sh`; a full release moves `addon/latest.json`), and uploads to CurseForge." Add a step after step 5: "If only the bucket step failed, run `gh workflow run addon-publish.yml -f tag=vX.Y.Z`."

- [ ] **Step 6: Commit**

```bash
git add apps/addon/scripts/publish.sh .github/workflows/release.yml .github/workflows/addon-publish.yml CLAUDE.md
git commit -m "Release: sign the addon zip and put it in the downloads bucket for the app (#54)"
```

---

### Task 2: Each game folder's client version

**Files:**
- Modify: `apps/desktop/engine/src/installs.rs`

**Interfaces:**
- Produces: `pub struct GameDir { pub path: PathBuf, pub name: String, pub client: Option<(u32, u32)> }`; `pub fn game_dirs(install: &Path) -> Vec<GameDir>`; `pub fn build_versions(text: &str) -> Vec<(String, String)>` (product, version); `pub fn flavor(text: &str) -> Option<String>`; `child` becomes `pub(crate)`.

- [ ] **Step 1: Write the failing tests**

In `installs.rs`'s `mod tests`, add:

```rust
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
        assert_eq!(flavor("Product Flavor!STRING:0\nwow_classic_beta\n"), Some("wow_classic_beta".to_string()));
        assert_eq!(flavor(""), None);
    }

    #[test]
    fn each_game_folder_carries_its_client_version_with_or_without_the_addon() {
        let install = tempfile::tempdir().unwrap();
        touch(&install.path().join(".build.info"), BUILD_INFO);
        touch(&install.path().join("_classic_beta_/.flavor.info"), "Product Flavor!STRING:0\nwow_classic_beta\n");
        touch(&install.path().join("_classic_era_/.flavor.info"), "Product Flavor!STRING:0\nwow_classic_era\n");
        fs::create_dir_all(install.path().join("_retail_")).unwrap();
        fs::create_dir_all(install.path().join("Utils")).unwrap();
        let dirs = game_dirs(install.path());
        let seen: Vec<(&str, Option<(u32, u32)>)> = dirs.iter().map(|d| (d.name.as_str(), d.client)).collect();
        assert_eq!(seen, vec![("_classic_beta_", Some((1, 60))), ("_classic_era_", Some((1, 15))), ("_retail_", None)]);
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p rts-sync installs 2>&1 | tail -5`
Expected: compile errors, `build_versions`, `flavor` and `game_dirs` not found.

- [ ] **Step 3: Implement**

Change `fn child` to `pub(crate) fn child`. Add after `game_folders`:

```rust
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
    let builds = fs::read_to_string(install.join(".build.info")).map(|t| build_versions(&t)).unwrap_or_default();
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
    let (Some(version), Some(product)) = (columns.iter().position(|c| *c == "Version"), columns.iter().position(|c| *c == "Product")) else {
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
```

- [ ] **Step 4: Run them to see them pass**

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p rts-sync installs 2>&1 | tail -5`
Expected: all installs tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/engine/src/installs.rs
git commit -m "App: read each game folder's client version from the game's own files (#54)"
```

---

### Task 3: The release the app installs: latest.json, versions, signatures

**Files:**
- Create: `apps/desktop/engine/src/addon.rs`
- Modify: `apps/desktop/engine/src/lib.rs` (`pub mod addon;`), `apps/desktop/engine/Cargo.toml`
- Create: `apps/desktop/engine/tests/fixtures/addon/RoadToSixty-1.10.1.zip`, `RoadToSixty-1.10.1.zip.sig`, `test.key.pub`

**Interfaces:**
- Produces: `pub const LATEST: &str`; `#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)] pub struct Latest { pub version: String, pub interface: u32, pub zip: String, pub signature: String }`; `pub fn numbers(version: &str) -> Option<(u32, u32, u32)>`; `pub fn newer(a: &str, b: &str) -> bool` (a newer than b); `pub fn fits(client: (u32, u32), interface: u32) -> bool`; `pub fn verify(data: &[u8], signature: &str, key: &str) -> Result<(), String>`; `pub fn fetch(url: &str) -> Result<Vec<u8>, String>`.

- [ ] **Step 1: Make the fixtures**

```bash
F=apps/desktop/engine/tests/fixtures/addon && mkdir -p $F && D=$(mktemp -d) && mkdir -p $D/RoadToSixty/ZoneMasks \
  && printf '## Interface: 16001\n## Version: 1.10.1\n' > $D/RoadToSixty/RoadToSixty.toc \
  && printf -- '-- made up for the app tests\n' > $D/RoadToSixty/Core.lua \
  && printf -- '-- a file in a subfolder\n' > $D/RoadToSixty/ZoneMasks/a.lua \
  && (cd $D && zip -q -X -r RoadToSixty-1.10.1.zip RoadToSixty) \
  && (cd apps/desktop && bunx tauri signer generate --ci -p "" -w $D/test.key >/dev/null) \
  && (cd apps/desktop && TAURI_SIGNING_PRIVATE_KEY="$(cat $D/test.key)" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" bunx tauri signer sign $D/RoadToSixty-1.10.1.zip >/dev/null) \
  && cp $D/RoadToSixty-1.10.1.zip $D/RoadToSixty-1.10.1.zip.sig $D/test.key.pub $F/ && rm -rf $D && ls $F
```

Expected: the three files listed. The private key is deleted with `$D`.

- [ ] **Step 2: Add the dependencies**

In `apps/desktop/engine/Cargo.toml` `[dependencies]`, add (the versions the app already locks):

```toml
base64 = "=0.22.1"
minisign-verify = "=0.3.0"
zip = { version = "=4.6.1", default-features = false, features = ["deflate-flate2-zlib-rs"] }
```

- [ ] **Step 3: Write the failing tests**

Create `apps/desktop/engine/src/addon.rs` with only its tests and `pub mod addon;` in `lib.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const ZIP: &[u8] = include_bytes!("../tests/fixtures/addon/RoadToSixty-1.10.1.zip");
    pub(crate) const SIG: &str = include_str!("../tests/fixtures/addon/RoadToSixty-1.10.1.zip.sig");
    pub(crate) const KEY: &str = include_str!("../tests/fixtures/addon/test.key.pub");

    #[test]
    fn versions_compare_by_their_numbers() {
        assert_eq!(numbers("1.10.0"), Some((1, 10, 0)));
        assert_eq!(numbers("1.11.0-beta"), Some((1, 11, 0)));
        assert_eq!(numbers("@project-version@"), None);
        assert!(newer("1.10.0", "1.9.0"));
        assert!(!newer("1.10.1", "1.11.0-beta"), "a beta of a later version is newer than the release");
        assert!(!newer("1.10.0", "1.10.0"));
        assert!(!newer("1.10.0", "not a version"));
    }

    #[test]
    fn a_release_fits_the_client_its_interface_names() {
        assert!(fits((1, 60), 16001));
        assert!(!fits((1, 15), 16001));
        assert!(!fits((5, 5), 16001));
    }

    #[test]
    fn latest_json_reads_as_the_bucket_writes_it() {
        let text = r#"{"version":"1.10.1","interface":16001,"zip":"https://dl.roadtosixty.online/addon/RoadToSixty-1.10.1.zip","signature":"c2ln"}"#;
        let latest: Latest = serde_json::from_str(text).unwrap();
        assert_eq!((latest.version.as_str(), latest.interface), ("1.10.1", 16001));
    }

    #[test]
    fn only_a_zip_signed_with_the_key_passes() {
        assert_eq!(verify(ZIP, SIG, KEY), Ok(()));
        let mut changed = ZIP.to_vec();
        *changed.last_mut().unwrap() ^= 1;
        assert_eq!(verify(&changed, SIG, KEY), Err("the download isn't signed by Road to Sixty".into()));
        assert!(verify(ZIP, "not a signature", KEY).is_err());
        assert!(verify(ZIP, SIG, "not a key").is_err());
    }
}
```

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p rts-sync addon 2>&1 | tail -5`
Expected: compile errors, `numbers`, `newer`, `fits`, `Latest`, `verify` not found.

- [ ] **Step 4: Implement**

At the top of `addon.rs`:

```rust
//! The addon release the app installs (spec 2026-10-16, addon updates):
//! the bucket's latest.json, its signature, which game it fits, and putting
//! it into a game's AddOns folder without the game ever seeing half of it.

use std::time::Duration;

use base64::Engine;
use serde::{Deserialize, Serialize};

pub const LATEST: &str = "https://dl.roadtosixty.online/addon/latest.json";

/// What `addon/latest.json` says: the newest full release.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Latest {
    pub version: String,
    /// The toc's `## Interface`, which names the client it is built for.
    pub interface: u32,
    pub zip: String,
    /// The `.sig` file's text: base64 of a minisign signature.
    pub signature: String,
}

/// A version's numbers; `1.11.0-beta` counts as 1.11.0.
pub fn numbers(version: &str) -> Option<(u32, u32, u32)> {
    let mut parts = version.split(['.', '-']);
    Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.parse().ok()?))
}

/// Whether a is newer than b. Anything unreadable is never newer, so a
/// copy whose version can't be read is never replaced by mistake.
pub fn newer(a: &str, b: &str) -> bool {
    matches!((numbers(a), numbers(b)), (Some(a), Some(b)) if a > b)
}

/// Whether a release built for `interface` loads in a client: 16001 is 1.60.
pub fn fits(client: (u32, u32), interface: u32) -> bool {
    client == (interface / 10000, interface / 100 % 100)
}

/// Checks a download against the app updater's public key, as the updater
/// checks the app's own updates. Both come as base64 of minisign's text.
pub fn verify(data: &[u8], signature: &str, key: &str) -> Result<(), String> {
    let text = |b64: &str| {
        base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
    };
    let key = text(key)
        .and_then(|t| minisign_verify::PublicKey::decode(&t).ok())
        .ok_or("the app's key can't be read")?;
    let signature = text(signature)
        .and_then(|t| minisign_verify::Signature::decode(&t).ok())
        .ok_or("the download's signature can't be read")?;
    key.verify(data, &signature, true)
        .map_err(|_| "the download isn't signed by Road to Sixty".to_string())
}

/// A file from the downloads bucket, up to 32 MB (a release is under 1 MB).
pub fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(60)))
        .build()
        .new_agent();
    agent
        .get(url)
        .call()
        .map_err(|e| e.to_string())?
        .body_mut()
        .with_config()
        .limit(32 * 1024 * 1024)
        .read_to_vec()
        .map_err(|e| e.to_string())
}
```

- [ ] **Step 5: Run them to see them pass**

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p rts-sync addon 2>&1 | tail -5`
Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add apps/desktop/engine apps/desktop/Cargo.lock
git commit -m "App: read the addon release, compare versions and check its signature (#54)"
```

---

### Task 4: Putting the addon into a game safely

**Files:**
- Modify: `apps/desktop/engine/src/addon.rs`

**Interfaces:**
- Consumes: `ZIP` from Task 3's tests; `installs::child` (now `pub(crate)`).
- Produces: `pub fn install(addons: &Path, zip: &[u8]) -> Result<(), String>` (`addons` is the game's AddOns folder; the zip must already be verified); `pub fn install_with(addons: &Path, zip: &[u8], rename: impl FnMut(&Path, &Path) -> std::io::Result<()>) -> Result<(), String>`; `pub fn is_link(path: &Path) -> bool`.

- [ ] **Step 1: Write the failing tests**

Add to `addon.rs`'s tests:

```rust
    use std::fs;
    use std::io::Write;
    use std::path::Path;

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    // A zip with these entries, as a hostile or broken download might be.
    fn zip_of(entries: &[(&str, &str)]) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut zip = zip::ZipWriter::new(&mut out);
        for (name, text) in entries {
            zip.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
        out.into_inner()
    }

    fn old_copy(addons: &Path) {
        fs::create_dir_all(addons.join("RoadToSixty")).unwrap();
        fs::write(addons.join("RoadToSixty/RoadToSixty.toc"), "## Version: 1.9.0\n").unwrap();
        fs::write(addons.join("RoadToSixty/Gone.lua"), "-- only in the old version\n").unwrap();
    }

    #[test]
    fn a_release_replaces_the_old_copy_whole() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        fs::create_dir_all(addons.join("RoadToSixty_Sync")).unwrap();
        install(&addons, ZIP).unwrap();
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.10.1"));
        assert!(addons.join("RoadToSixty/ZoneMasks/a.lua").is_file());
        assert!(!addons.join("RoadToSixty/Gone.lua").exists(), "nothing of the old version is left in it");
        assert!(addons.join("RoadToSixty_Sync").is_dir(), "the sync folder is left alone");
        assert!(!addons.join(".RoadToSixty-new").exists() && !addons.join(".RoadToSixty-old").exists());
    }

    #[test]
    fn a_first_install_makes_the_folder() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        install(&addons, ZIP).unwrap();
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.10.1"));
    }

    #[test]
    fn an_entry_outside_the_folder_refuses_the_whole_zip() {
        for bad in ["../evil.lua", "/tmp/evil.lua", "Other/evil.lua", "RoadToSixty/../../evil.lua"] {
            let game = tempfile::tempdir().unwrap();
            let addons = game.path().join("Interface/AddOns");
            old_copy(&addons);
            let zip = zip_of(&[("RoadToSixty/RoadToSixty.toc", "## Version: 1.10.1\n"), (bad, "-- no")]);
            assert!(install(&addons, &zip).is_err(), "{bad} is refused");
            assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.9.0"), "{bad}: the old copy stays");
            assert!(!game.path().join("evil.lua").exists() && !addons.join("evil.lua").exists());
            assert!(!addons.join(".RoadToSixty-new").exists());
        }
    }

    #[test]
    fn a_zip_without_the_addons_toc_is_refused() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        assert!(install(&addons, &zip_of(&[("RoadToSixty/Core.lua", "--")])).is_err());
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.9.0"));
    }

    #[test]
    fn a_failed_swap_puts_the_old_copy_back() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        let mut calls = 0;
        let result = install_with(&addons, ZIP, |from, to| {
            calls += 1;
            if calls == 2 { Err(std::io::Error::other("locked")) } else { fs::rename(from, to) }
        });
        assert!(result.is_err());
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.9.0"));
        assert!(!addons.join(".RoadToSixty-old").exists() && !addons.join(".RoadToSixty-new").exists());
    }

    #[test]
    fn leftovers_from_a_crash_are_cleared_first() {
        let game = tempfile::tempdir().unwrap();
        let addons = game.path().join("Interface/AddOns");
        old_copy(&addons);
        fs::create_dir_all(addons.join(".RoadToSixty-new/RoadToSixty")).unwrap();
        fs::create_dir_all(addons.join(".RoadToSixty-old")).unwrap();
        install(&addons, ZIP).unwrap();
        assert!(read(&addons.join("RoadToSixty/RoadToSixty.toc")).contains("1.10.1"));
        assert!(!addons.join(".RoadToSixty-new").exists() && !addons.join(".RoadToSixty-old").exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_addon_folder_is_never_written() {
        let game = tempfile::tempdir().unwrap();
        let repo = tempfile::tempdir().unwrap();
        fs::write(repo.path().join("RoadToSixty.toc"), "## Version: @project-version@\n").unwrap();
        let addons = game.path().join("Interface/AddOns");
        fs::create_dir_all(&addons).unwrap();
        std::os::unix::fs::symlink(repo.path(), addons.join("RoadToSixty")).unwrap();
        assert!(is_link(&addons.join("RoadToSixty")));
        assert!(install(&addons, ZIP).is_err());
        assert!(read(&repo.path().join("RoadToSixty.toc")).contains("@project-version@"));
    }
```

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p rts-sync addon 2>&1 | tail -5`
Expected: compile errors, `install`, `install_with`, `is_link` not found.

- [ ] **Step 2: Implement**

Add to the `use` lines at the top of `addon.rs`: `use std::fs;`, `use std::io;`, `use std::path::{Component, Path};`. Then:

```rust
const NAME: &str = "RoadToSixty";
const NEW: &str = ".RoadToSixty-new";
const OLD: &str = ".RoadToSixty-old";

/// Whether a folder is a link, as the developer copy is (a junction on
/// Windows counts too).
pub fn is_link(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink())
}

/// Puts a verified release into a game's AddOns folder.
pub fn install(addons: &Path, zip: &[u8]) -> Result<(), String> {
    install_with(addons, zip, |from, to| fs::rename(from, to))
}

/// The release is unpacked beside the old copy and swapped in by renaming,
/// so the game never sees half of it; a failed swap puts the old one back.
/// WoW loads neither leftover name: an addon folder loads only when its toc
/// has the folder's own name.
pub fn install_with(addons: &Path, zip: &[u8], mut rename: impl FnMut(&Path, &Path) -> io::Result<()>) -> Result<(), String> {
    let target = crate::installs::child(addons, NAME);
    if is_link(&target) {
        return Err("the addon folder is a link to a developer copy".into());
    }
    let (new, old) = (addons.join(NEW), addons.join(OLD));
    for leftover in [&new, &old] {
        if leftover.exists() {
            fs::remove_dir_all(leftover).map_err(words)?;
        }
    }
    fs::create_dir_all(addons).map_err(words)?;
    if let Err(e) = unpack(zip, &new) {
        let _ = fs::remove_dir_all(&new);
        return Err(e);
    }
    let had = target.exists();
    if had && let Err(e) = rename(&target, &old) {
        let _ = fs::remove_dir_all(&new);
        return Err(words(e));
    }
    if let Err(e) = rename(&new.join(NAME), &target) {
        if had {
            let _ = rename(&old, &target);
        }
        let _ = fs::remove_dir_all(&new);
        return Err(words(e));
    }
    let _ = fs::remove_dir_all(&new);
    if had {
        let _ = fs::remove_dir_all(&old);
    }
    Ok(())
}

/// Every entry must be a plain file or folder under `RoadToSixty/`; one
/// that isn't refuses the whole zip, so nothing lands anywhere else.
fn unpack(zip: &[u8], into: &Path) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(io::Cursor::new(zip)).map_err(|e| format!("the download isn't a zip ({e})"))?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let path = entry
            .enclosed_name()
            .filter(|p| !entry.is_symlink() && p.components().next() == Some(Component::Normal(NAME.as_ref())))
            .ok_or("the download has a file outside the addon's folder")?;
        let out = into.join(path);
        if entry.is_dir() {
            fs::create_dir_all(&out).map_err(words)?;
        } else {
            fs::create_dir_all(out.parent().unwrap_or(into)).map_err(words)?;
            let mut file = fs::File::create(&out).map_err(words)?;
            io::copy(&mut entry, &mut file).map_err(words)?;
        }
    }
    if !into.join(NAME).join("RoadToSixty.toc").is_file() {
        return Err("the download isn't the addon".into());
    }
    Ok(())
}

/// A file error in words a player can read.
fn words(e: io::Error) -> String {
    match e.kind() {
        io::ErrorKind::PermissionDenied | io::ErrorKind::ReadOnlyFilesystem => "the folder can't be written to".into(),
        io::ErrorKind::StorageFull => "the disk is full".into(),
        _ => e.to_string(),
    }
}
```

- [ ] **Step 3: Run them to see them pass**

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p rts-sync addon 2>&1 | tail -5`
Expected: all addon tests pass. If `enclosed_name` lets `RoadToSixty/../../evil.lua` through as `../evil.lua`-free, the `Component::Normal` check on the first component and `enclosed_name` returning `None` for paths that leave the root cover it; the test proves which.

- [ ] **Step 4: Format, lint, commit**

```bash
cd apps/desktop && . ~/.cargo/env && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings && cd ../..
git add apps/desktop/engine
git commit -m "App: put the addon into a game by unpacking beside it and swapping, never half a copy (#54)"
```

---

### Task 5: Each folder's addon state, and the words the tray and list use

**Files:**
- Create: `apps/desktop/src-tauri/src/addons.rs` (pure part)
- Modify: `apps/desktop/src-tauri/src/main.rs` (`mod addons;`), `apps/desktop/src-tauri/src/status.rs`

**Interfaces:**
- Consumes: `installs::GameDir`, `addon::{Latest, newer, fits, is_link}`.
- Produces (in `addons.rs`): `pub enum Copy { None, Developer, Version(String) }`; `pub fn copy_in(game: &Path) -> Copy`; `#[serde(tag = "state", rename_all = "camelCase")] pub enum FolderState { Current, Waiting { latest: String }, Missing { latest: String }, Developer, Failed { why: String }, Behind { latest: String }, OtherClient }`; `pub struct Folder { pub path: String, pub name: String, pub characters: usize, pub addon: Option<String>, pub updated_at: Option<u64>, #[serde(flatten)] pub state: FolderState }`; `pub fn state(copy: &Copy, client: Option<(u32, u32)>, latest: Option<&Latest>, failed: Option<&str>, updates: bool, asked: bool) -> Option<FolderState>`.
- Produces (in `status.rs`): `Status.folders: Vec<Folder>`, `Status.addon_updates: bool`, `Status.addon_updated: Option<AddonUpdated>`, `pub struct AddonUpdated { pub version: String, pub at: u64 }`.

- [ ] **Step 1: Write the failing tests**

Create `apps/desktop/src-tauri/src/addons.rs` with:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn latest() -> Latest {
        Latest { version: "1.10.1".into(), interface: 16001, zip: String::new(), signature: String::new() }
    }
    const FOREVER: Option<(u32, u32)> = Some((1, 60));
    const ERA: Option<(u32, u32)> = Some((1, 15));
    fn v(s: &str) -> Copy {
        Copy::Version(s.into())
    }

    #[test]
    fn a_folder_without_the_addon_is_offered_it_only_on_its_client() {
        let l = latest();
        assert_eq!(state(&Copy::None, FOREVER, Some(&l), None, true, false), Some(FolderState::Missing { latest: "1.10.1".into() }));
        assert_eq!(state(&Copy::None, ERA, Some(&l), None, true, false), None, "Classic Era isn't listed");
        assert_eq!(state(&Copy::None, None, Some(&l), None, true, false), None, "no .flavor.info: not listed");
        assert_eq!(state(&Copy::None, FOREVER, None, None, true, false), None, "nothing to install yet");
    }

    #[test]
    fn an_installed_copy_reads_as_current_waiting_behind_or_another_client() {
        let l = latest();
        assert_eq!(state(&v("1.10.1"), FOREVER, Some(&l), None, true, false), Some(FolderState::Current));
        assert_eq!(state(&v("1.11.0-beta"), FOREVER, Some(&l), None, true, false), Some(FolderState::Current), "never backwards");
        assert_eq!(state(&v("1.10.0"), FOREVER, Some(&l), None, true, false), Some(FolderState::Waiting { latest: "1.10.1".into() }));
        assert_eq!(state(&v("1.10.0"), FOREVER, Some(&l), None, false, false), Some(FolderState::Behind { latest: "1.10.1".into() }));
        assert_eq!(state(&v("1.10.0"), FOREVER, Some(&l), None, false, true), Some(FolderState::Waiting { latest: "1.10.1".into() }), "Update was pressed");
        assert_eq!(state(&v("1.10.0"), ERA, Some(&l), None, true, false), Some(FolderState::OtherClient));
        assert_eq!(state(&v("1.10.0"), FOREVER, None, None, true, false), Some(FolderState::Current), "offline: nothing newer known");
        assert_eq!(state(&v("1.10.0"), FOREVER, Some(&l), Some("the disk is full"), true, false), Some(FolderState::Failed { why: "the disk is full".into() }));
        assert_eq!(state(&Copy::Developer, FOREVER, Some(&l), None, true, false), Some(FolderState::Developer));
    }

    #[test]
    fn a_folder_reads_as_the_window_expects() {
        let f = Folder { path: "/wow/_classic_beta_".into(), name: "_classic_beta_".into(), characters: 2, addon: Some("1.10.0".into()), updated_at: None, state: FolderState::Waiting { latest: "1.10.1".into() } };
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
```

In `status.rs`'s tests, add:

```rust
    #[test]
    fn a_character_held_back_for_a_newer_addon_reads_calmly_while_updates_are_on() {
        let mut s = linked();
        s.characters = vec![Character { key: "Bo-Test".into(), here: true, update_addon: true, uploaded: None, problem: None, note: String::new() }];
        s.addon_updates = true;
        refresh(&mut s, 1000);
        assert_eq!(s.characters[0].note, "Its newest journey comes in when you next log in to Bo.");
        assert_ne!(s.line, "Update the addon on this PC");
        s.addon_updates = false;
        refresh(&mut s, 1000);
        assert_eq!(s.characters[0].note, "Update the addon on this PC to get the newest journey (Account, Game folders).");
        assert_eq!(s.line, "Update the addon on this PC");
    }

    #[test]
    fn an_addon_update_shows_in_the_line_for_an_hour() {
        let mut s = linked();
        s.last_synced = Some(900);
        s.addon_updated = Some(AddonUpdated { version: "1.10.1".into(), at: 1000 });
        refresh(&mut s, 1000);
        assert_eq!(s.line, "Addon updated to 1.10.1");
        refresh(&mut s, 1000 + 3600);
        assert_eq!(s.addon_updated, None);
        assert!(s.line.starts_with("Synced"));
    }
```

Check the existing status tests for the old note text "Update the addon on this PC to get the newest journey" (`grep -n "get the newest journey" src-tauri/src/status.rs`) and change each to the new text with " (Account, Game folders)." where it now applies (`addon_updates` is false in `linked()`).

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p road-to-sixty-app 2>&1 | tail -5`
Expected: compile errors for the missing items.

- [ ] **Step 2: Implement the pure part of addons.rs**

Above the tests in `addons.rs`, and `mod addons;` in `main.rs`:

```rust
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
    Waiting { latest: String },
    /// No addon yet, and the release fits this game.
    Missing { latest: String },
    Developer,
    /// The last try failed; the next check clears it and tries again.
    Failed { why: String },
    /// Updates are off and a newer version is out.
    Behind { latest: String },
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
pub fn state(copy: &Copy, client: Option<(u32, u32)>, latest: Option<&Latest>, failed: Option<&str>, updates: bool, asked: bool) -> Option<FolderState> {
    let fits = |l: &Latest| client.is_some_and(|c| addon::fits(c, l.interface));
    match copy {
        Copy::None => latest.filter(|l| fits(l)).map(|l| FolderState::Missing { latest: l.version.clone() }),
        Copy::Developer => Some(FolderState::Developer),
        Copy::Version(v) => Some(match latest {
            Some(l) if !fits(l) => FolderState::OtherClient,
            _ if failed.is_some() => FolderState::Failed { why: failed.unwrap_or_default().into() },
            Some(l) if addon::newer(&l.version, v) && (updates || asked) => FolderState::Waiting { latest: l.version.clone() },
            Some(l) if addon::newer(&l.version, v) => FolderState::Behind { latest: l.version.clone() },
            _ => FolderState::Current,
        }),
    }
}
```

- [ ] **Step 3: The status fields and words**

In `status.rs`, add to `Status` after `games`:

```rust
    /// Every game folder the addon is in or could go in, for the window.
    pub folders: Vec<crate::addons::Folder>,
    /// "Keep the addon up to date" is on.
    pub addon_updates: bool,
    /// The addon was just updated, for the line, for an hour.
    pub addon_updated: Option<AddonUpdated>,
```

and below `UpdateState`:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AddonUpdated {
    pub version: String,
    pub at: u64,
}
```

In `refresh`, after the `UpdateState::Updated` expiry:

```rust
    if status.addon_updated.as_ref().is_some_and(|u| now.saturating_sub(u.at) >= 3600) {
        status.addon_updated = None;
    }
```

Replace the character note's `update_addon` branch with:

```rust
        } else if c.update_addon && status.addon_updates {
            let name = c.key.split('-').next().unwrap_or(&c.key);
            format!("Its newest journey comes in when you next log in to {name}.")
        } else if c.update_addon {
            "Update the addon on this PC to get the newest journey (Account, Game folders).".into()
```

In the line, change `} else if status.characters.iter().any(|c| c.update_addon) {` to `} else if !status.addon_updates && status.characters.iter().any(|c| c.update_addon) {`, and before `} else if let Some(t) = status.last_synced {` add:

```rust
    } else if let Some(u) = &status.addon_updated {
        format!("Addon updated to {}", u.version)
```

The `for c in &mut status.characters` loop borrows `status` mutably while the new branch reads `status.addon_updates`: read it into `let updates = status.addon_updates;` before the loop and use `updates` in the branch.

- [ ] **Step 4: Run them to see them pass**

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p road-to-sixty-app 2>&1 | tail -5`
Expected: all pass (`addons.rs` items may warn as unused until Task 6; clippy runs after Task 6).

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/src-tauri/src
git commit -m "App: each game folder's addon state, and calm words while the addon updates itself (#54)"
```

---

### Task 6: The check, the tick and the commands

**Files:**
- Modify: `apps/desktop/src-tauri/src/addons.rs` (the `Addons` part), `apps/desktop/src-tauri/src/main.rs`

**Interfaces:**
- Consumes: Task 3 and 4's engine functions, Task 5's `state`, `copy_in`, `Folder`, status fields; `rts_sync::watch::{game_running, running_programs}`; `crate::runner::{local_keys, now, Notifier}`.
- Produces: `pub struct Addons`; `Addons::new(data: &Path, key: &str) -> Addons`; `check(&self) -> Result<(), String>`; `tick(&self, picked: &[PathBuf], notifier: &Notifier)`; `tick_with(&self, installs: &[PathBuf], notifier: &Notifier, running: &dyn Fn(&Path) -> bool)` (the installs given directly, so tests never touch a real WoW on the machine); `put_latest(&self, latest: Latest, zip: Vec<u8>)` (tests only); commands `install_addon(path: String)`, `update_addon(path: String)`, `set_addon_updates(on: bool)`.

- [ ] **Step 1: Write the failing tests**

Add to `addons.rs`'s tests:

```rust
    use std::fs;
    use std::path::PathBuf;

    const ZIP: &[u8] = include_bytes!("../../engine/tests/fixtures/addon/RoadToSixty-1.10.1.zip");
    const SIG: &str = include_str!("../../engine/tests/fixtures/addon/RoadToSixty-1.10.1.zip.sig");
    const KEY: &str = include_str!("../../engine/tests/fixtures/addon/test.key.pub");
    const BUILD_INFO: &str = "Version!STRING:0|Product!STRING:0\n1.60.1.70374|wow_classic_beta\n";

    // An install with one Forever game folder, holding the addon at `version`
    // or none: the temporary folder, the install as the tick sees it (its
    // real path, as find_installs gives it), and the game folder.
    fn install_with_game(version: Option<&str>) -> (tempfile::TempDir, Vec<PathBuf>, PathBuf) {
        let install = tempfile::tempdir().unwrap();
        fs::write(install.path().join(".build.info"), BUILD_INFO).unwrap();
        let game = install.path().join("_classic_beta_");
        fs::create_dir_all(&game).unwrap();
        fs::write(game.join(".flavor.info"), "Product Flavor!STRING:0\nwow_classic_beta\n").unwrap();
        if let Some(v) = version {
            let dir = game.join("Interface/AddOns/RoadToSixty");
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("RoadToSixty.toc"), format!("## Version: {v}\n")).unwrap();
        }
        let installs = vec![fs::canonicalize(install.path()).unwrap()];
        let game = installs[0].join("_classic_beta_");
        (install, installs, game)
    }

    fn addons(data: &Path, signature: &str) -> Addons {
        let a = Addons::new(data, KEY);
        a.put_latest(Latest { version: "1.10.1".into(), interface: 16001, zip: String::new(), signature: signature.into() }, ZIP.to_vec());
        a
    }

    fn installed(game: &Path) -> Copy {
        copy_in(game)
    }

    #[test]
    fn the_tick_updates_a_folder_whose_game_isnt_running() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()));
        let s = notifier.get();
        assert_eq!(s.folders[0].state, FolderState::Current);
        assert_eq!(s.addon_updated.map(|u| u.version), Some("1.10.1".into()));
        assert!(s.addon_updates);
    }

    #[test]
    fn the_tick_waits_for_a_running_game() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.tick_with(&installs, &notifier, &|_| true);
        assert_eq!(installed(&game), Copy::Version("1.10.0".into()), "nothing changes while it runs");
        assert_eq!(notifier.get().folders[0].state, FolderState::Waiting { latest: "1.10.1".into() });
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()), "then it goes in");
    }

    #[test]
    fn a_download_with_a_bad_signature_installs_nothing() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), "bm90IGEgc2lnbmF0dXJl");
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.0".into()));
        assert!(matches!(&notifier.get().folders[0].state, FolderState::Failed { .. }));
    }

    #[test]
    fn with_updates_off_a_copy_waits_for_its_update_button() {
        let (_keep, installs, game) = install_with_game(Some("1.10.0"));
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        a.set_updates(false).unwrap();
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.0".into()));
        assert_eq!(notifier.get().folders[0].state, FolderState::Behind { latest: "1.10.1".into() });
        a.update(&game);
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()));
        assert!(!Addons::new(data.path(), KEY).updates_on(), "the switch is remembered");
    }

    #[test]
    fn install_puts_the_addon_only_into_a_folder_offered_it() {
        let (_keep, installs, game) = install_with_game(None);
        let data = tempfile::tempdir().unwrap();
        let notifier = Notifier::new(|_| {});
        let a = addons(data.path(), SIG);
        assert!(a.install(&game).is_err(), "not offered before a tick listed it");
        a.tick_with(&installs, &notifier, &|_| false);
        assert_eq!(notifier.get().folders[0].state, FolderState::Missing { latest: "1.10.1".into() });
        a.install(&game).unwrap();
        assert_eq!(installed(&game), Copy::Version("1.10.1".into()));
        assert!(a.install(Path::new("/somewhere/else")).is_err());
    }
```

Run: `cd apps/desktop && . ~/.cargo/env && cargo test -p road-to-sixty-app addons 2>&1 | tail -5`
Expected: compile errors, `Addons` not found.

- [ ] **Step 2: Implement `Addons`**

Extend the `use` lines in `addons.rs`:

```rust
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rts_sync::installs::GameFolder;
use rts_sync::watch;
use serde::Deserialize;

use crate::runner::{Notifier, local_keys, now};
use crate::status::AddonUpdated;
```

Then:

```rust
/// What the app remembers, in `addon/addon.json` in its data folder: the
/// switch, and by game folder when it last put the addon in and the last
/// failure. Its own file, so it never races the sync thread's state.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Saved {
    #[serde(default = "on")]
    updates: bool,
    #[serde(default)]
    folders: BTreeMap<PathBuf, Record>,
}

fn on() -> bool {
    true
}

impl Default for Saved {
    fn default() -> Saved {
        Saved { updates: true, folders: BTreeMap::new() }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Record {
    updated_at: Option<u64>,
    failed: Option<String>,
}

#[derive(Default)]
struct Inner {
    latest: Option<Latest>,
    zip: Option<Vec<u8>>,
    saved: Saved,
    /// Folders whose Update button was pressed while updates are off.
    asked: BTreeSet<PathBuf>,
    /// Folders the last tick offered the addon to: the only ones Install may write.
    offered: BTreeSet<PathBuf>,
    updated: Option<AddonUpdated>,
}

pub struct Addons {
    dir: PathBuf,
    key: String,
    inner: Mutex<Inner>,
}

impl Addons {
    /// `key` is the updater's public key from tauri.conf.json. A release
    /// downloaded before, kept in the data folder, is used again if it
    /// still passes its signature, so a start without the network still knows it.
    pub fn new(data: &Path, key: &str) -> Addons {
        let dir = data.join("addon");
        let saved = fs::read(dir.join("addon.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let latest: Option<Latest> = fs::read(dir.join("latest.json")).ok().and_then(|b| serde_json::from_slice(&b).ok());
        let zip = fs::read(dir.join("RoadToSixty.zip")).ok();
        let (latest, zip) = match (latest, zip) {
            (Some(l), Some(z)) if addon::verify(&z, &l.signature, key).is_ok() => (Some(l), Some(z)),
            _ => (None, None),
        };
        Addons { dir, key: key.into(), inner: Mutex::new(Inner { latest, zip, saved, ..Inner::default() }) }
    }

    /// Reads latest.json and downloads a release not seen before. Failures
    /// from the last tries are cleared, so each folder gets another try.
    pub fn check(&self) -> Result<(), String> {
        self.inner.lock().unwrap().saved.folders.values_mut().for_each(|r| r.failed = None);
        let text = addon::fetch(addon::LATEST)?;
        let latest: Latest = serde_json::from_slice(&text).map_err(|e| e.to_string())?;
        if self.inner.lock().unwrap().latest.as_ref() == Some(&latest) {
            return Ok(());
        }
        let zip = addon::fetch(&latest.zip)?;
        fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        fs::write(self.dir.join("RoadToSixty.zip"), &zip).map_err(|e| e.to_string())?;
        fs::write(self.dir.join("latest.json"), &text).map_err(|e| e.to_string())?;
        self.put_latest(latest, zip);
        Ok(())
    }

    /// Takes a release in; the tick checks its signature before installing.
    pub fn put_latest(&self, latest: Latest, zip: Vec<u8>) {
        let mut inner = self.inner.lock().unwrap();
        inner.latest = Some(latest);
        inner.zip = Some(zip);
    }

    pub fn updates_on(&self) -> bool {
        self.inner.lock().unwrap().saved.updates
    }

    pub fn set_updates(&self, on: bool) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        inner.saved.updates = on;
        self.save(&inner.saved)
    }

    /// The Update button: this folder updates as if updates were on.
    pub fn update(&self, game: &Path) {
        self.inner.lock().unwrap().asked.insert(game.to_path_buf());
    }

    /// The Install button: only into a folder the last tick offered it to,
    /// at once, even with the game running: a new folder is only read at
    /// the game's next start.
    pub fn install(&self, game: &Path) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        if !inner.offered.contains(game) {
            return Err("that game folder isn't offered the addon".into());
        }
        self.put(&mut inner, game)
    }

    /// Lists every game folder with its state and puts waiting updates into
    /// games that aren't running. Runs every 30 seconds, so an update goes
    /// in soon after the game closes.
    pub fn tick(&self, picked: &[PathBuf], notifier: &Notifier) {
        let programs = watch::running_programs(&mut sysinfo::System::new());
        self.tick_with(&installs::find_installs(picked), notifier, &|game| watch::game_running(game, &programs));
    }

    pub fn tick_with(&self, found: &[PathBuf], notifier: &Notifier, running: &dyn Fn(&Path) -> bool) {
        let mut inner = self.inner.lock().unwrap();
        let mut folders = Vec::new();
        inner.offered.clear();
        for install in found {
            for dir in installs::game_dirs(install) {
                let mut found = self.folder_state(&inner, &dir.path, dir.client);
                if matches!(found, Some(FolderState::Waiting { .. })) && !running(&dir.path) {
                    let _ = self.put(&mut inner, &dir.path);
                    found = self.folder_state(&inner, &dir.path, dir.client);
                }
                let Some(state) = found else { continue };
                if matches!(state, FolderState::Missing { .. }) {
                    inner.offered.insert(dir.path.clone());
                }
                let game = GameFolder { path: dir.path.clone(), name: dir.name.clone() };
                folders.push(Folder {
                    path: dir.path.display().to_string(),
                    name: dir.name,
                    characters: local_keys(std::slice::from_ref(&game)).len(),
                    addon: match copy_in(&dir.path) {
                        Copy::Version(v) => Some(v),
                        _ => None,
                    },
                    updated_at: inner.saved.folders.get(&dir.path).and_then(|r| r.updated_at),
                    state,
                });
            }
        }
        let (updates, updated) = (inner.saved.updates, inner.updated.take());
        drop(inner);
        notifier.update(|s| {
            s.folders = folders;
            s.addon_updates = updates;
            if updated.is_some() {
                s.addon_updated = updated;
            }
        });
    }

    fn folder_state(&self, inner: &Inner, game: &Path, client: Option<(u32, u32)>) -> Option<FolderState> {
        let failed = inner.saved.folders.get(game).and_then(|r| r.failed.as_deref());
        state(&copy_in(game), client, inner.latest.as_ref(), failed, inner.saved.updates, inner.asked.contains(game))
    }

    /// Checks the release's signature and puts it into one game, noting the
    /// result. Only RoadToSixty is written.
    fn put(&self, inner: &mut Inner, game: &Path) -> Result<(), String> {
        let (Some(latest), Some(zip)) = (inner.latest.clone(), inner.zip.as_ref()) else {
            return Err("the addon hasn't downloaded yet; try again in a minute".into());
        };
        let result = addon::verify(zip, &latest.signature, &self.key).and_then(|()| addon::install(&installs::addons_folder(game), zip));
        let record = inner.saved.folders.entry(game.to_path_buf()).or_default();
        match &result {
            Ok(()) => {
                *record = Record { updated_at: Some(now()), failed: None };
                inner.asked.remove(game);
                inner.updated = Some(AddonUpdated { version: latest.version.clone(), at: now() });
            }
            Err(why) => record.failed = Some(why.clone()),
        }
        let _ = self.save(&inner.saved);
        result
    }

    fn save(&self, saved: &Saved) -> Result<(), String> {
        fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        fs::write(self.dir.join("addon.json"), serde_json::to_vec_pretty(saved).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
    }
}

/// The folders the player picked by hand, from the sync's saved state.
pub fn picked(data: &Path) -> Vec<PathBuf> {
    rts_sync::state::State::load(&data.join("state.json")).map(|s| s.picked).unwrap_or_default()
}

fn with_addons(app: &tauri::AppHandle, job: impl FnOnce(&Addons) -> Result<(), String> + Send + 'static) -> Result<(), String> {
    use tauri::Manager;
    let addons = app.state::<std::sync::Arc<Addons>>().inner().clone();
    let result = job(&addons);
    addons.tick(&picked(&rts_sync::state::data_dir()), &app.state::<Notifier>());
    result
}

#[tauri::command]
pub async fn install_addon(app: tauri::AppHandle, path: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || with_addons(&app, move |a| a.install(Path::new(&path))))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn update_addon(app: tauri::AppHandle, path: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        with_addons(&app, move |a| {
            a.update(Path::new(&path));
            Ok(())
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn set_addon_updates(app: tauri::AppHandle, on: bool) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || with_addons(&app, move |a| a.set_updates(on)))
        .await
        .map_err(|e| e.to_string())?
}
```

`Notifier::new` in tests needs `pub fn new`; it is already public. `local_keys` and `now` are already `pub` in `runner.rs`.

- [ ] **Step 3: Wire it into main.rs**

In `main.rs` `setup`, after `app.manage(notifier.clone());`:

```rust
            // The updater's public key also checks addon releases.
            let key = app
                .config()
                .plugins
                .0
                .get("updater")
                .and_then(|u| u.get("pubkey"))
                .and_then(|k| k.as_str())
                .unwrap_or_default()
                .to_string();
            let addons = Arc::new(addons::Addons::new(&data_dir(), &key));
            app.manage(addons.clone());
```

In the 30-second ticker's loop, after `commands::with_runner(ticker.clone(), |r| r.rescan());`, add (the closure needs its own clones made before `std::thread::spawn`: `let ticking = addons.clone(); let ticked = notifier.clone();` — move the existing `notifier` use accordingly):

```rust
                    ticking.tick(&addons::picked(&data_dir()), &ticked);
```

After the app-update thread, a thread of its own, so a waiting app update never holds it up:

```rust
            // The addon's check rides on the app's: at start and every six
            // hours. A thread of its own, because the app's waits to restart.
            let (checking, told) = (addons.clone(), notifier.clone());
            std::thread::spawn(move || {
                loop {
                    let _ = checking.check();
                    checking.tick(&addons::picked(&data_dir()), &told);
                    std::thread::sleep(Duration::from_secs(6 * 3600));
                }
            });
```

Add `addons::install_addon, addons::update_addon, addons::set_addon_updates,` to `generate_handler!`.

- [ ] **Step 4: Run every app test, fmt and clippy**

Run: `cd apps/desktop && . ~/.cargo/env && cargo test --workspace 2>&1 | grep -E "test result|FAILED|panicked" ; cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tail -3`
Expected: every `test result: ok`, no fmt or clippy output beyond "Finished".

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/src-tauri/src
git commit -m "App: check for addon releases with the app's own check, and put them into games while they're closed (#54)"
```

---

### Task 7: The window: first run, game folders and the switch

**Files:**
- Modify: `apps/desktop/src/api.ts`, `apps/desktop/src/format.ts`, `apps/desktop/src/format.test.ts`, `apps/desktop/src/Account.tsx`, `apps/desktop/src/FirstRun.tsx`

**Interfaces:**
- Consumes: `Status.folders`, `Status.addonUpdates`, commands `install_addon`, `update_addon`, `set_addon_updates` from Task 6.
- Produces: `type Folder`; `installAddon(path)`, `updateAddon(path)`, `setAddonUpdates(on)`; `folderWords(f: Folder, now: number): { line: string; warn: boolean; action: "install" | "update" | null }`.

- [ ] **Step 1: Write the failing tests**

In `format.test.ts`, replace the `addonLine` checks in the game folder test with nothing (the function goes), import `folderWords` and `type Folder` (from `./api`), and add:

```ts
test("each game folder's addon state reads as the mockups do", () => {
  const base = { path: "/wow/_classic_beta_", name: "_classic_beta_", characters: 3, addon: "1.10.1", updatedAt: null } as const;
  const day = 86400;
  const words = (f: Folder) => folderWords(f, 10 * day);
  expect(words({ ...base, state: "current" })).toEqual({ line: "Addon 1.10.1", warn: false, action: null });
  expect(words({ ...base, state: "current", updatedAt: 10 * day - 3600 }).line).toBe("Addon 1.10.1 · updated today");
  expect(words({ ...base, addon: "1.10.0", state: "waiting", latest: "1.10.1" }).line).toBe("Addon 1.10.0 · 1.10.1 installs when WoW closes");
  expect(words({ ...base, addon: null, state: "missing", latest: "1.10.1" })).toEqual({ line: "No addon yet", warn: false, action: "install" });
  expect(words({ ...base, addon: null, state: "developer" }).line).toBe("Developer addon · the app leaves it alone");
  expect(words({ ...base, state: "failed", why: "the disk is full" })).toEqual({
    line: "Couldn't update the addon: the disk is full. Trying again in a few hours.",
    warn: true,
    action: null,
  });
  expect(words({ ...base, addon: "1.10.0", state: "behind", latest: "1.10.1" })).toEqual({ line: "Addon 1.10.0 · 1.10.1 is out", warn: false, action: "update" });
  expect(words({ ...base, state: "otherClient" }).line).toBe("Addon 1.10.1 · not for this version of WoW");
});
```

Run: `cd apps/desktop && bun test src 2>&1 | grep -E "SyntaxError| pass$| fail$"`
Expected: FAIL, `folderWords` not exported.

- [ ] **Step 2: Types, calls and words**

In `api.ts`, after `Game`:

```ts
export type FolderState =
  | { state: "current" }
  | { state: "waiting"; latest: string }
  | { state: "missing"; latest: string }
  | { state: "developer" }
  | { state: "failed"; why: string }
  | { state: "behind"; latest: string }
  | { state: "otherClient" };
export type Folder = { path: string; name: string; characters: number; addon: string | null; updatedAt: number | null } & FolderState;
```

Add `folders: Folder[];` and `addonUpdates: boolean;` to `Status`, and after `pickFolder`:

```ts
export const installAddon = (path: string) => invoke("install_addon", { path });
export const updateAddon = (path: string) => invoke("update_addon", { path });
export const setAddonUpdates = (on: boolean) => invoke("set_addon_updates", { on });
```

In `format.ts`, delete `addonLine`, add `import type { Folder, Update } from "./api";` (in place of the `Update` import), and:

```ts
// A game folder's addon line. now and updatedAt are Unix seconds.
export function folderWords(f: Folder, now: number): { line: string; warn: boolean; action: "install" | "update" | null } {
  const has = `Addon ${f.addon ?? ""}`;
  switch (f.state) {
    case "current":
      return { line: f.updatedAt !== null && now - f.updatedAt < 86400 ? `${has} · updated today` : has, warn: false, action: null };
    case "waiting":
      return { line: `${has} · ${f.latest} installs when WoW closes`, warn: false, action: null };
    case "missing":
      return { line: "No addon yet", warn: false, action: "install" };
    case "developer":
      return { line: "Developer addon · the app leaves it alone", warn: false, action: null };
    case "failed":
      return { line: `Couldn't update the addon: ${f.why}. Trying again in a few hours.`, warn: true, action: null };
    case "behind":
      return { line: `${has} · ${f.latest} is out`, warn: false, action: "update" };
    case "otherClient":
      return { line: `${has} · not for this version of WoW`, warn: false, action: null };
  }
}
```

Run: `cd apps/desktop && bun test src 2>&1 | grep -E " pass$| fail$"`
Expected: all pass.

- [ ] **Step 3: Account**

In `Account.tsx`, import `installAddon, setAddonUpdates, updateAddon` from `./api` and `folderWords` from `./format` (drop `addonLine`). Replace the Game folders section's `status.games.map(...)` with:

```tsx
          {status.folders.map((f) => {
            const w = folderWords(f, Math.floor(Date.now() / 1000));
            const act = (go: () => Promise<unknown>) => go().catch((e) => setError({ at: "folders", why: String(e) }));
            return (
              <Card key={f.path}>
                <Row>
                  <div className="flex min-w-0 flex-1 flex-col gap-1">
                    <div className="flex items-baseline gap-2">
                      <span className="text-sm font-medium">{gameName(f.name)}</span>
                      {w.action === "install" ? (
                        <Button className={`ml-auto ${small}`} onClick={() => act(() => installAddon(f.path))}>
                          Install the addon
                        </Button>
                      ) : (
                        f.state !== "missing" && (
                          <span className="ml-auto shrink-0 text-xs text-muted">{f.characters === 1 ? "1 character" : `${f.characters} characters`}</span>
                        )
                      )}
                    </div>
                    <div className="flex items-center gap-2">
                      <span className={`text-xs ${w.warn ? "text-warn" : "text-muted"}`}>{w.line}</span>
                      {w.action === "update" && (
                        <Button className={`ml-auto ${small}`} onClick={() => act(() => updateAddon(f.path))}>
                          Update
                        </Button>
                      )}
                    </div>
                    <div className="text-[11.5px] text-faint [overflow-wrap:anywhere]" title={f.path}>
                      {installFolder(f.path, f.name)}
                    </div>
                  </div>
                </Row>
              </Card>
            );
          })}
          {problem("folders")}
```

`setError`, `small` and `problem` are the names Account.tsx already uses for its other sections' errors and small buttons: check with `grep -n "setError\|const small\|function problem\|const problem" src/Account.tsx` and use whatever the file calls them.

In This PC's card, after the Start at login `Row` and its error line, add:

```tsx
            <Row line>
              <label htmlFor="addonupdates" className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Keep the addon up to date</span>
                <span className="text-xs leading-[1.45] text-muted">New versions install while WoW is closed. A developer copy is never changed.</span>
              </label>
              <button
                id="addonupdates"
                type="button"
                role="switch"
                aria-checked={status.addonUpdates}
                onClick={act("addon", () => setAddonUpdates(!status.addonUpdates))}
                className={`flex h-6 w-10 shrink-0 rounded-full p-[3px] ${status.addonUpdates ? "justify-end bg-accent" : "justify-start bg-outline"}`}
              >
                <span className="size-[18px] rounded-full bg-cream" />
              </button>
            </Row>
            {error?.at === "addon" && <p className="px-3.5 pb-3 text-xs text-warn">Couldn't change it: {error.why}</p>}
```

(`act` here is the existing helper the Start at login switch uses; the per-folder one above is named `act` too inside the map: rename the inner one to `tryIt` if TypeScript complains about shadowing.)

- [ ] **Step 4: First run**

In `FirstRun.tsx`, import `installAddon` from `./api`, `useState` if not already, and `gameName, installFolder` from `./format`. Replace `const found = status.games.length > 0;` with:

```tsx
  const folders = status.folders;
  const missing = folders.filter((f) => f.state === "missing");
  const ready = folders.some((f) => f.state !== "missing");
  const found = folders.length > 0;
  const [installed, setInstalled] = useState(false);
  const [installError, setInstallError] = useState<string | null>(null);

  async function install(paths: string[]) {
    setInstallError(null);
    try {
      for (const p of paths) await installAddon(p);
      setInstalled(true);
    } catch (e) {
      setInstallError(`Couldn't install the addon: ${String(e)}`);
    }
  }
```

Replace step 1 with:

```tsx
        <Step n={1} done={ready} current={found && !ready} title={!found ? "WoW not found" : !ready ? "Install the addon" : installed ? "Addon installed" : "WoW found"}>
          {folders.map((f) => (
            <div key={f.path} className="flex min-w-0 flex-col gap-0.5 rounded-[10px] border border-line bg-panel px-3 py-2.5">
              <div className="flex items-baseline gap-2">
                <span className="text-sm font-medium">{gameName(f.name)}</span>
                {f.state === "missing" && ready ? (
                  <Button className="ml-auto h-[30px] rounded-lg px-3 text-xs" onClick={() => install([f.path])}>
                    Install the addon
                  </Button>
                ) : (
                  <span className="ml-auto text-xs text-muted">{f.state === "missing" ? "No addon yet" : f.addon ? `Addon ${f.addon}` : "Developer addon"}</span>
                )}
              </div>
              <div className="truncate text-[11.5px] text-faint">{installFolder(f.path, f.name)}</div>
            </div>
          ))}
          {found && !ready && missing.length > 0 && (
            <>
              <Button look="cream" className="h-10 w-full rounded-[10px] text-sm" onClick={() => install(missing.map((f) => f.path))}>
                Install Road to Sixty {missing[0]!.state === "missing" ? missing[0]!.latest : ""}
              </Button>
              <p className="text-xs text-faint">Puts the addon in this game's AddOns folder. It keeps itself up to date after that.</p>
            </>
          )}
          {installError && <p className="text-xs text-warn">{installError}</p>}
          {!found && <p className="text-[13px] text-muted">Install the Road to Sixty addon first, or show us where WoW is.</p>}
        </Step>
```

In step 2, change `current={found && !linked}` to `current={ready && !linked}` and `{found && !linked && (` to `{ready && !linked && (`. In step 3, change the line to "So the game loads the addon and the sync folder. Your journeys stay where they are."

- [ ] **Step 5: Build, test, typecheck**

Run: `cd apps/desktop && bun run build 2>&1 | tail -1 && bun test src 2>&1 | grep -E " pass$| fail$" && bun run typecheck 2>&1 | tail -1`
Expected: built, all pass, no type errors.

- [ ] **Step 6: Look at it**

Serve the build (`bunx vite preview --port 4799 --strictPort` in the background) and screenshot the first run (unlinked, one folder `missing`; then one `current` and one `missing`) and Account (one folder in each state, the switch) at 400 × 640, with `window.__TAURI_INTERNALS__.invoke` faked to return a made-up `status` (as done for app 0.1.8's game folders). Compare with `docs/superpowers/specs/2026-10-16-addon-updates-mockup.html`. Stop the preview afterwards.

- [ ] **Step 7: Commit**

```bash
git add apps/desktop/src
git commit -m "App: install the addon from first run and Account, with each game's addon state and the switch (#54)"
```

---

### Task 8: Website, version, docs

**Files:**
- Modify: `apps/web/src/components/Launch.astro:37`
- Modify: `apps/desktop/src-tauri/tauri.conf.json`, `apps/desktop/src-tauri/Cargo.toml`, `apps/desktop/Cargo.lock` (0.1.9)
- Modify: `apps/desktop/AGENTS.md`, `CLAUDE.md` (layout paragraph), `docs/superpowers/specs/2026-10-16-addon-updates-design.md` (`addon.json`)

- [ ] **Step 1: The website line**

In `Launch.astro`, change "Install the addon before you log in. The app keeps every step safe on every PC you play." to "Install the app before you log in: it puts the addon in for you and keeps every step safe on every PC you play."

Run: `cd apps/web && PUBLIC_SITE_URL=https://roadtosixty.online PUBLIC_DOWNLOADS=https://dl.roadtosixty.online PUBLIC_ADDON_URL=https://example.invalid PUBLIC_CONTACT_EMAIL=someone@example.invalid bun run build 2>&1 | tail -1 && bun test 2>&1 | grep -E " pass$| fail$"`
Expected: build complete, tests pass.

- [ ] **Step 2: Version 0.1.9**

Set `"version": "0.1.9"` in `tauri.conf.json` and `version = "0.1.9"` in `src-tauri/Cargo.toml`; run `cd apps/desktop && . ~/.cargo/env && cargo check -q -p road-to-sixty-app` so `Cargo.lock` follows.

- [ ] **Step 3: Docs**

In `apps/desktop/AGENTS.md`, engine list, add: "`addon.rs` is the addon release the app installs: `latest.json` from the downloads bucket, its signature (the updater's key), versions, which client a release fits, and putting it into a game by unpacking beside `RoadToSixty` and swapping by renaming. `installs::game_dirs` gives each game folder's client version from the game's `.flavor.info` and `.build.info`; a folder's name doesn't say which client it is." In the `src-tauri/` paragraph add: "`src/addons.rs` checks for an addon release with the app's own check (at start and every six hours, on a thread of its own), and on the 30-second ticker lists every game folder with its addon state and puts waiting updates into games that aren't running; it remembers the switch and each folder's last install in `addon/addon.json`, never `state.json`. It writes only `RoadToSixty`." In the root `CLAUDE.md`'s `src-tauri/` sentence, add "`addons.rs` installs and updates the addon," after "`update.rs` is self-update". In the spec, change "In `state.json`: `addon_updates`" to "In `addon/addon.json` in the app's data folder (its own file, so it never races the sync thread's `state.json`): `updates`".

- [ ] **Step 4: Everything**

Run: `cd /Users/jordan/personal/road-to-sixty-addon-updates && . ~/.cargo/env && PATH="$TMPDIR/luabin:$PATH" LUA51=$TMPDIR/lua51src/lua-5.1.5/src/lua bun run test 2>&1 | grep "Tasks:" && bun run typecheck 2>&1 | grep "Tasks:" && cd apps/desktop && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tail -1`
Expected: every task successful; clippy "Finished".

- [ ] **Step 5: Commit, and note it on #54**

```bash
git add apps/web apps/desktop CLAUDE.md docs/superpowers/specs
git commit -m "App: 0.1.9; the website says the app puts the addon in (#54)"
gh issue comment 54 --body "Built on branch \`addon-updates\`: the Release workflow signs the zip and puts it in the bucket (\`apps/addon/scripts/publish.sh\`, plus \`addon-publish.yml\` to redo one), the engine's \`addon.rs\` and \`installs::game_dirs\`, the app's \`addons.rs\` (check with the app's own, a 30-second tick that updates games that aren't running), first run and Account. Before release: run \`addon-publish.yml\` for v1.10.0 once the workflow is on \`main\`, then the by-hand checks (CurseForge's view of an app-updated copy on the Mac; on Windows an update waiting for WoW to close, and a first install)."
```

---

## After the tasks (not part of execution)

- Final whole-branch review on Opus, one fix pass with tests that fail first.
- Merge into `dev` with `--no-ff`, push; `main` brought up for Jordan to push (the workflows must be on `main` to run).
- Run `gh workflow run addon-publish.yml -f tag=v1.10.0`, check `https://dl.roadtosixty.online/addon/latest.json`.
- By-hand checks on #54, then tag `app-v0.1.9`.
