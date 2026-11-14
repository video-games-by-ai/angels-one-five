#!/usr/bin/env bash
# Rebuild the game packages: import, run the headless tests, export Linux,
# Windows and Android, and archive the desktop builds with their licences and a
# short readme (build/airflight-linux.tar.gz, build/airflight-windows.zip and
# build/airflight-android.apk).
# Requires Godot 4.5.1 with export templates (set AIRFLIGHT_GODOT if needed).
# The APK is signed with the key in GODOT_ANDROID_KEYSTORE_RELEASE_PATH/_USER/
# _PASSWORD; without them, with Godot's debug key on this machine. Android only
# installs an update over a build signed with the same key.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${AIRFLIGHT_GODOT:-$HOME/.cache/airfight/godot-4.5.1/Godot_v4.5.1-stable_linux.x86_64}"
cd "$ROOT"
"$GODOT" --headless --path game --editor --import --quit >/dev/null 2>&1
"$GODOT" --headless --path game --script res://tests/test_flight.gd
"$GODOT" --headless --path game --script res://tests/test_net.gd
"$GODOT" --headless --path game --script res://tests/test_touch.gd
mkdir -p build/airflight-linux build/airflight-windows build/airflight-android
"$GODOT" --headless --path game --export-release "Linux"
"$GODOT" --headless --path game --export-release "Windows"
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-$HOME/.local/share/godot/keystores/debug.keystore}"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="${GODOT_ANDROID_KEYSTORE_RELEASE_USER:-androiddebugkey}"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:-android}"
[ -f "$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" ] || { echo "No Android signing key at $GODOT_ANDROID_KEYSTORE_RELEASE_PATH" >&2; exit 1; }
rm -f build/airflight-android/airflight.apk build/airflight-android.apk
"$GODOT" --headless --path game --export-release "Android"
# (Godot can report success without writing the file, so the copy is the check.)
cp build/airflight-android/airflight.apk build/airflight-android.apk
# Each package carries the licences and a short readme. $2 is the start line.
package_notes() {
	cp -r LICENSE licenses "$1/"
	cat > "$1/README.txt" <<EOF
AIRFLIGHT - 1940s arcade dogfights over an Alpine valley

$2

Pick an aircraft (Spitfire, Mustang or Thunderbolt) and fight two AI fighters.
Mouse steers toward the aim circle. Left click or Space fires. Shift boosts.
W/S throttle. A/D roll. M on the aircraft screen changes the map (Alpine
Valley or Plav & Gusinje). Esc opens the pause menu with Change aircraft,
sensitivity, invert, camera shake, volume, graphics quality (Low/Medium/High)
and fullscreen. F11 toggles fullscreen.

Online: one player presses Host match, opens UDP port 24555 on their router
(or ticks "Open port automatically"), and sends the invite. Friends press
Join match and paste it. The invite works like a password: share it privately.
EOF
}
package_notes build/airflight-windows "Double-click Airflight.exe to play. No installer is needed.
Requires 64-bit Windows 10/11 and a graphics card with Vulkan support
(any GeForce GTX 900 / Radeon RX 400 / Intel Iris Xe or newer, current driver)."
package_notes build/airflight-linux "Run ./airflight.x86_64 to play. No installer is needed.
Requires 64-bit Linux and a graphics card with Vulkan support
(any GeForce GTX 900 / Radeon RX 400 / Intel Iris Xe or newer, current driver)."
rm -f build/airflight-windows.zip build/airflight-linux.tar.gz
(cd build && python3 -c "import shutil; shutil.make_archive('airflight-windows', 'zip', '.', 'airflight-windows')")
tar -C build -czf build/airflight-linux.tar.gz airflight-linux
ls -la build/airflight-linux.tar.gz build/airflight-windows.zip build/airflight-android.apk
