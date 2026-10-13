# Zig 0.17 migration — work order for the next cycle

**Mandate (`.agent/protocol.md` §8, gate G1):** `ecosys-ng` is built, tested and benchmarked with
**Zig 0.17.x. Zig 0.16 is retired.** No build, test, benchmark or parity evidence produced with a 0.16
compiler may be cited as current after this migration closes; it stays valid only as dated history.

This file is a *work order*, not a result. **Nothing here has been executed**: the tree is still on the
0.16-era build description and the migration is one full cycle of work (compile, test, re-establish parity).
It is the first item in `.agent/backlog.md`.

## Current state (recorded 2026-10-09, preflight)

| Fact | Value | Proof |
| --- | --- | --- |
| Installed compiler | `/opt/homebrew/bin/zig` → `0.17.0` | `uv run ecosys-audit/scripts/preflight.py` → `zig-version PASS` |
| `ecosys-ng/build.zig.zon` | `minimum_zig_version = "0.16.0"` | preflight → `build-zon-pin FAIL` |
| Source tree | untouched (no migration applied) | `git status` clean under `ecosys-ng/src/` |
| Prior probe builds (2026-10-08, both exit 1) | stopped at the first 0.17 parse error | `audit/runs/zig017-debug-migration-20261008/receipt.json`, `audit/runs/zig017-debug-migration-20261008-attempt2/receipt.json` |

## Known 0.17 breakages (proven, not guessed)

1. **`build.zig`: `std.Build.args` is gone.** The old `if (b.args) |args| run_cmd.addArgs(args);` line in
   the `run` step must be deleted: Zig 0.17's build runner applies `--` passthrough arguments to the
   executed `Run` step itself. Nothing else in `build.zig` is known to break.
2. **`**` array-repeat operator is gone.** 0.17 parses `a ** b` as two `*` operators, so
   `[_]f64{0} ** n` is a parse error ("binary operator '*' has whitespace on one side, but not the other";
   first hit: `src/ecosys_ng.zig:8142`) and must be spelled `[_]f64{0} * n`.
   Codemod + probe evidence: `ecosys-audit/scripts/zig017_repeat_migration.py` (rewrites `**` → ` * `,
   skipping strings/comments; verified that `[_]u8{0} * 3` still repeats the array).
   Run it over `ecosys-ng/src`, then `zig fmt`, and **diff-review every touched line count** — the token is
   unambiguous, but the size of the change must be recorded. Start with
   `uv run ecosys-audit/scripts/zig017_repeat_migration.py --dry-run ecosys-ng/src` (writes nothing).
   Measured 2026-10-12 at this commit: **1197 `**` repeats in 188 files** under `ecosys-ng/src`; re-run the
   dry-run at the start of the migration cycle and treat a different number as a change in scope.
3. **Expect more.** Anything the compiler rejects next is part of this same migration: fix it forward, fix it
   in the same cycle, and list each language/API change you hit in the cycle file. Never "fix" it by keeping
   or reinstalling a 0.16 compiler, and never gate a 0.17 result against 0.16 evidence.

## Procedure (one cycle)

```bash
./sync-main.sh pull
mkdir -p .tmp .cache .uv-cache ecosys-ng/.zig-cache ecosys-ng/.zig-cache-global
export TMPDIR="$PWD/.tmp" XDG_CACHE_HOME="$PWD/.cache" UV_CACHE_DIR="$PWD/.uv-cache" \
       ZIG_GLOBAL_CACHE_DIR="$PWD/ecosys-ng/.zig-cache-global"

# 1. declare the toolchain
#    ecosys-ng/build.zig.zon: minimum_zig_version = "0.17.0"
# 2. fix build.zig (delete the b.args passthrough line)
# 3. apply the `**` codemod, then format
uv run ecosys-audit/scripts/zig017_repeat_migration.py ecosys-ng/src
cd ecosys-ng && zig fmt src && cd ..

# 4. compile, in the repo, with repo-local caches, logged (§8a).
#    Zig 0.17 note (measured 2026-10-12, audit/runs/zig017-pin017-debug-20261012): `zig build` no longer accepts
#    --global-cache-dir — the global cache comes from ZIG_GLOBAL_CACHE_DIR in the export above.
uv run ecosys-audit/scripts/run_logged.py --cwd ecosys-ng --timeout 5400 \
  --out audit/runs/zig017-debug-$(date +%Y%m%d) -- \
  zig build -Doptimize=Debug --cache-dir .zig-cache
#    … then ReleaseSafe, then ReleaseFast (production mode), same flags, new --out each time

# 5. regressions
uv run ecosys-audit/scripts/run_logged.py --cwd ecosys-ng --timeout 7200 \
  --out audit/runs/zig017-test-$(date +%Y%m%d) -- \
  zig build test --cache-dir .zig-cache
TMPDIR="$PWD/.tmp" UV_CACHE_DIR="$PWD/.uv-cache" uv run pytest ecosys-audit/tests -q

# 6. preflight must go green on the pin
uv run ecosys-audit/scripts/preflight.py
```

`run_logged.py` requires `--timeout`, wants `--out` to be a **new** directory under `audit/runs/`, and takes the
command after `--`. Put the receipt path in the cycle file and print `zig version` there too, so the toolchain is
bound to the evidence.

## After it compiles — the part that is easy to skip

* **Numerics may move.** A compiler-version change can shift ReleaseFast results by ulps. Re-run the bounded
  parity comparisons you depend on (the hours/days already under parity verdict in `audit/`) and re-derive any
  threshold that was set at a "one-ulp" tightrope. A parity regression that appears only under 0.17 is a real
  finding: diagnose it (`ecosys-divergence-diagnosis`), do not loosen a bound.
* **Re-pin the records**: `audit/manifest/command_registry.json` (toolchain version), the build-receipt
  bindings in `evidence/manifest/`, and `audit/tools/*.md` if present. Old 0.16 receipts stay as dated evidence.
* **Math modes**: confirm the ReleaseFast/ReleaseSafe optimization and float-mode options still mean what the
  build reproducibility skill requires (`ecosys-build-reproducibility`).
* **Gates**: G1 (both modes, 0.17), G2 (full test suite), G4/G5 (re-derived parity on the touched range),
  G6 (no forbidden diff — the codemod must be a mechanical diff, no tolerance or clamp edits hiding inside it),
  G7 (fresh-context verifier re-derives the parity conclusion), G8 (push), G9 (all caches/logs stayed in-repo).

## Commit / push

One commit for the migration (`zig: migrate ecosys-ng to Zig 0.17.x …`) plus the evidence, then
`./sync-main.sh push` and `git rev-parse HEAD origin/main` — a cycle is not closed until `main` matches
(`.agent/protocol.md` §7).
