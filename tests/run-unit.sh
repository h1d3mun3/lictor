#!/bin/bash
#
# Swift unit tests for the app, via the Xcode test target.
#
#   bash tests/run-unit.sh
#
# Covers the pure logic in lictor/Core. The cross-language suites live
# elsewhere: run-socket.sh drives a real unix socket server, and run-interop.sh
# hands a file written here to the bash agent. Neither is expressible as a unit
# test of Swift code alone, which is why both stay outside Xcode.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

xcodebuild \
  -project "$ROOT/lictor.xcodeproj" \
  -scheme lictor \
  -destination "platform=macOS,arch=$(uname -m)" \
  test > "$LOG" 2>&1
rc=$?

# Suite-level results are enough for a summary; individual cases stay in the log
grep -E 'Suite .* (passed|failed)|Test run with' "$LOG" | sed 's/^/  /'

if [ "$rc" -ne 0 ]; then
  echo
  echo "  --- failures ---"
  grep -E "$(printf '✘')|error:" "$LOG" | sed 's/^/  /' | head -40
fi

exit "$rc"
