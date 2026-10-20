# Continuous autonomy

`.agent/protocol.md` governs. One model decides and continues to verified F1–F7 without
human approval or elapsed-time cutoffs. Worker failures trigger automatic reconciliation,
restart and capped backoff; scientific failures trigger diagnosis and a new experiment.
Healthy runs survive session/context boundaries. Preserve process identity, logs, checkpoints,
Git changes and next action. Never infer death from age or waive scientific gates to continue.

The supervisor permits three unchanged exits, then one REPLAN launch. If it still has no new
source/gate/frontier evidence, it waits for changed state or a new verified external-resource
identity. It never counts restart/log growth as progress. Continue other unblocked prerequisites
before declaring an external wait. See `tools/autonomy/README.md` for live deployment checks.

Numerical nonconvergence is a scientific diagnosis, not a worker crash to restart unchanged.
Use [bounded numerical recovery](playbooks/convergence-and-balance.md): finish benign cases
promptly, retain failed states and pursue the smallest causal fix without weakening acceptance.
NaN/Inf or physically invalid simulation exits also require causal repair. Preserve the last
valid checkpoint and failure evidence; a supervisor restart must not repeatedly propagate them.
Stopping the simulation is distinct from stopping the worker: the worker records the failure
and continues causal repair or another unblocked prerequisite without resetting the failed run.
