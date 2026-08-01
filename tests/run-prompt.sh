#!/bin/bash
#
# Tests for the zsh prompt integration.
#
#   bash tests/run-prompt.sh
#
# Runs the real zsh function against real state files. The prompt reads the same
# file the agent and the app do, so its parsing has to agree with both.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
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

# Evaluate the prompt against a state file written for `offset` seconds from now.
# Passing the literal string NONE means no file at all.
remaining_for() {
  local contents="$1"
  local state="$WORK/state.json"
  rm -f "$state"
  [ "$contents" = "NONE" ] || printf '%s' "$contents" > "$state"

  LICTOR_STATE_FILE="$state" zsh -c "
    source '$ROOT/shell/lictor-prompt.zsh' >/dev/null 2>&1
    _lictor_remaining || echo '<none>'
  " 2>/dev/null
}

state_in() {
  local seconds="$1"
  local expires
  expires="$(TZ=UTC date -r "$(( $(date -u '+%s') + seconds ))" '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"version":1,"expiresAt":"%s","durationSeconds":1800}' "$expires"
}

echo "=== countdown ==="

# One second of slack: the clock can tick between writing and reading
approx() {
  local name="$1" want="$2" alt="$3" got="$4"
  if [ "$got" = "$want" ] || [ "$got" = "$alt" ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        want=[%s] or [%s]\n        got =[%s]\n' "$name" "$want" "$alt" "$got"
  fi
}

approx "30 minutes out renders as mm:ss" "30:00" "29:59" "$(remaining_for "$(state_in 1800)")"
approx "2 hours out renders as h:mm"     "2:00"  "1:59"  "$(remaining_for "$(state_in 7200)")"
approx "8 hours out renders as h:mm"     "8:00"  "7:59"  "$(remaining_for "$(state_in 28800)")"
approx "just under an hour stays mm:ss"  "59:59" "59:58" "$(remaining_for "$(state_in 3599)")"

check "an expired session clamps to 0:00, never negative" \
  "0:00" "$(remaining_for "$(state_in -600)")"

echo
echo "=== absent or unusable state ==="

check "no state file -> no prompt segment" \
  "<none>" "$(remaining_for NONE)"
check "no expiresAt field -> no prompt segment" \
  "<none>" "$(remaining_for '{"version":1,"durationSeconds":1800}')"
check "unparsable timestamp -> no prompt segment" \
  "<none>" "$(remaining_for '{"version":1,"expiresAt":"nonsense"}')"
check "not JSON -> no prompt segment" \
  "<none>" "$(remaining_for 'garbage')"
check "empty file -> no prompt segment" \
  "<none>" "$(remaining_for '')"

echo
echo "=== format compatibility ==="

check "reads fractional seconds, as the app may emit them" \
  "0:00" "$(remaining_for '{"version":1,"expiresAt":"2020-01-01T00:00:00.123Z"}')"
check "reads the pretty-printed form the app writes" \
  "0:00" "$(remaining_for '{
  "durationSeconds" : 1800,
  "enabledAt" : "2020-01-01T00:00:00Z",
  "expiresAt" : "2020-01-01T00:30:00Z",
  "version" : 1
}')"

echo
echo "=== the prompt shares RPROMPT rather than taking it ==="

# _lictor_precmd is the function that assigns RPROMPT, and until now no test
# called it at all -- only _lictor_remaining, which reads the state file and
# assigns nothing.
precmd_rprompt() {
  local existing="$1" contents="$2"
  local state="$WORK/state.json"
  rm -f "$state"
  [ "$contents" = "NONE" ] || printf '%s' "$contents" > "$state"

  LICTOR_STATE_FILE="$state" zsh -c "
    RPROMPT='$existing'
    source '$ROOT/shell/lictor-prompt.zsh' >/dev/null 2>&1
    _lictor_precmd
    print -r -- \"\$RPROMPT\"
  " 2>/dev/null
}

check "an existing right prompt survives an open session" \
  "%F{red}ssh 0:00%f [%~]" "$(precmd_rprompt '[%~]' "$(state_in -60)")"
check "an existing right prompt survives with no session" \
  "[%~]" "$(precmd_rprompt '[%~]' NONE)"
check "with no existing prompt, only our segment appears" \
  "%F{red}ssh 0:00%f" "$(precmd_rprompt '' "$(state_in -60)")"
check "with no existing prompt and no session, nothing is left behind" \
  "" "$(precmd_rprompt '' NONE)"

echo
echo "=== no subprocess spawning of tailscale ==="

# This runs before every prompt. A process spawn per prompt would make the shell
# feel slow enough that the feature gets removed, so assert on the code rather
# than trusting the comment that says so. Comment lines are excluded.
check "the prompt never invokes the tailscale CLI" \
  "0" "$(grep -v '^[[:space:]]*#' "$ROOT/shell/lictor-prompt.zsh" \
         | grep -c 'tailscale' | tr -d ' ')"

echo
echo "────────────────────────────────"
printf '  PASS %d / FAIL %d\n' "$PASS" "$FAIL"
echo "────────────────────────────────"
[ "$FAIL" -eq 0 ]
