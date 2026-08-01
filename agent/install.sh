#!/bin/bash
#
# Register the Lictor enforcement agent as a LaunchAgent
#
#   bash agent/install.sh
#
# The generated plist points at this repository by absolute path.
# Re-run it if the repository is moved.

set -eu

LABEL="com.h1d3mun3.lictor.agent"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/lictor-agent.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.local/state/lictor"
UID_NUM="$(id -u)"

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found" >&2; exit 1; }

# Embed the absolute path to tailscale: launchd provides a minimal PATH that
# does not normally include Homebrew.
TS_BIN=""
for c in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale "$(command -v tailscale 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && TS_BIN="$c" && break
done
[ -n "$TS_BIN" ] || { echo "FATAL: tailscale not found" >&2; exit 1; }

mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"
chmod 700 "$STATE_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$SCRIPT</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>LICTOR_TAILSCALE</key>
		<string>$TS_BIN</string>
	</dict>
	<key>StartInterval</key>
	<integer>60</integer>
	<!-- RunAtLoad is required. RunSSH persists across reboots, but the deadline
	     tracking dies with the process, so it must be evaluated once at login. -->
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$STATE_DIR/agent.out.log</string>
	<key>StandardErrorPath</key>
	<string>$STATE_DIR/agent.err.log</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "Installed: $LABEL"
echo "  script    : $SCRIPT"
echo "  tailscale : $TS_BIN"
echo "  plist     : $PLIST"
echo "  log       : $STATE_DIR/agent.log"
echo
echo "Inspect with:"
echo "  launchctl print gui/$UID_NUM/$LABEL | head -20"
echo "  tail -f $STATE_DIR/agent.log"
