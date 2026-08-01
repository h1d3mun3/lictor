#!/bin/bash
#
# Enforce the repository language rule: everything tracked here is English.
#
#   bash tests/check-language.sh
#
# Scans every file tracked by git for CJK characters and fails if any are found.
# See CLAUDE.md and docs/adr/0007-write-everything-in-english.md for the rule.

set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git ls-files -z | python3 -c '
import sys

# Code point ranges rather than a literal character class, so that this file
# stays pure ASCII and does not trip its own check.
RANGES = (
    (0x3000, 0x303F),   # CJK symbols and punctuation
    (0x3040, 0x309F),   # hiragana
    (0x30A0, 0x30FF),   # katakana
    (0x4E00, 0x9FFF),   # CJK unified ideographs
    (0xFF00, 0xFFEF),   # halfwidth and fullwidth forms
)


def has_cjk(text):
    return any(
        any(low <= ord(char) <= high for low, high in RANGES)
        for char in text
    )


paths = [p for p in sys.stdin.buffer.read().split(b"\0") if p]
violations = 0

for raw in paths:
    path = raw.decode("utf-8", "replace")
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except (UnicodeDecodeError, OSError):
        continue  # binary or unreadable; nothing to check

    for number, line in enumerate(lines, 1):
        if has_cjk(line):
            violations += 1
            print(f"{path}:{number}: {line.rstrip()}")

if violations:
    print()
    print(f"FAIL  {violations} line(s) contain non-English text.")
    print("      Everything committed to this repository must be in English (CLAUDE.md).")
    sys.exit(1)

print(f"ok    {len(paths)} tracked files, no non-English text found")
'
