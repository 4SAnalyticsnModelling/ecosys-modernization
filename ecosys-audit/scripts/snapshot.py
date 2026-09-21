#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Hash the four preserved project trees; no builds or model modifications. Python 3.10+."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys

ROOTS = ('f77src', 'f77example', 'ecosys-ng', 'ecosys-ng-prod-examples')
EXCLUDED = ('.git', '.zig-cache', 'zig-cache', 'zig-out', '__pycache__')

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()

def safe_path(root: Path, value: str) -> Path:
    """Resolve a relative regular artifact path, rejecting traversal and symlinks."""
    rel = Path(value)
    if rel.is_absolute() or not rel.parts or '..' in rel.parts:
        raise ValueError(f'Expected a relative in-project path: {value!r}')
    result = root
    for part in rel.parts:
        result = result / part
        if result.is_symlink():
            raise ValueError(f'Unresolved symlink; freeze its target explicitly first: {result}')
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'Artifact escapes project: {value!r}')
    return result

def collect(root: Path) -> dict:
    root = root.resolve(strict=True)
    files: list[dict] = []
    excluded_paths: list[str] = []
    for folder in ROOTS:
        base = safe_path(root, folder)
        if not base.is_dir():
            raise ValueError(f'Missing authoritative directory: {base}')
        for current, directories, names in os.walk(base, followlinks=False):
            current = Path(current)
            kept = []
            for name in sorted(directories):
                path = current / name
                if name in EXCLUDED:
                    excluded_paths.append(path.relative_to(root).as_posix())
                elif path.is_symlink():
                    raise ValueError(f'Unresolved directory symlink: {path}')
                else:
                    kept.append(name)
            directories[:] = kept
            for name in sorted(names):
                path = current / name
                if path.is_symlink():
                    raise ValueError(f'Unresolved file symlink: {path}')
                if not path.is_file():
                    raise ValueError(f'Unsupported non-regular file: {path}')
                before = path.stat()
                digest = sha256(path)
                after = path.stat()
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    raise ValueError(f'File changed during snapshot: {path}')
                files.append({'path':path.relative_to(root).as_posix(), 'bytes':after.st_size, 'sha256':digest})
    return {'schema_version':1, 'created_utc':datetime.now(timezone.utc).isoformat(),
            'roots':list(ROOTS), 'excluded_directory_names':list(EXCLUDED),
            'excluded_paths':sorted(excluded_paths), 'files':sorted(files,key=lambda x:x['path'])}

def verify(root: Path, recorded: dict) -> list[str]:
    if recorded.get('schema_version') != 1 or recorded.get('roots') != list(ROOTS):
        return ['Snapshot format or root scope is invalid.']
    if recorded.get('excluded_directory_names') != list(EXCLUDED):
        return ['Snapshot exclusion policy differs from this pack.']
    entries = recorded.get('files')
    if not isinstance(entries,list) or not entries:
        return ['Snapshot has no inventoried files.']
    try:
        old = {entry['path']:(entry['bytes'],entry['sha256']) for entry in entries}
    except (KeyError,TypeError):
        return ['Malformed snapshot file record.']
    if len(old) != len(entries):
        return ['Duplicate paths in snapshot.']
    current = collect(root)
    new = {entry['path']:(entry['bytes'],entry['sha256']) for entry in current['files']}
    errors = [f'Source/input removed: {p}' for p in sorted(old.keys()-new.keys())]
    errors += [f'Source/input added: {p}' for p in sorted(new.keys()-old.keys())]
    errors += [f'Source/input changed: {p}' for p in sorted(old.keys() & new.keys()) if old[p] != new[p]]
    return errors

def write_new_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x',encoding='utf-8') as handle:
        json.dump(data,handle,indent=2,allow_nan=False)
        handle.write('\n')

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--out', required=True, help='New project-relative JSON path; existing evidence is never overwritten')
    args=parser.parse_args()
    try:
        root=args.root.resolve(strict=True)
        out=safe_path(root,args.out)
        if out.exists():
            raise ValueError(f'Output exists; use a new candidate-specific path: {out}')
        if any(out.is_relative_to(root / name) for name in ROOTS):
            raise ValueError('Store manifests outside the four snapshotted trees, for example under audit/manifest/.')
        data=collect(root)
        if not data['files']:
            raise ValueError('No files found; an empty snapshot cannot support an audit.')
        write_new_json(out,data)
        print(json.dumps({'path':str(out),'files':len(data['files']),'sha256':sha256(out)},indent=2))
        return 0
    except (OSError,ValueError) as exc:
        print(f'Snapshot stopped: {exc}',file=sys.stderr)
        return 2

if __name__=='__main__':
    raise SystemExit(main())
