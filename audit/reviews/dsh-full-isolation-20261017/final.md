# Session isolation and retained-model verification

PASS: each launch has private configuration/TUI state; each native agent has
private notes, watchdog state, checkpoints and hygiene index. Model/session routes
use different backend workers/cache roots. Native shell and code-mode probes
verify private temporary paths and credential stripping. Explicit resume retains
recovery checks rather than erasing interrupted transactions.

Validation:31Node tests and16Python tests pass. Actual TUI model-switch and
/new probes create distinct native sessions; post-removal dst boots and exits0.
Real Qwen Flash and GLM6 harness tasks completed the answer385 tool check.
Fresh post-removal generation succeeded twice per retained model, with4distinct
runtime roots and routerPIDs, cached prompt tokens0 in all4responses.
Independent read-only architecture review:G7PASS. Independent retained model
dependency/overlay review:PASS. These are targeted tests, not a proof of every
future third-party plugin behavior. Shared installed code/weights are immutable
inputs; user project files remain the ordinary shared workspace.

Qwen27 and GLM mixed4/8 were removed at the user's request; their planned
benchmark was cancelled with no speed results reported. GLM6's required draft
head was moved out of the removed mixed directory before deletion and validated
without changing its inode or bytes. Removal evidence and fresh generation
responses:../model-removal-20261017/.
