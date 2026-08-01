#!/bin/bash
#
# Table tests for lictor-agent.sh
#
#   bash agent/test-agent.sh
#
# decide() is a pure function, so neither tailscale nor launchd is needed.
# Side effects of do_disable() / main() are covered by test-agent-e2e.sh.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

LICTOR_NO_MAIN=1
export LICTOR_NO_MAIN
# shellcheck disable=SC1090
. "$DIR/lictor-agent.sh"

check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want=%s\n        got =%s\n' "$name" "$want" "$got"
  fi
}

# Reference instant: 2026-08-01T12:00:00Z
NOW="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-08-01T12:00:00Z' '+%s')"

echo "=== decide() ==="

# --- RunSSH == false ---
check "off, no state -> do nothing" \
  "none" "$(decide false "" "$NOW")"
check "off, state present -> drop the state file" \
  "clear-state" "$(decide false "2026-08-01T14:00:00Z" "$NOW")"
check "off, expired state -> drop it (SSH is already closed)" \
  "clear-state" "$(decide false "2026-08-01T10:00:00Z" "$NOW")"

# --- RunSSH == true ---
check "on, within deadline -> do nothing" \
  "none" "$(decide true "2026-08-01T14:00:00Z" "$NOW")"
check "on, past deadline -> disable" \
  "disable:expired" "$(decide true "2026-08-01T11:59:59Z" "$NOW")"
check "on, no state -> disable immediately (ADR-0005)" \
  "disable:no-state" "$(decide true "" "$NOW")"
check "on, unparsable expiresAt -> disable (fail safe)" \
  "disable:bad-state" "$(decide true "not-a-timestamp" "$NOW")"
check "on, empty expiresAt -> treated as missing state" \
  "disable:no-state" "$(decide true "" "$NOW")"

# --- boundaries ---
check "boundary: now == expiresAt counts as expired" \
  "disable:expired" "$(decide true "2026-08-01T12:00:00Z" "$NOW")"
check "boundary: one second left is still valid" \
  "none" "$(decide true "2026-08-01T12:00:01Z" "$NOW")"

# --- RunSSH unreadable ---
check "unknown RunSSH -> error, never disable blindly" \
  "error:unknown-runssh" "$(decide "" "2026-08-01T14:00:00Z" "$NOW")"
check "unexpected RunSSH value -> error" \
  "error:unknown-runssh" "$(decide "yes" "" "$NOW")"

echo
echo "=== iso_to_epoch() ==="
check "parses UTC with trailing Z" \
  "$NOW" "$(iso_to_epoch '2026-08-01T12:00:00Z')"
check "drops fractional seconds" \
  "$NOW" "$(iso_to_epoch '2026-08-01T12:00:00.123456Z')"
check "returns empty for garbage" \
  "" "$(iso_to_epoch 'garbage')"

echo
echo "=== read_expires_at() ==="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE_FILE="$TMP/state.json"

check "missing file -> empty" "" "$(read_expires_at)"

cat > "$STATE_FILE" <<'JSON'
{
  "version": 1,
  "expiresAt": "2026-08-01T14:30:00Z",
  "enabledAt": "2026-08-01T12:30:00Z",
  "durationSeconds": 7200
}
JSON
check "reads expiresAt from pretty-printed JSON" \
  "2026-08-01T14:30:00Z" "$(read_expires_at)"

printf '{"version":1,"expiresAt":"2026-08-01T14:30:00Z","durationSeconds":7200}' > "$STATE_FILE"
check "reads expiresAt from single-line JSON" \
  "2026-08-01T14:30:00Z" "$(read_expires_at)"

printf '{"version":1,"durationSeconds":7200}' > "$STATE_FILE"
check "no expiresAt -> empty" "" "$(read_expires_at)"

printf 'not json at all' > "$STATE_FILE"
check "not JSON -> empty" "" "$(read_expires_at)"

echo
echo "────────────────────────────────"
printf '  PASS %d / FAIL %d\n' "$PASS" "$FAIL"
echo "────────────────────────────────"
[ "$FAIL" -eq 0 ]
