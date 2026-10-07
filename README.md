# okminer

Desktop app for mining Monero on [oklahoma.li](https://www.oklahoma.li/), or any other pool. Works on Mac and Linux. It's a small front end for [XMRig](https://github.com/xmrig/xmrig).

Paste your wallet address, pick how many cores to use and hit Start. It mines on oklahoma.li out of the box, so there's nothing else to set up.

- mines on `pool.oklahoma.li:3333` over TLS by default, or any custom pool
- links to your stats page on oklahoma.li
- shows hashrate, accepted shares and uptime
- CPU throttle you can change while it's running
- XMRig's 1% dev donation is patched out, so you only pay the pool fee (0.5% on oklahoma.li)
- settings are saved, the computer stays awake while mining, and the miner stops when you quit

Runs on:

- Mac: Apple Silicon and Intel, macOS 13 or later (SwiftUI)
- Linux: x86_64 and arm64 (e.g. Raspberry Pi 4/5) as an AppImage (GTK4)

## Building

```sh
./build.sh
```

Builds to `build/okminer.app`. No Homebrew needed. The script:

- installs CMake into `.venv`
- clones XMRig v6.26.0 and applies `patches/okminer-xmrig.patch` (donate level 0, no donation pool)
- builds static libuv, hwloc and OpenSSL (`scripts/build_deps.sh`)
- builds xmrig and `app/okminer.swift` for both arm64 and x86_64 and combines them into a universal app

If you change the XMRig source, regenerate the patch:

```sh
git -C xmrig diff > patches/okminer-xmrig.patch
```

## Linux

The Linux app is in `linux/` (Rust + GTK4). To build the AppImages:

```sh
./linux/build-from-mac.sh
```

builds both architectures from a Mac, inside a Lima VM (`okminer-linux`) using Ubuntu 22.04 containers. On a Linux machine, `./linux/build.sh` builds one for that machine's architecture (the packages it needs are listed in `linux/Containerfile`). Output goes to `build/linux/`.

## Icons

`./scripts/make_icons.sh` draws the icon (`app/make_icon.swift`) and writes `icons/okminer.png` plus a Linux icon set in `icons/linux/`. Run `install-icons.sh` from that folder to install it on Linux.

## Notes

- The throttle is done by the app, not XMRig. It pauses and resumes the process with SIGSTOP/SIGCONT every 100 ms, so 60% means mining 60% of the time.
- Stats come from XMRig's HTTP API, bound to 127.0.0.1 with a random token per session.
- If the wallet field is empty it mines to the default address in `app/okminer.swift`.

## License

GPLv3, same as XMRig. See [LICENSE](LICENSE).
