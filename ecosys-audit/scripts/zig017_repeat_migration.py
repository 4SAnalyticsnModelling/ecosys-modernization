# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Zig 0.17 migration: the `**` array/vector repeat operator no longer exists.

Zig 0.17 parses `a ** b` as two `*` operators (exactly what `zig fmt` does), so every
array-repeat must be spelled with the ordinary multiply operator: `a ** b` -> `a * b`.
Evidence (probes, 2026-10-08, zig 0.17.0):
  - `zig fmt` rewrites `a**n` to `a * *n` and errors on `a ** n` ("binary operator '*'
    has whitespace on one side, but not the other");
  - `zig run` of `[_]u8{0} * 3` parses and repeats the array (len 3).

The old `**` token was unambiguously a repeat, so this codemod only has to skip
string literals and comments; it rewrites every `**` token to ` * ` and leaves
spacing to `zig fmt`. Pointer types (`*const`, `*[*]u8`) never contain a `**` token.

Usage: uv run ecosys-audit/scripts/zig017_repeat_migration.py <file-or-dir>...
Writes files in place only when a change was made; prints a per-file token count.
"""
from __future__ import annotations

import sys
from pathlib import Path


def migrate_text(text: str) -> tuple[str, int]:
    out: list[str] = []
    count = 0
    i = 0
    n = len(text)
    in_line_comment = False
    in_string = False
    in_multiline_string = False
    while i < n:
        c = text[i]
        if in_line_comment:
            out.append(c)
            if c == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if in_multiline_string:
            out.append(c)
            if text.startswith("\\\\", i):
                out.append(text[i + 1])
                in_multiline_string = False
                i += 2
                continue
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            in_line_comment = True
            out.append(c)
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n and text[i + 1] == "\\":
            in_multiline_string = True
            out.append(c)
            i += 1
            continue
        if c == "*" and i + 1 < n and text[i + 1] == "*":
            out.append(" * ")
            count += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out), count


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    total = 0
    for arg in argv:
        p = Path(arg)
        files = sorted(p.rglob("*.zig")) if p.is_dir() else [p]
        for f in files:
            text = f.read_text(encoding="utf-8")
            new, count = migrate_text(text)
            if count:
                f.write_text(new, encoding="utf-8")
                print(f"{f}: {count} repeats rewritten")
                total += count
    print(f"total: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))