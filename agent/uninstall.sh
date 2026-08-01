#!/bin/bash
#
# Unregister the Lictor enforcement agent
#
#   bash agent/uninstall.sh
#
# Warning: once unregistered nothing enforces the deadline. Verify that RunSSH
# is not left enabled.

set -eu

LABEL="com.h1d3mun3.lictor.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "Uninstalled: $LABEL"
echo
echo "Current RunSSH:"
tailscale debug prefs 2>/dev/null | grep RunSSH || echo "  (could not read)"
echo
echo "If it is still true, close it manually:  tailscale set --ssh=false"
