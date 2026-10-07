#!/bin/sh -e
# Builds static libuv, hwloc and OpenSSL for one architecture (arm64 or x86_64)
# into xmrig/scripts/deps-<arch> (no Homebrew/autotools needed).
ARCH="${1:-$(uname -m)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMAKE="$ROOT/.venv/bin/cmake"
DEPS="$ROOT/xmrig/scripts/deps-$ARCH"
WORK="${TMPDIR:-/tmp}/okminer-deps-build-$ARCH"  # autotools breaks on paths with spaces
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=12.0
case "$ARCH" in
  arm64)  HOST=aarch64-apple-darwin; SSL_TARGET=darwin64-arm64-cc ;;
  x86_64) HOST=x86_64-apple-darwin;  SSL_TARGET=darwin64-x86_64-cc ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
mkdir -p "$DEPS/include" "$DEPS/lib" "$WORK" && cd "$WORK"

UV=1.51.0
[ -f "$DEPS/lib/libuv.a" ] || {
  curl -fsSL "https://dist.libuv.org/dist/v$UV/libuv-v$UV.tar.gz" | tar -xz
  "$CMAKE" -S "libuv-v$UV" -B uv-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DLIBUV_BUILD_SHARED=OFF -DBUILD_TESTING=OFF
  "$CMAKE" --build uv-build -j"$JOBS"
  cp -fr "libuv-v$UV/include/." "$DEPS/include/"
  cp uv-build/libuv.a "$DEPS/lib/"
}

HW=2.12.1
[ -f "$DEPS/lib/libhwloc.a" ] || {
  curl -fsSL "https://download.open-mpi.org/release/hwloc/v2.12/hwloc-$HW.tar.gz" | tar -xz
  (cd "hwloc-$HW" && CC="clang -arch $ARCH" ./configure --host="$HOST" --disable-shared --enable-static \
    --disable-io --disable-libudev --disable-libxml2 >/dev/null && make -C hwloc -j"$JOBS" >/dev/null)
  cp -fr "hwloc-$HW/include/." "$DEPS/include/"
  cp "hwloc-$HW/hwloc/.libs/libhwloc.a" "$DEPS/lib/"
}

SSL=3.0.16
[ -f "$DEPS/lib/libssl.a" ] || {
  curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$SSL/openssl-$SSL.tar.gz" | tar -xz
  (cd "openssl-$SSL" && ./Configure "$SSL_TARGET" -no-shared -no-asm -no-zlib -no-comp -no-dgram -no-filenames -no-cms >/dev/null \
    && make -j"$JOBS" build_libs >/dev/null)
  cp -fr "openssl-$SSL/include/." "$DEPS/include/"
  cp "openssl-$SSL/libcrypto.a" "openssl-$SSL/libssl.a" "$DEPS/lib/"
}
echo "deps OK ($ARCH)"; ls "$DEPS/lib"
