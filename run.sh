#!/usr/bin/env bash
# Launch Airflight on Linux. Uses the exported build if present, otherwise runs
# the project with Godot 4.5.1 (set AIRFLIGHT_GODOT to its executable).
# Extra arguments are passed to the game, e.g.:  ./run.sh -- --quality=1
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$ROOT/build/airflight-linux/airflight.x86_64" ]]; then
  exec "$ROOT/build/airflight-linux/airflight.x86_64" "$@"
fi
GODOT="${AIRFLIGHT_GODOT:-$HOME/.cache/airfight/godot-4.5.1/Godot_v4.5.1-stable_linux.x86_64}"
if [[ ! -x "$GODOT" ]]; then
  GODOT="$(command -v godot || command -v godot4 || true)"
fi
if [[ -z "$GODOT" ]]; then
  echo "Install Godot 4.5.1 or set AIRFLIGHT_GODOT to its executable." >&2
  exit 1
fi
if [[ ! -d "$ROOT/game/.godot/imported" ]]; then
  "$GODOT" --headless --path "$ROOT/game" --editor --import --quit
fi
exec "$GODOT" --path "$ROOT/game" "$@"
