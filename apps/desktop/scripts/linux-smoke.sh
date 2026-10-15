#!/usr/bin/env bash
# Starts the AppImage in a bare Arch Linux, the base SteamOS is built on,
# with a fake screen and nothing else a desktop would add: no WebKitGTK,
# no GTK and no tray library, so anything the AppImage forgot to carry
# fails here. Run inside the archlinux image:
#
#   docker run --rm -v "$PWD":/w archlinux bash /w/apps/desktop/scripts/linux-smoke.sh /w/<AppImage> /w/smoke
#
# Leaves screenshot.png in the out folder, to see the window drew.
set -euo pipefail
appimage=$1
out=$2
mkdir -p "$out"

# What any Linux desktop has, and the AppImage leaves to it (fonts, X,
# OpenGL): linuxdeploy's exclude list.
pacman -Syu --noconfirm --needed xorg-server-xvfb imagemagick mesa libx11 libxcb fontconfig ttf-dejavu >/dev/null

home=$(mktemp -d)
cd "$(mktemp -d)"
# No FUSE in a container: unpack instead of mounting.
cp "$appimage" app.AppImage
chmod +x app.AppImage
./app.AppImage --appimage-extract >/dev/null
# Every program and library inside, the web view's helper programs too,
# with the AppImage's own library folders as its AppRun sets them, so only
# what it really lacks shows.
missing=$(LD_LIBRARY_PATH=$(find "$PWD/squashfs-root/usr/lib" -type d | paste -sd:) \
  find squashfs-root/usr -type f \( -name '*.so*' -o -perm -u+x \) -exec ldd {} \; 2>/dev/null | grep "not found" | sort -u || true)
if [ -n "$missing" ]; then
  echo "The AppImage needs libraries this system doesn't have:"
  echo "$missing"
  exit 1
fi

Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
sleep 2
# Under Xvfb there is no GPU to share buffers with; without this the web
# view may draw white while the app itself keeps running.
HOME=$home WEBKIT_DISABLE_DMABUF_RENDERER=1 squashfs-root/AppRun >"$out/app.log" 2>&1 &
app=$!
sleep 20
import -window root "$out/screenshot.png" || true
if ! kill -0 "$app" 2>/dev/null; then
  echo "The app quit or crashed:"
  cat "$out/app.log"
  exit 1
fi
# The web view runs as programs of its own; one that can't load leaves the
# window white while the app keeps running.
if grep -q "error while loading shared libraries" "$out/app.log"; then
  echo "Part of the app couldn't load:"
  cat "$out/app.log"
  exit 1
fi
echo "The app is still running after 20 seconds."
kill "$app"
