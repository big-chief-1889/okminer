#!/bin/sh -e
# Renders the icon to icons/ (macOS only, the drawing uses CoreGraphics).
# icons/linux/ can be copied to a Linux machine and installed with install-icons.sh.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/icons"
SIZES="16 22 24 32 48 64 128 256 512"

mkdir -p "$OUT/linux"
swift app/make_icon.swift "$OUT/okminer.png" >/dev/null
swift app/make_icon.swift "$OUT/linux/okminer.png" --linux >/dev/null

for s in $SIZES; do
  dir="$OUT/linux/hicolor/${s}x${s}/apps"
  mkdir -p "$dir"
  sips -z "$s" "$s" "$OUT/linux/okminer.png" --out "$dir/okminer.png" >/dev/null
done

cat > "$OUT/linux/okminer.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=okminer
Comment=Mine Monero with XMRig
Exec=okminer
Icon=okminer
Terminal=false
Categories=Utility;
DESKTOP

cat > "$OUT/linux/install-icons.sh" <<'INSTALL'
#!/bin/sh -e
# Installs the icons and launcher entry for the current user.
PREFIX="${PREFIX:-$HOME/.local/share}"
DIR="$(cd "$(dirname "$0")" && pwd)"
cp -r "$DIR/hicolor" "$PREFIX/icons/"
install -Dm644 "$DIR/okminer.desktop" "$PREFIX/applications/okminer.desktop"
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$PREFIX/icons/hicolor" || true
echo "Installed to $PREFIX (icons + launcher entry)."
INSTALL
chmod +x "$OUT/linux/install-icons.sh"

echo "Wrote:"
find "$OUT" -name "*.png" -o -name "*.desktop" -o -name "*.sh" | sort
