# TASK: T-NNNNN

## ROLE
PATHFINDER | FORGE | SAGE

## OBJECTIVE
One sentence. One question or one fix.

## INPUTS
- Failure packet / prior result / artifact paths (with sha256 where evidence).

## ALLOWED FILES
- Paths or globs this task may change. Empty = read-only task.

## DO NOT
- Modify source outside ALLOWED FILES.
- Run a full Ottawa simulation.
- Explore unrelated processes.

## RELEVANT SKILLS
- `.agents/skills/<name>` (only those needed)

## KNOWN FACTS
- Verified facts with their evidence path. Mark provisional ones.

## HYPOTHESIS
Required for FORGE production-science edits: `.agent/tasks/T-NNNNN.hypothesis.md`. Otherwise "n/a".

## SUCCESS CONDITION
Observable, checkable condition.

## STOP CONDITIONS
Role budget from `.agent/roster.json`; 3 rejected hypotheses; 2 failed implementations; no new evidence.

## OUTPUT FILE
.agent/results/T-NNNNN.md
