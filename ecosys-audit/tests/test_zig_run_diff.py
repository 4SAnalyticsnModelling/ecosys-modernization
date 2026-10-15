# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pytest",
# ]
# ///
"""Pytest suite for zig_run_diff.py — the same-toolchain output comparator.

The comparator decides determinism and cross-optimisation claims, so it is tested as an
instrument, not as a convenience:

1. Byte-identical streams report IDENTICAL (exit 0), with the cells actually compared.
2. A one-digit change in one cell of one row is detected, and the report names the file, the
   calendar key, the column and both values (a report that only says "different" is useless).
3. A row present on one side only makes the streams non-identical by default, and with
   `--allow-extra-rows` it is counted and reported instead of silently ignored.
4. A spelling-only difference (`-0e0` vs `0e0`) is not hidden: it is reported as a differing cell
   flagged `text_only`, with zero magnitude.
5. A header difference is reported as a failure of that stream.
6. Non-numeric garbage in a cell that differs counts as differing (infinite difference), never as
   equal.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "ecosys-audit" / "scripts" / "zig_run_diff.py"

HEADER = "year\tday_of_year\tmonth\tday\thour\tlongitude\twater[kg]\tcarbon[g]"


def rows(n: int, water: str = "1.2345678901234567e-3") -> list[str]:
    """Rows written as the model writes them: decimal text, exactly as parsed later."""
    return [f"1998\t{doy}\t1\t{doy}\t0\t-75.7\t{water}\t3.5e0" for doy in range(1, n + 1)]


def write_tree(root: Path, files: dict[str, list[str]]) -> Path:
    out = root / "modelled_outputs" / "water"
    out.mkdir(parents=True, exist_ok=True)
    for name, lines in files.items():
        (out / name).write_text("\n".join([HEADER, *lines]) + "\n", encoding="utf-8")
    return root


def run(a: Path, b: Path, *extra: str) -> tuple[int, dict]:
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--a", str(a), "--b", str(b), *extra],
        capture_output=True, text=True, check=False,
    )
    return proc.returncode, json.loads(proc.stdout)


def test_identical_streams_exit_zero(tmp_path: Path) -> None:
    files = {"cell_f25wh1.txt": rows(5)}
    a = write_tree(tmp_path / "a", files)
    b = write_tree(tmp_path / "b", files)
    code, rep = run(a, b)
    assert code == 0, rep
    assert rep["status"] == "IDENTICAL"
    assert rep["files_compared"] == 1
    assert rep["one_sided_rows"] == 0


def test_one_digit_change_is_located(tmp_path: Path) -> None:
    base = rows(5)
    a = write_tree(tmp_path / "a", {"cell_f25wh1.txt": list(base)})
    mutated = list(base)
    # `0.1` and `0.10000000000000002` are neighbouring f64 values: the smallest change a
    # rebuilt binary can produce, and the case a 1e-6 tolerance would happily swallow.
    mutated[2] = mutated[2].replace("1.2345678901234567e-3", "0.10000000000000002")
    assert mutated[2] != base[2]
    b = write_tree(tmp_path / "b", {"cell_f25wh1.txt": mutated})
    code, rep = run(a, b, "--json", str(tmp_path / "r.json"))
    assert code == 1, rep
    assert rep["status"] == "DIFFERENT"
    first = rep["first_difference"]
    assert first["key"] == ["1998", "3", "0"], first
    assert first["column"] == "water[kg]", first
    assert first["a"] == "1.2345678901234567e-3" and first["b"] == "0.10000000000000002"
    assert rep["worst_overall"]["abs"] > 0.0
    assert json.loads((tmp_path / "r.json").read_text())["streams"][0]["cells_compared"] == 10


def test_same_double_written_differently_is_reported_as_text_only(tmp_path: Path) -> None:
    """Two decimal spellings of the same f64 are not a value difference, and are not hidden."""
    a = write_tree(tmp_path / "a", {"cell_f25wh1.txt": ["1998\t1\t1\t1\t0\t-75.7\t1.2345678901234567e-3\t3.5e0"]})
    b = write_tree(tmp_path / "b", {"cell_f25wh1.txt": ["1998\t1\t1\t1\t0\t-75.7\t0.0012345678901234567\t3.5e0"]})
    assert float("1.2345678901234567e-3") == float("0.0012345678901234567")
    code, rep = run(a, b, "--json", str(tmp_path / "r.json"))
    assert code == 1, rep
    stream = json.loads((tmp_path / "r.json").read_text())["streams"][0]
    assert stream["cells_differing"] == 1 and stream["cells_text_only"] == 1 and stream["max_abs"] == 0.0


def test_truncation_default_fails_flag_counts_it(tmp_path: Path) -> None:
    a = write_tree(tmp_path / "a", {"cell_f25wh1.txt": rows(8)})
    b = write_tree(tmp_path / "b", {"cell_f25wh1.txt": rows(5)})
    code, rep = run(a, b)
    assert code == 1 and rep["status"] == "DIFFERENT"
    code, rep = run(a, b, "--allow-extra-rows")
    assert code == 0, rep
    assert rep["status"] == "IDENTICAL"
    assert rep["one_sided_rows"] == 3


def test_spelling_only_difference_is_not_hidden(tmp_path: Path) -> None:
    a = write_tree(tmp_path / "a", {"cell_f25wh1.txt": ["1998\t1\t1\t1\t0\t-75.7\t-0e0\t3.5e0"]})
    b = write_tree(tmp_path / "b", {"cell_f25wh1.txt": ["1998\t1\t1\t1\t0\t-75.7\t0e0\t3.5e0"]})
    code, rep = run(a, b, "--json", str(tmp_path / "r.json"))
    assert code == 1, rep
    stream = json.loads((tmp_path / "r.json").read_text())["streams"][0]
    assert stream["cells_differing"] == 1 and stream["cells_text_only"] == 1
    assert stream["max_abs"] == 0.0 and stream["max_rel"] == 0.0
    assert stream["first_diff"]["a"] == "-0e0"


def test_header_difference_is_a_failure(tmp_path: Path) -> None:
    a = write_tree(tmp_path / "a", {"cell_f25wh1.txt": rows(2)})
    b_root = tmp_path / "b"
    write_tree(b_root, {"cell_f25wh1.txt": rows(2)})
    f = b_root / "modelled_outputs" / "water" / "cell_f25wh1.txt"
    f.write_text(f.read_text(encoding="utf-8").replace("carbon[g]", "carbon[g C]"), encoding="utf-8")
    code, rep = run(a, b_root, "--json", str(tmp_path / "r.json"))
    assert code == 1, rep
    stream = json.loads((tmp_path / "r.json").read_text())["streams"][0]
    assert stream["header_identical"] is False and stream["identical"] is False
    assert stream["header_diff"]["b_only"] == ["carbon[g C]"]


def test_non_numeric_cell_is_never_equal(tmp_path: Path) -> None:
    a = write_tree(tmp_path / "a", {"cell_f25wh1.txt": ["1998\t1\t1\t1\t0\t-75.7\t1e0\t3.5e0"]})
    b = write_tree(tmp_path / "b", {"cell_f25wh1.txt": ["1998\t1\t1\t1\t0\t-75.7\tNaN\t3.5e0"]})
    code, rep = run(a, b)
    assert code == 1, rep
    assert rep["first_difference"]["b"] == "NaN"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
