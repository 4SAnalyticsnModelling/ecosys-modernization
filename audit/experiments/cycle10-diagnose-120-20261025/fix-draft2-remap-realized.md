# issue-120 fix draft 2 (PENDING attempt-2b receipt; supersedes fix-draft.md if geometry pins producer)

Producer candidate (arithmetically verified in python, runtime UNVERIFIED):
soil/gas/layer_remap.zig transferPair (:118-122)
    moved = fraction * values[source];
    values[source] -= moved;
    values[destination] += moved;
conservation defect: values[source] -= moved rounds (subnormal absorption: if moved < ulp(src)/2
source unchanged, destination += moved GAINS moved => net creation +moved); at the subnormal grid
(ulp 5e-324) this yields exactly the observed +1-ulp hourly drift with zero ledgers (REDIST
transfers are internal state moves, not booked as external fluxes).

Realized-delta fix (issue-119 pattern; exact per-transfer conservation):
    fn transferPair(values: []f64, source: usize, destination: usize, fraction: f64) void {
        const before = values[source];
        const moved = fraction * before;
        const after = before - moved;
        values[source] = after;
        values[destination] += before - after; // book the realized amount
    }
- bit-identical when before - after == moved exactly (normal magnitudes: Sterbenz-safe for
  moved <= before) => output-parity outside trace pools expected.
- multi-destination: each transfer individually exact => global exactness.
- validator untouched; no tolerance/gate change.

Open (resolve on receipt):
1) Does 120V block=geometry_finalize fire in the 1999 d361 window with subnormal old/new (slot
   pairs) and sumdelta == +5e-324 class? Does it also explain before=2.08 g (layer insertion
   shifts slot identities -> validator scope reindex)?
2) If scope identity shift is real at h-1/h-2, a same-hour mass-exact remap is NOT sufficient for
   the h0 failure? -> no: h0 fatal is within-slot +1 ulp; identity shift events passed within tol.
3) Ledger accounting: confirm layer-conservation treats unbooked intra-scope transfers (zero-ledger
   + pool change is only tolerated within tol) -> the drift fix must be EXACT, not approx.
