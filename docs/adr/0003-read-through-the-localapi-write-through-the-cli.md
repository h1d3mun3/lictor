# ADR-0003: Read through the LocalAPI, write through the CLI

- **Status**: Accepted
- **Date**: 2026-08-01

## Context

`RunSSH` can be read and written two ways: the `tailscale` CLI, or the LocalAPI over
`/var/run/tailscaled.socket`. Both were measured to work as the operator user, including
`PATCH /localapi/v0/prefs` (see [localapi.md](../localapi.md)).

Two facts came out of the measurement:

- `tailscale set` issues `POST /localapi/v0/check-prefs` before patching. A raw `PATCH`
  skips that validation
- `GET` requests are not recorded in `tailscaled.log`, while `POST` and `PATCH` are

## Decision

| Operation | Mechanism |
|---|---|
| reading `RunSSH`, `BackendState`, `Health` | `GET /localapi/v0/prefs`, `/localapi/v0/status` |
| writing `RunSSH` | `tailscale set --ssh=<bool>` |

## Consequences

Writes keep the validation pass and share one code path with the launchd agent, which is a
shell script and has no reasonable way to speak the LocalAPI.

Reads cost no process spawn and leave no trace in the daemon log, so polling every 30
seconds is free in both senses.

The app carries a hand-written unix socket HTTP client, because `URLSession` cannot talk to
unix sockets. That client is the least obvious thing in the codebase and is covered by its
own test suite against a fake server.
