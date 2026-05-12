# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

`rkdeveloptool` is a CLI for reading from and writing to Rockchip USB devices in Maskrom or Loader mode (RK3036 / RK3128 / RK3229 / RK3288 / RK3328 / RK3368 / RK3399 / RK3566 / RK3568).

This fork (`z80020100/rkdeveloptool`) adds:

- The `rockchip-tool` submodule, with `afptool` and `img_unpack` built in-tree alongside `rkdeveloptool` from a single autotools build.
- Helper scripts: `init.sh` (submodule init), `build.sh` (one-shot build), `flash.sh` (end-to-end flash from a partition dir or `update.img`).
- VLA compile fix for Clang `-Werror`.

Default branch: `master`. Remote: `git@github.com:z80020100/rkdeveloptool.git`.

## Prerequisites

- C++ toolchain with autotools (`autoconf`, `automake`)
- `pkg-config`
- `libusb-1.0` development headers
- `libcrypto` (OpenSSL) development headers — used by `img_unpack`

Debian / Ubuntu:

```bash
sudo apt-get install libudev-dev libusb-1.0-0-dev dh-autoreconf
```

macOS (Homebrew):

```bash
brew install autoconf automake pkg-config libusb openssl
```

## Common Commands

```bash
./build.sh                # init submodule, autogen, configure, make (one-shot)
./init.sh                 # git submodule update --init
./autogen.sh              # autoreconf --force --install
./configure && make       # standard autotools build
sudo ./rkdeveloptool ld   # list connected Rockchip devices
sudo ./flash.sh <path>    # flash an update.img file or unpacked partition dir
```

`flash.sh <path>` accepts either:

- A directory containing `parameter.txt`, `MiniLoaderAll.bin` and partition `.img` files, or
- A Rockchip `update.img` (auto-unpacked via `img_unpack` + `afptool` to a temp dir).

It detects device state (Maskrom / Loader / ADB), routes through Maskrom for a clean loader flash, writes the partition table from `parameter.txt`, then writes each matching partition image via `wlx`.

## Directory Structure

```
.
├── main.cpp / RK*.{cpp,h}     # rkdeveloptool sources
├── crc.cpp / gpt.h / Endian.h / Property.hpp / DefineHeader.h
├── rockchip-tool/             # submodule: afptool.cpp, img_unpack.cpp sources
├── cfg/                       # autotools aux files (config.sub, install-sh, ...)
├── 99-rk-rockusb.rules        # udev rules for Rockchip USB vendor/product IDs
├── parameter_gpt.txt          # sample GPT parameter file (RK3399)
├── build.sh / init.sh / autogen.sh / flash.sh
├── configure.ac / Makefile.am # autotools entry points
├── CMakeLists.txt             # legacy macOS build (Homebrew libusb / libiconv)
├── README.md                  # human-facing project README
└── Readme.txt                 # original upstream usage notes
```

## Architecture

Three binaries are produced by the autotools build (`Makefile.am`):

- **`rkdeveloptool`** — main CLI, built from `main.cpp` and the `RK*` modules:
  - `RKComm` — USB transport over `libusb-1.0`
  - `RKScan` — device discovery
  - `RKDevice` — loader / maskrom operations (`db`, `ul`, `wl`, `wlx`, `gpt`, `rd`, `cs`, `ef`, `rid`, ...)
  - `RKBoot` — bootloader image parsing
  - `RKImage` — `update.img` handling
  - `RKLog` — logging
  - `crc.cpp`, `gpt.h`, `Endian.h`, `Property.hpp` — support utilities
- **`afptool`** (from `rockchip-tool/afptool.cpp`) — packs / unpacks Rockchip firmware archives. Built with `-Wno-error -Wno-unused-result` and `-std=gnu++11`.
- **`img_unpack`** (from `rockchip-tool/img_unpack.cpp`) — unwraps `update.img` into `loader.bin` and `rkfw.img`. Built with `-DUSE_OPENSSL` and linked against `libcrypto`.

`flash.sh` orchestrates the three binaries:

1. Detect device (`rkdeveloptool ld`); if only ADB is visible, `adb reboot loader` first.
2. If in Loader mode, `rd 3` to switch to Maskrom (stock RK356x Loader rejects `gpt` writes).
3. `db MiniLoaderAll.bin` → load loader into RAM.
4. `ul MiniLoaderAll.bin` → write loader to flash.
5. `gpt parameter.txt` → write partition table.
6. `wlx <part> <part.img>` → write each partition listed in `parameter.txt`'s `mtdparts=` CMDLINE that has a matching `.img`.
7. `rd` → reboot.

## Submodule

`rockchip-tool` (`https://github.com/z80020100/rockchip-tool.git`) is pinned in `.gitmodules` at `rockchip-tool/`. Run `./init.sh` (or `git submodule update --init`) after cloning.

## udev Rules (Linux)

Install `99-rk-rockusb.rules` to `/etc/udev/rules.d/` to allow non-root access to the Rockchip USB IDs listed in that file. Without it, `rkdeveloptool` must be run with `sudo`.
