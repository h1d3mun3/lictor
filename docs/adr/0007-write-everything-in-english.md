# ADR-0007: Write everything in the repository in English

- **Status**: Accepted
- **Date**: 2026-08-01

## Context

The project was started in Japanese: comments, documentation, log output and UI strings.
Conversation about the work also happens in Japanese, and the two had not been separated.

## Decision

Everything that persists in the repository is English: source and comments, documentation,
commit messages, log output, notification bodies, and user-facing UI strings.

Conversation with the maintainer stays in Japanese. That is a separate concern from what
gets committed.

## Consequences

`tests/check-language.sh` enforces this by scanning every tracked file for CJK characters,
so the rule is checkable rather than merely stated. It runs as part of `tests/run-all.sh`.

There is a concrete secondary benefit in shell scripts. bash 3.2, the system bash on macOS,
folds bytes above 0x7F into variable names: a `$FLIP` immediately followed by U+FF09
FULLWIDTH RIGHT PARENTHESIS parses as a variable whose name includes that character and
aborts under `set -u`. That bug actually happened during the verification work. Restricting
the repository to ASCII removes the entire class.

The original Japanese brief the project was built from is deliberately not tracked. What it
specified now lives in [principles.md](../principles.md).
