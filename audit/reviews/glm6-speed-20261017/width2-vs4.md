# Lookahead2 versus4:16K comparison,2026-10-18

Keep production lookahead2. Four did not show a useful overall advantage.

| Metric | Two experts | Four experts |
| --- | ---: | ---: |
| Fresh request seconds |210.56|209.69|
| Prefill tokens/s |100.95|101.12|
| Fresh decode tokens/s |2.66|2.69|
| Cached decode tokens/s |3.31|3.24|
| Cached request SSD reads, decimalGB |200.47|218.53|
| Cached useful predicted experts |2310|3433|
| Cached unused predicted experts |1845|3046|
| Cached prediction usefulness |55.6%|53.0%|
| Peak physical memory, decimalGB |110.914|110.896|

Four improved fresh decode1.1% and reduced total fresh time0.4%, but cached
decode fell2.1% while cached SSD reads rose9.0%. It made2324 extra predictions;
1123 were useful and1201 went unused. Warm demand misses were identical8631.
These observations support retaining2; they do not prove that4 is slower on
every workload. This is one matched fresh/warm pair per setting, not a
statistically powered repeated experiment.

Both used exactly16384 prompt tokens,8192-token prefill, maximum thinking,
128 output tokens, seed20261014,12CPU I/O workers, native KV, MTP depth1,
101/288 resident experts and114GB cap. Fresh requests cached0tokens; warm
requests restored16382. Prompt, output and terminal hashes match across arms.
Every completion stream finished, source shard metadata remained unchanged,
and neither arm exceeded the memory cap. Both finished cleanly. The underlying
lookahead module hash matches the currently deployed implementation.

Telemetry counts above are warm-minus-fresh snapshots, isolating the cached
request. Disk read bytes are the backend process I/O counter deltas. Lookahead
only schedules raw reads; true routing and expert math remain native. It is
disabled during external prefill, whose logs allow8192/8190 without shrinking.
The startup duration-floor environment remains5632; the GLM fixed scheduler
replaces adaptive shrinking after import, so that floor did not constrain chunks.

Receipts: `compare-width2-16/result.json`, `compare-width4-16/result.json`,
per-arm `telemetry-fresh.json`/`telemetry-warm.json`, and `width2-vs4-state.json`.
No production configuration was changed by this comparison.
