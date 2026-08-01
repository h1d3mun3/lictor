#!/bin/bash
#
# Lictor enforcement agent -- expires Tailscale SSH
#
#   Run by launchd every 60 seconds (see agent/install.sh).
#   Can also be run standalone: bash agent/lictor-agent.sh
#
# The only write capability of this script is `tailscale set --ssh=false`.
# **Never run --ssh=true here.** This keeps every failure mode falling to the
# safe side (see principle 2). Notifications are emitted from here,
# independently of the menu bar app.
#
# Environment variables (test seams):
#   LICTOR_STATE_DIR   default $HOME/.local/state/lictor
#   LICTOR_TAILSCALE   default /opt/homebrew/bin/tailscale
#   LICTOR_OSASCRIPT   default /usr/bin/osascript
#   LICTOR_NO_MAIN=1   define functions only, do not run main (used by tests)

set -u

LICTOR_STATE_DIR="${LICTOR_STATE_DIR:-$HOME/.local/state/lictor}"
STATE_FILE="$LICTOR_STATE_DIR/state.json"
LOG_FILE="$LICTOR_STATE_DIR/agent.log"
HISTORY_FILE="$LICTOR_STATE_DIR/history.jsonl"
NOTIFY_MARK="$LICTOR_STATE_DIR/.last-notified"

# How recently the state file may have been written before this agent refuses to
# tidy it away. The app writes state.json and only then runs `tailscale set
# --ssh=true`, so for the duration of that CLI call the file exists while RunSSH
# is still false -- which looks exactly like a leftover. Deleting it there
# destroys a session the user just authorised. Far longer than the CLI takes, and
# only ever delays a cosmetic cleanup by one tick.
STATE_SETTLE_SECONDS=30

# Set by main() from the same reading the decision is made from; see state_unchanged.
STATE_TOKEN=""
STATE_EXPIRES=""
TAILSCALE="${LICTOR_TAILSCALE:-/opt/homebrew/bin/tailscale}"
OSASCRIPT="${LICTOR_OSASCRIPT:-/usr/bin/osascript}"

# ---------------------------------------------------------------- utilities ---

log_line() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE"
}

# ISO 8601 (UTC, trailing Z) -> epoch seconds.
# Prints nothing and returns 1 when the input cannot be parsed.
iso_to_epoch() {
  local iso="$1"
  iso="${iso%%.*}"                       # drop fractional seconds if present
  case "$iso" in
    *Z) : ;;
    *)  iso="${iso}Z" ;;
  esac
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null
}

# Do not repeat the same kind of notification.
# Without this the agent would fire an alert every 60 seconds and be tuned out.
notify_once() {
  local kind="$1" title="$2" body="$3"
  local last=""
  [ -f "$NOTIFY_MARK" ] && last="$(cat "$NOTIFY_MARK" 2>/dev/null)"
  [ "$last" = "$kind" ] && return 0
  printf '%s' "$kind" > "$NOTIFY_MARK"
  "$OSASCRIPT" -e "display notification \"$body\" with title \"Lictor\" subtitle \"$title\" sound name \"Submarine\"" >/dev/null 2>&1 || true
}

clear_notify_mark() { rm -f "$NOTIFY_MARK"; }

# Append one line to the shared history log, read by the app's history window.
#
# JSON Lines, because a single small append lands atomically even while the app
# is reading the same file. The format is the contract with the Swift side; see
# lictor/Core/HistoryEvent.swift, and tests/run-interop.sh checks that what is
# written here still parses there.
#
# **Failure is ignored on purpose.** Being unable to record that SSH closed is
# never a reason to leave it open.
history_append() {
  local event="$1" reason="$2"
  {
    printf '{"at":"%s","event":"%s","reason":"%s"}\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$reason" >> "$HISTORY_FILE"
  } 2>/dev/null || true
}

# ------------------------------------------------------------------ readers ---

# Prints "true" / "false" / "" (could not read)
read_runssh() {
  "$TAILSCALE" debug prefs 2>/dev/null \
    | tr -d ' \t' \
    | grep -o '"RunSSH":[a-z]*' \
    | head -1 \
    | cut -d: -f2
}

# Prints the expiresAt field of state.json, or nothing if the file is absent
read_expires_at() {
  [ -f "$STATE_FILE" ] || return 0
  grep -o '"expiresAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" 2>/dev/null \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

# Identity of the state file: inode, mtime, size.
state_token() {
  stat -f '%i:%m:%z' "$STATE_FILE" 2>/dev/null || true
}

# Whether the state file is still the one this tick's decision was made from.
#
# Both removals below act on a reading taken earlier in the tick. If the app
# wrote a new session in between, the file on disk is no longer the one the
# decision was about, and removing it would destroy a session the user just
# authorised. The deadline is the authoritative comparison -- a new session
# carries a new one -- with the file identity as a second signal for the case
# where a deadline happens to repeat.
state_unchanged() {
  [ "$(read_expires_at)" = "$STATE_EXPIRES" ] && [ "$(state_token)" = "$STATE_TOKEN" ]
}

# Seconds since the state file was last written. Prints nothing if it is absent.
state_age() {
  local written
  written="$(stat -f '%m' "$STATE_FILE" 2>/dev/null)" || return 0
  [ -n "$written" ] || return 0
  echo $(( $(date -u '+%s') - written ))
}

# ----------------------------------------------------------------- decision ---
#
# Pure function. No side effects; the current time is passed in (CLAUDE.md, testing).
#
#   decide <runSSH> <expiresAt|empty> <now_epoch>
#
# Prints one of:
#   none                 nothing to do
#   clear-state          just remove the leftover state.json
#   disable:expired      the deadline has passed
#   disable:no-state     RunSSH is true but there is no state.json (ADR-0005: close now)
#   disable:bad-state    state.json exists but expiresAt cannot be parsed
#   error:unknown-runssh RunSSH could not be read (tailscaled down, etc.)
#
decide() {
  local runssh="$1" expires="$2" now="$3"

  if [ "$runssh" != "true" ] && [ "$runssh" != "false" ]; then
    echo "error:unknown-runssh"; return
  fi

  if [ "$runssh" = "false" ]; then
    if [ -n "$expires" ]; then echo "clear-state"; else echo "none"; fi
    return
  fi

  # From here on RunSSH == true
  if [ -z "$expires" ]; then
    echo "disable:no-state"; return
  fi

  local exp
  exp="$(iso_to_epoch "$expires")"
  if [ -z "$exp" ]; then
    echo "disable:bad-state"; return
  fi

  # Boundary: now == expiresAt already counts as expired
  if [ "$now" -ge "$exp" ]; then
    echo "disable:expired"
  else
    echo "none"
  fi
}

# ------------------------------------------------------------------ actions ---

reason_text() {
  case "$1" in
    expired)   echo "The session has expired." ;;
    no-state)  echo "SSH was enabled without going through Lictor." ;;
    bad-state) echo "The state file is corrupt." ;;
    *)         echo "$1" ;;
  esac
}

do_disable() {
  local reason="$1" after
  log_line "DISABLE reason=$reason"

  if ! "$TAILSCALE" set --ssh=false >>"$LOG_FILE" 2>&1; then
    log_line "FAILED tailscale set exited non-zero; keeping state.json to retry next tick"
    notify_once "disable-failed" "Cannot disable SSH" "tailscale set failed. Please check manually."
    return 1
  fi

  after="$(read_runssh)"
  if [ "$after" != "false" ]; then
    log_line "FAILED set succeeded but RunSSH is still $after; keeping state.json"
    notify_once "disable-failed" "Cannot disable SSH" "RunSSH did not become false. Please check manually."
    return 1
  fi

  if state_unchanged; then
    rm -f "$STATE_FILE"
    log_line "OK RunSSH=false, state.json removed"
  else
    # A new session was written while this tick was closing the old one. SSH is
    # off, so the user's enable will finish against a state file that survives.
    log_line "OK RunSSH=false, kept state.json: it was replaced during this tick"
  fi
  history_append disabled "$reason"
  # Do NOT call clear_notify_mark here. Doing so would wipe the suppression
  # marker we are about to write, and the same notification would fire every
  # 60 seconds. The marker is cleared only when main() observes a healthy tick.
  notify_once "disabled-$reason" "SSH disabled" "$(reason_text "$reason")"
  return 0
}

# --------------------------------------------------------------------- main ---

main() {
  mkdir -p "$LICTOR_STATE_DIR"
  chmod 700 "$LICTOR_STATE_DIR" 2>/dev/null || true

  local runssh expires now action
  runssh="$(read_runssh)"
  expires="$(read_expires_at)"
  STATE_EXPIRES="$expires"
  STATE_TOKEN="$(state_token)"
  now="$(date -u '+%s')"
  action="$(decide "$runssh" "$expires" "$now")"

  case "$action" in
    none)
      clear_notify_mark
      ;;
    clear-state)
      local age
      age="$(state_age)"
      if ! state_unchanged \
         || { [ -n "$age" ] && [ "$age" -lt "$STATE_SETTLE_SECONDS" ]; }; then
        # Being mid-enable looks identical to being a leftover. Wait a tick.
        log_line "CLEAR skipped: state.json is too fresh to be a leftover"
      else
        rm -f "$STATE_FILE"
        log_line "CLEAR RunSSH=false, removed leftover state.json"
      fi
      clear_notify_mark
      ;;
    disable:*)
      do_disable "${action#disable:}"
      ;;
    error:unknown-runssh)
      log_line "ERROR cannot read RunSSH (check $TAILSCALE and tailscaled)"
      notify_once "unknown-runssh" "Cannot read state" "Unable to reach tailscaled. SSH status is unknown."
      ;;
  esac
}

[ "${LICTOR_NO_MAIN:-0}" = "1" ] || main "$@"
