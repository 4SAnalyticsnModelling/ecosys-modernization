"""Repository-local execution and stable source identity. No model or science decisions."""
from __future__ import annotations
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
from workflow import ROOT, ProtocolError, inside

CACHE_DIRS = {'TMPDIR': '.tmp', 'XDG_CACHE_HOME': '.cache', 'UV_CACHE_DIR': '.uv-cache',
              'ZIG_GLOBAL_CACHE_DIR': 'ecosys-ng/.zig-cache-global', 'PYTHONPYCACHEPREFIX': '.cache/python',
              'HF_HOME': '.cache/huggingface'}
SOURCE_SCOPE = ['ecosys-ng/src', 'ecosys-ng/build.zig', 'ecosys-ng/build.zig.zon']
GATE_SCOPE = SOURCE_SCOPE + ['ecosys-audit/scripts', 'ecosys-audit/tests', 'tools', 'scripts', '.agents/skills']

def environment(root: Path = ROOT) -> dict:
    env = dict(os.environ)
    for name, rel in CACHE_DIRS.items():
        p = inside(root, rel); p.mkdir(parents=True, exist_ok=True); env[name] = str(p)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    return env


def git(root: Path, *args: str) -> bytes:
    p = subprocess.run(['git', *args], cwd=root, capture_output=True)
    if p.returncode:
        raise ProtocolError(p.stderr.decode(errors='replace')[:500])
    return p.stdout


def content_digest(root: Path = ROOT, scope=None) -> str:
    """Hash actual source contents, stable across documentation-only commits and staging."""
    scope = GATE_SCOPE if scope is None else scope
    names = git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *scope)
    h = hashlib.sha256()
    for name in sorted(set(names.split(b'\0')) - {b''}):
        p = inside(root, os.fsdecode(name))
        if p.is_file():
            h.update(name + b'\0' + hashlib.sha256(p.read_bytes()).digest())
    return h.hexdigest()


def toolchain() -> dict:
    result = {}
    for name, args in [('zig', ['version']), ('uv', ['--version']), ('python3', ['--version'])]:
        exe = shutil.which(name)
        if exe:
            p = subprocess.run([exe, *args], capture_output=True, text=True)
            result[name] = {'path': exe, 'version': (p.stdout + p.stderr).strip(), 'exit_code': p.returncode}
    return result


def process_identity(pid: int) -> str | None:
    """PID plus kernel start time; prevents adoption of a recycled PID (POSIX hosts)."""
    p = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 and p.stdout.strip() else None


def owned_alive(record: dict) -> bool:
    pid, identity = record.get('pid'), record.get('process_start')
    return isinstance(pid, int) and bool(identity) and process_identity(pid) == identity
