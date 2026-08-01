# ADR-0005: Close immediately when `RunSSH` is true with no state file

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0006](0006-write-the-state-file-before-enabling.md)

## Context

The agent sees two things: `RunSSH`, and `state.json`. Four of the five combinations are
obvious. The fifth is not: **SSH is on, and there is no record of when it should close.**

Several causes produce it, and the agent cannot tell them apart:

- `tailscale set --ssh=true` was run directly, bypassing Lictor
- Lictor crashed and lost the state file
- the file was deleted by hand
- Lictor enabled SSH but failed to write the file

With the deadline unknown, doing nothing means SSH stays open forever, which is the exact
outcome this project exists to prevent.

## Decision

Disable immediately, with no grace period, and notify.

Detection to close takes at most one tick, currently 60 seconds.

## Consequences

Enabling SSH from a terminal without going through Lictor no longer works: it gets rolled
back within a minute. Under ADR-0001's single-user premise, that path had no value to
protect, and a grace period would only extend the time SSH stays open.

**The cost is real.** If Lictor crashes in a way that loses only the state file, a live SSH
session is cut within 60 seconds. Combined with [ADR-0008](0008-say-that-turning-off-disconnects.md),
that means losing whatever was running over it. Judged acceptable for a personal tool.

It also means the app must never create the window this closes; see ADR-0006.
