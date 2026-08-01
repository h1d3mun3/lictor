#!/bin/bash
#
# Lictor -- assumption verification
#
#   Where: a **local Terminal on the M1 Max host** (not over Tailscale SSH)
#   How:   bash verify/m0-verify.sh
#
# Run once, before any of this was built, to establish what the LocalAPI actually
# does. Its findings are written up in docs/localapi.md. Re-run it after a
# Tailscale upgrade to check the measurements still hold.
#
# What it checks:
#   S-1  can prefs be written without sudo under --operator  (toggles SSH temporarily)
#   S-2  the LocalAPI unix socket path and non-root reachability
#   S-3  whether active SSH sessions are observable locally
#
# Side effects:
#   S-1 and S-2b flip RunSSH temporarily. The original value is restored on exit,
#   including on Ctrl-C. Any in-flight Tailscale SSH session may be dropped, so
#   always run this from a local Terminal.
#
# Output:
#   verify/results/m0-report.md   full report including every command's output
#   verify/results/*.json         raw LocalAPI responses
#   Note: results/ contains this node's public keys and IPs, so it is gitignored.

set -u

# Survive a dying terminal so RunSSH always gets restored
trap '' HUP PIPE

# Seconds to watch daemon-logs during S-3 (shortened by the test harness)
DAEMON_LOG_SECS="${LICTOR_DAEMON_LOG_SECS:-25}"

# Once S-1 has passed, --skip-s1 avoids flipping RunSSH for it again
SKIP_S1=0
RUN_YES=0
for a in "$@"; do
  case "$a" in
    --skip-s1) SKIP_S1=1 ;;
    --yes)     RUN_YES=1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/results"
REPORT="$OUT_DIR/m0-report.md"

mkdir -p "$OUT_DIR"
# Never commit raw status/prefs. The `!.gitignore` line matters: without it the
# rule file excludes itself and the protection never reaches the repository.
printf '*\n!.gitignore\n' > "$OUT_DIR/.gitignore"

: > "$REPORT"

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------- helpers ---
#
# Note: this helper is named rep(), not log(), because a shell function named
# `log` would shadow /usr/bin/log and break the unified-log check in S-3.

rep()  { printf '%s\n' "$*" >> "$REPORT"; }
note() { printf '%s\n' "$*" >> "$REPORT"; printf '%s\n' "$*"; }
head2(){ printf '\n## %s\n' "$*" >> "$REPORT"; printf '\n=== %s ===\n' "$*"; }
head3(){ printf '\n### %s\n' "$*" >> "$REPORT"; }

LAST_OUT=""
LAST_RC=0

# run "heading" cmd args...   -- record output and exit code in the report
run() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  head3 "$label"
  {
    printf '```console\n$ %s\n' "$*"
    printf '%s\n' "$out"
    printf '[exit=%d]\n```\n' "$rc"
  } >> "$REPORT"
  printf '  [exit=%-3d] %s\n' "$rc" "$label"
  LAST_OUT="$out"; LAST_RC=$rc
  return $rc
}

# runsh "heading" 'shell expression'  -- for anything needing pipes
runsh() {
  local label="$1" cmd="$2"
  local out rc
  out="$(eval "$cmd" 2>&1)"; rc=$?
  head3 "$label"
  {
    printf '```console\n$ %s\n' "$cmd"
    printf '%s\n' "$out"
    printf '[exit=%d]\n```\n' "$rc"
  } >> "$REPORT"
  printf '  [exit=%-3d] %s\n' "$rc" "$label"
  LAST_OUT="$out"; LAST_RC=$rc
  return $rc
}

# ------------------------------------------------------------ prerequisites ---

TS_BIN="$(command -v tailscale || true)"
if [ -z "$TS_BIN" ]; then
  for c in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
    [ -x "$c" ] && TS_BIN="$c" && break
  done
fi
if [ -z "$TS_BIN" ]; then
  echo "FATAL: tailscale not found. Are you running this on the host?" >&2
  exit 1
fi

rep "# Lictor assumption verification report"
rep ""
rep "- run at (UTC): \`$TS\`"
rep "- host: \`$(hostname)\`"
rep "- user: \`$(id -un)\` (uid=$(id -u))"
rep "- tailscale binary: \`$TS_BIN\`"

# Extract RunSSH from prefs without depending on jq
get_runssh() {
  "$TS_BIN" debug prefs 2>/dev/null \
    | tr -d ' \t' \
    | grep -o '"RunSSH":[a-z]*' \
    | head -1 \
    | cut -d: -f2
}

ORIG_RUNSSH=""
RESTORE_NEEDED=0

RESTORE_DONE=0
restore_runssh() {
  [ "$RESTORE_DONE" -eq 0 ] || return 0
  RESTORE_DONE=1
  [ "$RESTORE_NEEDED" -eq 1 ] || return 0
  [ -n "$ORIG_RUNSSH" ] || return 0
  local now
  now="$(get_runssh)"
  if [ "$now" != "$ORIG_RUNSSH" ]; then
    printf '\n[restore] putting RunSSH back to %s...\n' "$ORIG_RUNSSH"
    "$TS_BIN" set --ssh="$ORIG_RUNSSH" >/dev/null 2>&1 \
      || sudo "$TS_BIN" set --ssh="$ORIG_RUNSSH" >/dev/null 2>&1
    now="$(get_runssh)"
  fi
  printf '[restore] final RunSSH = %s (original = %s)\n' "$now" "$ORIG_RUNSSH"
  {
    printf '\n## Restore on exit\n\n'
    printf -- '- original RunSSH: `%s`\n' "$ORIG_RUNSSH"
    printf -- '- final RunSSH: `%s`\n' "$now"
    if [ "$now" != "$ORIG_RUNSSH" ]; then
      printf -- '- **WARNING: restore failed. Run `tailscale set --ssh=%s` manually.**\n' "$ORIG_RUNSSH"
    fi
  } >> "$REPORT"
}
trap restore_runssh EXIT
trap 'echo; echo "[interrupted] restoring..."; restore_runssh; exit 130' INT TERM

# --------------------------------------------------------------- preflight ---

head2 "Preflight -- environment"

run "macOS version"           sw_vers
run "tailscale version"       "$TS_BIN" version
run "tailscale status"        "$TS_BIN" status
runsh "brew services (tailscale)" "command -v brew >/dev/null && brew services list | grep -i tailscale || echo 'no brew / no match'"
runsh "tailscaled process"    "ps aux | grep -i '[t]ailscaled'"

# Raw JSON goes to separate files to keep the report readable
"$TS_BIN" status --json    > "$OUT_DIR/status-initial.json"    2>&1
"$TS_BIN" debug prefs      > "$OUT_DIR/prefs-initial.json"     2>&1
rep ""
rep "Raw JSON saved to \`results/status-initial.json\` and \`results/prefs-initial.json\`."

ORIG_RUNSSH="$(get_runssh)"
rep ""
rep "**RunSSH at start = \`${ORIG_RUNSSH:-unreadable}\`**"
note ""
note "RunSSH at start = ${ORIG_RUNSSH:-unreadable}"

if [ -z "$ORIG_RUNSSH" ]; then
  note "FATAL: cannot read RunSSH from tailscale debug prefs. Is tailscaled running?"
  rep ""
  rep "> **Aborted**: RunSSH unreadable, S-1 skipped."
  exit 1
fi

# ------------------------------------------------------------ confirmation ---

cat <<EOF

────────────────────────────────────────────────────────────
 S-1 is about to toggle Tailscale SSH temporarily.

   current RunSSH : $ORIG_RUNSSH
   sequence       : $ORIG_RUNSSH -> $([ "$ORIG_RUNSSH" = "true" ] && echo false || echo true) -> $ORIG_RUNSSH (restored)

 Any in-flight Tailscale SSH session may be dropped.
 Run this from a local Terminal on the host.
────────────────────────────────────────────────────────────

EOF

if [ "$RUN_YES" -ne 1 ]; then
  printf 'Continue? [y/N]: '
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# --------------------------------------------------------------------- S-1 ---

head2 "S-1 -- can prefs be written without sudo under --operator [critical]"

rep ""
rep "The direction that actually changes the value is tried first; a no-op that"
rep "succeeds would prove nothing."
rep ""

FLIP="$([ "$ORIG_RUNSSH" = "true" ] && echo false || echo true)"
RESTORE_NEEDED=1

if [ "$SKIP_S1" -eq 1 ]; then

S1_VERDICT="SKIPPED (--skip-s1; already verified in an earlier run)"
rep ""
rep "> \`--skip-s1\` was passed, so S-1 did not run."

else

# --- first: the direction that really changes the value ---
run "without sudo: tailscale set --ssh=$FLIP" "$TS_BIN" set --ssh="$FLIP"
S1_RC_A=$LAST_RC
S1_AFTER_A="$(get_runssh)"
rep ""
rep "-> RunSSH after write = \`${S1_AFTER_A:-unreadable}\` (expected: \`$FLIP\`)"
note "  -> RunSSH = ${S1_AFTER_A:-?} (expected ${FLIP})"

# --- second: back to the original ---
run "without sudo: tailscale set --ssh=$ORIG_RUNSSH" "$TS_BIN" set --ssh="$ORIG_RUNSSH"
S1_RC_B=$LAST_RC
S1_AFTER_B="$(get_runssh)"
rep ""
rep "-> RunSSH after write = \`${S1_AFTER_B:-unreadable}\` (expected: \`$ORIG_RUNSSH\`)"
note "  -> RunSSH = ${S1_AFTER_B:-?} (expected ${ORIG_RUNSSH})"

if [ "$S1_AFTER_A" = "$FLIP" ] && [ "$S1_AFTER_B" = "$ORIG_RUNSSH" ] \
   && [ "$S1_RC_A" -eq 0 ] && [ "$S1_RC_B" -eq 0 ]; then
  S1_VERDICT="PASS -- RunSSH written in both directions without sudo"
else
  S1_VERDICT="FAIL -- cannot write without sudo (a privileged helper may be required; ask a human)"
  # Retry with sudo to confirm the failure really is about permissions
  run "(diagnostic) with sudo: tailscale set --ssh=$FLIP" sudo -n "$TS_BIN" set --ssh="$FLIP"
  S1_SUDO_AFTER="$(get_runssh)"
  rep ""
  rep "-> RunSSH after sudo write = \`${S1_SUDO_AFTER:-unreadable}\`"
  run "(diagnostic) with sudo: tailscale set --ssh=$ORIG_RUNSSH" sudo -n "$TS_BIN" set --ssh="$ORIG_RUNSSH"
fi

fi   # SKIP_S1

rep ""
rep "**S-1 verdict: $S1_VERDICT**"
note ""
note "S-1 verdict: $S1_VERDICT"

# --------------------------------------------------------------------- S-2 ---

head2 "S-2 -- LocalAPI socket path and reachability"

runsh "socket candidates" \
  "ls -la /var/run/tailscaled.socket /opt/homebrew/var/run/tailscaled.socket /usr/local/var/run/tailscaled.socket 2>&1"

runsh "lsof -U (sudo; enter your password if prompted)" \
  "sudo lsof -U 2>/dev/null | grep -i tailscale || echo 'no match / sudo unavailable'"

# Pick whichever socket actually exists
SOCK=""
for c in /var/run/tailscaled.socket /opt/homebrew/var/run/tailscaled.socket /usr/local/var/run/tailscaled.socket; do
  [ -S "$c" ] && SOCK="$c" && break
done

if [ -z "$SOCK" ]; then
  rep ""
  rep "> **No socket found at the known paths.** Identify the real path from the lsof output above."
  note "  no socket found (see lsof output)"
else
  rep ""
  rep "**Socket in use: \`$SOCK\`**"
  note "  socket: $SOCK"
  runsh "socket permissions" "ls -la '$SOCK'"

  # --- Host header and privilege matrix ---
  # curl derives Host from the URL, so http://local-tailscaled.sock/... is correct
  head3 "LocalAPI reachability matrix"
  {
    printf '```console\n'
    # "description@@command"; @@ never occurs inside the commands
    CODE="-sS -o /dev/null -w '%{http_code}'"
    for desc_cmd in \
      "non-root / correct Host@@curl $CODE --unix-socket $SOCK http://local-tailscaled.sock/localapi/v0/prefs" \
      "non-root / wrong Host@@curl $CODE --unix-socket $SOCK http://example.com/localapi/v0/prefs" \
      "non-root / Host removed@@curl $CODE -H 'Host:' --unix-socket $SOCK http://local-tailscaled.sock/localapi/v0/prefs" \
      "non-root / with Sec-Tailscale@@curl $CODE -H 'Sec-Tailscale: localapi' --unix-socket $SOCK http://local-tailscaled.sock/localapi/v0/prefs" \
      "root (sudo)@@sudo -n curl $CODE --unix-socket $SOCK http://local-tailscaled.sock/localapi/v0/prefs" \
    ; do
      d="${desc_cmd%%@@*}"; c="${desc_cmd#*@@}"
      printf '\n[%s]\n$ %s\n' "$d" "$c"
      eval "$c" 2>&1
      printf '  (exit=%d)\n' $?
    done
    printf '```\n'
  } >> "$REPORT"

  # --- Save raw endpoint responses ---
  LA="curl -sS --unix-socket $SOCK http://local-tailscaled.sock/localapi/v0"
  eval "$LA/prefs"  > "$OUT_DIR/localapi-prefs.json"  2>&1
  eval "$LA/status" > "$OUT_DIR/localapi-status.json" 2>&1
  rep ""
  rep "Raw LocalAPI responses saved to \`results/localapi-prefs.json\` and \`results/localapi-status.json\`."
  runsh "head of localapi/v0/prefs" "head -c 1200 '$OUT_DIR/localapi-prefs.json'"

  # --- S-2b: can we write through the LocalAPI instead of the CLI? ---
  head3 "S-2b -- writing RunSSH through the LocalAPI (PATCH /localapi/v0/prefs)"
  rep ""
  rep "If this works, the app could avoid spawning the CLI via \`Process\` entirely."
  {
    printf '```console\n'
    printf '$ curl -sS -X PATCH -d {"RunSSHSet":true,"RunSSH":%s} .../localapi/v0/prefs\n' "$FLIP"
    curl -sS -X PATCH \
      -H 'Content-Type: application/json' \
      --unix-socket "$SOCK" \
      --data "{\"RunSSHSet\":true,\"RunSSH\":$FLIP}" \
      http://local-tailscaled.sock/localapi/v0/prefs 2>&1 | head -c 800
    printf '\n  (exit=%d)\n' $?
    printf '```\n'
  } >> "$REPORT"
  S2B_AFTER="$(get_runssh)"
  rep ""
  rep "-> RunSSH after PATCH = \`${S2B_AFTER:-unreadable}\` (expected: \`$FLIP\`)"
  note "  S-2b: RunSSH after PATCH = ${S2B_AFTER:-?} (expected ${FLIP})"

  # Put it back
  curl -sS -X PATCH -H 'Content-Type: application/json' --unix-socket "$SOCK" \
    --data "{\"RunSSHSet\":true,\"RunSSH\":$ORIG_RUNSSH}" \
    http://local-tailscaled.sock/localapi/v0/prefs >/dev/null 2>&1
  "$TS_BIN" set --ssh="$ORIG_RUNSSH" >/dev/null 2>&1
  rep ""
  rep "-> RunSSH after restore = \`$(get_runssh)\`"

  if [ "$S2B_AFTER" = "$FLIP" ]; then
    S2B_VERDICT="PASS -- writable through the LocalAPI as non-root"
  else
    S2B_VERDICT="FAIL -- not writable through the LocalAPI; the CLI is required"
  fi
  rep ""
  rep "**S-2b verdict: $S2B_VERDICT**"
  note "  S-2b verdict: $S2B_VERDICT"

  # --- Probe for a session-listing endpoint (input for S-3) ---
  head3 "LocalAPI endpoint probe (looking for SSH session data)"
  {
    printf '```console\n'
    for ep in status prefs metrics ssh ssh-sessions sessions debug-log; do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" \
        "http://local-tailscaled.sock/localapi/v0/$ep" 2>&1)"
      printf '%-14s -> %s\n' "/localapi/v0/$ep" "$code"
    done
    printf '```\n'
  } >> "$REPORT"
fi

# --------------------------------------------------------------------- S-3 ---

head2 "S-3 -- are active SSH sessions observable locally?"

run "tailscale debug subcommands" "$TS_BIN" debug --help
runsh "brew log files" \
  "ls -la /opt/homebrew/var/log/ 2>/dev/null | grep -i tail || echo 'no match'"
runsh "tail of tailscaled.log" \
  "tail -n 40 /opt/homebrew/var/log/tailscaled.log 2>/dev/null || echo 'no log file'"
# Call /usr/bin/log by absolute path: a shell function named log would shadow it
runsh "does tailscaled appear in the unified log?" \
  "/usr/bin/log show --last 10m --predicate 'process == \"tailscaled\"' 2>&1 | tail -n 20"

cat <<EOF

────────────────────────────────────────────────────────────
 About to stream \`tailscale debug daemon-logs\` for ${DAEMON_LOG_SECS} seconds.

 If you can, connect **from another machine** during that window:
   ssh <this host's tailscale name>
 so we can see whether session start shows up in the logs.

 If no second machine is available, just leave it alone.
────────────────────────────────────────────────────────────

EOF
printf 'Press Enter to start: '
read -r _

head3 "tailscale debug daemon-logs (${DAEMON_LOG_SECS}s)"
DLOG="$OUT_DIR/daemon-logs.txt"
"$TS_BIN" debug daemon-logs > "$DLOG" 2>&1 &
DPID=$!
for i in $(seq "$DAEMON_LOG_SECS" -1 1); do printf '\r  %2d seconds left ' "$i"; sleep 1; done
printf '\r  done             \n'
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null

{
  printf '```console\n'
  printf '$ tailscale debug daemon-logs  (%ss)\n' "$DAEMON_LOG_SECS"
  grep -i -E 'ssh|session' "$DLOG" | head -n 40
  printf '\n--- (SSH-related lines only; full capture in results/daemon-logs.txt) ---\n'
  printf 'total lines: %s\n' "$(wc -l < "$DLOG" | tr -d ' ')"
  printf '```\n'
} >> "$REPORT"

# ------------------------------------------------------------------ summary ---

head2 "Summary"
rep ""
rep "| check | verdict |"
rep "|---|---|"
rep "| S-1 write prefs without sudo | $S1_VERDICT |"
rep "| S-2 LocalAPI socket | ${SOCK:-not found} |"
rep "| S-2b write through LocalAPI | ${S2B_VERDICT:-not run} |"
rep "| S-3 SSH session observation | judge from daemon-logs and the log files above |"

note ""
note "────────────────────────────────────────"
note "Done. Report: $REPORT"
note "────────────────────────────────────────"
