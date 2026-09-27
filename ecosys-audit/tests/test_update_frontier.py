# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pytest",
# ]
# ///
"""Pytest suite for update_frontier.py Ottawa promotion gate enforcement.

Asserts:
1. `update_frontier.py promote` rejects an Ottawa binding summary that omits `runottawa_hash`.
2. `update_frontier.py promote` rejects an Ottawa binding summary with mismatched `runottawa_hash`.
3. `update_frontier.py promote` succeeds when valid `runottawa_hash` (TARGET_BLOB) is present.
4. Refusal occurs when frontier case is Ottawa, or when summary binding deck is Ottawa, or when run_id is Ottawa.
5. Non-Ottawa deck and generic case can promote without `runottawa_hash`.
6. CLI promote returns exit code 1 on refusal and exit code 0 on promotion.
7. Record op preserves `runottawa_hash` in frontier history.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "ecosys-audit" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from stage_ottawa_deck import TARGET_BLOB
import update_frontier as uf


def make_test_env(
    root: Path,
    case: str = "Ottawa",
    deck_path: str = "ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
    runottawa_hash: str | None = None,
    staged_deck: str | None = None,
    binding_id: str = "b-test-001",
    completed_hour: int = 100,
) -> tuple[Path, Path, Path]:
    """Create a mock workspace with frontier.json and evidence artifacts."""
    agent_dir = root / ".agent"
    agent_dir.mkdir(parents=True, exist_ok=True)
    frontier_data = {
        "schema_version": 1,
        "case": case,
        "horizon_hours": 262920,
        "simulation_frontier": 0,
        "verified_frontier": 0,
        "current_failure_hour": None,
        "last_checkpoint_key": None,
        "candidate_commit": "abcdef12",
        "evidence_binding": None,
        "history": [],
    }
    (agent_dir / "frontier.json").write_text(json.dumps(frontier_data, indent=2), encoding="utf-8")

    evidence_dir = root / "evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)

    summary_data = {
        "schema_version": 1,
        "run_id": "ottawa-test-run-1" if "Cool Temperate" in deck_path or case == "Ottawa" else "generic-test-run",
        "mode": "strict",
        "status": "COMPLETE",
        "exit_code": 0,
        "start_hour": 0,
        "last_completed_hour": completed_hour,
        "conservation_breaches": 0,
        "solver_fallbacks_unexplained": 0,
        "binding": {
            "binding_id": binding_id,
            "deck": {"path": deck_path, "sha256": "mockdecksha", "files": 78},
        },
    }
    if runottawa_hash is not None:
        summary_data["runottawa_hash"] = runottawa_hash
    if staged_deck is not None:
        summary_data["staged_deck"] = staged_deck

    summary_path = evidence_dir / "summary.json"
    summary_path.write_text(json.dumps(summary_data, indent=2), encoding="utf-8")

    divcheck_data = {
        "status": "WITHIN_RULES",
        "rules_approved": True,
        "last_verified_hour": completed_hour,
        "binding": {"binding_id": binding_id},
    }
    divcheck_path = evidence_dir / "divcheck.json"
    divcheck_path.write_text(json.dumps(divcheck_data, indent=2), encoding="utf-8")

    restart_data = {
        "status": "PASS",
        "last_equivalent_hour": completed_hour,
        "binding": {"binding_id": binding_id},
    }
    restart_path = evidence_dir / "restart.json"
    restart_path.write_text(json.dumps(restart_data, indent=2), encoding="utf-8")

    return summary_path, divcheck_path, restart_path


def test_promote_refuses_when_runottawa_hash_missing_for_ottawa_case(tmp_path: Path):
    """Assert promote refuses an Ottawa campaign summary when runottawa_hash is missing."""
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="Ottawa",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=None,
    )
    res = uf.promote(
        tmp_path,
        str(s_path.relative_to(tmp_path)),
        str(d_path.relative_to(tmp_path)),
        str(r_path.relative_to(tmp_path)),
    )
    assert res["status"] == "REFUSED"
    problems = res.get("problems", [])
    assert any("runottawa_hash" in p and TARGET_BLOB in p for p in problems)
    assert any("got None" in p for p in problems)

    # Frontier was not updated
    fr = json.loads((tmp_path / ".agent" / "frontier.json").read_text(encoding="utf-8"))
    assert fr["verified_frontier"] == 0
    assert len(fr["history"]) == 0


def test_promote_refuses_when_case_generic_but_deck_is_ottawa(tmp_path: Path):
    """Assert promote refuses when case is not Ottawa but binding deck is Ottawa and hash is omitted."""
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="GenericCase",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=None,
    )
    res = uf.promote(
        tmp_path,
        str(s_path.relative_to(tmp_path)),
        str(d_path.relative_to(tmp_path)),
        str(r_path.relative_to(tmp_path)),
    )
    assert res["status"] == "REFUSED"
    problems = res.get("problems", [])
    assert any("runottawa_hash" in p and TARGET_BLOB in p for p in problems)


def test_promote_refuses_when_runottawa_hash_mismatch(tmp_path: Path):
    """Assert promote refuses when runottawa_hash is present but does not match TARGET_BLOB."""
    bad_hash = "9ec1bf4e7175910cfda2b9cdfa2a2cc4b104464f"
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="Ottawa",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=bad_hash,
    )
    res = uf.promote(
        tmp_path,
        str(s_path.relative_to(tmp_path)),
        str(d_path.relative_to(tmp_path)),
        str(r_path.relative_to(tmp_path)),
    )
    assert res["status"] == "REFUSED"
    problems = res.get("problems", [])
    assert any("runottawa_hash" in p and bad_hash in p for p in problems)

    fr = json.loads((tmp_path / ".agent" / "frontier.json").read_text(encoding="utf-8"))
    assert fr["verified_frontier"] == 0


def test_promote_succeeds_when_valid_runottawa_hash(tmp_path: Path):
    """Assert promote succeeds when runottawa_hash matches TARGET_BLOB and conditions hold."""
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="Ottawa",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=TARGET_BLOB,
        staged_deck="audit/runs/staged-decks/ottawa",
        completed_hour=100,
    )
    res = uf.promote(
        tmp_path,
        str(s_path.relative_to(tmp_path)),
        str(d_path.relative_to(tmp_path)),
        str(r_path.relative_to(tmp_path)),
    )
    assert res["status"] == "PROMOTED"
    assert res["from"] == 0
    assert res["to"] == 100
    assert res["advanced"] is True

    fr = json.loads((tmp_path / ".agent" / "frontier.json").read_text(encoding="utf-8"))
    assert fr["verified_frontier"] == 100
    assert len(fr["history"]) == 1
    h = fr["history"][0]
    assert h["op"] == "promote"
    assert h["to"] == 100
    assert h["runottawa_hash"] == TARGET_BLOB
    assert h["staged_deck"] == "audit/runs/staged-decks/ottawa"


def test_promote_non_ottawa_deck_without_hash(tmp_path: Path):
    """Assert promote succeeds for non-Ottawa decks without requiring runottawa_hash."""
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="NonOttawaCase",
        deck_path="other-examples/SiteB",
        runottawa_hash=None,
        completed_hour=50,
    )
    res = uf.promote(
        tmp_path,
        str(s_path.relative_to(tmp_path)),
        str(d_path.relative_to(tmp_path)),
        str(r_path.relative_to(tmp_path)),
    )
    assert res["status"] == "PROMOTED"
    assert res["to"] == 50

    fr = json.loads((tmp_path / ".agent" / "frontier.json").read_text(encoding="utf-8"))
    assert fr["verified_frontier"] == 50


def test_cli_promote_refusal_exit_code(tmp_path: Path):
    """Assert CLI update_frontier.py promote returns exit code 1 on refusal."""
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="Ottawa",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=None,
    )
    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS_DIR / "update_frontier.py"),
            "--root",
            str(tmp_path),
            "promote",
            "--summary",
            str(s_path.relative_to(tmp_path)),
            "--divcheck",
            str(d_path.relative_to(tmp_path)),
            "--restart",
            str(r_path.relative_to(tmp_path)),
        ],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 1, f"Expected returncode 1, got {proc.returncode}. Output: {proc.stdout}"
    data = json.loads(proc.stdout)
    assert data["status"] == "REFUSED"
    assert any("runottawa_hash" in p for p in data["problems"])


def test_cli_promote_success_exit_code(tmp_path: Path):
    """Assert CLI update_frontier.py promote returns exit code 0 on promotion."""
    s_path, d_path, r_path = make_test_env(
        tmp_path,
        case="Ottawa",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=TARGET_BLOB,
        completed_hour=240,
    )
    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS_DIR / "update_frontier.py"),
            "--root",
            str(tmp_path),
            "promote",
            "--summary",
            str(s_path.relative_to(tmp_path)),
            "--divcheck",
            str(d_path.relative_to(tmp_path)),
            "--restart",
            str(r_path.relative_to(tmp_path)),
        ],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"Expected returncode 0, got {proc.returncode}. Output: {proc.stdout} {proc.stderr}"
    data = json.loads(proc.stdout)
    assert data["status"] == "PROMOTED"
    assert data["to"] == 240


def test_record_preserves_runottawa_hash(tmp_path: Path):
    """Assert record operation records runottawa_hash in history when present."""
    s_path, _, _ = make_test_env(
        tmp_path,
        case="Ottawa",
        deck_path="ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON",
        runottawa_hash=TARGET_BLOB,
        staged_deck="audit/runs/staged-decks/ottawa",
        completed_hour=80,
    )
    res = uf.record(tmp_path, str(s_path.relative_to(tmp_path)))
    assert res["status"] == "RECORDED"
    assert res["simulation_frontier"] == 80

    fr = json.loads((tmp_path / ".agent" / "frontier.json").read_text(encoding="utf-8"))
    assert fr["simulation_frontier"] == 80
    assert len(fr["history"]) == 1
    h = fr["history"][0]
    assert h["op"] == "record"
    assert h["runottawa_hash"] == TARGET_BLOB
    assert h["staged_deck"] == "audit/runs/staged-decks/ottawa"
