#!/bin/sh
set -eu

HOST="100.88.238.58"
REMOTE_REPO="/Users/choijuwon/vipi-ios"
DEVICE="00008130-001C5C602883401C"
TEAM="Z8FZKW7QW6"
BUNDLE_ID="dev.vipi.ios"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
BUNDLE="/tmp/vipi-main.bundle"
REMOTE_RUNNER="/tmp/deploy-vipi-iphone.sh"
STATUS="/tmp/vipi-iphone-deploy.status"
LOG="/tmp/vipi-iphone-deploy.log"

cd "$ROOT"
[ "$(git branch --show-current)" = "main" ] || { echo "Deploy only from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Local main is not clean" >&2; exit 1; }

rm -f "$BUNDLE"
git bundle create "$BUNDLE" main
scp -q "$BUNDLE" "$HOST:/tmp/vipi-main.bundle"

ssh -o BatchMode=yes "$HOST" "
  set -eu
  cd '$REMOTE_REPO'
  [ -z \"\$(git status --porcelain)\" ] || { echo 'Remote repository is not clean' >&2; exit 1; }
  git fetch /tmp/vipi-main.bundle main
  git merge --ff-only FETCH_HEAD
"

cat > /tmp/vipi-remote-deploy-runner.sh <<EOF
#!/bin/zsh
set -uo pipefail
REPO="$REMOTE_REPO"
DEVICE="$DEVICE"
DERIVED="/tmp/vipi-iphone-derived"
LOG="$LOG"
STATUS="$STATUS"
rm -f "\$STATUS"
cd "\$REPO" || { echo repo-missing > "\$STATUS"; exit 1; }
rm -rf "\$DERIVED"
if ! xcodebuild \\
  -project Vipi.xcodeproj \\
  -scheme Vipi \\
  -configuration Debug \\
  -destination "platform=iOS,id=\$DEVICE" \\
  -derivedDataPath "\$DERIVED" \\
  DEVELOPMENT_TEAM=$TEAM \\
  CODE_SIGN_STYLE=Automatic \\
  "CODE_SIGN_IDENTITY=Apple Development" \\
  build >"\$LOG" 2>&1; then
  echo build-failed > "\$STATUS"; exit 1
fi
APP="\$DERIVED/Build/Products/Debug-iphoneos/Vipi.app"
if ! xcrun devicectl device install app --device "\$DEVICE" "\$APP" >>"\$LOG" 2>&1; then
  echo install-failed > "\$STATUS"; exit 1
fi
if ! xcrun devicectl device process launch --device "\$DEVICE" --terminate-existing "$BUNDLE_ID" >>"\$LOG" 2>&1; then
  echo launch-failed > "\$STATUS"; exit 1
fi
echo success > "\$STATUS"
EOF
chmod 700 /tmp/vipi-remote-deploy-runner.sh
scp -q /tmp/vipi-remote-deploy-runner.sh "$HOST:$REMOTE_RUNNER"

ssh -o BatchMode=yes "$HOST" "
  chmod 700 '$REMOTE_RUNNER'
  rm -f '$STATUS' '$LOG'
  osascript -e 'tell application \"Terminal\" to do script \"$REMOTE_RUNNER\"'
" >/dev/null

attempt=0
while [ "$attempt" -lt 180 ]; do
  result=$(ssh -o BatchMode=yes "$HOST" "cat '$STATUS' 2>/dev/null || true")
  if [ -n "$result" ]; then
    if [ "$result" = "success" ]; then
      echo "Vipi build, install, and launch succeeded on physical iPhone."
      exit 0
    fi
    echo "Physical iPhone deployment failed: $result" >&2
    ssh -o BatchMode=yes "$HOST" "tail -100 '$LOG' 2>/dev/null || true" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 2
done

echo "Timed out waiting for physical iPhone deployment" >&2
ssh -o BatchMode=yes "$HOST" "tail -100 '$LOG' 2>/dev/null || true" >&2
exit 1
