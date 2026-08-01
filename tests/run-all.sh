#!/bin/bash
#
# Run every check in the repository.
#
#   bash tests/run-all.sh
#
# None of these touch the real tailscaled, launchd, or the live state file.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

run_suite() {
  local name="$1"; shift
  printf '\n══ %s ══\n' "$name"
  if "$@"; then
    printf '   -> ok\n'
  else
    printf '   -> FAILED\n'
    FAILED=$((FAILED + 1))
  fi
}

run_suite "agent: decide() table tests"   bash "$ROOT/agent/test-agent.sh"
run_suite "agent: side effects"           bash "$ROOT/agent/test-agent-e2e.sh"
run_suite "app: unit tests"               bash "$ROOT/tests/run-unit.sh"
run_suite "app: unix socket client"       bash "$ROOT/tests/run-socket.sh"
run_suite "app+agent: state file interop" bash "$ROOT/tests/run-interop.sh"
run_suite "shell: zsh prompt"             bash "$ROOT/tests/run-prompt.sh"
run_suite "repo: language rule"           bash "$ROOT/tests/check-language.sh"

printf '\n════════════════════════════════\n'
if [ "$FAILED" -eq 0 ]; then
  printf '  all suites passed\n'
else
  printf '  %d suite(s) FAILED\n' "$FAILED"
fi
printf '════════════════════════════════\n'
[ "$FAILED" -eq 0 ]
