# ADR-0004: Do not observe SSH sessions

- **Status**: Accepted; not implemented in v1
- **Date**: 2026-08-01

## Context

"SSH is enabled" and "somebody is connected right now" are different facts, and the second
is the heavier one.

It is obtainable. `tailscale debug daemon-logs` streams session start and end, and
`/opt/homebrew/var/log/tailscaled.log` keeps them, with remote address and authenticated
account. The exact lines are recorded in [localapi.md](../localapi.md).

It is also only obtainable by parsing logs, and that measurement turned up three problems:

1. **Rate limiting is real** — `[RATELIMIT]` was observed in practice, so lines can be dropped
2. `daemon-logs` is a stream and knows nothing from before it was subscribed to
3. `tailscale debug` documents itself as "not a stable interface"

## Decision

Two parts, held to different standards.

**Firm.** Session state must never feed the enforcement decision. This does not change.

**Open.** v1 does not observe sessions at all. Whether to surface it later as display-only
information is undecided, and no work is planned around it.

## Consequences

`history.jsonl` records **when SSH was opened and closed, never who connected through it**.
It has no record of connections, remote identities, or session durations.

A `disabled` entry with reason `no-state` is the closest thing to an anomaly signal in the
file. It still says nothing about whether anyone connected.

Dropped lines are why this stays out of the log even as decoration. A missing line would
read as "nobody connected", which turns a gap in the data into a false statement. Recording
nothing is more honest than recording something that might be wrong.

Anyone who wants the data today can read it directly:

```bash
grep ssh-session /opt/homebrew/var/log/tailscaled.log
```
