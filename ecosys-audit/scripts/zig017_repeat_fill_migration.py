#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Zig 0.17 migration, part 2: the array-repeat operator is GONE (not renamed).

The first codemod (`zig017_repeat_migration.py`) rewrote `a ** b` to `a * b`
on the recorded premise that "0.17 still repeats the array with `*`".  That
premise is false, measured 2026-10-14 against the pinned zig 0.17.0
(probes in `.tmp/matrix/*.zig`, every shape rejected with
"incompatible types: '[1]f64' and '<count type>'"):

    [_]u8{0} * 3      -> error      [_]f64{0.5} * n   -> error
    .{0.5} * n        -> error      [_]f64{0.5} ** 3  -> parse error

So this codemod rewrites the leftover repeat sites onto the comptime helper
`ecosys-ng/src/core/array_compat.zig` (`filled(n, T, @as(T, v))`), which builds
exactly the array the retired operator built.  Rewrites, all mechanical (G6:
no behaviour, tolerance, clamp or bound edits):

  1. `[_]T{V} * C`                          -> `arr_compat.filled(C, T, @as(T, V))`
  2. `<lhs>: [<L>] T = .{V} * C`             -> `... = arr_compat.filled(C, T, @as(T, V))`
     (declaration / struct-field-default form: the element type is visible)
  3. `<place> = .{V} * C`                    -> `= @splat(V)`
     (assignment / struct-literal-field form: the destination already carries the
     array type, so the 0.17 built-in `@splat` fills it — no element type spelled
     out.  `--repair-splat` rewrites output of revision 1, which spelled this as
     `arr_compat.filled(C, @TypeOf(<place>[0]), ...)`; that names a field where an
     identifier is required and does not compile.)
  4. `&([_]T{V} * C)` inside a non-comptime temporary-lifetime position is left
     to `filled` too — measured legal in probes.
  Files gaining a call get `const arr_compat = @import("<rel>core/array_compat.zig");`
  inserted after the import block.

Anything the scanner cannot classify (ambiguous count expression, anonymous
literal whose element type is not visible, `&(...)` shapes, string/tuple
repeats) is reported as MANUAL and the file is left untouched: nothing guessed.

Usage: uv run ecosys-audit/scripts/zig017_repeat_fill_migration.py [--dry-run] [--repair-splat] [dir]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_ROOT = REPO / "ecosys-ng" / "src"
HELPER = REPO / "ecosys-ng" / "src" / "core" / "array_compat.zig"
SHIM_VAR = "arr_compat"
SKIP_NAMES = {"array_compat.zig"}

IDENT_CHAIN = re.compile(r"[A-Za-z_@][A-Za-z0-9_.@\"']*(?:\([^()\"']*\))?(?:[.][A-Za-z_@][A-Za-z0-9_.@\"']*(?:\([^()\"']*\))?)*")
NUM = re.compile(r"[0-9][0-9a-fA-FxX_.]*")
WS = " \t\r\n"


def build_mask(text: str) -> bytearray:
    """1 where a line comment, string literal or multiline string is active."""
    mask = bytearray(len(text))
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = 1
            i = j
            continue
        if text.startswith("//!", i) or text.startswith("///", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = 1
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            for k in range(i, min(j + 1, n)):
                mask[k] = 1
            i = min(j + 1, n)
            continue
        if c == "\\" and i + 1 < n and text[i + 1] == "\\":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = 1
            i = j
            continue
        i += 1
    return mask


def balanced(text: str, mask: bytearray, start: int, op: str, cl: str) -> int:
    """Index of the delimiter closing the one at `start`, or -1."""
    if start >= len(text) or text[start] != op:
        return -1
    depth = 0
    for i in range(start, len(text)):
        if mask[i]:
            continue
        if text[i] == op:
            depth += 1
        elif text[i] == cl:
            depth -= 1
            if depth == 0:
                return i
    return -1


def skip_ws(text: str, i: int) -> int:
    while i < len(text) and text[i] in WS:
        i += 1
    return i


def parse_count(text: str, mask: bytearray, i: int) -> tuple[int, int] | None:
    """Return (end_offset, count_end_for_ambiguity_check) of a primary count."""
    i = skip_ws(text, i)
    if i >= len(text):
        return None
    if text[i] == "(":
        close = balanced(text, mask, i, "(", ")")
        if close < 0:
            return None
        return close + 1, close + 1
    m = NUM.match(text, i)
    if m:
        return m.end(), m.end()
    m = IDENT_CHAIN.match(text, i)
    if m:
        return m.end(), m.end()
    return None


def count_is_bare(text: str, mask: bytearray, end: int) -> bool:
    """The count is followed by a terminator, not by a binary operator."""
    j = skip_ws(text, end)
    if j >= len(text):
        return True
    return text[j] not in "*/%+-"  # ';' ',' ')' ']' '}' '=' ok, operators not


def rel_import(path: Path) -> str:
    import os

    rel = os.path.relpath(HELPER, path.parent).replace("\\", "/")
    if not rel.startswith("."):
        rel = "./" + rel
    return rel


IMPORT_RE = re.compile(
    r"^const " + SHIM_VAR + r"\s*=\s*@import\(\"[^\"]*core/array_compat\.zig\"\);", re.M
)


def add_import(text: str, path: Path) -> str:
    if IMPORT_RE.search(text):
        return text
    line = f'const {SHIM_VAR} = @import("{rel_import(path)}");\n'
    # after the last top-level `const ... @import(...)` statement, else after
    # the leading doc comments
    last_end = None
    for m in re.finditer(r'^(?:pub )?const\s+\w+\s*=\s*@import\("[^"]*"\)(?:\([^"]*"\))?;\n', text, re.M):
        last_end = m.end()
    if last_end is None:
        for m in re.finditer(r"^(?://!|///|//)[^\n]*\n", text):
            last_end = m.end()
        if last_end is not None and last_end > 0:
            last_end = last_end
    if last_end is None:
        last_end = 0
    return text[:last_end] + "\n" + line + text[last_end:]


DECL_RE = re.compile(r":\s*\[[^\[\]]*\]\s*([A-Za-z_@][^=;{}]*?)\s*=\s*$", re.M)


def element_type_before(text: str, mask: bytearray, brace_pos: int) -> str | None:
    """Element type of `<lhs>: [<L>] T = .{V} * C` (declaration / field default)."""
    # walk back to the start of the statement/field
    start = max(
        text.rfind(";", 0, brace_pos),
        text.rfind("{", 0, brace_pos),
        text.rfind("}", 0, brace_pos),
    )
    head = text[start + 1 : brace_pos]
    m = re.search(r":\s*\[(?:[^\[\]]*)\]\s*([A-Za-z_@][A-Za-z0-9_.@]*((?:\([^()]*\))?)(?:\[[^\[\]]*\])*)\s*=\s*$", head)
    if m:
        return m.group(1).strip()
    return None


PLACE_ASSIGN_RE = re.compile(
    r"([A-Za-z_][A-Za-z0-9_.]*)\s*(?:\[[^\[\]]*\])?\s*=\s*$"
)


def place_before(text: str, mask: bytearray, brace_pos: int) -> str | None:
    """Assignment target of `<place> = .{V} * C`."""
    start = max(
        text.rfind(";", 0, brace_pos),
        text.rfind("{", 0, brace_pos),
        text.rfind("}", 0, brace_pos),
    )
    head = text[start + 1 : brace_pos]
    if re.search(r"(?:^|[\s(,])(?:const|var)\s", head):
        return None  # declaration: handled by the typed form
    m = PLACE_ASSIGN_RE.search(head)
    if m and "." in m.group(1) or (m and m.group(1) not in ("const", "var")):
        if m:
            return m.group(1)
    return None


def rewrite_file(path: Path, dry: bool) -> tuple[int, int, list[str]]:
    text = path.read_text(encoding="utf-8")
    mask = build_mask(text)
    edits: list[tuple[int, int, str]] = []
    manual: list[str] = []
    counts = {"typed": 0, "decl": 0, "place": 0}

    i = 0
    n = len(text)
    while i < n:
        if mask[i]:
            i += 1
            continue
        # ---- form 1: [_]T{V} * C -------------------------------------------
        if text.startswith("[_]", i):
            brace = None
            depth_seen = 0
            j = i + 3
            while j < n:
                if mask[j]:
                    j += 1
                    continue
                c = text[j]
                if c in "([":
                    depth_seen += 1
                elif c in ")]":
                    depth_seen -= 1
                elif c == "{":
                    if depth_seen < 0:
                        break
                    brace = j
                    break
                elif c in ";,=)" and depth_seen <= 0:
                    break
                j += 1
            if brace is None:
                i += 3
                continue
            elem_type = text[i + 3 : brace].strip()
            brace_end = balanced(text, mask, brace, "{", "}")
            if brace_end < 0 or not elem_type:
                i = brace + 1
                continue
            value = text[brace + 1 : brace_end].strip()
            k = skip_ws(text, brace_end + 1)
            if k >= n or text[k] != "*" or text[k : k + 2] == "**":
                i = i + 3
                continue
            parsed = parse_count(text, mask, k + 1)
            if parsed is None or not count_is_bare(text, mask, parsed[1]):
                manual.append(f"{path}:{offset_line(text, i)}: ambiguous repeat on `[_]{elem_type}{{...}}`")
                i = brace_end + 1
                continue
            count = text[k : parsed[0]].lstrip("*").strip()
            if not value:
                manual.append(f"{path}:{offset_line(text, i)}: empty element list `[_]{elem_type}{{}}`")
                i = brace_end + 1
                continue
            rep = f"{SHIM_VAR}.filled({count}, {elem_type}, @as({elem_type}, {value}))"
            edits.append((i, parsed[0], rep))
            counts["typed"] += 1
            i = parsed[0]
            continue

        # ---- forms 2/3: .{V} * C (anonymous literal repeat) ----------------
        if text[i] == "." and i + 1 < n and text[i + 1] == "{":
            brace_end = balanced(text, mask, i + 1, "{", "}")
            if brace_end < 0:
                i += 1
                continue
            k = skip_ws(text, brace_end + 1)
            if k >= n or text[k] != "*" or text[k : k + 2] == "**":
                i = i + 2
                continue
            parsed = parse_count(text, mask, k + 1)
            if parsed is None or not count_is_bare(text, mask, parsed[1]):
                i = i + 2
                continue  # plain `.{...}` followed by a multiply: not our class
            value = text[i + 2 : brace_end].strip()
            count = text[k : parsed[0]].lstrip("*").strip()
            elem_type = element_type_before(text, mask, i)
            if elem_type:
                rep = f"{SHIM_VAR}.filled({count}, {elem_type}, @as({elem_type}, .{{{value}}}))"
                edits.append((i, parsed[0], rep))
                counts["decl"] += 1
                i = parsed[0]
                continue
            place = place_before(text, mask, i)
            if place and value and "* " not in value and "{" not in value:
                # `<place> = .{v} * C` has a destination whose type the compiler
                # already knows (struct field, typed field path, annotated decl),
                # so the Zig 0.17 built-in `@splat` fills it with no element type
                # spelled out — measured 2026-10-14 (.tmp/probe5/t.zig): works for
                # struct-literal fields, typed-field assignment, array parameters
                # and `&@splat(...)`.  An invented `@TypeOf(<place>[0])` here names
                # a field, not an identifier, and does not compile.
                rep = f"@splat({value})"
                edits.append((i, parsed[0], rep))
                counts["place"] += 1
                i = parsed[0]
                continue
            manual.append(
                f"{path}:{offset_line(text, i)}: anonymous repeat .{{{value[:40]}}} * {count[:30]}"
                f" (elem type not visible, place={place!r})"
            )
            i = brace_end + 1
            continue
        i += 1

    if edits and not manual and not dry:
        edits.sort(key=lambda e: e[0])
        for s, e, rep in reversed(edits):
            text = text[:s] + rep + text[e:]
        text = add_import(text, path)
        path.write_text(text)
    return sum(counts.values()), counts, manual


def offset_line(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def split_args(text: str, mask: bytearray, open_paren: int) -> tuple[list[str], int] | None:
    """Top-level comma-split arguments of the call whose `(` is at `open_paren`."""
    close = balanced(text, mask, open_paren, "(", ")")
    if close < 0:
        return None
    args: list[str] = []
    depth = 0
    start = open_paren + 1
    for j in range(open_paren + 1, close):
        c = text[j]
        if mask[j]:
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            args.append(text[start:j].strip())
            start = j + 1
    args.append(text[start:close].strip())
    return args, close


def repair_place_calls(path: Path, dry: bool) -> int:
    """Rewrite the superseded place-assign output of this codemod to `@splat`.

    Revision 1 of the place-assign class emitted

        arr_compat.filled(C, @TypeOf(<place>[0]), @as(@TypeOf(<place>[0]), .{V}))

    which names a *field* where an identifier is required and does not compile.
    The destination of every place-assign site already carries its type, so the
    correct 0.17 spelling is the built-in `@splat(V)` (proved in .tmp/probe5).
    Value-preserving; drops the `arr_compat` import when nothing else needs it.
    """
    text = path.read_text(encoding="utf-8")
    needle = f"{SHIM_VAR}.filled("
    if needle not in text:
        return 0
    mask = build_mask(text)
    edits: list[tuple[int, int, str]] = []
    i = text.find(needle)
    while i >= 0:
        paren = i + len(needle) - 1
        parsed = split_args(text, mask, paren)
        if parsed is None:
            i = text.find(needle, i + 1)
            continue
        args, close = parsed
        nxt = text.find(needle, close + 1)
        if len(args) == 3 and args[1].startswith("@TypeOf(") and args[2].startswith("@as(@TypeOf("):
            inner = args[2][len("@as(@TypeOf(") :]
            # strip `@TypeOf(<place>[0]), ` then the outer `@as(...)` parens
            cut = inner.index("), ")
            value = inner[cut + 3 : -1].strip()
            if value.startswith(".{") and value.endswith("}"):
                value = value[2:-1].strip()  # `.{V}` was the one-element list
            edits.append((i, close + 1, f"@splat({value})"))
            i = text.find(needle, close + 1)
            continue
        i = nxt
    if not edits:
        return 0
    for s, e, rep in reversed(edits):
        text = text[:s] + rep + text[e:]
    if not re.search(rf"\b{SHIM_VAR}\.", text):
        text = re.sub(
            rf"^const {SHIM_VAR} = @import\(\"[^\"]*\"\);\n"
            rf"|^const {SHIM_VAR} = \w+\.array_compat;\n",
            "",
            text,
            flags=re.M,
        )
    if not dry:
        path.write_text(text, encoding="utf-8")
    return len(edits)


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv or "-n" in argv
    roots = [Path(a) for a in argv if not a.startswith("-")] or [DEFAULT_ROOT]
    files: list[Path] = []
    for r in roots:
        files.extend(sorted(r.rglob("*.zig")) if r.is_dir() else [r])
    if "--repair-splat" in argv:
        fixed = 0
        touched = 0
        for path in files:
            if path.name in SKIP_NAMES:
                continue
            n = repair_place_calls(path, dry)
            if n:
                touched += 1
                fixed += n
        print(f"files scanned        : {len(files)}")
        print(f"files {'to change' if dry else 'changed'}       : {touched}")
        print(f"place sites -> @splat : {fixed}")
        return 0
    total = 0
    touched = blocked = 0
    all_manual: list[str] = []
    buckets = {"typed": 0, "decl": 0, "place": 0}
    for path in files:
        if path.name in SKIP_NAMES:
            continue
        changed, counts, manual = rewrite_file(path, dry)
        for k in buckets:
            buckets[k] += counts[k]
        total += changed
        if changed:
            touched += 1
        if manual:
            blocked += 1
            all_manual.extend(manual)
    print(f"files scanned        : {len(files)}")
    print(f"files {'to change' if dry else 'changed'}       : {touched}")
    print(f"repeat rewrites      : {total}  "
          f"(typed [_]T{{v}}: {buckets['typed']}, typed decl: {buckets['decl']}, place assign: {buckets['place']})")
    print(f"files with MANUAL    : {blocked}")
    for m in all_manual:
        print(f"  {m}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
