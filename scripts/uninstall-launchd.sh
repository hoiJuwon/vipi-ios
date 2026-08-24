#!/bin/sh
set -eu
LABEL="dev.vipi.host"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
printf 'Uninstalled %s (token and logs retained in ~/.pi/agent/vipi).\n' "$LABEL"
