# Evidence manifests (committed)

One JSON file per stored artifact set, named `<area>-<yyyymmdd>-<short-id>.json`:

```json
{
  "schema_version": 1,
  "artifact_set": "legacy-oracle-30yr",
  "files": [{"path": "evidence/legacy/ecosys_legacy.exe", "sha256": "...", "bytes": 0}],
  "producer": {"argv": ["gfortran", "..."], "cwd": "...", "compiler": "gfortran 16.1.0", "flags": ["-O2", "-fdefault-real-8", "..."]},
  "deck_sha256": "...",
  "binding_id": "... (evidence_binding.py, where applicable)",
  "created": "2026-09-25",
  "limitations": "..."
}
```

Hash with `uv run ecosys-audit/scripts/evidence_binding.py` for bindings and sha256 for files. A manifest
records identity, not correctness.
