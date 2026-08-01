# ADR-0002: Enforce from a LaunchAgent, not a LaunchDaemon

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0001](0001-assume-a-single-user-with-operator-configured.md)

## Context

Enforcement is the layer that must not die (principle 1). Two ways to run it periodically:
a per-user LaunchAgent, or a system LaunchDaemon running as root.

A LaunchAgent inherits the operator dependency from ADR-0001 and, separately, **does not
run while the user is logged out**. Tailscale SSH is served by root's `tailscaled` and
keeps accepting connections in that state, so a logged-out machine would enforce nothing.

## Decision

Run enforcement as a user LaunchAgent.

## Consequences

There is a real hole: SSH stays open past its deadline for as long as the machine sits at
the login window. `RunAtLoad` covers the moment of login and nothing before it.

Accepted because the machine is used to keep a session alive under `tmux`, which presumes
being logged in continuously. Logging out and leaving it running is not a scenario this is
designed for.

The hole is independent of the operator question in ADR-0001, and closing one would not
close the other.
