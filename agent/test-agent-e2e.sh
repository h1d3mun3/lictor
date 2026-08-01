#!/bin/bash
#
# Side-effect tests for lictor-agent.sh
#
#   bash agent/test-agent-e2e.sh
#
# Uses fake tailscale / osascript binaries to observe what main() actually
# invokes and mutates. Touches neither the real tailscaled nor launchd.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1)); printf '    ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '    FAIL  %s\n          want=[%s]\n          got =[%s]\n' "$name" "$want" "$got"
  fi
}

# --- stubs -------------------------------------------------------------------
mkdir -p "$ROOT/bin"

cat > "$ROOT/bin/tailscale" <<'STUB'
#!/bin/bash
# Record every invocation before responding
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1 $2" in
  "debug prefs")
    [ "${STUB_PREFS_FAIL:-0}" = "1" ] && exit 1
    printf '{"RunSSH": %s, "OperatorUser": "tester"}\n' "$(cat "$STUB_RUNSSH")"
    ;;
  "set --ssh=false")
    [ "${STUB_SET_FAIL:-0}" = "1" ] && { echo "stub: set failed" >&2; exit 1; }
    [ "${STUB_SET_NOOP:-0}" = "1" ] || echo false > "$STUB_RUNSSH"
    ;;
  *) echo "stub: unexpected: $*" >&2; exit 2 ;;
esac
STUB

cat > "$ROOT/bin/osascript" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_NOTIFY"
STUB

chmod +x "$ROOT/bin/tailscale" "$ROOT/bin/osascript"

# --- run a single case -------------------------------------------------------
# run_case <name> <initial RunSSH> <state.json contents|NONE>
run_case() {
  CASE_DIR="$ROOT/case-$1"
  mkdir -p "$CASE_DIR"
  export STUB_RUNSSH="$CASE_DIR/runssh"
  export STUB_CALLS="$CASE_DIR/calls"
  export STUB_NOTIFY="$CASE_DIR/notify"
  export LICTOR_STATE_DIR="$CASE_DIR/state"
  export LICTOR_TAILSCALE="$ROOT/bin/tailscale"
  export LICTOR_OSASCRIPT="$ROOT/bin/osascript"

  mkdir -p "$LICTOR_STATE_DIR"
  echo "$2" > "$STUB_RUNSSH"
  : > "$STUB_CALLS"
  : > "$STUB_NOTIFY"

  if [ "$3" != "NONE" ]; then
    printf '%s' "$3" > "$LICTOR_STATE_DIR/state.json"
  fi

  printf '\n  [%s]\n' "$1"
  bash "$DIR/lictor-agent.sh" >/dev/null 2>&1
}

state_exists() { [ -f "$LICTOR_STATE_DIR/state.json" ] && echo yes || echo no; }
set_calls()    { grep -c 'set --ssh' "$STUB_CALLS" 2>/dev/null | tr -d ' '; }
notify_count() { grep -c 'display notification' "$STUB_NOTIFY" 2>/dev/null | tr -d ' '; }

PAST='{"version":1,"expiresAt":"2020-01-01T00:00:00Z","durationSeconds":1800}'
FUTURE='{"version":1,"expiresAt":"2099-01-01T00:00:00Z","durationSeconds":1800}'

echo "=== main() side effects ==="

run_case expired true "$PAST"
check "expired -> calls tailscale set once" "1" "$(set_calls)"
check "expired -> RunSSH becomes false"     "false" "$(cat "$STUB_RUNSSH")"
check "expired -> removes state.json"       "no" "$(state_exists)"
check "expired -> notifies once"            "1" "$(notify_count)"

run_case within true "$FUTURE"
check "within deadline -> no set call"      "0" "$(set_calls)"
check "within deadline -> RunSSH stays true" "true" "$(cat "$STUB_RUNSSH")"
check "within deadline -> keeps state.json" "yes" "$(state_exists)"
check "within deadline -> no notification"  "0" "$(notify_count)"

run_case nostate true NONE
check "on without state -> disables (ADR-0005)"  "1" "$(set_calls)"
check "on without state -> RunSSH=false"    "false" "$(cat "$STUB_RUNSSH")"
check "on without state -> notifies"        "1" "$(notify_count)"

run_case offwithstate false "$FUTURE"
check "off with leftover state -> no set call" "0" "$(set_calls)"
check "off with leftover state -> drops state" "no" "$(state_exists)"
check "off with leftover state -> no notification" "0" "$(notify_count)"

run_case offclean false NONE
check "off and clean -> does nothing"    "0" "$(set_calls)"
check "off and clean -> no notification" "0" "$(notify_count)"

echo
echo "=== failure paths ==="

STUB_PREFS_FAIL=1 run_case daemondown true "$PAST"
check "tailscaled down -> no set call (never guess)" "0" "$(set_calls)"
check "tailscaled down -> keeps state.json"          "yes" "$(state_exists)"
check "tailscaled down -> notifies"                  "1" "$(notify_count)"
unset STUB_PREFS_FAIL

STUB_SET_FAIL=1 run_case setfails true "$PAST"
check "set fails -> keeps state.json for the next retry" "yes" "$(state_exists)"
check "set fails -> notifies the failure"                "1" "$(notify_count)"
unset STUB_SET_FAIL

STUB_SET_NOOP=1 run_case setlies true "$PAST"
check "set succeeds but RunSSH unchanged -> keeps state" "yes" "$(state_exists)"
check "set succeeds but RunSSH unchanged -> notifies"    "1" "$(notify_count)"
unset STUB_SET_NOOP

run_case badstate true '{"version":1,"expiresAt":"nonsense"}'
check "corrupt expiresAt -> disables (fail safe)" "1" "$(set_calls)"
check "corrupt expiresAt -> RunSSH=false"         "false" "$(cat "$STUB_RUNSSH")"

echo
echo "=== principle 2: only ever moves toward OFF ==="

ALL_CALLS="$(cat "$ROOT"/case-*/calls 2>/dev/null)"
check "never invoked --ssh=true in any case" \
  "0" "$(printf '%s\n' "$ALL_CALLS" | grep -c -- '--ssh=true' | tr -d ' ')"
check "the only write performed is --ssh=false" \
  "0" "$(printf '%s\n' "$ALL_CALLS" | grep -- 'set ' | grep -vc -- '--ssh=false' | tr -d ' ')"

echo
echo "=== notification suppression ==="

run_case repeat true NONE
FIRST="$(notify_count)"
echo true > "$STUB_RUNSSH"          # re-enabled with no healthy tick in between
bash "$DIR/lictor-agent.sh" >/dev/null 2>&1
check "same reason does not fire every 60 seconds" "$FIRST" "$(notify_count)"

# One healthy tick releases the suppression
echo false > "$STUB_RUNSSH"
bash "$DIR/lictor-agent.sh" >/dev/null 2>&1   # action=none -> marker cleared
echo true  > "$STUB_RUNSSH"
bash "$DIR/lictor-agent.sh" >/dev/null 2>&1   # detected again -> should notify
check "notifies again after a healthy tick" "2" "$(notify_count)"

echo
echo "────────────────────────────────"
printf '  PASS %d / FAIL %d\n' "$PASS" "$FAIL"
echo "────────────────────────────────"
[ "$FAIL" -eq 0 ]
