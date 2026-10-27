#!/usr/bin/env bash
# pi-cleanup.sh - undo everything pi-setup.sh did.
#
# Usage:  ./pi-cleanup.sh [-y] [TV_IP]
# Env:    FORCE=1  carry on with the Pi cleanup even if the TV could not be restored
#                  (the recovery record is deleted, so the restore can no longer be run)
#
# Order: 1) restore the TV (re-enable packages, stock launcher as Home, remove the launcher)
#        2) remove what was installed on this Pi (workspace incl. venv, SDK, gradle override, apt packages)

set -Eeuo pipefail

ASSUME_YES=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

WORK="${CYTV_WORK:-$HOME/cleanyourtv-pi}"
STATE="$WORK/state.env"
STOCK_LAUNCHER="${STOCK_LAUNCHER:-com.google.android.apps.tv.launcherx}"
LOG_KEEP="$HOME/cleanyourtv-pi-logs"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

confirm() {
    [[ "$ASSUME_YES" == 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

[[ -f "$STATE" ]] || die "no state file at $STATE; was pi-setup.sh run on this machine?"
# shellcheck disable=SC1090
source "$STATE"

TV_HOST="${POSITIONAL[0]:-${TV_HOST:-192.168.1.140}}"
export TV_HOST
LAUNCHER_PKG="${LAUNCHER_PKG:-com.gathin.tvhome}"
PY="${REPO:-}/tools/venv/bin/python"
[[ -x "$PY" ]] || PY=python3

log "TV: $TV_HOST | workspace: $WORK"
confirm "Restore the TV and remove everything pi-setup.sh installed?" || die "cancelled"

# --- 1. Restore the TV -----------------------------------------------------------------------

tv_restored=0
if [[ -d "${REPO:-}" && -f "${LIST:-}" ]]; then
    log "1/2 Restoring the TV (wake it; accept any ADB prompt)"
    cd "$REPO"
    if "$PY" -I tools/tv.py --probe && tools/restore.sh "$LIST" "$STOCK_LAUNCHER"; then
        home="$("$PY" -I tools/tv.py 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' | tail -n 1)"
        log "Home resolves to: $home"
        if [[ "$home" == *"$LAUNCHER_PKG"* ]]; then
            log "WARNING: Home still points at $LAUNCHER_PKG; leaving the launcher installed"
        else
            "$PY" -I tools/tv.py "pm uninstall $LAUNCHER_PKG" || log "launcher was not installed or could not be removed"
            tv_restored=1
        fi
    else
        log "WARNING: could not restore the TV"
    fi
else
    log "1/2 Repo or list missing; skipping the TV restore"
    tv_restored=1
fi

if [[ "$tv_restored" != 1 && "${FORCE:-0}" != 1 ]]; then
    die "TV not restored; nothing on the Pi was removed. Fix the connection and re-run, or set FORCE=1."
fi

if [[ -d "${REPO:-}" ]]; then
    log "Turn off USB debugging on the TV (Settings > System > Developer options)."
    if [[ "$ASSUME_YES" != 1 ]]; then
        read -r -p "Press Enter when done to verify the ADB port is closed (or Ctrl-C to skip): " _
        "$PY" -I "$REPO/tools/adb-closed.py" || log "adb-closed.py reports the port may still be open"
    else
        log "Verify later with: $PY -I $REPO/tools/adb-closed.py"
    fi
fi

# --- 2. Remove what was installed on the Pi --------------------------------------------------

log "2/2 Removing Pi-side installs"
cd "$HOME"
pkill -f GradleDaemon 2>/dev/null || true

mkdir -p "$LOG_KEEP"
cp -f "$WORK"/*.log "$LOG_KEEP"/ 2>/dev/null || true

if [[ -n "${GRADLE_LINE:-}" && -f "$HOME/.gradle/gradle.properties" ]]; then
    grep -vxF "$GRADLE_LINE" "$HOME/.gradle/gradle.properties" > "$WORK/gradle.properties.new" || true
    cat "$WORK/gradle.properties.new" > "$HOME/.gradle/gradle.properties"
    rm -f "$WORK/gradle.properties.new"
    if [[ "${GRADLE_PROPS_EXISTED:-1}" == 0 && ! -s "$HOME/.gradle/gradle.properties" ]]; then
        rm -f "$HOME/.gradle/gradle.properties"
    fi
fi
[[ "${GRADLE_DIR_EXISTED:-1}" == 0 ]] && rm -rf "$HOME/.gradle"
[[ "${ANDROID_DIR_EXISTED:-1}" == 0 ]] && rm -rf "$HOME/.android"
[[ "${CYTV_DIR_EXISTED:-1}" == 0 ]] && rm -rf "$HOME/.cleanyourtv"

if [[ -n "${APT_ADDED:-}" ]] && confirm "Remove apt packages the setup installed (${APT_ADDED})? Other packages are left alone."; then
    # shellcheck disable=SC2086
    sudo apt-get remove -y $APT_ADDED
fi

rm -rf "$WORK"

log "Done. The TV is back on its stock launcher with the debloat undone; logs kept in $LOG_KEEP."
log "Left in place on purpose: unused apt dependencies (run 'sudo apt autoremove' yourself if you want them gone)."
