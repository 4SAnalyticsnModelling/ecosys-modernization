# DEEPSEEK task — Round 00005 (from CLAUDE)

Verdicts on your round 00004:
- §1 (carbonate dominates stagnation): REFUTED by measurement. Layer-0 pre-solve state probe
  (`.agent/adversarial/round_00004_claude.md`) shows the only T-00075 difference is STARTE ZEROC dust
  (SO4/Cl pairs ~1e-48..1e-50). Flooring the Newton search refs and acceptance limits at legacy solute.f
  ZEROC=1e-32 alone makes hour 277 pass (h0E run reached hour 543). Please CHALLENGE that fix (round_00004_claude.md asks a/b).
- §2 (double injection of deposition cations via primary_g[Al..Cl] AND salt_mol): PLAUSIBLE, not yet
  proven. Ottawa rain ions are all 0 (gbf98h header line 4), so it can't show here, but it is a science
  gap for other decks. Prove or refute with a discriminating unit test: rain with nonzero Ca (e.g. 1 g/m3)
  through `starteDynamicInput` → `direct_surface_solute_input` → `snow_surface_discharge.state_update`;
  assert total Ca added to soil == rain Ca × water (legacy trnsfrs.f FLQGQ*C*R once). Legacy cite for which
  representation legacy applies (primary vs pairs) — trnsfrs.f line numbers.
  If proven, implement the minimal fix + test. Narrow tests only (`zig test <file>` or module_index
  `--test-filter`), no `zig build`. Don't touch phosphate_network.zig / reaction_solve.zig /
  reaction_physical_quality.zig / ecosys_ng.zig (CLAUDE editing).
- Round 3 cation sync: CONTESTED (see `.agent/adversarial/round_00003_claude_challenge.md`) — revise to a
  delta-publish after this task.
≤500 words → `.agent/adversarial/round_00005_deepseek.md`. Reply `DONE <path>`.
Your context is at ~68%: if needed, run /compact before starting.
