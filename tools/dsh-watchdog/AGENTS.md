# Context engineering

Follow `.agent/protocol.md`. Preserve native capacity admission, balanced compaction,
verbatim durable notes, session/tool pairing, full JSONL/diff snapshots and atomic fsynced
publication. Internal capacity checks stay; usage/cost accounting is removed.

Batch independent tools with awaited native `run_code`/Promise.allSettled and inspect failures.
Use `project.sh code`: outline → targeted search → complete relevant ranges/callers. Prefer
diffs after edits; cite source/evidence instead of reloading unchanged files. Keep full output
on disk, expose truncation and retrieve omitted decisive ranges before concluding.

Repeated failures trigger a new hypothesis/reproducer, not a permanent mission stop. Never
kill healthy work for silence. Ambiguous persistence is preserved for automatic reconciliation
by the mission recovery worker; never reset state to fabricate success. One native compaction
owns each boundary. Preserve unrelated configuration and existing sessions.
