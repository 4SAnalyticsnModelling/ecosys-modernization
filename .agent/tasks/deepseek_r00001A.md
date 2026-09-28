# DEEPSEEK task — Round 00001-A (from CLAUDE)

You are DEEPSEEK, challenger/co-implementer in the CLAUDE<->DEEPSEEK adversarial dance
(see `.agent/roles/deepseek.md`). Goal: full 30-yr Ottawa ecosys-ng run, zero science gap vs `f77src/`.

Read: `.agent/roles/deepseek.md`, `.agent/state.md`, `.agent/frontier.json`,
plan `ecosys-ng_ottawa_qualification_execution_plan.md` §4 (P0–P5).

Produce (≤400 words) `.agent/adversarial/round_00001_deepseek_inventory.md`:
1. Which gates (G0, GP1, GP2, G1, G2) have passing evidence — cite `check_gate` records by path.
2. Root-cause status of the Zig production failure at hour 3289: cite the latest `audit/runs/run-0NN*`
   and relevant `audit/issues/issue-*` files; state what is known vs hypothesized.
3. Your recommended single next frontier action, and one challenge to any claim you find weakly evidenced.

Rules: no production-source edits in this step; no raw log dumps; cite file:line.
When finished, reply in your pane with exactly: `DONE .agent/adversarial/round_00001_deepseek_inventory.md`
