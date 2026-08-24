#!/bin/sh
set -eu

LABEL="dev.vipi.host"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NODE=$(command -v node)
NPM=$(command -v npm)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.pi/agent/vipi"

mkdir -p "$HOME/Library/LaunchAgents" "$STATE"
chmod 700 "$STATE"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$NPM</string><string>run</string><string>host</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>VIPI_HOST</key><string>127.0.0.1</string>
    <key>VIPI_PORT</key><string>8765</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$STATE/host.log</string>
  <key>StandardErrorPath</key><string>$STATE/host-error.log</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
EOF
chmod 600 "$PLIST"
plutil -lint "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
printf 'Installed %s. Publish privately with: tailscale serve --bg http://127.0.0.1:8765\n' "$LABEL"
