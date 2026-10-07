#!/bin/sh -e
# Installs the icons and launcher entry for the current user.
PREFIX="${PREFIX:-$HOME/.local/share}"
DIR="$(cd "$(dirname "$0")" && pwd)"
cp -r "$DIR/hicolor" "$PREFIX/icons/"
install -Dm644 "$DIR/okminer.desktop" "$PREFIX/applications/okminer.desktop"
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$PREFIX/icons/hicolor" || true
echo "Installed to $PREFIX (icons + launcher entry)."
