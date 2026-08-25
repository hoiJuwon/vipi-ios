#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STATE=$(mktemp -d "${TMPDIR:-/tmp}/vipi-e2e.XXXXXX")
TOKEN="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
PORT=9876
cleanup() {
  [ -n "${RUNTIME_PID:-}" ] && kill "$RUNTIME_PID" 2>/dev/null || true
  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null || true
  rm -rf "$STATE"
}
trap cleanup EXIT INT TERM
mkdir -p "$STATE/vipi"
printf '%s\n' "$TOKEN" > "$STATE/vipi/token"
chmod 700 "$STATE" "$STATE/vipi"
chmod 600 "$STATE/vipi/token"
FIXTURE_SESSION_FILE="$STATE/vipi-e2e.jsonl"
cat > "$FIXTURE_SESSION_FILE" <<EOF
{"type":"session","version":3}
{"id":"entry-1","parentId":null,"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"History restored"}],"timestamp":1787529600000}}
EOF
cat > "$STATE/tmux-session-tree.json" <<EOF
{"entries":[{"piSessionId":"e2e","name":"E2E / Live session","cwd":"/tmp/vipi-e2e","status":"idle","tmuxSession":"fixture","tmuxWindow":"1","tmuxPaneId":"${TMUX_PANE:-}","lastSeen":"2026-08-24T00:00:00.000Z","sessionFile":"$FIXTURE_SESSION_FILE"}]}
EOF
chmod 600 "$STATE/tmux-session-tree.json" "$FIXTURE_SESSION_FILE"
cd "$ROOT"
PI_CODING_AGENT_DIR="$STATE" VIPI_HOST=127.0.0.1 VIPI_PORT=$PORT node --import tsx host/src/server.ts >"$STATE/host.log" 2>&1 &
HOST_PID=$!
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
PI_CODING_AGENT_DIR="$STATE" VIPI_BROKER_URL="ws://127.0.0.1:$PORT/ws" \
  VIPI_FIXTURE_SESSION_FILE="$FIXTURE_SESSION_FILE" \
  node --import tsx host/test/fixture-runtime.ts >"$STATE/runtime.log" 2>&1 &
RUNTIME_PID=$!
sleep 0.5
DESTINATION=${VIPI_TEST_DESTINATION:-platform=iOS Simulator,name=Vipi iPhone}
xcodebuild -project Vipi.xcodeproj -scheme Vipi -destination "$DESTINATION" test
