#!/usr/bin/env bash
# pi-setup.sh - cleanyourtv end to end from a Raspberry Pi (64-bit Raspberry Pi OS).
#
# Usage:  ./pi-setup.sh [-y] [TV_IP]
# Env:    KEEP_VOICE=1  (default) keep the voice assistant and the remote's mic button
#         KEEP_CAST=1   (default) keep the Chromecast receiver (casting from a phone)
#         LIST_SRC      debloat list inside the repo
#                       (default examples/tcl-g06-google-tv-indonesia/debloat.txt)
#         BT_VERSION    Android build-tools version (default 36.0.0)
#
# Everything lives under ~/cleanyourtv-pi (including the Python venv the repo's scripts require),
# apart from apt packages, ~/.gradle, ~/.android and ~/.cleanyourtv. pi-cleanup.sh reverts all of it.

set -Eeuo pipefail

ASSUME_YES=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

TV_HOST="${POSITIONAL[0]:-${TV_HOST:-192.168.1.140}}"
KEEP_VOICE="${KEEP_VOICE:-1}"
KEEP_CAST="${KEEP_CAST:-1}"
BT_VERSION="${BT_VERSION:-36.0.0}"
PLATFORM="android-34"
LIST_SRC="${LIST_SRC:-examples/tcl-g06-google-tv-indonesia/debloat.txt}"
CMDTOOLS_URL="${CMDTOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}"
ARM_BT_URL="https://raw.githubusercontent.com/Commit451/android-arm-build-tools/main/install.sh"
REPO_URL="https://github.com/Gathin23/cleanyourtv"
LAUNCHER_PKG="com.gathin.tvhome"

WORK="${CYTV_WORK:-$HOME/cleanyourtv-pi}"
REPO="$WORK/cleanyourtv"
SDK="$WORK/android-sdk"
STATE="$WORK/state.env"
LIST="$WORK/my-tcl.txt"
LOG="$WORK/setup.log"

mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

confirm() {
    [[ "$ASSUME_YES" == 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

state_has() { grep -q "^$1=" "$STATE" 2>/dev/null; }
state_set() {
    local key=$1
    shift
    touch "$STATE"
    sed -i "/^${key}=/d" "$STATE"
    printf '%s=%q\n' "$key" "$*" >> "$STATE"
}

# --- Preflight -------------------------------------------------------------------------------

[[ "$(uname -m)" == "aarch64" ]] || die "needs 64-bit Raspberry Pi OS (uname -m is $(uname -m))"
[[ "$EUID" -ne 0 ]] || die "run as your normal user; the script calls sudo where needed"
command -v sudo >/dev/null || die "sudo not found"

log "TV: $TV_HOST | workspace: $WORK | list: $LIST_SRC"
confirm "Install tooling on this Pi and change the TV at $TV_HOST?" || die "cancelled"

state_set TV_HOST "$TV_HOST"
state_set WORK "$WORK"
state_set LAUNCHER_PKG "$LAUNCHER_PKG"
state_has GRADLE_DIR_EXISTED || state_set GRADLE_DIR_EXISTED "$([[ -d $HOME/.gradle ]] && echo 1 || echo 0)"
state_has GRADLE_PROPS_EXISTED || state_set GRADLE_PROPS_EXISTED "$([[ -f $HOME/.gradle/gradle.properties ]] && echo 1 || echo 0)"
state_has ANDROID_DIR_EXISTED || state_set ANDROID_DIR_EXISTED "$([[ -d $HOME/.android ]] && echo 1 || echo 0)"
state_has CYTV_DIR_EXISTED || state_set CYTV_DIR_EXISTED "$([[ -d $HOME/.cleanyourtv ]] && echo 1 || echo 0)"

# --- 1. System packages ----------------------------------------------------------------------

log "1/8 System packages"
sudo apt-get update -qq

PKGS=(git python3-pip python3-venv unzip curl adb)
jdk17_candidate="$(apt-cache policy openjdk-17-jdk 2>/dev/null | awk '/Candidate:/ {print $2}')"
if [[ -n "$jdk17_candidate" && "$jdk17_candidate" != "(none)" ]]; then
    PKGS+=(openjdk-17-jdk)
fi

missing=()
for pkg in "${PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]})); then
    log "installing: ${missing[*]}"
    sudo apt-get install -y "${missing[@]}"
fi
# Accumulate across re-runs so cleanup removes everything this script ever installed.
apt_before="$( (source "$STATE" 2>/dev/null; echo "${APT_ADDED:-}") )"
state_set APT_ADDED "$(printf '%s\n' $apt_before "${missing[@]:-}" | sort -u | xargs)"

# --- 2. JDK 17 -------------------------------------------------------------------------------

log "2/8 JDK 17"
JAVA_HOME=""
for candidate in "$WORK/jdk17" /usr/lib/jvm/java-17-openjdk-arm64; do
    if [[ -x "$candidate/bin/javac" ]]; then
        JAVA_HOME="$candidate"
        break
    fi
done
if [[ -z "$JAVA_HOME" ]]; then
    log "openjdk-17 not available from apt; downloading Temurin 17 (aarch64)"
    mkdir -p "$WORK/jdk17"
    curl -fL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/aarch64/jdk/hotspot/normal/eclipse" \
        -o "$WORK/jdk17.tar.gz"
    tar -xzf "$WORK/jdk17.tar.gz" -C "$WORK/jdk17" --strip-components=1
    rm -f "$WORK/jdk17.tar.gz"
    JAVA_HOME="$WORK/jdk17"
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
java_version="$("$JAVA_HOME/bin/java" -version 2>&1)"
[[ "$java_version" == *'"17.'* ]] || die "JDK at $JAVA_HOME is not version 17"
log "JAVA_HOME=$JAVA_HOME"

# --- 3. Repo and Python dependencies ---------------------------------------------------------

log "3/8 Repo and Python dependencies"
if [[ -d "$REPO/.git" ]]; then
    git -C "$REPO" pull --ff-only
else
    git clone --depth 1 "$REPO_URL" "$REPO"
fi

# The repo's own scripts (disable.sh, restore.sh, build-and-install.sh) only run tools/venv/bin/python
# and stop without it. The venv sits inside the workspace, so system Python is never touched and
# cleanup deletes it with everything else.
VENV="$REPO/tools/venv"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install -r "$REPO/tools/requirements.txt"
PY="$VENV/bin/python"

# --- 4. Android SDK --------------------------------------------------------------------------

log "4/8 Android SDK (platform $PLATFORM, build-tools $BT_VERSION)"
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"

if [[ ! -x "$SDKMANAGER" ]]; then
    mkdir -p "$SDK/cmdline-tools"
    curl -fL "$CMDTOOLS_URL" -o "$WORK/cmdtools.zip"
    unzip -q -o "$WORK/cmdtools.zip" -d "$SDK/cmdline-tools"
    rm -rf "$SDK/cmdline-tools/latest"
    mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
    rm -f "$WORK/cmdtools.zip"
fi

"$SDKMANAGER" --sdk_root="$SDK" --licenses < <(yes) > /dev/null || true
# build-tools 34.0.0 is the Android Gradle Plugin's default for this project; installing it now keeps
# Gradle from trying to download it mid-build. The arm64 aapt2 comes from $BT_VERSION (next step).
"$SDKMANAGER" --sdk_root="$SDK" "platforms;$PLATFORM" "build-tools;34.0.0" "build-tools;$BT_VERSION"

# --- 5. arm64 build tools --------------------------------------------------------------------

log "5/8 arm64 aapt2 for Gradle"
if ! "$SDK/build-tools/$BT_VERSION/aapt2" version >/dev/null 2>&1; then
    curl -fsSL "$ARM_BT_URL" -o "$WORK/arm-build-tools-install.sh"
    log "downloaded $WORK/arm-build-tools-install.sh"
    log "sha256: $(sha256sum "$WORK/arm-build-tools-install.sh" | cut -d' ' -f1)"
    confirm "Review that script if you wish ($WORK/arm-build-tools-install.sh). Run it now?" || die "cancelled"
    chmod +x "$WORK/arm-build-tools-install.sh"
    "$WORK/arm-build-tools-install.sh" --version "$BT_VERSION" --sdk "$SDK"
fi
"$SDK/build-tools/$BT_VERSION/aapt2" version >/dev/null 2>&1 || die "arm64 aapt2 does not run; check the installer output above"

mkdir -p "$HOME/.gradle"
GRADLE_LINE="android.aapt2FromMavenOverride=$SDK/build-tools/$BT_VERSION/aapt2"
if ! grep -qxF "$GRADLE_LINE" "$HOME/.gradle/gradle.properties" 2>/dev/null; then
    echo "$GRADLE_LINE" >> "$HOME/.gradle/gradle.properties"
fi

# --- 6. Connect to the TV --------------------------------------------------------------------

log "6/8 Connecting to $TV_HOST (wake the TV; accept 'Allow USB debugging?' and tick 'Always allow')"
export TV_HOST
cd "$REPO"

connected=0
for attempt in 1 2 3 4 5 6; do
    if "$PY" -I tools/tv.py --probe; then
        connected=1
        break
    fi
    log "no answer yet (attempt $attempt/6); retrying in 10s"
    sleep 10
done
[[ "$connected" == 1 ]] || die "could not reach the TV over ADB at $TV_HOST:5555"

# --- 7. Debloat ------------------------------------------------------------------------------

log "7/8 Debloat list: $LIST_SRC"
[[ -f "$REPO/$LIST_SRC" ]] || die "list not found: $REPO/$LIST_SRC"
cp "$REPO/$LIST_SRC" "$LIST"

comment_out() {
    local pkg=$1
    sed -i -E "s/^${pkg//./\\.}([[:space:]]|\$)/# &/" "$LIST"
}
if [[ "$KEEP_VOICE" == 1 ]]; then
    for pkg in com.google.android.katniss com.google.android.tv.assistant com.tcl.micmanager; do
        comment_out "$pkg"
    done
    log "keeping the voice assistant (KEEP_VOICE=0 to disable it)"
fi
if [[ "$KEEP_CAST" == 1 ]]; then
    comment_out com.google.android.apps.mediashell
    log "keeping the Chromecast receiver (KEEP_CAST=0 to disable it)"
fi

# Google TV: the setup wizard also answers Home and outranks a third-party launcher, so it has to be
# disabled before the stock launcher. It goes into the list so restore.sh brings it back.
SETUP_PKG=com.google.android.tungsten.setupwraith
if ! grep -qE "^${SETUP_PKG//./\\.}([[:space:]]|\$)" "$LIST"; then
    printf '\n# Needed off for a replacement launcher; restore re-enables it\n%s\n' "$SETUP_PKG" >> "$LIST"
fi

# A Wi-Fi network saved during the first-run wizard belongs to the setup wizard, and Android deletes it
# when the wizard is disabled: the TV drops off Wi-Fi and ADB goes with it.
wifi_owner="$("$PY" -I tools/tv.py 'dumpsys wifi' | grep -o 'cname=[^ ]*' | sort -u || true)"
log "saved Wi-Fi network owner(s): ${wifi_owner:-none found}"
if grep -q setupwraith <<<"$wifi_owner" && [[ -z "${FORCE_SETUPWRAITH:-}" ]]; then
    die "the TV's saved Wi-Fi belongs to the setup wizard; disabling it would delete the network. On the TV: Settings > Network & Internet, forget the network and join it again, then re-run this script. On Ethernet, re-run with FORCE_SETUPWRAITH=1."
fi

state_set LIST "$LIST"
state_set REPO "$REPO"
state_set SDK "$SDK"
state_set GRADLE_LINE "$GRADLE_LINE"

tools/disable.sh "$LIST"
"$PY" -I tools/check.py "$LIST" || log "check.py reported drift; re-run with --fix if the TV re-enabled something"

# --- 8. Launcher -----------------------------------------------------------------------------

log "8/8 Building and installing the launcher"
launcher/build-and-install.sh

home="$("$PY" -I tools/tv.py 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' | tail -n 1)"
log "Home now resolves to: $home"
[[ "$home" == *"$LAUNCHER_PKG"* ]] || log "WARNING: Home is not the new launcher yet; check the TV before continuing"

focused="$("$PY" -I tools/tv.py 'dumpsys activity activities' | grep -m1 mFocusedApp || true)"
log "Focused app (ground truth for Home): ${focused:-unknown}"

log "Done. Log: $LOG"
log "Reboot the TV once and confirm Home, HDMI inputs, Wi-Fi, the remote and your apps."
log "To undo everything: ./pi-cleanup.sh"
