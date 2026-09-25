#!/usr/bin/env bash
# ==============================================================================
# Adversarial Workflow Orchestrator: Claude Code (Editor) <-> Pi (Reviewer)
# Session: ecosys-modernization
# Root:    D:\ecosys-modernization
# ==============================================================================
set -euo pipefail

SESSION="ecosys-modernization"
WORKDIR="/d/ecosys-modernization"
MAX_LOOPS=10
TIMEOUT_WORKER_MS=900000    # 15 minutes per editor turn
TIMEOUT_REVIEWER_MS=600000  # 10 minutes per reviewer turn

cd "$WORKDIR"

echo "================================================================="
echo " Starting Adversarial Workflow on Session: $SESSION"
echo " Working Directory: $WORKDIR"
echo " Max Iteration Loops: $MAX_LOOPS"
echo "================================================================="

# 1. Check Herdr Session Status
if ! herdr --session "$SESSION" workspace list >/dev/null 2>&1; then
    echo "[-] Error: Herdr session '$SESSION' is not running or accessible."
    exit 1
fi

# Ensure agents 'editor' and 'reviewer' exist in the session
AGENTS=$(herdr --session "$SESSION" agent list)
if ! echo "$AGENTS" | grep -q '"name":"editor"'; then
    echo "[-] Error: Agent 'editor' (Claude Code) is not running in session '$SESSION'."
    echo "    Please run setup-ecosys-adversarial.sh first."
    exit 1
fi

if ! echo "$AGENTS" | grep -q '"name":"reviewer"'; then
    echo "[-] Error: Agent 'reviewer' (Pi) is not running in session '$SESSION'."
    echo "    Please run setup-ecosys-adversarial.sh first."
    exit 1
fi

echo "[+] Verified both 'editor' (Claude) and 'reviewer' (Pi) are present."

# 2. Define the Mission Prompt for Claude Code
MISSION_TASK=$(cat << 'EOF'
MISSION: Make ecosys-ng production v1.0.0 ready.

Core Success Criteria:
1. Science Parity: ecosys-ng model has NO science gaps compared to the Fortran oracle.
2. Complete Run: The production ecosys-ng example run completes to the end successfully without panics, NaN/divergence, or crashes.
3. Output Validation: The ecosys-ng model outputs are comparable against Fortran oracle outputs within acceptable numerical tolerance.
4. Performance: The ecosys-ng model is highly performant (much faster and more memory-efficient than Fortran oracle).
5. Repository Cleanliness: Keep the repository absolutely clean; do not leave temporary artifacts or untracked debris.

Authoritative Resources & Reference Data:
- Project contract: `ecosys-audit/PROJECT_CONTRACT.md`
- Evidence guide: `ecosys-audit/EVIDENCE_GUIDE.md`
- Skills: `.agents/skills/` (specifically `ecosys-release-orchestrator`, `ecosys-process-science-parity`, `ecosys-fortran-zig-traceability`, `ecosys-output-comparison`, `ecosys-performance-engineering`, etc.)
- Previous work reference (READ-ONLY): `C:\Users\symon.mezbahuddin\OneDrive - Government of Alberta\ProjectsSymon\ecosys_modernization\ecosys-ng`
- Fortran source: `f77src/` and examples in `f77example/`
- Zig source: `ecosys-ng/`

Execution Rules:
- Multi-agent spawning: Spawn sub-agents or dispatch background auditing where appropriate to avoid idle waiting.
- Commit policy: When a discrete unit of work is completed and verified, ensure clean git state.
- Proceed autonomously with the current priority task, run tests, and report your summary of changes and validation results.
EOF
)

# 3. Initial Editor Kickoff (if needed or starting fresh)
echo "[*] Loop 1 Kickoff: Dispatching task to Editor (Claude Code)..."
herdr --session "$SESSION" agent prompt editor "$MISSION_TASK" --wait --timeout "$TIMEOUT_WORKER_MS"

LOOP=1
while [ "$LOOP" -le "$MAX_LOOPS" ]; do
    echo "-----------------------------------------------------------------"
    echo ">>> Loop $LOOP / $MAX_LOOPS: Review Phase"
    echo "-----------------------------------------------------------------"

    # Check Git diff and status
    GIT_STATUS=$(git status --short)
    GIT_DIFF=$(git diff -U3 HEAD~1 2>/dev/null || git diff -U3)
    LAST_COMMIT=$(git log -1 --stat 2>/dev/null || echo "No commits yet")

    # Read recent output from Editor to get Claude's claim/summary
    EDITOR_LOG=$(herdr --session "$SESSION" agent read editor --source recent-unwrapped --lines 120)

    # 4. Formulate the Adversarial Review Prompt for Pi
    REVIEW_PROMPT=$(cat << EOF
You are an uncompromising adversarial reviewer for the ecosys-ng v1.0.0 production migration.
Your objective: Rigorously audit the editor's work against the project contract, science parity, performance, and cleanliness.

Current Git Status:
\`\`\`
$GIT_STATUS
\`\`\`

Recent Git Commit:
\`\`\`
$LAST_COMMIT
\`\`\`

Editor's Recent Report / Log:
\`\`\`
$EDITOR_LOG
\`\`\`

Reference Knowledge:
- Read-only historical reference: C:\Users\symon.mezbahuddin\OneDrive - Government of Alberta\ProjectsSymon\ecosys_modernization\ecosys-ng
- Authoritative contract: ecosys-audit/PROJECT_CONTRACT.md & EVIDENCE_GUIDE.md
- Available audit skills: .agents/skills/ (ecosys-conservation-audit, ecosys-process-science-parity, ecosys-output-comparison, etc.)

Your Review Checklist:
1. Science Parity: Are there science omissions, ungrounded approximations, or Fortran deviations?
2. Stability & Test Runs: Did the test / production run finish cleanly without NaN or divergence?
3. Output Validation: Are the output numbers directly verified against the oracle?
4. Performance: Is the code optimized in Zig without memory leaks or unnecessary bottlenecks?
5. Hygiene: Is the directory strictly clean of stray debug files?
6. Git Sync: Are changes committed with meaningful messages and ready to push?

Verdict:
- If ANY flaws, gaps, uncommitted files, or unverified claims remain: list concrete, prioritized critique and actionable directives for the editor. Do NOT approve.
- ONLY if the milestone/step is fully verified, clean, robust, and tested: end your review with:
ECOSYS_VERDICT_APPROVED
EOF
)

    echo "[*] Submitting changes to Reviewer (Pi)..."
    herdr --session "$SESSION" agent prompt reviewer "$REVIEW_PROMPT" --wait --timeout "$TIMEOUT_REVIEWER_MS"

    REVIEW_OUTPUT=$(herdr --session "$SESSION" agent read reviewer --source recent-unwrapped --lines 120)

    # Check if approved
    if echo "$REVIEW_OUTPUT" | grep -q "ECOSYS_VERDICT_APPROVED"; then
        echo "================================================================="
        echo "[+] SUCCESS: Reviewer (Pi) APPROVED the iteration in Loop $LOOP!"
        echo "================================================================="
        
        # Sync Git: Push to remote
        echo "[*] Pushing verified commits to remote..."
        git push origin main || echo "[!] Notice: git push failed or already up-to-date"
        
        # Check if production v1.0.0 readiness is achieved
        if echo "$REVIEW_OUTPUT" | grep -q "PRODUCTION_V1_READY"; then
            echo "[***] Full v1.0.0 Production Readiness Achieved! Exiting loop."
            break
        fi
    fi

    LOOP=$((LOOP + 1))
    if [ "$LOOP" -gt "$MAX_LOOPS" ]; then
        echo "[-] Reached MAX_LOOPS ($MAX_LOOPS) without full completion. Pausing for human review."
        break
    fi

    echo "[-] Reviewer requested changes or further verification. Passing feedback to Editor..."
    FEEDBACK_PROMPT=$(cat << EOF
The Reviewer (Pi) has scrutinized your latest work and provided the following critique and requirements:

$REVIEW_OUTPUT

Address every critique:
1. Fix all science, numerical, or logic gaps identified.
2. Verify production runs and output parity against the Fortran oracle.
3. Clean all temporary and untracked files.
4. When verified, commit your changes.
EOF
)
    herdr --session "$SESSION" agent prompt editor "$FEEDBACK_PROMPT" --wait --timeout "$TIMEOUT_WORKER_MS"
done
