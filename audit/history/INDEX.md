# Historical handoff lookup

Do not read these archives at startup. The live checkpoint is `audit/handoff.md`.
Archives retain original bytes and line numbering; an older citation to
`audit/handoff.md:Lx-Ly` before the 2026-09-23 migration resolves to the same lines
in the archive below. This index is navigation, not new scientific evidence.

## Initial migration, 2026-09-23

- Archive: `audit/history/handoff-8b3fc0d1fcf27b3b6e36902da984071f11680bfb4ed29f9dda6bac9eb5cabebc.md`
- SHA-256: `8b3fc0d1fcf27b3b6e36902da984071f11680bfb4ed29f9dda6bac9eb5cabebc`
- Original size: 279,795 bytes; 1,263 lines.
- Source baseline: `6944efe15be5e149158166e1e279f0e3c55e813f`.
- Lines 1-640: early baseline/source-audit history (many superseded claims).
- Lines 641-833: early adversarial rounds; see per-issue records for current disposition.
- Lines 834-1139: rounds 23 onward, including subsequent corrections.
- Lines 1140-1215: late issue-099/100 investigations and rounds 30-32.
- Lines 1216-1263: round 33 and inherited next actions.

Future checkpoint replacements create `handoff-<sha256>.md` archives automatically.
Use filenames/hashes from checkpoint receipts rather than rereading every archive.

The pre-existing untracked workflow scripts were also preserved byte-for-byte under
`audit/history/workflow-before-2026-09-23/` before the controller replacement:

- `orchestrate-adversarial.sh`: SHA-256 `3c9b71fe65256a1412295fb3afd45afa055e6f8f0d847c68c07ea0f97a09031f`
- `setup-layout-and-agents.sh`: SHA-256 `79330bad02c2d0bbbf4409eaf9648d7531bcd08a4754ee9c69af9380b8418699`

These are historical text, not scripts to execute. In particular the old automatic
push and approval-string logic are obsolete.
