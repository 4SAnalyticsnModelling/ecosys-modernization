#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Zig 0.17 migration, part 2c: an array whose address escapes must stay a
comptime-known *expression*, so `array_compat.filled(...)` becomes `@as([n]T, @splat(v))`.

Why (measured 2026-10-14, zig 0.17.0, probe `.tmp/probe7/esc.zig` and
`.tmp/probe7/splat_addr.zig`, failure receipt `audit/runs/zig017-test-20261014-2`):

Zig gives a local `const` whose initialiser is a comptime-known *expression*
(static promotion / rodata) the address it needs, and a local whose initialiser
is a *runtime* value a stack slot.  Handing that stack slot back to the caller
is dangling, and 0.17 does not always reject it: it reads whatever bytes are
left on the stack.  Concretely, in

    const values = arr_compat.filled(6, f64, @as(f64, 1));   // function call
    return .{ .fixed_dinitrogen_g_n = &values };              // address escapes

the call is not folded at comptime inside a runtime function, so `&values` is a
dangling stack address and the callee reads denormal garbage (-8.9e-310 where
1.0 was expected).  The 0.16 source spelled the same thing as a literal,

    const values = [_]f64{1} ** 6;

which *is* comptime-known, was statically promoted, and was safe.  Part 2 of the
migration (`zig017_repeat_fill_migration.py`) turned that literal into a call
and silently changed its storage class.  Three
`soil.biogeochemistry.transformation_aggregation` tests reproduced it; the class
is silent, so the whole call set is moved back onto a comptime-known expression.

`@as([n]T, @splat(v))` is the 0.17 spelling of the retired `[_]T{v} ** n`
literal: same array type, same element type, same values, and it folds at
comptime exactly like the literal did (`@splat` also survives wide comptime
fills, where a `for` loop hits the 1000-backwards-branch limit).  Probes:

    @as([6]f64, @splat(@as(f64, 1)))   address escapes        -> {1,1,1,1,1,1}
    @as([4]f64, @splat(rt))            runtime operand        -> {rt,rt,rt,rt}
    @as([2]f64, @splat(0.5))           untyped literal coerce -> {0.5,0.5}
    @as([3]usize, @splat(3))           untyped literal coerce -> {3,3,3}
    @as([2]bool, @splat(true))         bool                   -> {true,true}
    @as([2]F, @splat(.{ .x = 1 }))     struct anon literal    -> ok
    @as([2]F, @splat(@as(F, .{...})))  nested/struct          -> ok
    @as([0]f64, @splat(@as(f64, 1)))   zero length            -> ok
    @as([2][]f64, @splat(&arr))        slice elements         -> ok

Where `v` is a *runtime* value and the array's address escapes, the rewrite is
still the right thing: the compiler now sees the escape and reports it instead
of letting the read dangle.

Rewrites (all mechanical, G6: no behaviour, tolerance, clamp or bound edits):

  1. `ALIAS.filled(N, T, V)`    -> `@as([N]T, @splat(V))`
     Only qualified calls with exactly three arguments are touched, so the
     unrelated 2-argument local helper `fn filled(comptime T: type, value: f64) T`
     (erosion modules) is never matched.
  2. `--prune-imports`: drop the `const <alias> = @import(".../array_compat.zig");`
     line of a file that no longer mentions the alias (an unused *local* import
     is a compile error in Zig).

`filled`/`filledRef` stay in `src/core/array_compat.zig`: `filledRef` remains the
`&([_]T{v} ** n)` shape (its own `comptime value` keeps it comptime-known), and
the doc block records this trap.  Anything the scanner cannot parse — a
non-balanced call, a call that is not qualified, an argument count that is not
3, a length or element-type argument containing brackets (ambiguous inside
`[N]T`) — is reported as MANUAL and left untouched: nothing guessed.

Usage:
  uv run ecosys-audit/scripts/zig017_fill_escape_migration.py [--dry-run] [--prune-imports] [dir]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

IMPORT_RE = re.compile(
    r'^([ \t]*)const ([A-Za-z_][A-Za-z0-9_]*) = @import\("[^"]*array_compat\.zig"\);[ \t]*$',
    re.MULTILINE,
)
CALL_RE = re.compile(r"(?:\b[A-Za-z_][A-Za-z0-9_]*\.)+filled\(")

OPENERS = {"(": ")", "[": "]", "{": "}"}
CLOSERS = set(OPENERS.values())


def skip_string(src: str, i: int) -> int:
    """Return the index just past the string/char literal starting at src[i]."""
    quote = src[i]
    i += 1
    while i < len(src):
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == quote:
            return i + 1
        i += 1
    return i


def scan(src: str, starts: list[tuple[int, int]]) -> list[tuple[int, int, list[str]]]:
    """For each (call_start, paren_start) return (call_start, end, [args])."""
    out: list[tuple[int, int, list[str]]] = []
    for call_start, paren in starts:
        i = paren
        depth = 0
        args: list[str] = []
        cur = i + 1
        ok = False
        while i < len(src):
            c = src[i]
            if c == "/" and src.startswith("//", i):
                nl = src.find("\n", i)
                i = len(src) if nl < 0 else nl
                continue
            if c in "\"'":
                # triple-quoted string
                if src.startswith('"""', i):
                    end = src.find('"""', i + 3)
                    i = len(src) if end < 0 else end + 3
                    continue
                i = skip_string(src, i)
                continue
            if c in OPENERS:
                depth += 1
                i += 1
                continue
            if c in CLOSERS:
                depth -= 1
                if depth == 0:
                    if c != ")":
                        ok = False
                        break
                    args.append(src[cur:i])
                    out.append((call_start, i + 1, args))
                    ok = True
                    i += 1
                    break
                i += 1
                continue
            if c == "," and depth == 1:
                args.append(src[cur:i])
                cur = i + 1
            i += 1
        if not ok:
            out.append((call_start, -1, []))
    return out


def one_line(text: str) -> str:
    return " ".join(text.split())


def rewrite_file(path: Path, dry_run: bool, prune_imports: bool) -> tuple[int, int, list[str]]:
    src = path.read_text(encoding="utf-8")
    manual: list[str] = []
    skipped_local = 0
    starts: list[tuple[int, int]] = []
    for m in CALL_RE.finditer(src):
        # never rewrite the helper definition itself or a qualified def
        line_start = src.rfind("\n", 0, m.start()) + 1
        prefix = src[line_start : m.start()]
        if prefix.lstrip().startswith("pub fn ") or prefix.lstrip().startswith("fn "):
            continue
        starts.append((m.start(), m.end() - 1))
    calls = scan(src, starts)
    # A call nested inside another matched call is left MANUAL: the outer rewrite
    # replaces the whole span, so the two edits would overlap and drift (measured
    # 2026-10-14: revision 1 mangled src/surface/autotrophic_complex_step.zig:570
    # exactly that way).  Both known sites are hand-rewritten.
    good = [(s, e) for s, e, a in calls if e > 0]
    nested = {(s, e) for s, e in good for s2, e2 in good if s2 < s and e < e2}
    edits: list[tuple[int, int, str]] = []
    for call_start, end, args in calls:
        if end < 0:
            manual.append(f"{path}: unbalanced call at offset {call_start}")
            continue
        if (call_start, end) in nested:
            manual.append(
                f"{path}: nested call at offset {call_start}: {src[call_start:min(end, call_start + 90)]}"
            )
            continue
        call_text = src[call_start:end]
        if len(args) == 3 and not args[-1].strip():
            args = args[:-1]  # trailing comma: `filled(T, v,)` is a 2-argument call
        if len(args) != 3:
            # The unrelated 2-argument local helper `fn filled(comptime T: type, value: f64) T`
            # in the erosion/reaction modules is a different function: never touched.
            if len(args) > 3:
                manual.append(f"{path}: {len(args)} args at offset {call_start}: {one_line(call_text)[:90]}")
            else:
                skipped_local += 1
            continue
        n_raw, t_raw, v_raw = (a.strip() for a in args)
        if not n_raw or not t_raw or not v_raw:
            manual.append(f"{path}: empty argument at offset {call_start}: {call_text[:90]}")
            continue
        # `[N]T` is unambiguous when only T carries brackets — nested arrays are legal
        # (`@as([7][2]f64, @splat(@as([2]f64, .{0, 0})))`, probe `.tmp/probe7/nested.zig`);
        # a bracketed *length* would be ambiguous, so that one is left MANUAL.
        if any(ch in n_raw for ch in "[]"):
            manual.append(f"{path}: bracketed length at offset {call_start}: {call_text[:90]}")
            continue
        repl = f"@as([{one_line(n_raw)}]{one_line(t_raw)}, @splat({one_line(v_raw)}))"
        edits.append((call_start, end, repl))
    out = src
    for start, end, repl in sorted(edits, key=lambda e: e[0], reverse=True):
        out = out[:start] + repl + out[end:]
    pruned = 0
    if prune_imports:
        for m in reversed(list(IMPORT_RE.finditer(out))):
            alias = m.group(2)
            body = out[: m.start()] + out[m.end() :]
            if re.search(rf"\b{re.escape(alias)}\b", body):
                continue
            out = out[: m.start()] + out[m.end() + 1 :]
            pruned += 1
    n = len(edits) + pruned
    if n and out != src and not dry_run:
        path.write_text(out, encoding="utf-8")
    return n, skipped_local, manual


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--prune-imports", action="store_true")
    ap.add_argument("target", nargs="?", default="ecosys-ng/src")
    args = ap.parse_args()

    root = Path(args.target)
    files = sorted(p for p in root.rglob("*.zig") if p.is_file() and p.name != "array_compat.zig")
    total = 0
    touched = 0
    local = 0
    manual: list[str] = []
    for path in files:
        n, s, m = rewrite_file(path, args.dry_run, args.prune_imports)
        if n:
            total += n
            touched += 1
        local += s
        manual.extend(m)
    mode = "dry-run" if args.dry_run else "written"
    print(
        f"{mode}: {total} rewrites in {touched} files under {root} "
        f"(prune_imports={args.prune_imports}); {local} local-helper calls left alone"
    )
    if manual:
        print(f"MANUAL ({len(manual)}):")
        for line in manual:
            print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
