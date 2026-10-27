# tcl-tv-debloat

Debloat a TCL Google TV and give it a clean launcher, driven from a Raspberry Pi over Wi-Fi.
This is a thin wrapper around the MIT-licensed [Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv)
project. It does the parts that are awkward on a Pi: an ARM Android build toolchain, the repo's
required Python venv, the Google TV setup-wizard Home conflict, and a full undo.

Nothing from upstream is copied here. `pi-setup.sh` clones it at run time.

## What it does

`scripts/pi-setup.sh` runs these steps, and each is safe to repeat:

1. Installs system packages (`git`, `python3-venv`, `adb`, ...).
2. Installs JDK 17 (apt if available, otherwise Temurin 17 for aarch64).
3. Clones upstream and creates its `tools/venv`.
4. Installs the Android SDK command-line tools, platform 34 and build-tools.
5. Swaps in arm64 `aapt2` from [Commit451/android-arm-build-tools](https://github.com/Commit451/android-arm-build-tools)
   and points Gradle at it.
6. Connects to the TV over ADB (port 5555).
7. Applies a debloat list. The Google TV setup wizard is added to it so the new launcher can own Home.
8. Builds and installs the launcher.

`scripts/pi-cleanup.sh` undoes it all: restores the TV from the recovery record, puts Google's launcher
back, removes the launcher, then removes what the setup installed on the Pi.

## Requirements

- Raspberry Pi running **64-bit** Raspberry Pi OS (`uname -m` prints `aarch64`).
- A TV running Android TV or Google TV, with USB debugging on and network ADB on port 5555.
- The Pi and TV on the same network.

## Usage

```bash
git clone git@github.com:<you>/tcl-tv-debloat.git
cd tcl-tv-debloat
chmod +x scripts/*.sh
scripts/pi-setup.sh 192.168.1.140
```

Wake the TV first and accept "Allow USB debugging?" with "Always allow".

| Variable | Default | Effect |
| --- | --- | --- |
| `KEEP_VOICE` | `1` | Keep the voice assistant and the remote's mic button. `0` disables them. |
| `KEEP_CAST` | `1` | Keep the Chromecast receiver. `0` disables it. |
| `LIST_SRC` | `examples/tcl-g06-google-tv-indonesia/debloat.txt` | Debloat list inside the upstream repo. |
| `BT_VERSION` | `36.0.0` | Build-tools version that gets the arm64 `aapt2`. |
| `FORCE_SETUPWRAITH` | unset | Set to `1` on Ethernet to skip the Wi-Fi ownership check. |
| `CYTV_WORK` | `~/cleanyourtv-pi` | Where everything is installed. |

`-y` skips the confirmation prompts.

## Important: Wi-Fi and the setup wizard

On Google TV the setup wizard (`com.google.android.tungsten.setupwraith`) also answers Home and
outranks a third-party launcher, so it has to be disabled. If your saved Wi-Fi network was added during the
first-run wizard, the wizard owns it, and Android deletes the network when the wizard is disabled. The TV
then drops offline and ADB goes with it.

The script checks this before it changes anything and stops with instructions. On the TV, forget the Wi-Fi
network and join it again; it then belongs to the system. On Ethernet, run with `FORCE_SETUPWRAITH=1`.

## Undo

```bash
scripts/pi-cleanup.sh 192.168.1.140
```

Run it from the same Pi that applied the debloat, because the recovery record lives in `~/.cleanyourtv/`
on that machine. If the TV can't be restored, the script stops before deleting anything (`FORCE=1`
overrides that, and the recovery record is then lost).

## Diagnostics

```bash
scripts/diagnose.sh 192.168.1.140
```

Writes `~/cleanyourtv-pi/diagnostics.txt`: device info, who owns Home and Wi-Fi, installed and disabled
packages, free storage and recent errors.

## Developed against

| Item | Value |
| --- | --- |
| TV | TCL "Smart TV", device `G06`, build `AR2101`, Google TV 11 (SDK 30) |
| Pi OS | Raspberry Pi OS (Debian 13 "trixie"), arm64 |
| Upstream | Gathin23/cleanyourtv, launcher built with AGP 8.5.2 and Gradle 8.9 |

Other TVs should work with a different `LIST_SRC`, but only the setup above has been exercised.

## License

MIT, see [LICENSE](LICENSE). Upstream cleanyourtv is MIT, copyright its author.
