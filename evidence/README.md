# Repository-local evidence

Authority: `.agent/protocol.md`. Artifacts live here; committed manifests record identity and
provenance. Generated binary artifacts remain ignored. Historical external Windows evidence
paths map into this repository; they are not current execution requirements.

| Directory | Content |
|---|---|
| `legacy/` | Complete legacy oracle binary, outputs and state dumps |
| `oracle-src/` | Instrumented staged Fortran copies; protected references stay untouched |
| `checkpoints/<binding_id>/` | Full-state checkpoints with verified restart provenance |
| `runs/<run-id>/` | Staged decks and run artifacts |
| `dumps/`, `gcov/`, `timing/` | Diagnostic dumps, source coverage and timing measurements |
| `manifest/`, `schema/` | Committed artifact manifests and dump schemas |

Every cited artifact needs a committed manifest/receipt with path, hash, producer argv, compiler
and flags, input identity and binding where applicable. Preserve cited artifacts. Cleanup must
check references and live-job ownership first. Read the actual runner's storage checks before
launching; obsolete drive-specific probes are historical. Schemas and qualification requirements
are documented in [qualification evidence](../ecosys-audit/qualification-evidence.md).
