# Architecture decision records

One document, one decision. Each records what was chosen, what it was chosen over, and what
it costs. They are written to be read by someone deciding whether to change them.

The constraints these are weighed against are in [../principles.md](../principles.md).
Measured facts about the Tailscale LocalAPI are in [../localapi.md](../localapi.md).

| # | Decision | Status |
|---|---|---|
| [0007](0007-write-everything-in-english.md) | Write everything in the repository in English | Accepted |

## Writing a new one

Number sequentially, name the file after the decision rather than the area, and keep it to
one concern. If a document needs the word "and" in its title, it is probably two.

Use the same shape: **Context** (what forced a choice, including anything measured),
**Decision** (what was chosen, in the imperative), **Consequences** (what this costs and
what it now forbids).

Superseding an ADR does not mean deleting it. Mark the old one and link both ways: the
reason a decision was reversed is worth more than the decision itself.
