# Ottawa execution-plan review — R3

Planning review only; D1–D8 remain fixed. No commands, builds, or tests were run.

## R2 resolution check

- **N1 — PARTIAL:** §4 explicitly permits parent-binding diagnostic replay, but P5.3 still categorically prohibits other bindings; replace that prohibition with a reference to the exception and identify the batch’s checkpoint-producing ancestor.
- **N2 — RESOLVED:** P6 makes extrapolation advisory and reserves performance acceptance for P7’s full-horizon medians.
- **N3 — RESOLVED:** P2.1–3 adds matching pre-advance `init` dumps and includes initialization in comparator self-tests.
- **Item 2 — PARTIAL:** P5.4 adds combined-candidate extended replay while retaining strict campaign-only promotion, but checkpoint eligibility remains contradictory under N1.
- **Item 3 — RESOLVED:** readiness, extended replay, campaign limits, survey frequency, and elapsed-time escalation are now explicit; the new extended-window problem is listed below.
- **Item 5 — RESOLVED:** P2.8 adds a material-state serialization inventory with reviewed exclusions and isolated output-tree seam validation.
- **Item 7 — RESOLVED:** §4/P0.4 specify exclusive-machine scheduling, common output/drive settings, a warmup policy, and median/spread reporting.
- **Item 9 — RESOLVED:** §0 explicitly makes historical figures provisional and requires legacy horizon verification before evidence use.

## New MAJOR finding

### N4 — P5.4: Unconditional 60-day replay can block valid late-run repairs

The combined candidate must pass **at least 60 simulated days** before another campaign. A divergence within the final 60 days cannot meet this condition without extending the fixed workload. Moreover, a newly exposed independent failure inside that window triggers mandatory batch bisection even when every accumulated fix is correct, risking another repetitive diagnosis loop.

**Concrete fix:** bound the extended window by the remaining Ottawa horizon and require completion through that endpoint for late-run repairs. When a new failure interrupts replay, preserve the failed gate, localize it, and distinguish regression from an independent defect before ordering bisection; queue the latter for bounded repair without permitting a failing batch into another full campaign.

REVISE
