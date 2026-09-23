# The v1.0.0 release contract and gate matrix, transcribed into this repository, 2026-09-23

**Provenance, stated first because it governs how this file may be used.** Every quotation below is transcribed verbatim from `docs/v1_release_checklist.md` in the reference tree at `C:\Users\symon.mezbahuddin\OneDrive - Government of Alberta\ProjectsSymon\ecosys_modernization\ecosys-ng\`, which the user granted **read-only** access to. That file is 629 lines and is **not present in this repository** (`issue-097`). It is not a contract this session authored, agreed, or may amend. Its own baseline commit is `468ef0d52b63d5cb50445077e21efbbe62dd10a8`, which is **not** this repository's history, and it warns of itself: "Historical status columns are leads, not current verdicts."

**Why transcribe it rather than bulk-import `docs/`.** `issue-097` records 1,043 reference files cited 307 times by this repo's own source, and has been awaiting a user provenance decision. The user's standing instruction is to work autonomously because no one will answer. Copying 1,043 unverified files wholesale would change the audited corpus in a way an audit should not do unilaterally; but leaving the *definition of the release* out of the repository means no gate can be adjudicated at all. So the bounded decision taken here is to transcribe **the release criteria only**, with provenance, as an audit artefact -- not source, not tooling, not a claim of compliance.

## The fixed release contract, verbatim

> - Ship ReleaseSafe with exact Zig 0.16.0; independently run all four test roots in Debug, ReleaseSafe, and ReleaseFast.
> - Immutable `examples_ng-prod`; production examples run only through isolated acceptance. Ottawa requires **262,920 accepted hours / 30 passes**: six forcing years (1998-2003), five repeats, the model's modulo-four calendar.
> - Attempted, committed, accepted and normally completed are distinct. A date, resumed suffix, survey, timeout, or incomplete journal cannot certify a run.
> - Tracked required Ottawa input copy is authorized. No external push, LICENSE/remote work, or hosted-CI execution requirement.
> - Monitored detached runs may last up to 24 hours each; one heavy model at a time.
> - No weakened accuracy, unjustified ceiling increase, audit bypass, unexplained clipping, skipped required capability, or release with a failed mandatory gate.

And the file's own verdict on itself, its opening line:

> **NOT PRODUCTION READY.** Full Ottawa completion, final same-candidate qualification, clean release package, and release tag remain unproven.

## The nine remaining gates, verbatim (columns truncated as read)

| Gate | Still required |
|---|---|
| Execution identity | "Fresh full scie..." |
| Scientific ownership | "Reconcile each mandatory PR requirement once; nonzero growing-..." |
| Hydrology | "Promote reviewed tests; full hete..." |
| Freeze-thaw | "Run full dedicated Release..." |
| Restart/spatial | "Active-science and calendar/repeat splits; continuous/resumed, seria..." |
| Performance | "Complete calibration -> frozen independently evidenced reference -> separate measur..." |
| Engineering validation | (historical: "full ReleaseSafe 4,412; current active-search candidate 254 selected library tests, four filtered roots, 11 solver guards and formatting ...") |
| Scientific outputs/oracle | "Finite complete ordered outputs; active science; numerical comparison and a..." |
| Reproducibility/release | "Scoped clean commit, clean-checkout ..." |

The right-hand column is truncated in the reading above; **the full text has not been transcribed and should be re-read before any gate is claimed.**

## What this establishes about the four criteria in the user's goal

This is the first time in this session that v1.0.0 has had a *defined* meaning rather than an inferred one, and three of the four criteria map onto named gates:

- **Criterion 1 (outputs legacy-Fortran comparable)** is the **Scientific outputs/oracle** gate, which still requires "finite complete ordered outputs; active science; numerical comparison". This repo cannot attempt it: the frontier run stops pre-emergence on day 137, so no plant output exists to compare (`audit/analysis/frontier-hour-3275-...md`).
- **Criterion 2 (no science gap)** spans **Scientific ownership**, **Hydrology**, **Freeze-thaw** and **Restart/spatial**, all four with outstanding work.
- **Criterion 3 (significantly more performant)** is the **Performance** gate, and the contract is explicit that its reference is **"explicitly unqualified"** -- i.e. there is no frozen, independently evidenced baseline to be faster *than* yet. This is decisive: `run-021`'s measured 1.72-2.37x slower cannot be compared against a qualified reference because none exists, and the gate requires "complete calibration -> frozen independently evidenced reference -> separate measurement" in that order. **Criterion 3 is therefore not merely unmet; it is not yet measurable in the contract's terms.**
- **Criterion 4 (repo sync)** is not a release gate; it is satisfied and maintained.

## Two hard numbers worth carrying

1. **The horizon is confirmed: 262,920 accepted hours / 30 passes.** This repo's frontier is **hour 3,275**, i.e. **1.25%**.
2. **The reference project's own frontier was hour 2,649** ("Fresh snow-corrected Ottawa now accepts 2649 hours and fails attempt2650 with `InvalidLitterSoilInterfacePhysicalState`", dated 2026-09-14). **This repository is 626 hours ahead of the reference tree's recorded best**, and reaches a later failure (the day-137 event) than the reference ever did.

That second point cuts both ways and both halves matter. It is genuine evidence that the work in this repo is not behind the reference. It is equally evidence that **a project with far more history than this session had also not achieved v1.0.0**, and that the remaining 98.75% of the horizon is not a formality -- the reference hit distinct blocking failures at hours 2,534, 2,645, 2,646, 2,649 and 2,650.

## Test-matrix gap this reveals in my own work

The contract requires **"all four test roots in Debug, ReleaseSafe, and ReleaseFast"** -- twelve independent test executions -- plus "11 solver guards and formatting". Every test figure this session has quoted (`4380 passed / 1 skipped / 0 failed`) is **one root in one mode**. The reference's historical figure is `full ReleaseSafe 4,412`. So my test evidence is roughly a twelfth of the required matrix, and I had not known that. No claim in this session's records should be read as engineering-validation evidence.

## Limitations

**Transcription, not verification.** I have read one of 629 lines' worth of sections in detail and quoted two blocks; the gate table's right column is truncated and the "Historical development predecessors" (lines 236-463), "Pre-warm-start surface repair" (464-527), "Independent candidates" (567-658) and "Evidence and final freeze" (659+) sections are **unread**. Nothing here is checked against this repository's source, and the reference tree's baseline commit is not in this history, so its per-gate status columns may not describe this code at all. `check_gate.py` owns gate status in this repository and this file changes nothing about it. The 2,649-versus-3,275 comparison assumes both count accepted hours the same way, which is **not** verified -- the contract explicitly distinguishes "attempted, committed, accepted and normally completed", and this session has been quoting the hour at which a run *fails*, which is an attempted hour, not an accepted one. **On the contract's own definitions this repo's accepted count is 3,274, and possibly lower if any earlier hour was committed but not accepted.**
