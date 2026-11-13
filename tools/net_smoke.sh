#!/usr/bin/env bash
# Two copies of the game play one online match over loopback, both flown by the
# AI, headless. The host autostarts when the joiner is in; both quit when the
# match ends. The joiner starts on another map, so it also checks that a joiner
# loads the host's map. Each player says one chat line when the match starts, and
# every log must show both lines. Pass a directory for the logs, or a temporary one is used.
#
#   tools/net_smoke.sh [LOG_DIR]
#   AIRFLIGHT_SERVER=1 tools/net_smoke.sh   # dedicated server + two joiners instead
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${AIRFLIGHT_GODOT:-$HOME/.cache/airfight/godot-4.5.1/Godot_v4.5.1-stable_linux.x86_64}"
OUT="${1:-$(mktemp -d)}"
PORT="${AIRFLIGHT_PORT:-24655}"
LIMIT="${AIRFLIGHT_SCORE_LIMIT:-2}"
mkdir -p "$OUT"
rm -f "$OUT/invite.txt"
COMMON=(--headless --path game --)
FLY=(--ai-player --log --quit-after-matches=1 --quit-at=600)

if [[ "${AIRFLIGHT_SERVER:-0}" == "1" ]]; then
  "$GODOT" "${COMMON[@]}" --server --map=alpine --address=127.0.0.1 --port="$PORT" --score-limit="$LIMIT" \
    --invite-out="$OUT/invite.txt" --quit-after-matches=1 --quit-at=600 --log > "$OUT/host.log" 2>&1 &
else
  "$GODOT" "${COMMON[@]}" --host --map=plav --aircraft=1 --name=Host --address=127.0.0.1 --port="$PORT" \
    --score-limit="$LIMIT" --autostart=2 --invite-out="$OUT/invite.txt" --say="good luck from the host" "${FLY[@]}" > "$OUT/host.log" 2>&1 &
fi
HOST_PID=$!
for _ in $(seq 1 120); do [[ -s "$OUT/invite.txt" ]] && break; sleep 0.5; done
[[ -s "$OUT/invite.txt" ]] || { echo "no invite written"; kill $HOST_PID; exit 1; }
INVITE="$(cat "$OUT/invite.txt")"

"$GODOT" "${COMMON[@]}" --join="$INVITE" --map=alpine --aircraft=0 --name=Guest --say="you too, says the guest" "${FLY[@]}" > "$OUT/guest.log" 2>&1 &
GUEST_PID=$!
PIDS=($HOST_PID $GUEST_PID)
if [[ "${AIRFLIGHT_SERVER:-0}" == "1" ]]; then
  "$GODOT" "${COMMON[@]}" --join="$INVITE" --aircraft=2 --name=Third "${FLY[@]}" > "$OUT/third.log" 2>&1 &
  PIDS+=($!)
fi
status=0
for pid in "${PIDS[@]}"; do wait "$pid" || status=$?; done
echo "logs in $OUT (exit $status)"
grep -h -E "^NET: match|^SERVER: match|^HOST|^JOIN|^CHAT|quitting" "$OUT"/*.log || true
for log in "$OUT"/*.log; do
  if ! grep -q "^CHAT Guest: you too, says the guest" "$log"; then echo "chat line from the guest missing in $log"; status=1; fi
  if [[ "${AIRFLIGHT_SERVER:-0}" != "1" ]] && ! grep -q "^CHAT Host: good luck from the host" "$log"; then echo "chat line from the host missing in $log"; status=1; fi
done
exit $status
