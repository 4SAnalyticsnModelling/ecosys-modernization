# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Preflight: the two mandates that a fresh session most easily violates.

Checks, without building, testing or running anything:

1. **Toolchain (protocol.md §8, gate G1)** — `zig` reports a 0.17.x version and
   `ecosys-ng/build.zig.zon` declares `minimum_zig_version = "0.17.0"`. Zig 0.16 is retired;
   evidence produced with it is historical and cannot close a current gate.
2. **Containment (protocol.md §8a, gate G9)** — caches and scratch are pointed inside the
   repository, and no command argument resolves to a path outside the repository root.
   Use `--command` to vet a command line *before* running it.
3. **Sync (protocol.md §7, gate G8)** — the branch is `main` and `HEAD` matches `origin/main`.
4. **Cycle ledger** — `.agent/cycle.json` status is a known status, reported for the pickup ritual.

Exit code 0 = PASS (warnings allowed), 1 = at least one FAIL, 2 = the checker itself failed.
`--json` prints the machine-readable form for a cycle record; `--allow-unpushed` downgrades the
G8 sha mismatch to a warning when a push is known to be pending (network/auth) so the rest of
the checks still report.

Usage: uv run ecosys-audit/scripts/preflight.py [--json] [--allow-unpushed]
       uv run ecosys-audit/scripts/preflight.py --command "zig build -Doptimize=Debug"
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLCHAIN_FILE = ROOT / ".agent" / "toolchain.json"
BUILD_ZON = ROOT / "ecosys-ng" / "build.zig.zon"
CYCLE_FILE = ROOT / ".agent" / "cycle.json"
KNOWN_STATUSES = {"PLANNING", "WORKING", "VERIFYING", "DECIDED", "PUSHED", "BLOCKED"}
ENV_VARS = ("TMPDIR", "TMP", "TEMP", "UV_CACHE_DIR", "XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR")


def finding(check: str, level: str, detail: str) -> dict:
    return {"check": check, "level": level, "detail": detail}


def zig_reported_version(zig_bin: str) -> str | None:
    """Return the compiler's own version string, or None if it cannot be read."""
    try:
        out = subprocess.run([zig_bin, "version"], capture_output=True, text=True, timeout=None)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def check_zig(pinned_prefix: str) -> list[dict]:
    zig_bin = shutil.which("zig")
    if not zig_bin:
        return [finding("zig-version", "FAIL",
                        "no `zig` on PATH; install Zig 0.17.x (prefer a repo-local tools/zig/) — "
                        "do not substitute a 0.16 toolchain (protocol.md §8)")]
    version = zig_reported_version(zig_bin)
    if version is None:
        return [finding("zig-version", "FAIL", f"`{zig_bin} version` did not succeed")]
    if not version.startswith(pinned_prefix):
        return [finding("zig-version", "FAIL",
                        f"`{zig_bin} version` = {version}, expected {pinned_prefix}* (Zig 0.16 is "
                        "retired; ecosys-ng builds only with 0.17.x)")]
    return [finding("zig-version", "PASS", f"{zig_bin} -> {version}")]


def check_zon_pin(text: str, required: str) -> list[dict]:
    match = re.search(r"\.minimum_zig_version\s*=\s*\"([^\"]+)\"", text)
    if not match:
        return [finding("build-zon-pin", "FAIL",
                        f"{BUILD_ZON.relative_to(ROOT)} declares no minimum_zig_version")]
    declared = match.group(1)
    if declared != required:
        return [finding("build-zon-pin", "FAIL",
                        f"minimum_zig_version = {declared!r}, must be {required!r} "
                        "(execute .agent/migrations/zig-0.17.md)")]
    return [finding("build-zon-pin", "PASS", f"minimum_zig_version = {declared}")]


def outside_root(path: str, root: Path, cwd: Path) -> Path | None:
    """Resolve one candidate path; return it if it lands outside the repository root."""
    raw = path.strip().strip("'\"")
    if not raw or raw.startswith("-") or "://" in raw:
        return None
    if not (raw.startswith(("/", "./", "../", "~")) or "/" in raw or raw.startswith("..")):
        return None
    if raw.startswith("~"):
        candidate = Path(raw).expanduser()
    elif raw.startswith("/"):
        candidate = Path(raw)
    else:
        candidate = cwd / raw
    try:
        resolved = candidate.resolve()
    except OSError:
        return None
    try:
        resolved.relative_to(root)
    except ValueError:
        return resolved
    return None


def check_command(command: str, root: Path, cwd: Path) -> list[dict]:
    offenders = []
    for token in command.split():
        escaped = outside_root(token, root, cwd)
        if escaped is not None:
            offenders.append(str(escaped))
    if offenders:
        return [finding("containment", "FAIL",
                        f"command writes/reads outside the repository: {', '.join(sorted(set(offenders)))}; "
                        "redirect it into the repo (TMPDIR/UV_CACHE_DIR/ZIG_GLOBAL_CACHE_DIR/--cache-dir) "
                        "or record a blocker (protocol.md §8a)")]
    return [finding("containment", "PASS", "no command argument escapes the repository root")]


def check_environment(env: dict, root: Path) -> list[dict]:
    results = []
    for name in ENV_VARS:
        value = (env.get(name) or "").strip()
        if not value:
            continue
        escaped = outside_root(value, root, root)
        if escaped is not None:
            results.append(finding(f"env:{name}", "WARN",
                                   f"{name}={value} points outside the repository; export it to a "
                                   "repo-local directory for build/test/run commands"))
        else:
            results.append(finding(f"env:{name}", "PASS", f"{name} is repo-local"))
    missing = [name for name in ("TMPDIR", "UV_CACHE_DIR", "ZIG_GLOBAL_CACHE_DIR") if not (env.get(name) or "").strip()]
    if missing:
        results.append(finding("env:repo-local-caches", "WARN",
                               "not exported in this shell: " + ", ".join(missing) +
                               " — export them (mkdir -p first) for any build, test or run command "
                               "so caches land inside the repository (protocol.md §8a)"))
    return results


def git_output(args: list[str], root: Path) -> str | None:
    try:
        out = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, timeout=None)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def check_git(root: Path, allow_unpushed: bool) -> list[dict]:
    results = []
    branch = git_output(["rev-parse", "--abbrev-ref", "HEAD"], root)
    if branch is None:
        return [finding("git-sync", "FAIL", "git is not usable in this directory")]
    if branch != "main":
        results.append(finding("git-branch", "FAIL",
                               f"HEAD is on {branch!r}; this mission works on main only"))
    else:
        results.append(finding("git-branch", "PASS", "HEAD is on main"))
    head = git_output(["rev-parse", "HEAD"], root)
    remote = git_output(["rev-parse", "origin/main"], root)
    if remote is None:
        results.append(finding("git-sync", "WARN",
                               "origin/main is unknown locally — ./sync-main.sh pull, and push at cycle end"))
    elif head == remote:
        results.append(finding("git-sync", "PASS", f"HEAD == origin/main ({head[:9]})"))
    else:
        level = "WARN" if allow_unpushed else "FAIL"
        results.append(finding("git-sync", level,
                               f"HEAD {head[:9] if head else '?'} != origin/main "
                               f"{remote[:9]} — a cycle is not closed until main is on GitHub (§7)"))
    status = git_output(["status", "--porcelain"], root)
    if status:
        results.append(finding("git-dirty", "WARN",
                               f"{len(status.splitlines())} uncommitted path(s) — commit or revert; "
                               "never leave main dirty between cycles"))
    return results


def check_cycle(root: Path) -> list[dict]:
    path = CYCLE_FILE
    if not path.exists():
        return [finding("cycle-ledger", "WARN", ".agent/cycle.json missing — open a cycle with cycle_runner.py")]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [finding("cycle-ledger", "FAIL", f".agent/cycle.json unreadable: {exc}")]
    status = str(data.get("status", "")).upper()
    cycle = data.get("cycle", data.get("cycle_id", "?"))
    if status not in KNOWN_STATUSES:
        return [finding("cycle-ledger", "FAIL", f"unknown cycle status {status!r} (cycle {cycle})")]
    hint = {"PUSHED": "close it and open the next cycle", "BLOCKED": "work the next unblocked backlog item",
            "PLANNING": "finish the plan, then work"}.get(status, "finish this cycle before opening another")
    return [finding("cycle-ledger", "PASS", f"cycle {cycle} is {status} — {hint}")]


def load_pin() -> tuple[str, str]:
    try:
        data = json.loads(TOOLCHAIN_FILE.read_text(encoding="utf-8"))
        zig = data["ecosys_ng"]["zig"]
        return str(zig["expected_reported_prefix"]), str(zig["declared_value_required"])
    except (OSError, ValueError, KeyError):
        return "0.17.", "0.17.0"


def run(argv: list[str], root: Path, cwd: Path, env: dict) -> tuple[list[dict], int]:
    prefix, required = load_pin()
    findings: list[dict] = []
    parser = argparse.ArgumentParser(prog="preflight.py")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--allow-unpushed", action="store_true")
    parser.add_argument("--command", default=None)
    opts = parser.parse_args(argv)

    findings += check_zig(prefix)
    if BUILD_ZON.exists():
        findings += check_zon_pin(BUILD_ZON.read_text(encoding="utf-8"), required)
    else:
        findings.append(finding("build-zon-pin", "FAIL", f"{BUILD_ZON} not found"))
    if opts.command:
        findings += check_command(opts.command, root, cwd)
    findings += check_environment(env, root)
    findings += check_git(root, opts.allow_unpushed)
    findings += check_cycle(root)

    if opts.json:
        print(json.dumps({"root": str(root), "findings": findings}, indent=2))
    else:
        for item in findings:
            print(f"{item['level']:4} {item['check']:24} {item['detail']}")
        failures = [f for f in findings if f["level"] == "FAIL"]
        print(("PREFLIGHT FAIL: " + str(len(failures)) + " blocking finding(s)") if failures
              else "PREFLIGHT PASS")
    return findings, (1 if any(f["level"] == "FAIL" for f in findings) else 0)


def main() -> int:
    try:
        _, code = run(sys.argv[1:], ROOT, Path.cwd(), dict(os.environ))
        return code
    except (OSError, ValueError) as exc:  # the checker itself broke
        print(f"preflight: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
