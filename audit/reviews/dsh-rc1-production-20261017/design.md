# Production rc1 and continuous dsh hygiene

The user explicitly authorizes global production deployment. Qwen Flash Next Q8
will use installed oMLX 0.7.1rc1 / MLX0.32.4 through the ordinary session-owned
router, with its own rc1 state/cache and native scheduler as in the completed
16K benchmark. The route keeps 60% expert residency, 8192 prefill chunks,
native KV, MTP<=3 and 112GiB memory guard. Other model routes are unchanged.
Both the router command builder and fallback production-runtime selector must
choose rc1; startup asserts package versions. Source templates and originals
are recorded in-repository; installed deployment writes are explicitly authorized.

The dsh singleton watchdog will invoke the installed native ToolResultPruner
before every pre-step, preserving append-only originals, source references,
error metadata, tool pairing and replay. New tool outputs spill above 1200
estimated tokens; any tool-result text over 2048 codepoints keeps a 768-character
head and 384-character tail. No model calls occur during hygiene. Cleaned results
are idempotent and full output remains retrievable. Rules require targeted
file ranges, bounded search, durable decisions and retrieval of omitted diagnostics.
No tool-call messages are deleted separately and no source/decision/user messages
are trimmed. The engine measures pressure AFTER cleanup and summarizes once at
75000, with no early summary. Request-error retries rebuild if cleanup changed the
surface; they never send a stale assembled request.

Gates: native replay/Unicode/error/source-link/idempotence tests, below-75K
zero-summary proof, all installed profile singleton/policy checks, production
command/runtime/cache assertions, fresh read-only verification. Preserve the
user's science-cycle edits. No new 16K speed benchmark is authorized or needed;
validate serving startup/model load and the installed route without another
performance run. Retain a deterministic rollback backup for installed changes.
