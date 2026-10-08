#!/bin/sh -e
# Builds build/linux/okminer-<arch>.AppImage for this machine's architecture.
# Run on Ubuntu 22.04 or similar (see linux/Containerfile for the packages), with Rust installed.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCH="$(uname -m)"  # x86_64 or aarch64
XMRIG_TAG=v6.26.0
PATCH="$ROOT/patches/okminer-xmrig.patch"
OUT="$ROOT/build/linux"
TOOLS="$ROOT/build/linux-tools-$ARCH"
APPDIR="${TMPDIR:-/tmp}/okminer-AppDir-$ARCH"

[ -d xmrig ] || git clone --depth 1 --branch "$XMRIG_TAG" https://github.com/xmrig/xmrig.git
git -C xmrig apply --reverse --check "$PATCH" 2>/dev/null || git -C xmrig apply "$PATCH"

# keep build paths out of the binaries
export CFLAGS="-ffile-prefix-map=$ROOT=." CXXFLAGS="-ffile-prefix-map=$ROOT=."
cmake -S xmrig -B "xmrig/build-linux-$ARCH" -DCMAKE_BUILD_TYPE=Release -DWITH_OPENCL=OFF -DWITH_CUDA=OFF >/dev/null
cmake --build "xmrig/build-linux-$ARCH" -j"$(nproc)"

RUSTFLAGS="--remap-path-prefix=$ROOT=okminer --remap-path-prefix=$HOME=~" \
  cargo build --release --manifest-path gtk/Cargo.toml --target-dir "build/linux-target-$ARCH"

rm -rf "$APPDIR" && mkdir -p "$APPDIR/usr/bin" "$TOOLS" "$OUT"
cp "build/linux-target-$ARCH/release/okminer" "xmrig/build-linux-$ARCH/xmrig" "$APPDIR/usr/bin/"

# linuxdeploy bundles GTK and the other shared libraries, then packs the AppImage
DL=https://github.com/linuxdeploy
[ -x "$TOOLS/linuxdeploy-$ARCH.AppImage" ] || {
  curl -fsSL -o "$TOOLS/linuxdeploy-$ARCH.AppImage" "$DL/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage"
  curl -fsSL -o "$TOOLS/linuxdeploy-plugin-appimage-$ARCH.AppImage" \
    "$DL/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-$ARCH.AppImage"
  curl -fsSL -o "$TOOLS/linuxdeploy-plugin-gtk.sh" \
    "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"
  chmod +x "$TOOLS"/*
  # clear the AppImage magic bytes so binfmt (qemu/Rosetta) still recognises the ELF
  for f in "$TOOLS"/*.AppImage; do printf '\0\0\0' | dd of="$f" bs=1 seek=8 conv=notrunc 2>/dev/null; done
}
export PATH="$TOOLS:$PATH" APPIMAGE_EXTRACT_AND_RUN=1 ARCH DEPLOY_GTK_VERSION=4
export LDAI_OUTPUT="$OUT/okminer-$ARCH.AppImage"
"$TOOLS/linuxdeploy-$ARCH.AppImage" --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/okminer" --executable "$APPDIR/usr/bin/xmrig" \
  --desktop-file icons/linux/okminer.desktop --icon-file icons/linux/hicolor/256x256/apps/okminer.png \
  --plugin gtk --output appimage
echo "Built $LDAI_OUTPUT"
