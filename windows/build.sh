#!/bin/sh -e
# Builds build/windows/okminer-windows-x64.zip (okminer.exe, xmrig.exe and the GTK runtime).
# Cross-compiles with MinGW; run in the container from windows/Containerfile.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
XMRIG_TAG=v6.26.0
PATCH="$ROOT/patches/okminer-xmrig.patch"
MINGW=/usr/x86_64-w64-mingw32/sys-root/mingw
OUT="$ROOT/build/windows"
STAGE="${TMPDIR:-/tmp}/okminer-windows/okminer"

[ -d xmrig ] || git clone --depth 1 --branch "$XMRIG_TAG" https://github.com/xmrig/xmrig.git
git -C xmrig apply --reverse --check "$PATCH" 2>/dev/null || git -C xmrig apply "$PATCH"

# static libuv, hwloc and OpenSSL for MinGW (same versions as scripts/build_deps.sh)
DEPS="$ROOT/build/windows-deps"
WORK="${TMPDIR:-/tmp}/okminer-windows-deps"
mkdir -p "$DEPS/include" "$DEPS/lib" "$WORK"
UV=1.51.0
[ -f "$DEPS/lib/libuv.a" ] || (cd "$WORK"
  curl -fsSL "https://dist.libuv.org/dist/v$UV/libuv-v$UV.tar.gz" | tar -xz
  cmake -S "libuv-v$UV" -B uv-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc -DLIBUV_BUILD_SHARED=OFF -DBUILD_TESTING=OFF >/dev/null
  cmake --build uv-build -j"$(nproc)" >/dev/null
  cp -r "libuv-v$UV/include/." "$DEPS/include/" && cp uv-build/libuv.a "$DEPS/lib/")
HW=2.12.1
[ -f "$DEPS/lib/libhwloc.a" ] || (cd "$WORK"
  curl -fsSL "https://download.open-mpi.org/release/hwloc/v2.12/hwloc-$HW.tar.gz" | tar -xz
  cd "hwloc-$HW" && ./configure --host=x86_64-w64-mingw32 --disable-shared --enable-static \
    --disable-io --disable-libxml2 >/dev/null && make -C hwloc -j"$(nproc)" >/dev/null
  cp -r include/. "$DEPS/include/" && cp hwloc/.libs/libhwloc.a "$DEPS/lib/")
SSL=3.0.16
[ -f "$DEPS/lib/libssl.a" ] || (cd "$WORK"
  curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$SSL/openssl-$SSL.tar.gz" | tar -xz
  cd "openssl-$SSL" && ./Configure mingw64 --cross-compile-prefix=x86_64-w64-mingw32- no-shared no-asm \
    no-zlib no-comp no-dgram no-filenames no-cms >/dev/null && make -j"$(nproc)" build_libs >/dev/null
  cp -r include/. "$DEPS/include/" && cp libcrypto.a libssl.a "$DEPS/lib/")

# xmrig includes <Windows.h> etc.; MinGW's headers are lowercase and Linux is case-sensitive
CASE="${TMPDIR:-/tmp}/okminer-mingw-case"
mkdir -p "$CASE"
for h in Windows BaseTsd Objbase Shobjidl; do
  ln -sf "$MINGW/include/$(echo $h | tr 'A-Z' 'a-z').h" "$CASE/$h.h"
done

# keep build paths out of the binaries
export CFLAGS="-ffile-prefix-map=$ROOT=. -I$CASE" CXXFLAGS="-ffile-prefix-map=$ROOT=. -I$CASE"
cmake -S xmrig -B xmrig/build-windows-x64 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
  -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ \
  -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres -DXMRIG_DEPS="$DEPS" \
  -DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DWITH_MSR=OFF >/dev/null
cmake --build xmrig/build-windows-x64 -j"$(nproc)"

PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG=x86_64-w64-mingw32-pkg-config \
CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc \
RUSTFLAGS="--remap-path-prefix=$ROOT=okminer --remap-path-prefix=$HOME=~" \
  cargo build --release --target x86_64-pc-windows-gnu --manifest-path gtk/Cargo.toml --target-dir build/windows-target

rm -rf "$STAGE" && mkdir -p "$STAGE" "$OUT"
cp build/windows-target/x86_64-pc-windows-gnu/release/okminer.exe xmrig/build-windows-x64/xmrig.exe LICENSE "$STAGE/"
sed 's/$/\r/' windows/README.txt > "$STAGE/README.txt"  # CRLF for Notepad

# every DLL the two programs import from the MinGW sysroot, recursively
copy_dlls() {
  x86_64-w64-mingw32-objdump -p "$1" | sed -n 's/.*DLL Name: //p' | while read -r dll; do
    if [ -f "$MINGW/bin/$dll" ] && [ ! -f "$STAGE/$dll" ]; then  # system DLLs aren't in the sysroot
      cp "$MINGW/bin/$dll" "$STAGE/"
      copy_dlls "$STAGE/$dll"
    fi
  done
}
copy_dlls "$STAGE/okminer.exe"
copy_dlls "$STAGE/xmrig.exe"

# GTK runtime data, found relative to the exe
mkdir -p "$STAGE/share/glib-2.0/schemas"
cp "$MINGW"/share/glib-2.0/schemas/*.xml "$STAGE/share/glib-2.0/schemas/" 2>/dev/null || true
glib-compile-schemas "$STAGE/share/glib-2.0/schemas"
if [ -d "$MINGW/lib/gdk-pixbuf-2.0" ]; then
  mkdir -p "$STAGE/lib" && cp -r "$MINGW/lib/gdk-pixbuf-2.0" "$STAGE/lib/"
  find "$STAGE/lib" -name "*.dll.a" -delete
  for f in "$STAGE"/lib/gdk-pixbuf-2.0/*/loaders/*.dll; do
    if [ -f "$f" ]; then copy_dlls "$f"; fi
  done
fi

rm -f "$OUT/okminer-windows-x64.zip"
(cd "$STAGE/.." && zip -qr "$OUT/okminer-windows-x64.zip" okminer)
echo "Built $OUT/okminer-windows-x64.zip"
