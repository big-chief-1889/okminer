#!/bin/sh -e
# Builds patched xmrig and packages okminer.app.
# Patch: removes XMRig's developer donation (donate level 0, no donation pool).
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET=13.0
XMRIG_TAG=v6.26.0
PATCH="$ROOT/patches/okminer-xmrig.patch"

[ -x .venv/bin/cmake ] || { python3 -m venv .venv && .venv/bin/pip install -q cmake; }
[ -d xmrig ] || git clone --depth 1 --branch "$XMRIG_TAG" https://github.com/xmrig/xmrig.git
git -C xmrig apply --reverse --check "$PATCH" 2>/dev/null || git -C xmrig apply "$PATCH"

# Universal app: build deps, xmrig and the app for each architecture, then lipo them together.
ARCHS="arm64 x86_64"
OBJ="$(mktemp -d)"
for arch in $ARCHS; do
  ./scripts/build_deps.sh "$arch"
  .venv/bin/cmake -S xmrig -B "xmrig/build-$arch" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$arch" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DXMRIG_DEPS="$ROOT/xmrig/scripts/deps-$arch" -DWITH_OPENCL=OFF -DWITH_CUDA=OFF >/dev/null
  .venv/bin/cmake --build "xmrig/build-$arch" -j"$(sysctl -n hw.ncpu)"
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" -o "$OBJ/okminer-$arch" app/okminer.swift
done

APP="$ROOT/build/okminer.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/okminer" "$OBJ"/okminer-*
lipo -create -output "$APP/Contents/Resources/xmrig" $(for arch in $ARCHS; do echo "xmrig/build-$arch/xmrig"; done)

# App icon, drawn by app/make_icon.swift
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift app/make_icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>okminer</string>
  <key>CFBundleDisplayName</key><string>okminer</string>
  <key>CFBundleIdentifier</key><string>local.okminer</string>
  <key>CFBundleExecutable</key><string>okminer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
