# Worker orientation

Run `./scripts/project.sh pickup`; live ledgers and receipts override this orientation.
Cycle 3 is open: `InsufficientSoilMineralNitrogen` at h4556, with parent checkpoint h4320.
An existing uncommitted patch in `nitrogen_state_update.zig` belongs to the science worker;
inspect and verify it before keeping or changing it. Workflow maintenance did not validate it.
Verified strict frontier remains 0. Do not interpret diagnostic replays as promotion evidence.

Next: reconcile the current patch and replay receipts, reproduce parent failure, then trace
mineral-N supply/consumption to legacy. Priorities: `.agent/backlog.md`. No science campaign
is launched by the workflow revision. For process liveness use pickup's identity checks.
