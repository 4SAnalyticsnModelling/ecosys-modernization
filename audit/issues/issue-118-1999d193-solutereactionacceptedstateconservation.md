# issue-118: SoluteReactionAcceptedStateConservationFailure at 1999 d193 (post-issue-117 frontier)

Status: OPEN (registered cycle 00007; fix scope = cycle 00008).

Evidence (audit/runs/ottawa/cycle7-verify-candidate-20261022/stderr.log):
- 74798: SOLUTE retained-state inventory failure: inventory=nitrogen_mol_per_m3
  before=1.6103856504600056e0 after=1.6103856505023122e0 residual=4.2306602665576065e-11
  limit=7.358943829275302e-13 (cell=0 layer=0)
- 74799: SOLUTE hourly reaction solver failed: cell=0 layer=0 error=SoluteReactionAcceptedStateConservationFailure
- 74801: fatal at total_hour=13370 year=1999 day_of_year=193 hour=2 (scene_hour 4610, exec 1 scenario 1 scene 2)
- preceding warnings: phosphate site reconciliation rejected nonconservative transformation
  (residual ~-4.4e-20 vs envelope 1.3e-20 - borderline rounding class).

Context: first defect encountered after issue-117 advanced the trajectory from 1999 d140; distinct from the
resolved solute translation defects (issue-113/114) and from the recorded h2173 legacy solver stall. The
residual (4.2e-11 against ~1.6 mol/m3 inventory) is a near-zero signed defect class -> follow
.agent/playbooks/convergence-and-balance.md: diagnose cause before any scale/floor change; preserve gates.
Frontier: h13369 (last accepted hour, 1999 d193 h1).
