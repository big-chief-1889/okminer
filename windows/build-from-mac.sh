#!/bin/sh -e
# Builds the Windows zip from a Mac: windows/build.sh runs in a Fedora container
# inside the same Lima VM as the Linux build.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM=okminer-linux

limactl list -q | grep -qx "$VM" || limactl create --name="$VM" --vm-type=vz --rosetta --cpus=6 --memory=8 \
  --disk=40 --mount-only "$ROOT:w" --mount-type=virtiofs --tty=false template:ubuntu-24.04
[ "$(limactl list -f '{{.Status}}' "$VM")" = Running ] || limactl start "$VM"
limactl shell "$VM" -- sh -c 'command -v podman >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq podman; }'

limactl shell "$VM" -- podman build -q -t okminer-build-windows -f "$ROOT/windows/Containerfile" "$ROOT/windows"
limactl shell "$VM" -- podman run --rm -v "$ROOT:/src" -v okminer-cargo-windows:/root/.cargo/registry \
  -w /src okminer-build-windows ./windows/build.sh
ls -lh "$ROOT/build/windows/okminer-windows-x64.zip"
