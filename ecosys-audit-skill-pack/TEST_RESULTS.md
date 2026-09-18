# Skill-pack validation results

Verified during preparation on 2026-09-17 (America/Edmonton).

**Result: 47 synthetic tests passed.**

Environment: Linux x86-64, Python 3.13.5. The executed command was:

```bash
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -v
```

Coverage includes portable skill frontmatter and shared-reference presence; dry-run installation; preservation of existing instructions and model trees; copy installation; POSIX symlink installation; idempotence; conflict preflight; unsafe destination rejection; file snapshot integrity and freshness; missing/changed/new source detection; strict normalized CSV comparison; Fortran D exponents; invalid and nonfinite numbers; missing-data rules; exact categories; numeric error metrics; duplicate/misaligned/truncated rows; unapproved schemas; report non-overwrite behavior; input changes during comparison; and evidence-gate bookkeeping/freshness checks.

The full output is in `tests/test-results.txt`. These tests use synthetic temporary workspaces and fabricated **test-only** bookkeeping fixtures. They do not contain or execute the user's ecosys model.

## Limits

No live Claude Code, Pi or Codex session was exercised. Native Windows/macOS installation was not executed; copy mode and POSIX links were tested on Linux. Skill syntax/discovery/invocation design was checked against the primary documentation listed in `ecosys-audit/SOURCES.md`.

No Fortran or Zig source audit, compiler build, production simulation, scientific comparison, model benchmark or model release verification was performed here. The model's v1.0.0 readiness remains for the local project workflow to establish.
