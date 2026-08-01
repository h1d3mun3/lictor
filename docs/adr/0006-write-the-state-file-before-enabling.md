# ADR-0006: Write the state file before enabling SSH

- **Status**: Accepted
- **Date**: 2026-08-01
- **Related**: [ADR-0005](0005-close-immediately-when-there-is-no-state-file.md)

## Context

Enabling is two writes: the state file, and `RunSSH`. They cannot be made atomic together,
so an agent tick can land between them. Both orderings leave a window; they differ in what
that window contains.

## Decision

Always:

1. write `state.json` atomically
2. then run `tailscale set --ssh=true`
3. if step 2 fails, delete the state file again

Never the reverse.

## Consequences

| Order | Transient state | Agent verdict | Outcome |
|---|---|---|---|
| **state, then SSH** | `RunSSH=false` with a state file | clean up the file | harmless |
| SSH, then state | `RunSSH=true` with no state file | close at once (ADR-0005) | the enable is silently undone |

The chosen order never opens a window on the side where SSH is on with an unknown
deadline. The window it does open is one the agent already knows how to tidy.

Extending follows the same order for the same reason.
