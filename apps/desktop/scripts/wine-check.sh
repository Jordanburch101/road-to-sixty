#!/usr/bin/env bash
# Starts a stand-in WowClassic.exe through Wine inside a made-up Lutris
# prefix, and checks rts-sync finds the install and sees the game running:
# under Wine the program file is Wine's own, so this is the only way to
# know the command line check works. Needs Wine, the mingw compiler and
# Xvfb (CI installs them).
#
#   scripts/wine-check.sh <rts-sync binary>
set -euo pipefail
rts=$(realpath "$1")
home=$(mktemp -d)
export HOME=$home WINEPREFIX=$home/Games/wow WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="

work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$home" "$work"' EXIT
printf '#include <windows.h>\nint main(void) { Sleep(120000); return 0; }\n' >"$work/wait.c"
x86_64-w64-mingw32-gcc -o "$work/WowClassic.exe" "$work/wait.c"

# Wine won't make the prefix when the folder above it is missing. One
# display for every Wine call: wineboot leaves wineserver tied to it.
mkdir -p "$WINEPREFIX"
Xvfb :98 -screen 0 1024x768x24 &
export DISPLAY=:98
sleep 2
wine wineboot --init
game="$WINEPREFIX/drive_c/Program Files (x86)/World of Warcraft/_classic_beta_"
mkdir -p "$game/Interface/AddOns/RoadToSixty"
echo "## Interface: 16001" >"$game/Interface/AddOns/RoadToSixty/RoadToSixty.toc"
cp "$work/WowClassic.exe" "$game/"

wine "C:\\Program Files (x86)\\World of Warcraft\\_classic_beta_\\WowClassic.exe" &
sleep 10
status=$(RTS_DATA_DIR="$work/data" "$rts" status)
echo "$status"
wineserver -k || true
grep -q "_classic_beta_ (addon developer), running" <<<"$status" || { echo "rts-sync didn't see the game running"; exit 1; }
echo "rts-sync saw the game running under Wine."
