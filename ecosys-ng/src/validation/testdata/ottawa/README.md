# Required Ottawa inputs

Authorized byte-identical copy of the immutable Ottawa runscript and complete
input directory, captured on 2026-09-13. `PROVENANCE.json` records every original
file's byte length and SHA-256. Git attributes preserve those bytes across hosts.

Input-layout tests read this packaged copy and fail on missing or changed files.
The `src` package/source-hash scope includes all of these inputs. No output,
checkpoint, modified forcing, shortened scene, or acceptance verdict is included.

Do not run the model in this fixture directory. Production qualification still
uses `tools/production_acceptance.ps1` and an isolated copy of `examples_ng-prod`.
These inputs make clean-checkout tests and package reconstruction possible; they
are not evidence that the full 262,920-hour production workload has completed.
