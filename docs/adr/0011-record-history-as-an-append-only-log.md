# ADR-0011: Record history as an append-only JSON Lines log

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0009](0009-split-notification-ownership.md), [ADR-0012](0012-show-history-in-a-window.md)

## Context

History needs both halves of a session, and only half existed. The agent's `agent.log`
recorded closes; nothing recorded opens, because `state.json` is deleted when a session
ends and the agent never observes an enable (ADR-0009).

`agent.log` was the obvious candidate to reuse and the wrong one. It is free-form text for
humans, and building a UI on parsing it is the same trap ADR-0004 exists to avoid.

## Decision

A new file, `~/.local/state/lictor/history.jsonl`, appended to by both processes.

```jsonl
{"at":"2026-08-01T12:30:00Z","event":"enabled","durationSeconds":7200,"expiresAt":"2026-08-01T14:30:00Z"}
{"at":"2026-08-01T13:10:00Z","event":"extended","expiresAt":"2026-08-01T15:00:00Z"}
{"at":"2026-08-01T15:00:49Z","event":"disabled","reason":"expired"}
```

- **App writes**: `enabled`, `extended`, and the `disabled` the user asks for
- **Agent writes**: the `disabled` it performs itself, with the reason
- Append only. No line is ever rewritten
- **A failed write is discarded silently**

## Consequences

JSON Lines rather than a JSON document because a single small append lands atomically while
the other process may be reading, and that guarantee only holds because nothing rewrites.

Discarding failed writes is not laziness. Being unable to record that SSH closed is never a
reason to leave it open (principle 1), so no history failure may propagate into the
enforcement path.

The file is never trimmed and has no clear function. It grows by a few hundred bytes a day;
the reader caps how much it renders instead. Deleting it by hand is how it gets cleared.

Parsing is deliberately forgiving: a malformed or unrecognised line is skipped rather than
surfaced as an error, because a log outlives the format that wrote it.

The format is a cross-language contract like `state.json`, and `tests/run-interop.sh` covers
it in both directions.
