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
| **state, then SSH** | `RunSSH=false` with a state file | tidy the file away | the enable is undone one tick later |
| SSH, then state | `RunSSH=true` with no state file | close at once (ADR-0005) | the enable is undone immediately |

The chosen order is still the right one, but not for the reason first recorded here.
Its window never puts SSH **on** with an unknown deadline, which is the state that
would leave a machine open indefinitely if anything went wrong next. That is the
property worth having.

What the first version of this document got wrong was calling the remaining window
harmless. It is not. A state file written seconds ago is indistinguishable from one
left behind by a closed session, so the agent's own cleanup deletes the session the
user just authorised; the next tick then finds `RunSSH=true` with no state file and
closes SSH under ADR-0005, blaming the user in the notification and the history log
for an enable that went through Lictor. The two rows above differ in latency, not in
outcome.

The agent therefore refuses to remove a state file that is not the one its decision
was made from: it compares the deadline it read, and declines to tidy away a file
written within the last 30 seconds. Delaying a cosmetic cleanup by one tick costs
nothing; deleting a live session costs the session.

Extending follows the same order, and is guarded the same way.
