#!/bin/bash
# Run UnixSocketHTTP / TailscaleLocalAPI against a fake LocalAPI server
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep the socket path short: AF_UNIX caps it at 104 bytes
SOCK_DIR="${TMPDIR:-/tmp}/lictor-sock-test"
SOCK="$SOCK_DIR/ts.sock"
BIN="$(mktemp -d)/socket-tests"

cleanup() { kill "${SERVER_PID:-0}" 2>/dev/null || true; rm -rf "$SOCK_DIR" "$(dirname "$BIN")"; }
trap cleanup EXIT

swiftc -o "$BIN" \
  "$ROOT/lictor/Core/Models.swift" \
  "$ROOT/lictor/Services/UnixSocketHTTP.swift" \
  "$ROOT/lictor/Services/TailscaleLocalAPI.swift" \
  "$ROOT/tests/socket/main.swift"

# Connections served: happy path + 404 + wrong Host + snapshot(prefs, status) = 5
python3 "$ROOT/tests/socket/server.py" "$SOCK_DIR" 5 > "$SOCK_DIR.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
[ -S "$SOCK" ] || { echo "FATAL: server did not start"; cat "$SOCK_DIR.log"; exit 1; }

"$BIN" "$SOCK"
rc=$?

# Three more servers, one per framing, plus one that hangs up mid-handshake.
# tests/socket/server.py only ever sent Content-Length before, so nothing here
# could fail on framing no matter how the client was written.
for mode in chunked eof slam; do
  echo
  # Both of these report the failure they were asked to cause, so neither may
  # be allowed to trip set -e.
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$SOCK_DIR"
  python3 "$ROOT/tests/socket/server.py" "$SOCK_DIR" 4 "$mode" > "$SOCK_DIR.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
  "$BIN" "$SOCK" "$mode" || rc=1
done
echo
echo "--- requests seen by the server ---"
grep '^REQ' "$SOCK_DIR.log" || true
exit $rc
