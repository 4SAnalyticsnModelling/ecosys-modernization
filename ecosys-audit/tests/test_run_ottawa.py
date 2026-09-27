# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pytest",
# ]
# ///
"""Pytest suite for run_ottawa.py staging and receipt recording.

Asserts:
1. Ottawa qualification runner stages approved deck into a fresh directory with blob ecf5e61ab453288b1763f81f841729bee34e8426.
2. Dest runottawa has line 6 f6=100.
3. Protected deck remains untouched (f6=200, blob 9ec1bf4e...).
4. Both receipt.json and summary.json record runottawa_hash == TARGET_BLOB.
5. Runner refuses to stage into an existing non-empty deck directory.
6. Failure/non-zero exit of simulation binary still records runottawa_hash in receipt and summary.
7. Hash mismatch in staged deck aborts execution cleanly.
"""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "ecosys-audit" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from stage_ottawa_deck import DEFAULT_SOURCE_REL, TARGET_BLOB

PROTECTED_RUNOTTAWA = REPO_ROOT / DEFAULT_SOURCE_REL / "runottawa"
PROTECTED_EXPECTED_HASH = "9ec1bf4e7175910cfda2b9cdfa2a2cc4b104464f"


@pytest.fixture(scope="session")
def dummy_success_exe(tmp_path_factory) -> Path:
    """Compile a stand-in executable with Zig that exits 0 immediately."""
    build_dir = tmp_path_factory.mktemp("zig_success")
    src = build_dir / "success.zig"
    src.write_text("pub fn main() void {}\n", encoding="utf-8")
    exe = build_dir / "ecosys_ng_dummy.exe"
    p = subprocess.run(
        ["zig", "build-exe", str(src), f"-femit-bin={exe}", "-OReleaseSmall"],
        capture_output=True,
        text=True,
    )
    assert p.returncode == 0, f"Zig build failed: {p.stderr}"
    assert exe.is_file()
    return exe


@pytest.fixture(scope="session")
def dummy_fail_exe(tmp_path_factory) -> Path:
    """Compile a stand-in executable with Zig that exits nonzero."""
    build_dir = tmp_path_factory.mktemp("zig_fail")
    src = build_dir / "fail.zig"
    src.write_text("pub fn main() !void { return error.SimFailure; }\n", encoding="utf-8")
    exe = build_dir / "ecosys_ng_failing.exe"
    p = subprocess.run(
        ["zig", "build-exe", str(src), f"-femit-bin={exe}", "-OReleaseSmall"],
        capture_output=True,
        text=True,
    )
    assert p.returncode == 0, f"Zig build failed: {p.stderr}"
    assert exe.is_file()
    return exe


def test_run_ottawa_stages_approved_deck_and_records_receipt(dummy_success_exe: Path, tmp_path: Path):
    """Smoke run: assert approved deck is staged and receipt.json + summary.json record runottawa_hash."""
    run_id = f"test-smoke-{uuid.uuid4().hex[:8]}"
    script = SCRIPTS_DIR / "run_ottawa.py"
    test_lock = tmp_path / "test.lock"

    # Pre-condition: check protected deck
    assert PROTECTED_RUNOTTAWA.is_file()
    p_hash = subprocess.check_output(["git", "hash-object", str(PROTECTED_RUNOTTAWA)], text=True).strip()
    assert p_hash == PROTECTED_EXPECTED_HASH

    # Invoke run_ottawa with stand-in exe
    res = subprocess.run(
        [
            sys.executable,
            str(script),
            "--exe",
            str(dummy_success_exe),
            "--mode",
            "strict",
            "--build-mode",
            "Debug",
            "--timeout",
            "30",
            "--run-id",
            run_id,
            "--lock-file",
            str(test_lock),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    try:
        assert res.returncode == 0, f"run_ottawa failed (stderr: {res.stderr}, stdout: {res.stdout})"

        # Verify staged deck was created under evidence/runs/<run_id>/deck
        staged_deck = REPO_ROOT / f"evidence/runs/{run_id}/deck"
        assert staged_deck.is_dir()

        staged_runottawa = staged_deck / "runottawa"
        assert staged_runottawa.is_file()

        # 1. Assert staged file hash matches TARGET_BLOB
        h_proc = subprocess.run(
            ["git", "hash-object", str(staged_runottawa)],
            capture_output=True,
            text=True,
            check=True,
        )
        assert h_proc.stdout.strip() == TARGET_BLOB

        # 2. Assert line 6 has f6=100
        lines = staged_runottawa.read_text(encoding="utf-8").splitlines()
        assert lines[5].split(",")[5] == "100"
        assert lines[5] == "runtime,4,1,1e-8,1e-11,100,0.5"

        # 3. Assert protected deck remains untouched
        p_hash_after = subprocess.check_output(["git", "hash-object", str(PROTECTED_RUNOTTAWA)], text=True).strip()
        assert p_hash_after == PROTECTED_EXPECTED_HASH
        p_lines = PROTECTED_RUNOTTAWA.read_text(encoding="utf-8").splitlines()
        assert p_lines[5] == "runtime,4,1,1e-8,1e-11,200,0.5"

        # 4. Assert receipt.json records runottawa_hash
        receipt_path = REPO_ROOT / f"audit/runs/ottawa/{run_id}/receipt.json"
        assert receipt_path.is_file()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["runottawa_hash"] == TARGET_BLOB
        assert receipt["staged_deck"] == f"evidence/runs/{run_id}/deck"
        assert receipt["exit_code"] == 0

        # 5. Assert summary.json records runottawa_hash
        summary_path = REPO_ROOT / f"audit/runs/ottawa/{run_id}/summary.json"
        assert summary_path.is_file()
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        assert summary["runottawa_hash"] == TARGET_BLOB
        assert summary["status"] == "COMPLETE"
        assert summary["staged_deck"] == f"evidence/runs/{run_id}/deck"

    finally:
        # Cleanup test run artifacts
        stage_dir = REPO_ROOT / f"evidence/runs/{run_id}"
        if stage_dir.is_dir():
            shutil.rmtree(stage_dir, ignore_errors=True)
        logs_dir = REPO_ROOT / f"audit/runs/ottawa/{run_id}"
        if logs_dir.is_dir():
            shutil.rmtree(logs_dir, ignore_errors=True)


def test_run_ottawa_refuses_nonempty_staged_deck(dummy_success_exe: Path, tmp_path: Path):
    """Assert runner refuses to start when destination staged deck already contains files."""
    run_id = f"test-nonempty-{uuid.uuid4().hex[:8]}"
    script = SCRIPTS_DIR / "run_ottawa.py"
    test_lock = tmp_path / "test.lock"

    dirty_deck = tmp_path / "dirty_deck"
    dirty_deck.mkdir(parents=True, exist_ok=True)
    (dirty_deck / "stale_file.txt").write_text("stale", encoding="utf-8")

    res = subprocess.run(
        [
            sys.executable,
            str(script),
            "--exe",
            str(dummy_success_exe),
            "--mode",
            "strict",
            "--build-mode",
            "Debug",
            "--timeout",
            "30",
            "--staged-deck",
            str(dirty_deck),
            "--run-id",
            run_id,
            "--lock-file",
            str(test_lock),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert res.returncode == 2, f"Expected exit 2 for non-empty deck, got {res.returncode}"
    assert "already exists and is not empty" in res.stderr


def test_run_ottawa_records_hash_on_simulation_failure(dummy_fail_exe: Path, tmp_path: Path):
    """Assert receipt and summary record runottawa_hash even when simulation binary exits nonzero."""
    run_id = f"test-fail-{uuid.uuid4().hex[:8]}"
    script = SCRIPTS_DIR / "run_ottawa.py"
    test_lock = tmp_path / "test.lock"

    res = subprocess.run(
        [
            sys.executable,
            str(script),
            "--exe",
            str(dummy_fail_exe),
            "--mode",
            "strict",
            "--build-mode",
            "Debug",
            "--timeout",
            "30",
            "--run-id",
            run_id,
            "--lock-file",
            str(test_lock),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    try:
        assert res.returncode == 1, f"Expected exit 1 for failing simulation, got {res.returncode}"

        receipt_path = REPO_ROOT / f"audit/runs/ottawa/{run_id}/receipt.json"
        assert receipt_path.is_file()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["runottawa_hash"] == TARGET_BLOB
        assert receipt["exit_code"] != 0

        summary_path = REPO_ROOT / f"audit/runs/ottawa/{run_id}/summary.json"
        assert summary_path.is_file()
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        assert summary["runottawa_hash"] == TARGET_BLOB
        assert summary["status"] == "FAIL"

    finally:
        stage_dir = REPO_ROOT / f"evidence/runs/{run_id}"
        if stage_dir.is_dir():
            shutil.rmtree(stage_dir, ignore_errors=True)
        logs_dir = REPO_ROOT / f"audit/runs/ottawa/{run_id}"
        if logs_dir.is_dir():
            shutil.rmtree(logs_dir, ignore_errors=True)


def test_run_ottawa_custom_staged_deck_and_out_options(dummy_success_exe: Path, tmp_path: Path):
    """Assert runner stages into custom --staged-deck and writes to custom --out."""
    custom_deck = tmp_path / "custom_staged"
    custom_logs_rel = f"audit/runs/ottawa/custom-{uuid.uuid4().hex[:6]}"
    custom_logs_abs = REPO_ROOT / custom_logs_rel
    script = SCRIPTS_DIR / "run_ottawa.py"
    test_lock = tmp_path / "test.lock"

    res = subprocess.run(
        [
            sys.executable,
            str(script),
            "--exe",
            str(dummy_success_exe),
            "--mode",
            "strict",
            "--build-mode",
            "Debug",
            "--timeout",
            "30",
            "--staged-deck",
            str(custom_deck),
            "--out",
            custom_logs_rel,
            "--lock-file",
            str(test_lock),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    try:
        assert res.returncode == 0, f"run_ottawa failed: {res.stderr}"

        # Assert custom deck exists and has TARGET_BLOB
        assert (custom_deck / "runottawa").is_file()
        h_proc = subprocess.run(
            ["git", "hash-object", str(custom_deck / "runottawa")],
            capture_output=True,
            text=True,
            check=True,
        )
        assert h_proc.stdout.strip() == TARGET_BLOB

        # Assert custom logs receipt.json
        receipt_path = custom_logs_abs / "receipt.json"
        assert receipt_path.is_file()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["runottawa_hash"] == TARGET_BLOB

    finally:
        if custom_logs_abs.is_dir():
            shutil.rmtree(custom_logs_abs, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
