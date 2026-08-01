# Architecture decision records

One document, one decision. Each records what was chosen, what it was chosen over, and what
it costs. They are written to be read by someone deciding whether to change them.

The constraints these are weighed against are in [../principles.md](../principles.md).
Measured facts about the Tailscale LocalAPI are in [../localapi.md](../localapi.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-assume-a-single-user-with-operator-configured.md) | Assume a single user with `--operator` configured | Accepted |
| [0002](0002-enforce-from-a-launchagent.md) | Enforce from a LaunchAgent, not a LaunchDaemon | Accepted |
| [0003](0003-read-through-the-localapi-write-through-the-cli.md) | Read through the LocalAPI, write through the CLI | Accepted |
| [0004](0004-do-not-observe-ssh-sessions.md) | Do not observe SSH sessions | Accepted, not implemented |
| [0005](0005-close-immediately-when-there-is-no-state-file.md) | Close immediately when `RunSSH` is true with no state file | Accepted |
| [0006](0006-write-the-state-file-before-enabling.md) | Write the state file before enabling SSH | Accepted |
| [0007](0007-write-everything-in-english.md) | Write everything in the repository in English | Accepted |
| [0008](0008-say-that-turning-off-disconnects.md) | State unconditionally that turning off disconnects live sessions | Accepted |

## Writing a new one

Number sequentially, name the file after the decision rather than the area, and keep it to
one concern. If a document needs the word "and" in its title, it is probably two.

Use the same shape: **Context** (what forced a choice, including anything measured),
**Decision** (what was chosen, in the imperative), **Consequences** (what this costs and
what it now forbids).

Superseding an ADR does not mean deleting it. Mark the old one and link both ways: the
reason a decision was reversed is worth more than the decision itself.
