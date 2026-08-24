#!/bin/sh
set -eu
UDID=${VIPI_SIMULATOR_UDID:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for values in d.values() for x in values if x["state"] == "Booted"))')}
DESTINATION="platform=iOS Simulator,id=$UDID"
OUT=${VIPI_ACCESSIBILITY_OUTPUT:-"${TMPDIR:-/tmp}/vipi-accessibility"}
mkdir -p "$OUT"

set_pref() { xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility "$1" -bool "$2"; }
run_case() {
  name=$1
  xcrun simctl launch --terminate-running-process "$UDID" dev.vipi.ios >/dev/null
  sleep 1
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null
  xcodebuild -project Vipi.xcodeproj -scheme Vipi -destination "$DESTINATION" test-without-building \
    -only-testing:VipiUITests/VipiUITests/testPairingAndConnectionControlsAreAccessible >"$OUT/$name.log" 2>&1
  printf '%s: PASS\n' "$name" | tee -a "$OUT/results.txt"
}
reset() {
  xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1 || true
  xcrun simctl ui "$UDID" increase_contrast disabled >/dev/null 2>&1 || true
  xcrun simctl ui "$UDID" content_size large >/dev/null 2>&1 || true
  set_pref ReduceMotionEnabled false >/dev/null 2>&1 || true
  set_pref ReduceTransparencyEnabled false >/dev/null 2>&1 || true
  set_pref VoiceOverTouchEnabled false >/dev/null 2>&1 || true
}
trap reset EXIT INT TERM
: > "$OUT/results.txt"
xcodebuild -project Vipi.xcodeproj -scheme Vipi -destination "$DESTINATION" build-for-testing >"$OUT/build.log" 2>&1

xcrun simctl ui "$UDID" appearance light; run_case light
xcrun simctl ui "$UDID" appearance dark; run_case dark
xcrun simctl ui "$UDID" increase_contrast enabled; run_case increase-contrast
xcrun simctl ui "$UDID" increase_contrast disabled
xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large; run_case dynamic-type-xxxl
xcrun simctl ui "$UDID" content_size large
set_pref ReduceMotionEnabled true; run_case reduce-motion
set_pref ReduceMotionEnabled false
set_pref ReduceTransparencyEnabled true; run_case reduce-transparency
set_pref ReduceTransparencyEnabled false
set_pref VoiceOverTouchEnabled true; run_case voiceover
cat "$OUT/results.txt"
