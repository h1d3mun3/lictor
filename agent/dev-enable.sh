#!/bin/bash
#
# [DEVELOPMENT ONLY] Enable Tailscale SSH with a deadline
#
#   bash agent/dev-enable.sh <minutes>
#   e.g. bash agent/dev-enable.sh 2   -> the agent closes it two minutes later
#
# The menu bar app is how this is normally done. This exists to exercise the
# agent without the app: enabling from a terminal, then watching the deadline get
# enforced, is the fastest way to confirm the enforcement path still works.
#
# There is no Touch ID here. **This is a development tool, not part of the product.**
# The duration argument is still mandatory (principle 4: never
# create an "enabled indefinitely" path).
#
# The state.json format and the write ordering below are the reference
# implementation that the Swift side must follow.

set -eu

MINUTES="${1:-}"
case "$MINUTES" in
  ''|*[!0-9]*) echo "usage: bash agent/dev-enable.sh <minutes>" >&2; exit 1 ;;
esac
[ "$MINUTES" -gt 0 ] || { echo "minutes must be 1 or greater" >&2; exit 1; }

STATE_DIR="${LICTOR_STATE_DIR:-$HOME/.local/state/lictor}"
STATE_FILE="$STATE_DIR/state.json"
TAILSCALE="${LICTOR_TAILSCALE:-/opt/homebrew/bin/tailscale}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

NOW_EPOCH="$(date -u '+%s')"
EXP_EPOCH=$((NOW_EPOCH + MINUTES * 60))
ENABLED_AT="$(TZ=UTC date -r "$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
EXPIRES_AT="$(TZ=UTC date -r "$EXP_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"

# --- ordering matters ---------------------------------------------------------
# Write state.json first, then enable SSH.
#
# The reverse order creates a window where RunSSH is true with no state.json.
# If an agent tick lands in that window, ADR-0005 closes SSH immediately.
#
# With this order the transient state is "RunSSH=false with a state.json",
# which the agent merely cleans up (decide -> clear-state). Harmless.
# Never open a window on the dangerous side.
# ------------------------------------------------------------------------------

TMP="$(mktemp "$STATE_DIR/.state.XXXXXX")"
cat > "$TMP" <<JSON
{
  "version": 1,
  "expiresAt": "$EXPIRES_AT",
  "enabledAt": "$ENABLED_AT",
  "durationSeconds": $((MINUTES * 60))
}
JSON
chmod 600 "$TMP"
mv -f "$TMP" "$STATE_FILE"          # atomic rename

if ! "$TAILSCALE" set --ssh=true; then
  rm -f "$STATE_FILE"               # do not leave state behind on failure
  echo "FATAL: tailscale set --ssh=true failed" >&2
  exit 1
fi

echo "Tailscale SSH enabled"
echo "  enabled at : $ENABLED_AT (UTC)"
echo "  expires at : $EXPIRES_AT (UTC)  -- in $MINUTES minute(s)"
echo "  state file : $STATE_FILE"
echo
echo "Agent log:  tail -f $STATE_DIR/agent.log"
