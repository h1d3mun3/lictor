# ADR-0008: State unconditionally that turning off disconnects live sessions

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0004](0004-do-not-observe-ssh-sessions.md), [ADR-0005](0005-close-immediately-when-there-is-no-state-file.md)

## Context

Whether `tailscale set --ssh=false` merely refuses new connections or also tears down
established ones was unknown, and it changes what the off control means.

Measured: an `ssh -t <host> 'tmux new -A -s test'` session held open from another machine
was **disconnected the moment `--ssh=false` ran**. It does not only block new connections.

## Decision

1. The off control says it disconnects active sessions, **unconditionally** rather than
   only when a session is detected
2. The five-minute warning must offer an extend action
3. Off stays one click with no authentication (principle 3)

## Consequences

Turning SSH off is destructive, whichever path triggers it: the menu bar button, an expiring
deadline, or ADR-0005 firing. The cost recorded in ADR-0005 is measured, not hypothetical.

The five-minute warning becomes load-bearing rather than a convenience. Without it, an
expiring deadline silently kills whatever is running.

The warning is unconditional because detecting a live session means parsing logs, which
ADR-0004 established can silently miss. A warning that stops appearing is worse than one
that is always there. If session display is ever added, it may **add** emphasis; it may
never **remove** the baseline warning.

Off keeps its lack of friction even though it is destructive to in-flight work. Principle 3
is about the direction that opens SSH, and making the closing direction harder would be the
wrong trade.
