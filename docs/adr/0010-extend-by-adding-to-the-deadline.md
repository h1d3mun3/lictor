# ADR-0010: Extend by adding to the deadline, behind Touch ID

- **Status**: Accepted
- **Date**: 2026-08-01
- **Supersedes**: an earlier decision to measure the extension from the moment it is granted
- **Related**: [ADR-0008](0008-say-that-turning-off-disconnects.md)

## Context

The five-minute warning offers an extension. Extension was first implemented as "30 minutes
from now", which meant pressing it with four minutes left produced 30 minutes rather than
34, discarding the remaining time.

A control labelled "Extend 30 min" reads as half an hour more than you had. The label is
the argument, and the implementation was contradicting it.

## Decision

The duration is **added to the current deadline**.

The base is the later of the current deadline and now, so extending a session whose
deadline has already passed grants the full stated amount rather than less, or a deadline
still in the past.

Extending requires Touch ID, the same as enabling.

## Consequences

`enabledAt` is carried across an extension, so it keeps meaning "when this session began"
rather than "when it was last touched". `durationSeconds` accumulates into the total
granted so far.

The boundary matters more than it looks. The warning fires five minutes out, the deadline
can pass before anyone reacts, and the agent takes up to another 60 seconds to close
(ADR-0008), so the button really is reachable after expiry.

Extending still runs the CLI even though SSH is normally already on. If the agent closed
SSH in that window, extending has to genuinely reopen it rather than leave a state file
describing a session that no longer exists.

Requiring Touch ID means a stray click on a notification cannot silently prolong a session,
and keeps the cost on the direction that keeps SSH open (principle 3).
