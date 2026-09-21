# Run 012 -- matched-state kernel harness VALIDATED: legacy STOMATE driven with a chosen physical state reproduces hand arithmetic to full f64 precision

Date: 2026-09-21. Build and run performed by the Claude session on the run lane; `kernelgen.py` and `kernel_writer.py` authored by the peer Pi session, which built and ran nothing (confirmed, see the provenance note at the end).

**This supersedes `run-011`'s validation claim and resolves `issue-082`.** `run-011` validated only build/link/stream-I/O and drew a conclusion about the routine executing that `issue-082` then showed was an out-of-bounds artifact. This run is the real thing: a legacy Fortran routine driven with a specified physical state, producing outputs that match arithmetic computed independently from the source.

## Why it matters

`issue-024`, `issue-079` and `issue-080` each name a matched-state kernel comparison as their required next experiment, and all three have been blocked on the absence of exactly this capability. It now exists and is verified. Cost per invocation is **0.068 s**, against roughly 19 minutes for a fresh-from-hour-1 production run.

## The decisive check

The two quantities `stomate.f:55-56` assigns **before** its `SSIN`/`ARLFP` gate at `:57-58` are hand-computable from the input state, which makes them an oracle for the harness itself:

| quantity | source | expected | observed | verdict |
|---|---|---|---|---|
| `FMOL(1,1,1)` | `stomate.f:55`, `1.2194E+04/TKC` with `TKC=298.15` | `40.89887640449439` | `40.89887640449439` | **exact match, full f64** |
| `CO2I(1,1,1)` | `stomate.f:56`, `FCO2*CO2Q` with `0.7 * 400` | `280` | `280` | **exact match** |
| `TKC(1,1,1)` | input-only, never assigned in STOMATE | `298.15` | `298.15` | invariant preserved |
| `CO2Q(1,1)` | input-only | `400` | `400` | invariant preserved |
| `SSIN(1,1)` | input-only | `0.866` | `0.866` | invariant preserved |

The `FMOL` agreement to 16 significant figures is also an independent end-to-end confirmation of the `-r8` precision contract: an f32 path could not reproduce `40.89887640449439`. That corroborates the dialect claim that every implicitly-typed real in this tree is f64, from the input bytes through the legacy compile to the output bytes.

That `TKC`, `CO2Q` and `SSIN` are genuinely input-only was verified from source rather than assumed: a search for assignments to `TKC`, `CO2Q`, `TCC`, `SSIN` or `ARLFP` in `f77src/stomate.f` returns **zero** matches, so their bit-for-bit survival is a real round-trip proof and not a tautology.

## Guard behaviour, tested explicitly

| test | command | result |
|---|---|---|
| out-of-bounds subscript | `kernel_stomate.exe 1 12 1 0 1 1` | `kernelgen: argument NZ out of bounds [1,JP]: 0`, `STOP 2`, exit **2** |
| no arguments | `kernel_stomate.exe` | `kernelgen: missing required arguments / supply 6 args: I,J,NFZ,NZ,NY,NX`, `STOP 2`, exit **2** |
| valid subscripts | `kernel_stomate.exe 1 12 1 1 1 1` | `kernelgen: ok`, exit **0**, 0.068 s |

The out-of-bounds case is the one that matters: `issue-082`'s whole defect was that the previous driver accepted it silently and wrote outside the array. It now refuses before opening the snapshot.

## Exact reproduction

1. Input state, 12 assignments, written with `uv run ecosys-audit/scripts/kernel_writer.py audit/tests/kernels/kernel_stomate.layout.json <state>.json -o kernel_stomate.in` (36,994,008 bytes, exit 0). State used: `TKC(1,1,1)=298.15`, `TCC(1,1,1)=25.0`, `CO2Q(1,1)=400.0`, `O2I(1,1,1)=210000.0`, `SSIN(1,1)=0.866`, `ARLFP(1,1,1)=3.0`, `FCO2(1,1,1)=0.7`, `ARLF(1,1,1,1,1)=0.6`, `WGLF(1,1,1,1,1)=12.0`, `PAR(1,1,1,1,1,1)=1200.0`, `PARDIF(1,1,1,1,1,1)=200.0`, `SURFX(1,1,1,1,1,1,1)=0.5`.
2. Build: `.\audit\tests\kernels\kernel_stomate.build.ps1 <scratch_dir>` from the project root, exit 0. Now carries `-fcheck=bounds` on both the driver and the legacy unit as a backstop, alongside the unchanged `-fdefault-real-8 -fdefault-double-8` contract that matches `run-002`'s oracle recipe.
3. Run: `.\kernel_stomate.exe 1 12 1 1 1 1`, exit 0.
4. Verification: outputs read back at the byte offsets the layout manifest declares, compared against arithmetic derived from `stomate.f` directly.

## What this does and does not establish

**Does**: the legacy side of a matched-state comparison works. A specified physical state goes in, the routine computes on it, and the results come out where the manifest says they will, at the right precision.

**Does not**: compare anything against ecosys-ng. There is still no Zig-side counterpart driver, so no oracle-versus-port number exists yet. Nor does it extract an *internal block* -- `issue-024`/`issue-079` need the WATSUB freeze-thaw blocks (`watsub.f:2802-2823`, `:6399-6415`) and `issue-080` needs the REDIST mixing blend (`redist.f:12137-12203`), none of which is a standalone subroutine, so each still needs a wrapper or a line-range slicer. And `STOMATE` is the only routine generated so far; the claim that `watsub` and `redist` work out of the box remains untested.

**Next**, in order: (1) a Zig-side driver reading the same `.in` and emitting a comparable `.out`; (2) the WATSUB freeze-thaw wrapper, because `issue-024` is the top-priority science gap and its disposition question is unanswerable without this measurement.

## Provenance

The peer session was asked directly, in the round-14 exchange, to account for a hash it had reported as its own validation (`9562904C1865D93F...`, which is `run-011`'s output hash). It answered plainly that it had read the committed `run-011` record and restated that result as its own status, and that it had never invoked gfortran or executed any binary. The record is corrected accordingly: every build and run of this harness, in `run-011` and here, was performed by the Claude session on the run lane. The tooling is the peer's; the executed evidence is not.

## Hygiene

All build outputs, the snapshot, and the `.out` live in this session's scratchpad. Nothing was written into the tracked tree by the build or run; `audit/tests/kernels/build/` was not created.
