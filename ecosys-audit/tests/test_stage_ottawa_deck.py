# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pytest",
# ]
# ///
"""Pytest suite for stage_ottawa_deck.py.

Asserts:
1. Destination runottawa git hash matches ecf5e61ab453288b1763f81f841729bee34e8426.
2. Deck line 6 has f6=100 (runtime,4,1,1e-8,1e-11,100,0.5).
3. The source deck is byte-unchanged.
4. Nonzero exit when hash does not match target blob.
5. Deck is staged outside the repo directory.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "ecosys-audit" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from stage_ottawa_deck import (
    DEFAULT_SOURCE_REL,
    TARGET_BLOB,
    stage_ottawa_deck,
)

SOURCE_DECK_DIR = REPO_ROOT / DEFAULT_SOURCE_REL


def hash_all_files(directory: Path) -> dict[str, str]:
    """Compute sha256 for all files in a directory tree relative to directory."""
    hashes = {}
    for p in sorted(directory.rglob("*")):
        if p.is_file():
            rel = str(p.relative_to(directory)).replace("\\", "/")
            h = hashlib.sha256()
            with p.open("rb") as f:
                while chunk := f.read(65536):
                    h.update(chunk)
            hashes[rel] = h.hexdigest().lower()
    return hashes


def test_stage_ottawa_deck_direct(tmp_path: Path):
    """Test staging via python API: asserts hash, line 6 f6=100, source unchanged."""
    staged_dir = tmp_path / "staged_deck"

    # Pre-condition: record source deck state
    source_hashes_before = hash_all_files(SOURCE_DECK_DIR)
    assert len(source_hashes_before) == 78

    # Assert tmp_path is NOT inside the repository
    assert not staged_dir.resolve().is_relative_to(REPO_ROOT.resolve()), (
        f"Staged dir {staged_dir} must not be inside repo {REPO_ROOT}"
    )

    # Perform staging
    report = stage_ottawa_deck(out_dir=staged_dir, repo_root=REPO_ROOT)
    assert report["status"] == "DECK_STAGED"
    assert report["runottawa_hash"] == TARGET_BLOB

    # Assert 1: Destination runottawa hash matches target blob
    staged_runottawa = staged_dir / "runottawa"
    assert staged_runottawa.is_file()
    hash_proc = subprocess.run(
        ["git", "hash-object", str(staged_runottawa)],
        capture_output=True,
        text=True,
        check=True,
    )
    actual_hash = hash_proc.stdout.strip()
    assert actual_hash == TARGET_BLOB

    # Assert 2: Deck line 6 has f6=100
    lines = staged_runottawa.read_text(encoding="utf-8").splitlines()
    assert len(lines) >= 6
    line6 = lines[5]
    fields = line6.split(",")
    assert fields[0] == "runtime"
    assert fields[5] == "100", f"Expected f6=100 on line 6, got: {line6}"
    assert line6 == "runtime,4,1,1e-8,1e-11,100,0.5"

    # Assert 3: Source deck is byte-unchanged
    source_hashes_after = hash_all_files(SOURCE_DECK_DIR)
    assert source_hashes_after == source_hashes_before, "Source deck files were modified!"

    # Verify source runottawa still has original un-staged hash (9ec1bf4e...)
    src_hash_proc = subprocess.run(
        ["git", "hash-object", str(SOURCE_DECK_DIR / "runottawa")],
        capture_output=True,
        text=True,
        check=True,
    )
    assert src_hash_proc.stdout.strip() == "9ec1bf4e7175910cfda2b9cdfa2a2cc4b104464f"

    # Verify source runottawa line 6 still has f6=200
    src_lines = (SOURCE_DECK_DIR / "runottawa").read_text(encoding="utf-8").splitlines()
    assert src_lines[5] == "runtime,4,1,1e-8,1e-11,200,0.5"


def test_stage_ottawa_deck_cli(tmp_path: Path):
    """Test staging via CLI invocation."""
    staged_dir = tmp_path / "cli_staged_deck"
    script = SCRIPTS_DIR / "stage_ottawa_deck.py"

    source_hashes_before = hash_all_files(SOURCE_DECK_DIR)

    res = subprocess.run(
        [sys.executable, str(script), "--out", str(staged_dir)],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0, f"CLI staging failed with stderr: {res.stderr}"

    # Verify stdout report
    report = json.loads(res.stdout)
    assert report["status"] == "DECK_STAGED"
    assert report["runottawa_hash"] == TARGET_BLOB

    # Assert hash
    staged_runottawa = staged_dir / "runottawa"
    hash_proc = subprocess.run(
        ["git", "hash-object", str(staged_runottawa)],
        capture_output=True,
        text=True,
        check=True,
    )
    assert hash_proc.stdout.strip() == TARGET_BLOB

    # Assert line 6 f6=100
    lines = staged_runottawa.read_text(encoding="utf-8").splitlines()
    assert lines[5].split(",")[5] == "100"
    assert lines[5] == "runtime,4,1,1e-8,1e-11,100,0.5"

    # Assert source byte-unchanged
    assert hash_all_files(SOURCE_DECK_DIR) == source_hashes_before


def test_stage_ottawa_deck_mismatch_exits_nonzero(tmp_path: Path):
    """Assert nonzero exit if git hash-object does not equal the target blob."""
    staged_dir = tmp_path / "mismatch_deck"
    script = SCRIPTS_DIR / "stage_ottawa_deck.py"

    # Pass an intentionally bogus target blob
    bogus_blob = "0000000000000000000000000000000000000000"
    res = subprocess.run(
        [sys.executable, str(script), "--out", str(staged_dir), "--blob", bogus_blob],
        capture_output=True,
        text=True,
    )
    assert res.returncode != 0, "Expected nonzero exit code when blob cannot be verified"


def test_stage_ottawa_deck_requires_out_arg():
    """Assert missing --out exits nonzero."""
    script = SCRIPTS_DIR / "stage_ottawa_deck.py"
    res = subprocess.run(
        [sys.executable, str(script)],
        capture_output=True,
        text=True,
    )
    assert res.returncode != 0


def test_stage_ottawa_deck_hash_comparison_branch_fails(tmp_path: Path, monkeypatch):
    """Assert RuntimeError from hash-comparison branch when actual hash != blob_hash (SAGE T-00221)."""
    staged_dir = tmp_path / "corrupted_deck"
    real_run = subprocess.run

    def mock_run(args, **kwargs):
        if len(args) >= 2 and args[1] == "hash-object":
            # Simulate a mismatched hash returned by git hash-object
            return subprocess.CompletedProcess(args, 0, stdout="bad_hash_000000000000000000000000000000\n", stderr="")
        return real_run(args, **kwargs)

    monkeypatch.setattr(subprocess, "run", mock_run)
    with pytest.raises(RuntimeError, match="git hash-object verification failed"):
        stage_ottawa_deck(out_dir=staged_dir, repo_root=REPO_ROOT)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
