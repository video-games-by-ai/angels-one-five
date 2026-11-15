#!/usr/bin/env bash
# Is the delay the stats readout shows the real one? Games on this machine fly
# one online match by AI, each joiner through a proxy that delays its packets
# (tools/net_delay_proxy.py). All share one clock, so the real age of every
# picture can be worked out from the logs and compared with the readout
# (tools/net_delay_check.py). Fails if they differ by more than 15 ms.
#
#   tools/net_delay_check.sh [LOG_DIR]
#   AIRFLIGHT_DELAYS="40 90" tools/net_delay_check.sh   # one joiner per figure: ms each way (default "40")
#   AIRFLIGHT_SERVER=1 ...                              # dedicated server, so joiners see each other through it
#   AIRFLIGHT_JITTER=20 AIRFLIGHT_LOSS=5 ...            # ms of jitter and percent lost, each way
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${AIRFLIGHT_GODOT:-$HOME/.cache/airfight/godot-4.5.1/Godot_v4.5.1-stable_linux.x86_64}"
OUT="${1:-$(mktemp -d)}"
PORT="${AIRFLIGHT_PORT:-24665}"
SECONDS_FLOWN="${AIRFLIGHT_SECONDS:-45}"
read -r -a DELAYS <<< "${AIRFLIGHT_DELAYS:-40}"
NAMES=(Ana Ben Cy)
mkdir -p "$OUT"
rm -f "$OUT"/*.log "$OUT/invite.txt"
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT
COMMON=(--headless --path game --)
FLY=(--ai-player --log --score-limit=50 --quit-at="$SECONDS_FLOWN")
PLAYERS=$(( ${#DELAYS[@]} + 1 ))

if [[ "${AIRFLIGHT_SERVER:-0}" == "1" ]]; then
  PLAYERS=${#DELAYS[@]}
  "$GODOT" "${COMMON[@]}" --server --map=alpine --address=127.0.0.1 --port="$PORT" --autostart="$PLAYERS" \
    --invite-out="$OUT/invite.txt" --log --score-limit=50 --quit-at="$SECONDS_FLOWN" > "$OUT/host.log" 2>&1 &
else
  "$GODOT" "${COMMON[@]}" --host --map=alpine --aircraft=1 --name=Host --address=127.0.0.1 --port="$PORT" \
    --autostart="$PLAYERS" --invite-out="$OUT/invite.txt" "${FLY[@]}" > "$OUT/host.log" 2>&1 &
fi
PIDS+=($!)
for _ in $(seq 1 120); do [[ -s "$OUT/invite.txt" ]] && break; sleep 0.5; done
[[ -s "$OUT/invite.txt" ]] || { echo "no invite written"; exit 1; }

cat > "$OUT/reinvite.gd" <<'GD'
extends SceneTree
func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var inv: Invite = Invite.decode(args[0])
	inv.port = int(args[1])
	print("INVITE " + inv.encode())
	quit()
GD
LOGS=("$OUT/host.log")
for i in "${!DELAYS[@]}"; do
  via=$(( PORT + 1 + i ))
  python3 tools/net_delay_proxy.py "$via" "$PORT" "${DELAYS[$i]}" "${AIRFLIGHT_JITTER:-0}" "${AIRFLIGHT_LOSS:-0}" &
  PIDS+=($!)
  invite="$("$GODOT" --headless --path game --script "$OUT/reinvite.gd" -- "$(cat "$OUT/invite.txt")" "$via" 2>/dev/null | sed -n 's/^INVITE //p')"
  "$GODOT" "${COMMON[@]}" --join="$invite" --aircraft="$(( i % 3 ))" --name="${NAMES[$i]}" "${FLY[@]}" > "$OUT/${NAMES[$i]}.log" 2>&1 &
  PIDS+=($!)
  LOGS+=("$OUT/${NAMES[$i]}.log")
done
sleep "$(( SECONDS_FLOWN + 12 ))"
echo "logs in $OUT"
python3 tools/net_delay_check.py "${LOGS[@]}"
