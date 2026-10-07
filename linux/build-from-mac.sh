#!/bin/sh -e
# Builds both Linux AppImages from a Mac: linux/build.sh runs in Ubuntu 22.04
# containers inside a Lima VM, with x86_64 going through Rosetta.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM=okminer-linux

limactl list -q | grep -qx "$VM" || limactl create --name="$VM" --vm-type=vz --rosetta --cpus=6 --memory=8 \
  --disk=40 --mount-only "$ROOT:w" --mount-type=virtiofs --tty=false template:ubuntu-24.04
[ "$(limactl list -f '{{.Status}}' "$VM")" = Running ] || limactl start "$VM"
limactl shell "$VM" -- sh -c 'command -v podman >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq podman; }'

for platform in arm64 amd64; do
  limactl shell "$VM" -- podman build -q --platform "linux/$platform" -t "okminer-build-$platform" -f "$ROOT/linux/Containerfile" "$ROOT/linux"
  limactl shell "$VM" -- podman run --rm --platform "linux/$platform" -v "$ROOT:/src" \
    -v "okminer-cargo-$platform:/root/.cargo/registry" -w /src "okminer-build-$platform" ./linux/build.sh
done
ls -lh "$ROOT"/build/linux/*.AppImage
