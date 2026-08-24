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
cd "$ROOT"
PI_CODING_AGENT_DIR="$STATE" VIPI_HOST=127.0.0.1 VIPI_PORT=$PORT node --import tsx host/src/server.ts >"$STATE/host.log" 2>&1 &
HOST_PID=$!
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
PI_CODING_AGENT_DIR="$STATE" VIPI_BROKER_URL="ws://127.0.0.1:$PORT/ws" \
  node --import tsx host/test/fixture-runtime.ts >"$STATE/runtime.log" 2>&1 &
RUNTIME_PID=$!
sleep 0.5
DESTINATION=${VIPI_TEST_DESTINATION:-platform=iOS Simulator,name=Vipi iPhone}
xcodebuild -project Vipi.xcodeproj -scheme Vipi -destination "$DESTINATION" test
