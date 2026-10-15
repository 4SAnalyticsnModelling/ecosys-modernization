#!/usr/bin/env python3
"""Cycle-1 Zig 0.17 migration: mechanical `@typeInfo`/`std.meta.fields` rewrites.

Zig 0.17 removed `std.builtin.Type.StructField` / `EnumField` and
`std.meta.fields`; `std.lang.Type` now carries parallel slices
(`field_names`, `field_types`, `field_values`).  This codemod rewrites, with
zero behavior change (G6: mechanical only):

  1. `@typeInfo(ARG).@"struct"|"union".fields` used as loop iterable,
     initializer, or argument  ->  `ti_compat.fieldViews(ARG)`
  2. `@typeInfo(ARG).@"enum".fields` in the same positions
     ->  `ti_compat.enumFieldViews(ARG)`
  3. `...@"struct"|"union"|"enum".fields.len`  ->  `...field_names.len`
  4. `...fields[I].name|.type|.value`  ->  `field_names[I]` / `field_types[I]`
     / `field_values[I]` (member token dropped)
  5. `std.meta.fields(ARG)`  ->  `ti_compat.fieldViews(ARG)`
  6. `pointer.is_const` / `pointer_info.is_const` (typeInfo Pointer payload)
     ->  `attrs.@"const"` in the three surveyed snapshot/rollback files
  7. Adds `const ti_compat = @import("<rel>core/typeinfo_compat.zig");` after
     the import block of every file that gained a shim call.

Comment and string literals are masked; matches inside them are ignored.
Any `.fields` occurrence NOT covered by a recognized rewrite (prong-capture
loops like `.@"struct" => |s|` + `s.fields`, alias bindings, odd contexts) is
reported as MANUAL and blocks all writes to that file.  Nothing is guessed.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "ecosys-ng" / "src"
CORE = SRC / "core"

SKIP_FILES = {"typeinfo_compat.zig"}
SHIM_VAR = "ti_compat"

IS_CONST_FILES = {
    "hourly_geometry_disturbance.zig",
    "hourly_heat_water_solute.zig",
    "outer_hour_transaction.zig",
}

PRONG_RE = re.compile(r'\.\s*@"(struct|union|enum)"')
FIELDS_RE = re.compile(r"\.\s*fields\b")
LEN_RE = re.compile(r"\.\s*len\b")
MEMBER_RE = re.compile(r"\.\s*(name|type|value)\b")
CALL_START_RE = re.compile(r"@typeInfo\s*\(|std\.meta\.fields\s*\(")


def build_mask(text: str) -> bytearray:
    """True where a line comment, string, or multiline string is active."""
    mask = bytearray(len(text))
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            mask[i] = 1
            if c == "\\":
                if i + 1 < n:
                    mask[i + 1] = 1
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            mask[i] = 1
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = 1
            i = j
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


def balanced_delim(text: str, mask: bytearray, open_idx: int, open_c: str, close_c: str) -> int:
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        if mask[i]:
            i += 1
            continue
        c = text[i]
        if c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def rel_shim_import(path: Path) -> str:
    target = os.path.relpath(CORE / "typeinfo_compat.zig", path.parent)
    return f'const {SHIM_VAR} = @import("{target}");'


def add_import(text: str, path: Path) -> str:
    if f"{SHIM_VAR} = @import(" in text:
        return text
    lines = text.splitlines(keepends=True)
    last_import = -1
    for idx, line in enumerate(lines[:200]):
        if re.match(r"^(pub )?const \w+ = @import\(", line):
            last_import = idx
    insertion = rel_shim_import(path) + "\n"
    if last_import < 0:
        return insertion + text
    lines.insert(last_import + 1, insertion)
    return "".join(lines)


def rewrite_file(path: Path) -> tuple[int, int, list[str]]:
    """Returns (shim_calls, other_edits, manual_notes) for one file."""
    text = path.read_text()
    manual: list[str] = []
    mask = build_mask(text)

    edits: list[tuple[int, int, str]] = []
    covered: list[tuple[int, int]] = []
    shim_calls = 0
    other_edits = 0

    def note(msg: str) -> None:
        manual.append(f"{path.relative_to(REPO)}: {msg}")

    def covers(pos: int) -> bool:
        return any(s <= pos < e for s, e in covered)

    # --- recognized rewrites -----------------------------------------------
    for m in CALL_START_RE.finditer(text):
        if mask[m.start()]:
            continue
        open_idx = text.index("(", m.start())
        close = balanced_delim(text, mask, open_idx, "(", ")")
        if close < 0:
            note(f"unbalanced parens at offset {m.start()}")
            continue
        arg = text[open_idx + 1 : close]
        if text[m.start() : open_idx].startswith("std.meta.fields"):
            edits.append((m.start(), close + 1, f"{SHIM_VAR}.fieldViews({arg})"))
            covered.append((m.start(), close + 1))
            shim_calls += 1
            continue
        pm = PRONG_RE.match(text, close + 1)
        if pm is None:
            continue
        kind = pm.group(1)
        j2 = pm.end()
        fm = FIELDS_RE.match(text, j2)
        if fm is None:
            continue
        j3 = fm.end()

        lm = LEN_RE.match(text, j3)
        if lm is not None:
            edits.append((j2, j3, ".field_names"))
            covered.append((j2, j3))
            other_edits += 1
            continue

        if text[j3 : j3 + 1] == "[":
            bracket_end = balanced_delim(text, mask, j3, "[", "]")
            if bracket_end < 0:
                note(f"unbalanced [ at offset {j3}")
                continue
            content = text[j3 + 1 : bracket_end]
            if ".." in content:
                # Slice of the retired fields array (e.g. `.fields[1..]`):
                # slice the reconstructed views instead so the loop payload
                # keeps carrying both `name` and `type`.
                shim = (
                    f"{SHIM_VAR}.enumFieldViews({arg})"
                    if kind == "enum"
                    else f"{SHIM_VAR}.fieldViews({arg})"
                )
                edits.append((m.start(), j3, shim))
                covered.append((m.start(), j3))
                shim_calls += 1
                continue
            mm = MEMBER_RE.match(text, bracket_end + 1)
            if mm is None:
                note(f"indexed .fields without .name/.type/.value at offset {j3}")
                continue
            member = mm.group(1)
            table = (
                {"name": "field_names", "value": "field_values"}
                if kind == "enum"
                else {"name": "field_names", "type": "field_types"}
            )
            slice_name = table.get(member)
            if slice_name is None:
                note(f"unsupported indexed member .{member} at offset {j3}")
                continue
            edits.append((j2, j3, "." + slice_name))
            edits.append((bracket_end + 1, mm.end(), ""))
            covered.append((j2, j3))
            covered.append((bracket_end + 1, mm.end()))
            other_edits += 1
            continue

        nxt = text[j3 : j3 + 1]
        if nxt in (")", ";", ","):
            shim = (
                f"{SHIM_VAR}.enumFieldViews({arg})" if kind == "enum" else f"{SHIM_VAR}.fieldViews({arg})"
            )
            edits.append((m.start(), j3, shim))
            covered.append((m.start(), j3))
            shim_calls += 1
            continue

        note(f"unrecognized context after .fields at offset {j3}: {text[j3:j3+48]!r}")

    # --- prong-capture loops: `.@"struct" => |s| ... s.fields` --------------
    prong_cap_re = re.compile(r'\.\s*@"(struct|union|enum)"\s*=>\s*\|(\w+)\|')
    # Reverse text order: a nested prong that reuses the same capture ident
    # must claim its own `.fields` before an outer prong's reach span does.
    for pm in reversed(list(prong_cap_re.finditer(text))):
        if mask[pm.start()]:
            continue
        kind, ident = pm.group(1), pm.group(2)
        # Reach span: the first balanced { or ( after the capture (the prong
        # body block, or the header parens of `inline for (... )`), else a
        # short linear cap for single-expression prongs.
        reach_lo = reach_hi = None
        for k in range(pm.end(), min(len(text), pm.end() + 200)):
            if mask[k]:
                continue
            c = text[k]
            if c in "({":
                close_c = ")" if c == "(" else "}"
                close_idx = balanced_delim(text, mask, k, c, close_c)
                if close_idx < 0:
                    break
                reach_lo, reach_hi = k, close_idx + 1
                break
        if reach_lo is None:
            reach_lo, reach_hi = pm.end(), min(len(text), pm.end() + 200)
        target_re = re.compile(r"\b" + re.escape(ident) + r"\s*\.\s*fields\b")
        for hit in target_re.finditer(text, reach_lo, reach_hi):
            if covers(hit.start()):
                continue
            shim = (
                f"{SHIM_VAR}.enumFieldViewsFromInfo({ident})"
                if kind == "enum"
                else f"{SHIM_VAR}.fieldViewsFromInfo({ident})"
            )
            edits.append((hit.start(), hit.end(), shim))
            covered.append((hit.start(), hit.end()))
            other_edits += 1

    # --- safety net: any other `.fields` token is manual --------------------
    for m in FIELDS_RE.finditer(text):
        if mask[m.start()] or covers(m.start()):
            continue
        ctx = text[max(0, m.start() - 70) : m.end() + 30].replace("\n", "\\n")
        note(f"residual .fields (prong capture or alias?) offset {m.start()}: ...{ctx!r}...")

    if manual:
        return shim_calls, other_edits, manual

    if not edits:
        if path.name in IS_CONST_FILES:
            new_text, n_sub = re.subn(
                r"\b(pointer|pointer_info)\.is_const\b", r'\1.attrs.@"const"', text
            )
            if n_sub:
                path.write_text(new_text)
                return shim_calls, n_sub, manual
        return shim_calls, other_edits, manual

    # --- overlap guard, then apply (offsets all refer to original text) -----
    edits.sort(key=lambda e: (e[0], -e[1]))
    applied: list[tuple[int, int, str]] = []
    last_end = -1
    for s, e, rep in edits:
        if s < last_end:
            note(f"overlapping edits at offset {s}; skipped")
            continue
        applied.append((s, e, rep))
        last_end = e
    if manual:
        return shim_calls, other_edits, manual

    for s, e, rep in reversed(applied):
        text = text[:s] + rep + text[e:]

    # --- pointer payload is_const moved under attrs (0.17) ------------------
    if path.name in IS_CONST_FILES:
        text, n_sub = re.subn(r"\b(pointer|pointer_info)\.is_const\b", r'\1.attrs.@"const"', text)
        other_edits += n_sub

    if f"{SHIM_VAR}." in text:
        text = add_import(text, path)

    path.write_text(text)
    return shim_calls, other_edits, manual


def main() -> int:
    files = sorted(p for p in SRC.rglob("*.zig") if p.name not in SKIP_FILES)
    total_shim = total_other = 0
    touched = 0
    blocked = 0
    all_manual: list[str] = []
    for path in files:
        shim_calls, other_edits, manual = rewrite_file(path)
        total_shim += shim_calls
        total_other += other_edits
        if shim_calls or other_edits:
            touched += 1
        if manual:
            blocked += 1
        all_manual.extend(manual)
    print(f"files scanned: {len(files)}")
    print(f"files modified: {touched}")
    print(f"files blocked (manual): {blocked}")
    print(f"shim call rewrites: {total_shim}")
    print(f"in-place slice rewrites + is_const: {total_other}")
    if all_manual:
        print("MANUAL items:")
        for note_txt in all_manual:
            print(f"  {note_txt}")
    else:
        print("MANUAL items: none")
    return 0


if __name__ == "__main__":
    sys.exit(main())