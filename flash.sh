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
REFRESH_INTERVAL="${REFRESH_INTERVAL:-1}"

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
Per-device output is prefixed with [loc=X] and streamed to the terminal
as well as \$TMPDIR/flash-<locationID>.log.

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
STATUS_FLAG=""
COORD_PID=""
cleanup() {
    [ -n "$COORD_PID" ] && kill "$COORD_PID" 2>/dev/null
    [ -n "$STATUS_FLAG" ] && rm -f "$STATUS_FLAG"
    [ -n "$LOG_DIR" ] && rm -f "$LOG_DIR"/flash-*.status 2>/dev/null
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
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
# Full output goes to $LOG_DIR/flash-<loc>.log; a one-line status file at
# $LOG_DIR/flash-<loc>.status is what the coordinator paints on screen.
flash_one() {
    local loc="$1"
    local log="$LOG_DIR/flash-${loc}.log"
    local status_file="$LOG_DIR/flash-${loc}.status"

    set_status() { printf '%s' "$*" >"$status_file"; }

    run_step() {
        if ! "$RKDEV" -l "$loc" "$@"; then
            set_status "FAIL: $1"
            echo "FAIL: $1"
            exit 1
        fi
    }

    {
        set_status "starting"
        echo "Start at $(date '+%Y-%m-%d %H:%M:%S')"

        local mode
        mode=$(mode_of_location "$loc" || true)
        echo "Initial mode: ${mode:-unknown}"

        if [ "$mode" = "Loader" ]; then
            set_status "Loader -> Maskrom (rd 3)"
            echo "Switching Loader -> Maskrom (rd 3)"
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
                set_status "FAIL: did not reach Maskrom"
                echo "FAIL: did not reach Maskrom (current=${mode:-gone})"
                exit 1
            fi
        elif [ "$mode" != "Maskrom" ]; then
            set_status "FAIL: unexpected mode '${mode:-gone}'"
            echo "FAIL: unexpected mode '${mode:-gone}'"
            exit 1
        fi

        set_status "Step 1/5: db (download loader)"
        echo "Step 1: Download loader to RAM (db)"
        run_step db "$IMG_DIR/MiniLoaderAll.bin"
        sleep 3  # let the in-RAM loader re-enumerate on USB before subsequent steps

        set_status "Step 2/5: ul (write loader)"
        echo "Step 2: Write loader to flash (ul)"
        run_step ul "$IMG_DIR/MiniLoaderAll.bin"

        set_status "Step 3/5: gpt (partition table)"
        echo "Step 3: Write partition table (gpt)"
        run_step gpt "$PARAM_FILE"

        echo "Step 4: Write ${#MATCHED[@]} partition image(s)"
        local part
        for part in "${MATCHED[@]}"; do
            set_status "Step 4/5: wlx $part"
            echo "Writing $part.img"
            if ! "$RKDEV" -l "$loc" wlx "$part" "$IMG_DIR/$part.img"; then
                set_status "FAIL: wlx $part"
                echo "FAIL: wlx $part"
                exit 1
            fi
        done

        set_status "Step 5/5: rd (reboot)"
        echo "Step 5: Reboot (rd)"
        "$RKDEV" -l "$loc" rd >/dev/null 2>&1 || true
        set_status "OK"
        echo "OK at $(date '+%Y-%m-%d %H:%M:%S')"
    } >"$log" 2>&1
}

# Strip rkdeveloptool's in-place ANSI repaint and CRs from a log tail and
# return the most recent progress line: "(NN%)" for wlx and "current XK" for
# db / ul / erase variants.
log_tail_progress() {
    local log_file="$1"
    [ -r "$log_file" ] || return 0
    tail -c 4096 "$log_file" 2>/dev/null |
        tr -d '\r\033' |
        sed -E 's/\[[0-9;]*[A-Za-z]//g' |
        awk '/\([0-9]+%\)|current [0-9]+K/ { last = $0 } END { if (last) print last }'
}

# Repaint LOC_COUNT fixed terminal lines in place by reading each device's
# one-line status file. mtime gives elapsed-in-step so long writes (super.img)
# never look stuck. Appends the latest "current/total" line from the log so
# byte-level progress shows alongside the step name.
coordinator_loop() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 120)
    local esc
    esc=$(printf '\033')
    local first=1
    while [ -f "$STATUS_FLAG" ]; do
        if [ "$first" -eq 0 ]; then
            printf '%s[%dA' "$esc" "$LOC_COUNT"
        fi
        first=0
        local loc status_file line mtime now elapsed progress prefix width
        now=$(date +%s)
        for loc in "${LOCS[@]}"; do
            status_file="$LOG_DIR/flash-${loc}.status"
            if [ -r "$status_file" ]; then
                line=$(cat "$status_file" 2>/dev/null)
                mtime=$(stat -f %m "$status_file" 2>/dev/null || stat -c %Y "$status_file" 2>/dev/null || echo "$now")
                elapsed=$((now - mtime))
                progress=$(log_tail_progress "$LOG_DIR/flash-${loc}.log")
                if [ -n "$progress" ] && [ "$line" != "OK" ] && [ "${line#FAIL}" = "$line" ]; then
                    line="$line | $progress"
                fi
                if [ "$elapsed" -ge 2 ] && [ "$line" != "OK" ] && [ "${line#FAIL}" = "$line" ]; then
                    line="$line (${elapsed}s)"
                fi
            else
                line="(waiting)"
            fi
            prefix="[loc=$loc] "
            width=$((cols - ${#prefix} - 1))
            [ "$width" -lt 10 ] && width=10
            printf '\r%s[2K%s%.*s\n' "$esc" "$prefix" "$width" "$line"
        done
        sleep "$REFRESH_INTERVAL"
    done
}

PIDS=()
LOCS=()
for loc in $LOCATIONS; do
    : >"$LOG_DIR/flash-${loc}.log"
    flash_one "$loc" &
    PIDS+=("$!")
    LOCS+=("$loc")
done

echo "Flashing $LOC_COUNT device(s) in parallel (logs: $LOG_DIR/flash-*.log) ..."

USE_COORDINATOR=0
if [ -t 1 ]; then
    USE_COORDINATOR=1
    STATUS_FLAG=$(mktemp)
    for ((__i = 0; __i < LOC_COUNT; __i++)); do echo; done
    coordinator_loop &
    COORD_PID=$!
fi

RESULTS=()
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        RESULTS+=("OK")
    else
        RESULTS+=("FAIL")
    fi
done

if [ "$USE_COORDINATOR" -eq 1 ]; then
    rm -f "$STATUS_FLAG"
    STATUS_FLAG=""
    wait "$COORD_PID" 2>/dev/null
    COORD_PID=""
    ESC=$(printf '\033')
    printf '%s[%dA' "$ESC" "$LOC_COUNT"
    for i in "${!LOCS[@]}"; do
        printf '\r%s[2K[loc=%s] %s\n' "$ESC" "${LOCS[$i]}" "${RESULTS[$i]}"
    done
fi
echo

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
