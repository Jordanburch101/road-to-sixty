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
