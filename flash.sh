#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RKDEV="$SCRIPT_DIR/rkdeveloptool"
IMG_UNPACK="$SCRIPT_DIR/img_unpack"
AFPTOOL="$SCRIPT_DIR/afptool"

TARGET=""

usage() {
    cat <<EOF
Usage: $(basename "$0") <path>

  <path>  Either:
           - a directory containing parameter.txt and partition .img files
             (e.g. MiniLoaderAll.bin, uboot.img, boot.img ...), or
           - a Rockchip update.img file (auto-unpacked to a temp directory).

  MiniLoaderAll.bin is required: flashing always goes through Maskrom and
  writes a fresh loader first so that gpt writes are accepted (a stock
  RK356x Loader rejects gpt).

Options:
  -h, --help   Show this help
EOF
}

require_tool() {
    if [ ! -x "$2" ]; then
        echo "Error: $1 not found at $2" >&2
        echo "Please build it first: ./build.sh" >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        echo "Error: Unknown option: $1" >&2
        exit 1
        ;;
    *)
        if [ -n "$TARGET" ]; then
            echo "Error: Too many arguments" >&2
            exit 1
        fi
        TARGET="$1"
        shift
        ;;
    esac
done

if [ -z "$TARGET" ]; then
    usage
    exit 1
fi

require_tool rkdeveloptool "$RKDEV"

TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [ -d "$TARGET" ]; then
    MODE="partition"
    IMG_DIR="${TARGET%/}"
elif [ -f "$TARGET" ]; then
    MODE="update.img"
    require_tool img_unpack "$IMG_UNPACK"
    require_tool afptool "$AFPTOOL"

    TMP_DIR=$(mktemp -d)
    echo "Unpacking $TARGET ..."
    # Strip blank lines from each tool's stderr while keeping version banners and error text
    "$IMG_UNPACK" "$TARGET" "$TMP_DIR/loader.bin" "$TMP_DIR/rkfw.img" 2>&1 >/dev/null |
        sed '/^$/d' >&2
    "$AFPTOOL" -unpack "$TMP_DIR/rkfw.img" "$TMP_DIR/unpacked" 2>&1 >/dev/null |
        sed '/^$/d' >&2
    IMG_DIR="$TMP_DIR/unpacked/Image"
    if [ ! -d "$IMG_DIR" ]; then
        echo "Error: Unpack produced unexpected layout (no $IMG_DIR)" >&2
        exit 1
    fi
else
    echo "Error: Target not found or not a file/directory: $TARGET" >&2
    exit 1
fi

PARAM_FILE="$IMG_DIR/parameter.txt"
if [ ! -f "$PARAM_FILE" ]; then
    echo "Error: parameter.txt not found at $PARAM_FILE" >&2
    exit 1
fi

if [ ! -f "$IMG_DIR/MiniLoaderAll.bin" ]; then
    echo "Error: MiniLoaderAll.bin not found in $IMG_DIR" >&2
    exit 1
fi

# Parse partition names from parameter.txt CMDLINE
# Format: mtdparts=rk29xxnand:SIZE@0xOFFSET(name[:flag]),... (SIZE is 0xHEX or - for last partition)
PARTITIONS=$(
    tr -d '\r' <"$PARAM_FILE" |
        sed -n 's/.*CMDLINE:[[:space:]]*mtdparts=rk29xxnand://p' |
        tr ',' '\n' |
        sed -n 's/.*@0x[0-9a-fA-F]*(\([^):]*\)[^)]*).*/\1/p'
)

if [ -z "$PARTITIONS" ]; then
    echo "Error: No partitions found in $PARAM_FILE" >&2
    exit 1
fi

detect_device() {
    local output
    for i in 1 2 3; do
        output=$("$RKDEV" ld 2>&1) || true
        case "$output" in
        *Maskrom*)
            echo "maskrom"
            return
            ;;
        *Loader*)
            echo "loader"
            return
            ;;
        esac
        [ "$i" -lt 3 ] && sleep 3
    done
    return 1
}

run_rkdev() {
    local rc=0
    "$RKDEV" "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  -> rkdeveloptool $* failed (exit code $rc)" >&2
        return "$rc"
    fi
}

echo "Detecting device ..."

# Try rockusb first; fall back to ADB reboot if no rockusb device found
DEV_MODE=$(detect_device) || {
    if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q 'device$'; then
        echo "Device found in ADB mode and rebooting to loader ..."
        adb reboot loader
        sleep 5
    fi
    DEV_MODE=$(detect_device) || {
        echo "Error: No Rockchip device found." >&2
        echo "Please connect the device in Maskrom or Loader mode." >&2
        exit 1
    }
}

# A stock RK356x Loader rejects gpt writes; always route through Maskrom to flash a fresh loader first
if [ "$DEV_MODE" = "loader" ]; then
    echo "Loader mode detected and switching to Maskrom for a clean loader flash ..."
    "$RKDEV" rd 3 >/dev/null 2>&1 || true
    sleep 5
    DEV_MODE=$(detect_device) || true
    if [ "$DEV_MODE" != "maskrom" ]; then
        echo "Error: Failed to switch to Maskrom mode." >&2
        exit 1
    fi
fi

echo "========================================="
echo " Rockchip Flash Script (rkdeveloptool)"
echo "========================================="
echo
echo "Source:          $TARGET ($MODE mode)"
echo "Image directory: $IMG_DIR"
echo "Parameter file:  $PARAM_FILE"
echo

echo "[Step 1] Downloading loader to RAM ..."
run_rkdev db "$IMG_DIR/MiniLoaderAll.bin"
echo "Loader downloaded and waiting for device ..."
sleep 3

echo "[Step 2] Writing loader to flash ..."
run_rkdev ul "$IMG_DIR/MiniLoaderAll.bin"
echo "Loader written to flash."
echo

echo "[Step 3] Writing partition table ..."
run_rkdev gpt "$PARAM_FILE"
echo "Partition table written."
echo

echo "[Step 4] Writing partition images ..."

MATCHED=()
SKIPPED=()
while IFS= read -r part; do
    if [ -f "$IMG_DIR/$part.img" ]; then
        MATCHED+=("$part")
    else
        SKIPPED+=("$part")
    fi
done <<<"$PARTITIONS"
echo "  Flash: ${MATCHED[*]:-(none)}"
echo "  Skip:  ${SKIPPED[*]:-(none)}"
echo

if [ ${#MATCHED[@]} -eq 0 ]; then
    echo "Warning: No partition images matched and only GPT was written."
    echo "Expected files like: uboot.img, boot.img, recovery.img, etc."
    echo "========================================="
    echo " No partitions were flashed (GPT updated)."
    echo "========================================="
else
    # wlx resolves partition offset from device GPT by name
    for part in "${MATCHED[@]}"; do
        echo "Writing $part.img ..."
        run_rkdev wlx "$part" "$IMG_DIR/$part.img"
    done
    echo "========================================="
    echo " All done! Flashed ${#MATCHED[@]} partition(s)."
    echo "========================================="
fi
echo
echo "[Step 5] Rebooting device ..."
if run_rkdev rd; then
    echo "Device is rebooting."
else
    echo "Warning: Failed to reboot device. Please reboot manually." >&2
fi
