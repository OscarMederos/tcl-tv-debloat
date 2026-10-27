#!/usr/bin/env bash
# diagnose.sh - collect diagnostics for a cleanyourtv run started by pi-setup.sh.
#
# Usage:  ./diagnose.sh [TV_IP]
# Output: terminal and $CYTV_WORK/diagnostics.txt (default ~/cleanyourtv-pi/diagnostics.txt)

set -u

WORK="${CYTV_WORK:-$HOME/cleanyourtv-pi}"
REPO="${CYTV_REPO:-$WORK/cleanyourtv}"
PY="$REPO/tools/venv/bin/python"
OUT="$WORK/diagnostics.txt"
TV_HOST="${1:-${TV_HOST:-192.168.1.140}}"
export TV_HOST

if [[ ! -x "$PY" ]]; then
    echo "venv not found at $PY. Run scripts/pi-setup.sh first." >&2
    exit 1
fi
cd "$REPO" || exit 1

tv() { "$PY" -I tools/tv.py "$@" 2>&1; }
section() { printf '\n===== %s =====\n' "$1"; }

{
    echo "diagnostics $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$TV_HOST"

    section "Connection and device"
    tv --probe

    section "Owner of the saved Wi-Fi network"
    tv 'dumpsys wifi' | grep -o 'cname=[^ ]*' | sort -u

    section "Which app answers HOME"
    tv 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'

    section "Focused app (ground truth for Home)"
    tv 'dumpsys activity activities' | grep -m1 mFocusedApp

    section "All HOME activities"
    tv 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME'

    section "Launcher-related packages"
    tv 'pm list packages | grep -i -E "launcher|tvhome|setupwraith"'

    section "Third-party packages"
    tv 'pm list packages -3'

    section "Disabled packages"
    tv 'pm list packages -d'

    section "TV screen state and free storage"
    tv 'dumpsys power | grep -E "mWakefulness=|Display Power"'
    tv 'df /data'

    section "Recovery records on this Pi"
    ls -la "$HOME/.cleanyourtv" 2>/dev/null

    section "Build tools on this Pi"
    echo "JAVA_HOME=${JAVA_HOME:-<unset>}"
    echo "ANDROID_HOME=$WORK/android-sdk"
    "$WORK/android-sdk/build-tools/36.0.0/aapt2" version 2>&1 | head -n 1

    section "Recent errors on the TV (last 60 lines)"
    tv 'logcat -d -t 400 *:E | tail -n 60'
} 2>&1 | tee "$OUT"

echo
echo "Saved to $OUT"
