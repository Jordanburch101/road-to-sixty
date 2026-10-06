#!/usr/bin/env bash
# CurseForge helpers for GitHub Actions.
#
#   scripts/curseforge.sh check            check the token and resolve the game versions
#   scripts/curseforge.sh upload <zip> <display name> <alpha|beta|release> <changelog>
#
# Environment:
#   CF_API_TOKEN      API token (legacy.curseforge.com > Account > API Tokens)
#   CF_PROJECT_ID     project ID (upload only)
#   CF_GAME_VERSIONS  optional override: comma-separated game versions, by
#                     name ("1.60.1") or ID. Normally unset: the version comes
#                     from "## Interface" in the toc (16001 is 1.60.1), which
#                     scripts/sync-version.ps1 keeps in step with the client.
set -euo pipefail

API="https://wow.curseforge.com/api"
TOC="$(dirname "$0")/../RoadToSixty/RoadToSixty.toc"

: "${CF_API_TOKEN:?CF_API_TOKEN is not set}"

if [ -z "${CF_GAME_VERSIONS:-}" ]; then
    interface=$(grep -m1 '^## Interface:' "$TOC" | sed 's/[^0-9,]//g' | cut -d, -f1)
    [ -z "$interface" ] && { echo "No ## Interface line in $TOC" >&2; exit 1; }
    CF_GAME_VERSIONS="$((interface / 10000)).$((interface / 100 % 100)).$((interface % 100))"
    echo "Game version from the toc: interface $interface is $CF_GAME_VERSIONS" >&2
fi

# Prints the IDs for CF_GAME_VERSIONS as a JSON array. A name may match
# versions of several game flavours; all matches are printed to stderr so the
# log shows what was picked. Fails if an entry matches nothing.
resolve_versions() {
    local all ids="[]" wanted entry matches
    all=$(curl -sS --fail-with-body -H "X-Api-Token: $CF_API_TOKEN" "$API/game/versions")
    IFS=',' read -ra wanted <<< "$CF_GAME_VERSIONS"
    for entry in "${wanted[@]}"; do
        entry=$(echo "$entry" | xargs)
        [ -z "$entry" ] && continue
        if [[ "$entry" =~ ^[0-9]+$ ]]; then
            matches=$(jq -c --argjson id "$entry" '[.[] | select(.id == $id)]' <<< "$all")
        else
            matches=$(jq -c --arg name "$entry" '[.[] | select(.name == $name)]' <<< "$all")
        fi
        # A new patch can reach players before CurseForge lists it: use the
        # newest listed patch of the same major.minor below it, with a warning.
        if [ "$(jq length <<< "$matches")" = "0" ] && [[ "$entry" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
            fallback=$(jq -r --arg p "${BASH_REMATCH[1]}." '.[] | select(.name | startswith($p)) | .name' <<< "$all" \
                | { cat; echo "$entry"; } | sort -uV | grep -B1 -x -F "$entry" | head -n1)
            if [ -n "$fallback" ] && [ "$fallback" != "$entry" ]; then
                echo "::warning::CurseForge has no game version $entry yet; using $fallback" >&2
                matches=$(jq -c --arg name "$fallback" '[.[] | select(.name == $name)]' <<< "$all")
            fi
        fi
        if [ "$(jq length <<< "$matches")" = "0" ]; then
            echo "No CurseForge game version matches \"$entry\". Versions with a similar name:" >&2
            jq -r --arg p "${entry%%.*}." '.[] | select(.name | startswith($p)) | "  \(.name)  id \(.id)  type \(.gameVersionTypeID)"' <<< "$all" | sort -V | tail -n 40 >&2
            exit 1
        fi
        jq -r --arg e "$entry" '.[] | "Game version \"\($e)\": \(.name), id \(.id), type \(.gameVersionTypeID)"' <<< "$matches" >&2
        ids=$(jq -c --argjson m "$matches" '. + ($m | map(.id)) | unique' <<< "$ids")
    done
    echo "$ids"
}

case "${1:-}" in
    check)
        ids=$(resolve_versions)
        echo "Token works. Game version IDs to upload with: $ids"
        ;;
    upload)
        zip="$2"; name="$3"; type="$4"; changelog="$5"
        : "${CF_PROJECT_ID:?CF_PROJECT_ID is not set}"
        ids=$(resolve_versions)
        metadata=$(jq -n --arg name "$name" --arg type "$type" --arg changelog "$changelog" --argjson versions "$ids" \
            '{displayName: $name, releaseType: $type, changelog: $changelog, changelogType: "markdown", gameVersions: $versions}')
        echo "Uploading $zip to CurseForge project $CF_PROJECT_ID as $type: $metadata"
        curl -sS --fail-with-body \
            -H "X-Api-Token: $CF_API_TOKEN" \
            -F "metadata=$metadata" \
            -F "file=@$zip" \
            "$API/projects/$CF_PROJECT_ID/upload-file"
        echo
        ;;
    *)
        echo "usage: $0 check | upload <zip> <display name> <alpha|beta|release> <changelog>" >&2
        exit 2
        ;;
esac
