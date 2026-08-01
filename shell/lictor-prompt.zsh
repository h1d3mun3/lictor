#
# Lictor -- third window onto the SSH state, in the shell prompt.
#
# Install by adding this to ~/.zshrc:
#
#     source /path/to/lictor/shell/lictor-prompt.zsh
#
# This is the layer that is allowed to be wrong. The menu bar app can be quit and
# the terminal still shows the countdown; both can be gone and the launchd agent
# still closes SSH on time. Three independent windows, one enforcement path.
#
# **Only state.json is read. The tailscale CLI is never invoked.** This runs
# before every prompt, and spawning a process each time would make the shell feel
# slow enough that the feature gets removed.
#
# Known blind spot: state.json is written by Lictor, so SSH enabled outside
# Lictor shows nothing here. The agent closes that case within 60 seconds anyway
# (ADR-0005), and paying a process spawn per prompt to cover a 60 second window is not
# a trade worth making.

LICTOR_STATE_FILE="${LICTOR_STATE_FILE:-$HOME/.local/state/lictor/state.json}"

# Whatever RPROMPT was before this file was sourced, captured once so that
# re-sourcing cannot swallow our own segment. Lictor is one more thing on the
# right of the prompt, not the owner of it.
#
# This only rescues a static RPROMPT. A theme that assigns RPROMPT from its own
# precmd hook (powerlevel10k, starship, vcs_info) still wins or loses on hook
# order, and the two cannot be reconciled from here.
typeset -g _LICTOR_BASE_RPROMPT="${_LICTOR_BASE_RPROMPT-$RPROMPT}"

# Shown when a session is active. %F/%f are zsh prompt colour escapes.
: "${LICTOR_PROMPT_COLOR:=red}"

_lictor_remaining() {
  [[ -r "$LICTOR_STATE_FILE" ]] || return 1

  local iso
  iso=$(grep -o '"expiresAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$LICTOR_STATE_FILE" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  [[ -n "$iso" ]] || return 1

  # Strip fractional seconds; BSD date cannot parse them
  iso="${iso%%.*}"
  [[ "$iso" == *Z ]] || iso="${iso}Z"

  local expires now left
  expires=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null) || return 1
  now=$(date -u '+%s')
  left=$(( expires - now ))

  (( left < 0 )) && left=0

  # Same format as the menu bar: h:mm at an hour or more, mm:ss below
  if (( left >= 3600 )); then
    printf '%d:%02d' $(( left / 3600 )) $(( (left % 3600) / 60 ))
  else
    printf '%d:%02d' $(( left / 60 )) $(( left % 60 ))
  fi
}

_lictor_precmd() {
  local remaining
  if remaining=$(_lictor_remaining); then
    LICTOR_RPROMPT="%F{$LICTOR_PROMPT_COLOR}ssh ${remaining}%f"
  else
    # Nothing at all when closed. The menu bar is the always-on indicator;
    # the prompt only speaks up when SSH is open.
    LICTOR_RPROMPT=""
  fi

  # Our segment goes to the left of whatever was already there, so an existing
  # right prompt keeps the position its user is used to.
  if [[ -n "$LICTOR_RPROMPT" && -n "$_LICTOR_BASE_RPROMPT" ]]; then
    RPROMPT="${LICTOR_RPROMPT} ${_LICTOR_BASE_RPROMPT}"
  else
    RPROMPT="${LICTOR_RPROMPT}${_LICTOR_BASE_RPROMPT}"
  fi
}

autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _lictor_precmd \
  || precmd_functions+=(_lictor_precmd)
