#!/usr/bin/env bash
# Rebuild the game packages: import, run the headless tests, export Linux and
# Windows, and zip the Windows build with its licences and a short readme.
# Requires Godot 4.5.1 with export templates (set AIRFLIGHT_GODOT if needed).
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${AIRFLIGHT_GODOT:-$HOME/.cache/airfight/godot-4.5.1/Godot_v4.5.1-stable_linux.x86_64}"
cd "$ROOT"
"$GODOT" --headless --path game --editor --import --quit >/dev/null 2>&1
"$GODOT" --headless --path game --script res://tests/test_flight.gd
mkdir -p build/airflight-linux build/airflight-windows
"$GODOT" --headless --path game --export-release "Linux"
"$GODOT" --headless --path game --export-release "Windows"
cp -r LICENSE licenses build/airflight-windows/
cat > build/airflight-windows/README.txt <<'EOF'
AIRFLIGHT - 1940s arcade dogfights over an Alpine valley

Double-click Airflight.exe to play. No installer is needed.
Requires 64-bit Windows 10/11 and a graphics card with Vulkan support
(any GeForce GTX 900 / Radeon RX 400 / Intel Iris Xe or newer, current driver).

Pick an aircraft (Spitfire, Mustang or Thunderbolt) and fight two AI fighters.
Mouse steers toward the aim circle. Left click or Space fires. Shift boosts.
W/S throttle. A/D roll. M on the aircraft screen changes the map (Alpine
Valley or Plav & Gusinje). Esc opens the pause menu with Change aircraft,
sensitivity, invert, camera shake, volume, graphics quality (Low/Medium/High)
and fullscreen. F11 toggles fullscreen.
EOF
rm -f build/airflight-windows.zip
(cd build && python3 -c "import shutil; shutil.make_archive('airflight-windows', 'zip', '.', 'airflight-windows')")
ls -la build/airflight-linux build/airflight-windows.zip
