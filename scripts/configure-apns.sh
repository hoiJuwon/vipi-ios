#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /path/to/AuthKey_KEYID.p8 KEYID12345" >&2
  exit 64
fi

SOURCE_KEY=$1
KEY_ID=$2
STATE="$HOME/.pi/agent/vipi"
TARGET_KEY="$STATE/AuthKey.p8"
CONFIG="$STATE/apns.json"
TEAM_ID="Z8FZKW7QW6"
TOPIC="com.abovetech.vipi.choijuwon"

[ "${#KEY_ID}" -eq 10 ] || { echo "APNs key ID must be exactly 10 uppercase letters or digits." >&2; exit 64; }
case "$KEY_ID" in
  *[!A-Z0-9]*) echo "APNs key ID must be exactly 10 uppercase letters or digits." >&2; exit 64 ;;
esac
[ -f "$SOURCE_KEY" ] || { echo "APNs key not found: $SOURCE_KEY" >&2; exit 66; }
grep -q "BEGIN PRIVATE KEY" "$SOURCE_KEY" || { echo "The selected file is not an APNs .p8 private key." >&2; exit 65; }

mkdir -p "$STATE"
chmod 700 "$STATE"
cp "$SOURCE_KEY" "$TARGET_KEY"
chmod 600 "$TARGET_KEY"
python3 - "$CONFIG" "$TARGET_KEY" "$KEY_ID" "$TEAM_ID" "$TOPIC" <<'PY'
import json, os, sys
path, key_path, key_id, team_id, topic = sys.argv[1:]
temporary = path + ".tmp"
with open(temporary, "w") as handle:
    json.dump({"keyPath": key_path, "keyID": key_id, "teamID": team_id, "topic": topic}, handle, indent=2)
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY

launchctl kickstart -k "gui/$(id -u)/dev.vipi.host"
echo "Configured APNs for $TOPIC and restarted dev.vipi.host."
