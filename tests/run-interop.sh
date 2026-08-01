#!/bin/bash
#
# Interoperability between the Swift app and the bash agent.
#
#   bash tests/run-interop.sh
#
# The app writes state.json; the agent reads it with grep and decides whether to
# close SSH. Nothing in either language checks the other, so a change to the
# serialisation could silently disable enforcement while every other suite still
# passes. This suite is the thing that would catch that.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/interop-writer"
STATE_DIR="$WORK/state"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        want=[%s]\n        got =[%s]\n' "$name" "$want" "$got"
  fi
}

swiftc -o "$BIN" \
  "$ROOT/lictor/Core/Models.swift" \
  "$ROOT/lictor/Services/StateFileStore.swift" \
  "$ROOT/tests/interop/main.swift" || exit 1

mkdir -p "$STATE_DIR"

# Load the agent's functions without running it
LICTOR_NO_MAIN=1
LICTOR_STATE_DIR="$STATE_DIR"
export LICTOR_NO_MAIN LICTOR_STATE_DIR
# shellcheck disable=SC1090
. "$ROOT/agent/lictor-agent.sh"

echo "=== the app writes, the agent reads ==="

# Reference instant: 2026-08-01T12:00:00Z
NOW="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-08-01T12:00:00Z' '+%s')"

for duration in 1800 7200 28800; do
  WRITTEN="$("$BIN" "$STATE_DIR" "$duration" "$NOW")"
  PARSED="$(read_expires_at)"
  check "duration=${duration}s: the agent parses the expiresAt the app wrote" \
    "$WRITTEN" "$PARSED"

  EXPECTED_EPOCH=$((NOW + duration))
  check "duration=${duration}s: both sides agree on the instant" \
    "$EXPECTED_EPOCH" "$(iso_to_epoch "$PARSED")"
done

echo
echo "=== the agent's verdict on app-written state ==="

"$BIN" "$STATE_DIR" 1800 "$NOW" > /dev/null
check "within the deadline -> leave it alone" \
  "none" "$(decide true "$(read_expires_at)" "$NOW")"
check "one second past the deadline -> disable" \
  "disable:expired" "$(decide true "$(read_expires_at)" "$((NOW + 1801))")"
check "exactly at the deadline -> disable" \
  "disable:expired" "$(decide true "$(read_expires_at)" "$((NOW + 1800))")"
check "SSH already off -> just drop the file" \
  "clear-state" "$(decide false "$(read_expires_at)" "$NOW")"

echo
echo "=== file properties ==="

check "written with mode 0600" \
  "600" "$(stat -f '%OLp' "$STATE_DIR/state.json")"
check "the state directory is 0700" \
  "700" "$(stat -f '%OLp' "$STATE_DIR")"
check "valid JSON" \
  "ok" "$(python3 -c "import json;json.load(open('$STATE_DIR/state.json'));print('ok')" 2>&1)"
check "records the version" \
  "1" "$(python3 -c "import json;print(json.load(open('$STATE_DIR/state.json'))['version'])")"
check "records durationSeconds" \
  "1800" "$(python3 -c "import json;print(json.load(open('$STATE_DIR/state.json'))['durationSeconds'])")"
check "expiresAt is on a single line, as the agent's grep assumes" \
  "1" "$(grep -c '"expiresAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_DIR/state.json" | tr -d ' ')"

echo
echo "=== the agent's own writer stays compatible ==="

# dev-enable.sh is the reference implementation the Swift side had to match.
# Compare the key set the two produce.
rm -f "$STATE_DIR/state.json"
APP_KEYS="$("$BIN" "$STATE_DIR" 1800 "$NOW" > /dev/null; python3 -c "
import json; print(','.join(sorted(json.load(open('$STATE_DIR/state.json')))))")"
check "the app writes exactly the documented field set" \
  "durationSeconds,enabledAt,expiresAt,version" "$APP_KEYS"

echo
echo "────────────────────────────────"
printf '  PASS %d / FAIL %d\n' "$PASS" "$FAIL"
echo "────────────────────────────────"
[ "$FAIL" -eq 0 ]
