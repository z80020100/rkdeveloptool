# rkdeveloptool

A CLI for reading from and writing to Rockchip USB devices in Maskrom or Loader mode.

Supported SoCs: RK3036 / RK3128 / RK3229 / RK3288 / RK3328 / RK3368 / RK3399 / RK3566 / RK3568.

This fork ([`z80020100/rkdeveloptool`](https://github.com/z80020100/rkdeveloptool)) adds:

- The [`rockchip-tool`](https://github.com/z80020100/rockchip-tool) submodule, with `afptool` and `img_unpack` built in-tree alongside `rkdeveloptool` from a single autotools build.
- Helper scripts: `init.sh`, `build.sh`, `flash.sh`.
- VLA compile fix for Clang `-Werror`.

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

## Build

One-shot:

```bash
git clone https://github.com/z80020100/rkdeveloptool.git
cd rkdeveloptool
./build.sh
```

`build.sh` runs `./init.sh` → `./autogen.sh` → `./configure` → `make` and produces three binaries:

- `rkdeveloptool` — main CLI
- `afptool` — pack / unpack Rockchip firmware archives
- `img_unpack` — unwrap `update.img` into `loader.bin` + `rkfw.img`

Step-by-step equivalent:

```bash
./init.sh        # git submodule update --init
./autogen.sh     # autoreconf --force --install
./configure
make
```

## Usage

Run `./rkdeveloptool -h` for the full command list.

### One-shot flash

`flash.sh <path>` accepts either a directory of partition images or a Rockchip `update.img` and flashes the device end-to-end (Maskrom switch → loader → GPT → partitions → reboot):

```bash
sudo ./flash.sh path/to/Image/        # directory with parameter.txt + MiniLoaderAll.bin + *.img
sudo ./flash.sh path/to/update.img    # update.img (auto-unpacked via img_unpack + afptool)
```

The source must contain `parameter.txt` and `MiniLoaderAll.bin`. Partition names are read from `parameter.txt`'s `mtdparts=` CMDLINE and every matching `<name>.img` is flashed via `wlx`.

### Low-level examples

```bash
sudo ./rkdeveloptool ld                       # list connected Rockchip devices
sudo ./rkdeveloptool db RKXXLoader.bin        # download usbplug (loader) to device RAM
sudo ./rkdeveloptool wl 0x8000 kernel.img     # write kernel.img at sector 0x8000
sudo ./rkdeveloptool wlx boot boot.img        # write boot.img to partition named "boot"
sudo ./rkdeveloptool gpt parameter.txt        # write GPT partition table
sudo ./rkdeveloptool rd                       # reset device
```

## udev Rules (Linux)

To allow non-root access, install `99-rk-rockusb.rules`:

```bash
sudo cp 99-rk-rockusb.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

## Troubleshooting

If `./configure` fails with:

```
./configure: line 4269: syntax error near unexpected token `LIBUSB1,libusb-1.0'
./configure: line 4269: `PKG_CHECK_MODULES(LIBUSB1,libusb-1.0)'
```

install `pkg-config` and `libusb-1.0` development headers:

```bash
sudo apt-get install pkg-config libusb-1.0-0-dev
```

## License

See [`license.txt`](license.txt). `rkdeveloptool` is GPL-2.0+ (Fuzhou Rockchip Electronics).
