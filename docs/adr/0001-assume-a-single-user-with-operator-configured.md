# ADR-0001: Assume a single user with `--operator` configured

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0002](0002-enforce-from-a-launchagent.md)

## Context

Before any UI existed, the first thing verified was whether prefs could be written without
`sudo`. It could: `tailscale set --ssh=false` succeeded in both directions as the ordinary
user.

That result is not a property of Tailscale. It holds because this machine has
`OperatorUser` set, confirmed by reading `prefs.OperatorUser` directly.

If that setting is lost, `tailscale set --ssh=false` stops working and **Lictor can no
longer close SSH**. The failure lands on the dangerous side.

Moving enforcement to a root LaunchDaemon would remove the dependency entirely, since root
can always write prefs.

## Decision

Treat these as preconditions and implement no handling for their absence:

- the machine has exactly one user
- `sudo tailscale set --operator=$USER` has already been run

The root LaunchDaemon alternative was considered and rejected.

## Consequences

Losing the operator setting breaks the toggle silently as far as the write path is
concerned, so it is **detected instead**: the app reads `prefs.OperatorUser` and shows a
warning when it does not match the current user. A non-functional toggle is visible rather
than mysterious.

Rejecting the daemon keeps the privilege footprint small and keeps notifications simple,
since `osascript` cannot reach a GUI session from a root context.

This decision is wrong for corporate or multi-user deployments. It is sized for one person
on one laptop.
