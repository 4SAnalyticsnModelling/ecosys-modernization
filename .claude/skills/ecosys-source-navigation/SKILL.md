---
name: ecosys-source-navigation
description: Navigate and audit the legacy ECOSYS Fortran 77 source and its traceability evidence using the f77index tooling. Use when you need to read, locate, or reason about anything in f77src/ (routines, COMMON state, loops, equations), when you need a coverage or binding number for a gate, or when you need a matched-state legacy oracle for a routine. Always prefer these tools over reading a .f file directly -- the routines are up to 13,179 lines each.
---

# ECOSYS source navigation and audit tooling

Five read-only tools in `ecosys-audit/scripts/`. Run every one with `uv run` from the
project root so the interpreter is pinned (PATH `python` on this host is MSYS2 3.12 and is
not what these scripts are validated against). All are stdlib-only with PEP 723 headers.

Verified commands live in `audit/manifest/command_registry.json` under `analysis`. Prefer
copying an argv from there over composing your own.

## Why not just read the file

`f77src/` is one enormous program unit per file. `REDIST` is 13,094 lines in a single
subroutine, `GROSUB` 13,179, `TRNSFRS` 9,748. The call graph is almost empty -- REDIST,
GROSUB and TRNSFR make zero calls -- so call-graph navigation tells you nothing. The real
skeleton is the DO-loop nest plus the prose comment runs, which is what `outline` renders.
Reading a whole routine burns context for no benefit.

## Build the index first

```
uv run ecosys-audit/scripts/f77index.py --root . --out audit/manifest/f77index.json
```

It refuses to overwrite existing evidence; delete the file to rebuild. Rebuild after any
change to `f77src/`. Confirm `totals.unclosed_loops == 0`.

## Navigate: f77query.py

```
uv run ecosys-audit/scripts/f77query.py units                       # all units, largest first
uv run ecosys-audit/scripts/f77query.py outline grosub.f --depth 1  # 13,179 lines -> ~109
uv run ecosys-audit/scripts/f77query.py outline uptake.f --sections all
uv run ecosys-audit/scripts/f77query.py loops uptake.f              # every loop + span
uv run ecosys-audit/scripts/f77query.py show grosub.f --loop 2990   # one loop body
uv run ecosys-audit/scripts/f77query.py show redist.f --lines 6870-6900
uv run ecosys-audit/scripts/f77query.py common BLK13A --users       # state + who declares it
uv run ecosys-audit/scripts/f77query.py grep 'ZNH4FA\(' --limit 40  # hits with loop context
uv run ecosys-audit/scripts/f77query.py stats                       # dialect + parameters
```

`outline` shows prose comment runs by default. `--sections all` adds variable glossaries
and dormant commented-out code (1,503 such runs exist tree-wide and stay in the audit
inventory per the contract). `grep` reports the enclosing unit and innermost DO loop for
every hit, which is usually the context you actually wanted.

## Coverage and bindings

```
uv run ecosys-audit/scripts/tracecov.py  --root . --out audit/traceability/coverage-<date>.json
uv run ecosys-audit/scripts/bindcheck.py --root . --out audit/manifest/bindcheck-<date>.json
```

`tracecov.py` joins `audit/traceability/traceability.csv` against the index and computes
statement coverage over the in-build legacy scope, plus stale-hash and broken-path
problems. Exit 1 means a report was produced but something blocks a gate. It excludes
out-of-build files from both numerator and denominator.

`bindcheck.py` inventories all 2,970 COMMON members with the type the legacy build
actually produced, and reports whether each name occurs in Zig code, only in Zig comments,
or nowhere. Treat it as a worklist for `bindings.csv`, not as coverage: the port renames
fields, so an absent name is not proof of missing state, and a present name is not proof
of a correct translation.

## Matched-state legacy oracle

```
uv run ecosys-audit/scripts/kernelgen.py STOMATE --root . --scope referenced
pwsh -NoProfile -File audit/tests/kernels/kernel_stomate.build.ps1
```

Emits a driver that restores the routine's COMMON state from a snapshot, calls the routine
once, and dumps the post-call state, plus a `.layout.json` giving every item's type,
extents, byte offset and order so the Zig side can read the identical stream.

**Check the reported snapshot size before generating data.** `--scope referenced` (default)
dumps only members the routine mentions; STOMATE is 35 MB per side. `--scope included`
dumps every member of every included block, which for UPTAKE is ~237 MB per side. Full
COMMON state is ~258 MB.

This is the legacy half only. It deliberately does not generate the Zig counterpart,
because the correspondence must come from the binding register, not from name matching.

## Dialect facts you must not rediscover

Recorded in `dialect` in the index. Summarised here because getting these wrong silently
produces wrong science:

- Fixed form, code in columns 7-72. No code anywhere in the tree extends past column 72.
- `ifort -r8 -i4`, and **no `IMPLICIT` statement exists anywhere**. So Fortran 77 default
  typing is in force everywhere and every implicitly-typed real is **f64**, not f32.
  Compare against `f64`.
- Array lower bounds are frequently 0, not 1 (`ORGC(0:JZ,JY,JX)`). Fortran is column-major.
- `ifort` is not installed here. gfortran 16.1.0 reproduces the precision contract only;
  it is not ifort-identical code generation.
- gfortran 16 implements the Fortran 2023 `SPLIT` intrinsic, which shadows this project's
  own `split.f`. `soil.f` therefore fails with "Too many arguments in call to split" even
  though the call is correct -- `split.f` declares 10 arguments and `soil.f` passes 10. Add
  `EXTERNAL split` after that unit's header (use `header_line_end`, not `line_start`; five
  units have continued headers) or compile that one unit with `-std=f95`.
- `f77src/redist_utf8.f` is a full 13,094-line duplicate of `redist.f` that the makefile
  never builds. It is not the reference. The index marks it `in_build: false` and
  `f77query` warns when you navigate into it.

## What these tools do not do

They parse text. They do not compile the model, prove semantic equivalence, verify units
or index order, or make a gate decision. `check_gate.py` owns gate status; a coverage
percentage is not a pass. Every tool prints its own `limitations` in its JSON output --
quote those alongside any number you report.
