#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RKDEV="$SCRIPT_DIR/rkdeveloptool"
IMG_UNPACK="$SCRIPT_DIR/img_unpack"
AFPTOOL="$SCRIPT_DIR/afptool"
LOG_DIR="${TMPDIR:-/tmp}"
LOG_DIR="${LOG_DIR%/}"
WAIT_ROCKUSB_SECS="${WAIT_ROCKUSB_SECS:-30}"
WAIT_MASKROM_SECS="${WAIT_MASKROM_SECS:-15}"

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

All currently connected Rockchip devices are flashed in parallel. ADB-mode
devices are rebooted to Loader via 'adb -t <transport_id> reboot loader'.
Per-device logs are written to \$TMPDIR/flash-<locationID>.log.

Options:
  -h, --help   Show this help

Environment:
  WAIT_ROCKUSB_SECS   Seconds to wait for ADB-mode devices to enter rockusb
                      (default: 30)
  WAIT_MASKROM_SECS   Seconds to wait per device for Loader -> Maskrom
                      (default: 15)
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

MATCHED=()
SKIPPED=()
while IFS= read -r part; do
    if [ -f "$IMG_DIR/$part.img" ]; then
        MATCHED+=("$part")
    else
        SKIPPED+=("$part")
    fi
done <<<"$PARTITIONS"

# Emit "locationID mode" pairs, one per line, for each currently visible rockusb device.
list_rockusb_devices() {
    "$RKDEV" ld 2>/dev/null | tr -d '\r' |
        awk -F'\t' '/LocationID=/ {
            split($2, vp, ",")
            split(vp[3], lid, "=")
            print lid[2] " " $3
        }'
}

list_rockusb_locations() {
    list_rockusb_devices | awk '{print $1}'
}

mode_of_location() {
    list_rockusb_devices | awk -v L="$1" '$1 == L {print $2; exit}'
}

list_adb_transports() {
    command -v adb >/dev/null 2>&1 || return 0
    adb devices -l 2>/dev/null | awk '
        $2 == "device" {
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^transport_id:/) {
                    split($i, a, ":")
                    print a[2]
                }
            }
        }'
}

echo "Detecting devices ..."
INITIAL_COUNT=$(list_rockusb_locations | grep -c '^' || true)

ADB_TIDS=$(list_adb_transports)
ADB_COUNT=$(printf '%s' "$ADB_TIDS" | grep -c '^' || true)

EXPECTED=$((INITIAL_COUNT + ADB_COUNT))
if [ "$EXPECTED" -eq 0 ]; then
    echo "Error: No Rockchip devices (rockusb or ADB) found." >&2
    exit 1
fi
echo "  rockusb: $INITIAL_COUNT, adb: $ADB_COUNT (expected total: $EXPECTED)"

if [ "$ADB_COUNT" -gt 0 ]; then
    echo "Rebooting ADB-mode devices to Loader ..."
    while IFS= read -r tid; do
        [ -z "$tid" ] && continue
        echo "  adb -t $tid reboot loader"
        adb -t "$tid" reboot loader >/dev/null 2>&1 || true
    done <<<"$ADB_TIDS"

    echo "Waiting up to ${WAIT_ROCKUSB_SECS}s for $EXPECTED rockusb device(s) ..."
    for i in $(seq "$WAIT_ROCKUSB_SECS"); do
        CURRENT=$(list_rockusb_locations | grep -c '^' || true)
        if [ "$CURRENT" -ge "$EXPECTED" ]; then
            break
        fi
        sleep 1
    done
fi

LOCATIONS=$(list_rockusb_locations)
LOC_COUNT=$(printf '%s' "$LOCATIONS" | grep -c '^' || true)
if [ "$LOC_COUNT" -lt 1 ]; then
    echo "Error: No rockusb devices ready after ${WAIT_ROCKUSB_SECS}s." >&2
    exit 1
fi
LOST=$((EXPECTED - LOC_COUNT))
if [ "$LOST" -gt 0 ]; then
    echo "Warning: $LOST device(s) did not enter rockusb within ${WAIT_ROCKUSB_SECS}s and will be skipped." >&2
fi

echo
echo "========================================="
echo " Rockchip Flash Script (parallel)"
echo "========================================="
echo "Source:          $TARGET ($MODE mode)"
echo "Image directory: $IMG_DIR"
echo "Parameter file:  $PARAM_FILE"
echo "Devices ($LOC_COUNT):"
list_rockusb_devices | awk '{printf "  loc=%-8s mode=%s\n", $1, $2}'
echo "Flash partitions: ${MATCHED[*]:-(none)}"
echo "Skip partitions:  ${SKIPPED[*]:-(none)}"
echo "Per-device log:   $LOG_DIR/flash-<loc>.log"
echo

# Burn one device end-to-end, identified by its USB locationID.
# Exits non-zero on any hard failure so the parent's wait() can tag it FAIL.
flash_one() {
    local loc="$1"
    local log="$LOG_DIR/flash-${loc}.log"

    run_step() {
        if ! "$RKDEV" -l "$loc" "$@"; then
            echo "[loc=$loc] FAIL: $1"
            exit 1
        fi
    }

    {
        echo "[loc=$loc] Start at $(date '+%Y-%m-%d %H:%M:%S')"

        local mode
        mode=$(mode_of_location "$loc" || true)
        echo "[loc=$loc] Initial mode: ${mode:-unknown}"

        if [ "$mode" = "Loader" ]; then
            echo "[loc=$loc] Switching Loader -> Maskrom (rd 3)"
            "$RKDEV" -l "$loc" rd 3 >/dev/null 2>&1 || true
            local j
            for j in $(seq "$WAIT_MASKROM_SECS"); do
                sleep 1
                mode=$(mode_of_location "$loc" || true)
                if [ "$mode" = "Maskrom" ]; then
                    break
                fi
            done
            if [ "$mode" != "Maskrom" ]; then
                echo "[loc=$loc] FAIL: did not reach Maskrom (current=${mode:-gone})"
                exit 1
            fi
        elif [ "$mode" != "Maskrom" ]; then
            echo "[loc=$loc] FAIL: unexpected mode '${mode:-gone}'"
            exit 1
        fi

        echo "[loc=$loc] Step 1: Download loader to RAM (db)"
        run_step db "$IMG_DIR/MiniLoaderAll.bin"
        sleep 3  # let the in-RAM loader re-enumerate on USB before subsequent steps

        echo "[loc=$loc] Step 2: Write loader to flash (ul)"
        run_step ul "$IMG_DIR/MiniLoaderAll.bin"

        echo "[loc=$loc] Step 3: Write partition table (gpt)"
        run_step gpt "$PARAM_FILE"

        echo "[loc=$loc] Step 4: Write ${#MATCHED[@]} partition image(s)"
        local part
        for part in "${MATCHED[@]}"; do
            echo "[loc=$loc] Writing $part.img"
            if ! "$RKDEV" -l "$loc" wlx "$part" "$IMG_DIR/$part.img"; then
                echo "[loc=$loc] FAIL: wlx $part"
                exit 1
            fi
        done

        echo "[loc=$loc] Step 5: Reboot (rd)"
        "$RKDEV" -l "$loc" rd >/dev/null 2>&1 || true
        echo "[loc=$loc] OK at $(date '+%Y-%m-%d %H:%M:%S')"
    } >"$log" 2>&1
}

PIDS=()
LOCS=()
for loc in $LOCATIONS; do
    : >"$LOG_DIR/flash-${loc}.log"
    flash_one "$loc" &
    PIDS+=("$!")
    LOCS+=("$loc")
done

echo "Flashing $LOC_COUNT device(s) in parallel (tail -f $LOG_DIR/flash-*.log to follow) ..."
echo

RESULTS=()
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        RESULTS+=("OK")
    else
        RESULTS+=("FAIL")
    fi
done

echo "========================================="
echo " Flash report"
echo "========================================="
OK_COUNT=0
FAIL_COUNT=0
for i in "${!LOCS[@]}"; do
    loc="${LOCS[$i]}"
    res="${RESULTS[$i]}"
    log="$LOG_DIR/flash-${loc}.log"
    printf "  loc=%-8s %-4s  log=%s\n" "$loc" "$res" "$log"
    if [ "$res" = "OK" ]; then
        OK_COUNT=$((OK_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done
echo "-----------------------------------------"
echo " Success: $OK_COUNT  Failed: $FAIL_COUNT"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
