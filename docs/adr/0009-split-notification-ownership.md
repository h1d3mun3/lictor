# ADR-0009: Split notification ownership between the agent and the app

- **Status**: Accepted
- **Date**: 2026-08-01

## Context

Both processes can post notifications, and both have reason to. If neither owns anything
exclusively, a single event produces two alerts whenever both happen to be running.

The agent already notified on automatic disable before the app had notifications at all.

## Decision

| Event | Notified by | Why there |
|---|---|---|
| SSH enabled | app | the agent never observes an enable; it only ever closes |
| five minutes before expiry | app | it carries an action, and only the app can authenticate |
| automatically disabled | **agent** | it has to fire when the app is not running |

Neither side notifies about an event the other owns. In particular the app does not
announce an automatic disable it merely observed.

## Consequences

The agent's notification is the load-bearing one. SSH closing behind the user's back is
exactly when they must be told, and exactly when the app is least guaranteed to exist
(principle 1).

The five-minute warning cannot live in the agent: it needs an actionable button and Touch
ID to act on it, and `osascript` provides neither.

The user's own off action is announced by nobody, because they just performed it. The
history log still records it.
