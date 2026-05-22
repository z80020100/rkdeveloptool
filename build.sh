#!/bin/sh
set -e

show_help() {
  cat <<EOF
Usage: $0 [configure args]

Build rkdeveloptool, afptool and img_unpack.

Options:
  --enable-static    Statically link libusb-1.0 and libcrypto so the binaries
                     need no Homebrew or distro -dev packages at runtime. libc
                     and libstdc++ remain dynamic so the libc ABI of the build
                     host still bounds where the binary can run.
  -h, --help         Show this help.

Any other arguments are forwarded to ./configure.

Examples:
  $0                       # default (dynamic) build
  $0 --enable-static       # self-contained dependency build
EOF
}

for arg in "$@"; do
  case "$arg" in
  -h | --help)
    show_help
    exit 0
    ;;
  --help=* | -V | --version)
    ./init.sh
    ./autogen.sh
    exec ./configure "$arg"
    ;;
  esac
done

./init.sh
./autogen.sh
./configure "$@"
make
