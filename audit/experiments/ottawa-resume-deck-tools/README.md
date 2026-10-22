# Ottawa restart.manifest / replay-deck tools (cycle 00003)

Manifest layout authority: `ecosys-ng/src/io/checkpoint/manifest.zig` (write(): magic ECOSBNDL,
u32 version 3, u64 generation, instant fields, u32 canonical_root length + bytes, u64
run_identity, u64 fingerprint, RuntimeShape, entries). Fingerprint = std.hash.Wyhash
(seed 0x4f5554524f4f5433) over run_identity little-endian then canonical_root, matching
`outputIdentityFingerprint`.

- `fingerprint.zig` — standalone fingerprint replica (superseded by the self-generating
  programs inside the python tools; kept for reference).
- `patch_manifest.py` — rewrite canonical_root for a copied from-scratch deck; verifies the
  stored fingerprint of the source manifest before writing (control check).
- `build_resume_deck.py` — copy a completed deck, set scene-option record 6
  resume_from_checkpoint=YES (f25y98) and re-point/rewrite restart.manifest (control-checked);
  validated by audit/runs/ottawa/zig017-resume4320-dev021-20261021 (resume=true, records
  4321-4411 replayed unchanged).
- `extract_n_failures.py` — pull state_update failure/breakdown lines from stderr logs.

Usage notes: run from the repository root; zig run must execute with cwd
`.tmp/manifest-tool` (or the tool dir) because fingerprints are computed by `zig run`
using the same Zig 0.17 std as the engine.
