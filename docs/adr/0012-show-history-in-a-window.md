# ADR-0012: Show history in a window, not in the dropdown

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0011](0011-record-history-as-an-append-only-log.md)

## Context

The original brief listed history as an item inside the menu bar dropdown. The dropdown had
just been reworked into compact rows, and a list of sessions is the largest thing that
would ever go in it.

## Decision

The list lives in its own window. The dropdown keeps a `History` row that opens it.

The window is a viewer: no editing, no filtering, no clear button.

## Consequences

This departs from the brief, deliberately. Reviewing a list is a different activity from
glancing at a state. The dropdown answers "is SSH open right now"; the window answers "was
there a session I did not open", which is the question the log exists for. Keeping a row in
the dropdown preserves the route the brief asked for.

No clear button, because a clear button lets the audit trail be destroyed from inside the
thing whose job is to keep it. Deleting the file by hand is deliberate in a way a button is
not.

Anomalous entries -- SSH enabled outside Lictor, or an unreadable state file -- are the only
rows that carry colour, because they are the only reason to open the window rather than
trust the menu bar.

The window is suppressed at launch. A menu bar app that opens a window on login contradicts
what it is, and an `LSUIElement` app has no Dock icon to bring one back with, so opening it
also activates the app explicitly.
