#!/bin/sh
set -eu

REMOTE_HOST="100.88.238.58"
REMOTE_REPO="/Users/choijuwon/vipi-ios"
TEAM="Z8FZKW7QW6"
CANONICAL_BUNDLE="com.abovetech.vipi.choijuwon"
LEGACY_DUPLICATE="dev.vipi.ios"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
BUNDLE="/tmp/vipi-main.bundle"
RUNNER_LOCAL="/tmp/vipi-physical-deploy-runner.sh"
RUNNER_REMOTE="/tmp/vipi-physical-deploy-runner.sh"
STATUS="/tmp/vipi-iphone-deploy.status"
LOG="/tmp/vipi-iphone-deploy.log"
APPS="/tmp/vipi-iphone-apps.txt"

physical_device_id() {
  xcodebuild -project "$1/Vipi.xcodeproj" -scheme Vipi -showdestinations 2>/dev/null \
    | sed -n 's/.*platform:iOS, arch:[^,]*, id:\([^,]*\),.*/\1/p' \
    | head -1
}

has_connected_iphone() {
  xcrun devicectl list devices 2>/dev/null | grep -E 'connected[[:space:]]+iPhone' >/dev/null
}

cd "$ROOT"
[ "$(git branch --show-current)" = "main" ] || { echo "Deploy only from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Local main is not clean" >&2; exit 1; }

TARGET="local"
TARGET_REPO="$ROOT"
DEVICE=""
if has_connected_iphone; then
  DEVICE=$(physical_device_id "$ROOT")
  [ -n "$DEVICE" ] || { echo "A local iPhone is connected but Xcode has no physical destination" >&2; exit 1; }
  echo "Deploying through locally connected iPhone destination $DEVICE"
else
  TARGET="remote"
  echo "No physical iPhone on Mac Studio; checking MacBook Pro $REMOTE_HOST"
  ssh -o BatchMode=yes "$REMOTE_HOST" "xcrun devicectl list devices 2>/dev/null | grep -E 'connected[[:space:]]+iPhone' >/dev/null" \
    || { echo "No connected physical iPhone found on Mac Studio or MacBook Pro" >&2; exit 1; }

  rm -f "$BUNDLE"
  git bundle create "$BUNDLE" main
  scp -q "$BUNDLE" "$REMOTE_HOST:/tmp/vipi-main.bundle"
  ssh -o BatchMode=yes "$REMOTE_HOST" "
    set -eu
    cd '$REMOTE_REPO'
    [ -z \"\$(git status --porcelain)\" ] || { echo 'Remote repository is not clean' >&2; exit 1; }
    git fetch /tmp/vipi-main.bundle main
    git merge --ff-only FETCH_HEAD
  "
  DEVICE=$(ssh -o BatchMode=yes "$REMOTE_HOST" "
    xcodebuild -project '$REMOTE_REPO/Vipi.xcodeproj' -scheme Vipi -showdestinations 2>/dev/null \
      | sed -n 's/.*platform:iOS, arch:[^,]*, id:\\([^,]*\\),.*/\\1/p' | head -1
  ")
  [ -n "$DEVICE" ] || { echo "MacBook sees the iPhone but Xcode has no physical destination" >&2; exit 1; }
  TARGET_REPO="$REMOTE_REPO"
fi

cat > "$RUNNER_LOCAL" <<EOF
#!/bin/zsh
set -uo pipefail
REPO="$TARGET_REPO"
DEVICE="$DEVICE"
TEAM="$TEAM"
CANONICAL="$CANONICAL_BUNDLE"
LEGACY="$LEGACY_DUPLICATE"
DERIVED="/tmp/vipi-iphone-derived"
LOG="$LOG"
STATUS="$STATUS"
APPS="$APPS"
rm -f "\$STATUS" "\$LOG" "\$APPS"
cd "\$REPO" || { echo repo-missing > "\$STATUS"; exit 1; }
rm -rf "\$DERIVED"
if ! xcodebuild \\
  -project Vipi.xcodeproj \\
  -scheme Vipi \\
  -configuration Debug \\
  -destination "platform=iOS,id=\$DEVICE" \\
  -derivedDataPath "\$DERIVED" \\
  DEVELOPMENT_TEAM="\$TEAM" \\
  CODE_SIGN_STYLE=Automatic \\
  "CODE_SIGN_IDENTITY=Apple Development" \\
  build >"\$LOG" 2>&1; then
  echo build-failed > "\$STATUS"; exit 1
fi
APP="\$DERIVED/Build/Products/Debug-iphoneos/Vipi.app"
BUILT_BUNDLE=\$(plutil -extract CFBundleIdentifier raw "\$APP/Info.plist" 2>/dev/null || true)
if [ "\$BUILT_BUNDLE" != "\$CANONICAL" ]; then
  echo "Refusing bundle ID: \$BUILT_BUNDLE" >>"\$LOG"
  echo wrong-bundle-id > "\$STATUS"; exit 1
fi
if ! xcrun devicectl device install app --device "\$DEVICE" "\$APP" >>"\$LOG" 2>&1; then
  echo install-failed > "\$STATUS"; exit 1
fi
if ! xcrun devicectl device info apps --device "\$DEVICE" >"\$APPS" 2>>"\$LOG"; then
  echo app-verification-failed > "\$STATUS"; exit 1
fi
if ! grep -F "\$CANONICAL" "\$APPS" >/dev/null; then
  echo canonical-app-missing > "\$STATUS"; exit 1
fi
if grep -F "\$LEGACY" "\$APPS" >/dev/null; then
  if ! xcrun devicectl device uninstall app --device "\$DEVICE" "\$LEGACY" >>"\$LOG" 2>&1; then
    echo duplicate-removal-failed > "\$STATUS"; exit 1
  fi
fi
if ! xcrun devicectl device process launch --device "\$DEVICE" --terminate-existing "\$CANONICAL" >>"\$LOG" 2>&1; then
  echo launch-failed > "\$STATUS"; exit 1
fi
sleep 2
if ! xcrun devicectl device info apps --device "\$DEVICE" >"\$APPS" 2>>"\$LOG"; then
  echo final-verification-failed > "\$STATUS"; exit 1
fi
CANONICAL_COUNT=\$(grep -F -c "\$CANONICAL" "\$APPS" || true)
LEGACY_COUNT=\$(grep -F -c "\$LEGACY" "\$APPS" || true)
if [ "\$CANONICAL_COUNT" -ne 1 ] || [ "\$LEGACY_COUNT" -ne 0 ]; then
  echo "canonical=\$CANONICAL_COUNT legacy=\$LEGACY_COUNT" >>"\$LOG"
  echo duplicate-verification-failed > "\$STATUS"; exit 1
fi
echo success > "\$STATUS"
EOF
chmod 700 "$RUNNER_LOCAL"

if [ "$TARGET" = "remote" ]; then
  scp -q "$RUNNER_LOCAL" "$REMOTE_HOST:$RUNNER_REMOTE"
  ssh -o BatchMode=yes "$REMOTE_HOST" "
    chmod 700 '$RUNNER_REMOTE'
    rm -f '$STATUS' '$LOG' '$APPS'
    osascript -e 'tell application \"Terminal\" to do script \"$RUNNER_REMOTE\"'
  " >/dev/null
  run_host="$REMOTE_HOST"
else
  rm -f "$STATUS" "$LOG" "$APPS"
  osascript -e "tell application \"Terminal\" to do script \"$RUNNER_LOCAL\"" >/dev/null
  run_host=""
fi

attempt=0
while [ "$attempt" -lt 180 ]; do
  if [ -n "$run_host" ]; then
    result=$(ssh -o BatchMode=yes "$run_host" "cat '$STATUS' 2>/dev/null || true")
  else
    result=$(cat "$STATUS" 2>/dev/null || true)
  fi
  if [ -n "$result" ]; then
    if [ "$result" = "success" ]; then
      echo "Vipi updated, duplicate-free, and launched on physical iPhone ($DEVICE via $TARGET)."
      exit 0
    fi
    echo "Physical iPhone deployment failed: $result" >&2
    if [ -n "$run_host" ]; then ssh -o BatchMode=yes "$run_host" "tail -120 '$LOG' 2>/dev/null || true" >&2
    else tail -120 "$LOG" >&2 || true
    fi
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 2
done

echo "Timed out waiting for physical iPhone deployment" >&2
exit 1
