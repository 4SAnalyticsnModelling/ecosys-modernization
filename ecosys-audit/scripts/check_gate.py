#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Check gate bookkeeping, artifact hashes and source freshness, not scientific truth."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import sys
from snapshot import safe_path, sha256, verify

REQUIREMENTS = json.loads((Path(__file__).resolve().parents[1] / 'gate_requirements.json').read_text(encoding='utf-8'))
HASH_RE=re.compile(r'^[0-9a-f]{64}$')

def nonempty(value: object) -> bool:
    return isinstance(value,str) and bool(value.strip())

def check(root: Path, gate: dict) -> list[str]:
    root=root.resolve(strict=True)
    errors: list[str]=[]
    if not isinstance(gate,dict) or gate.get('schema_version') != 1:
        return ['Invalid gate schema/version.']
    stage=gate.get('stage')
    if not isinstance(stage,str) or stage not in REQUIREMENTS:
        return ['Unknown gate stage.']
    subject=gate.get('snapshot')
    if not isinstance(subject,dict):
        return ['Missing snapshot binding.']
    try:
        expected=subject.get('sha256')
        if not isinstance(expected,str) or not HASH_RE.fullmatch(expected):
            raise ValueError('Snapshot digest is missing/invalid.')
        snapshot_path=safe_path(root,subject['path'])
        if not snapshot_path.is_file() or sha256(snapshot_path)!=expected:
            raise ValueError('Snapshot artifact is missing or its hash changed.')
        recorded=json.loads(snapshot_path.read_text(encoding='utf-8'))
        if not isinstance(recorded,dict):
            raise ValueError('Malformed snapshot JSON.')
        errors.extend(verify(root,recorded))
    except (OSError,ValueError,KeyError,TypeError) as exc:
        errors.append(f'Snapshot: {exc}')
    records=gate.get('checks')
    if not isinstance(records,list):
        return errors+['Gate checks must be a list.']
    ids=[record.get('id') if isinstance(record,dict) else None for record in records]
    if any(not isinstance(item,str) for item in ids):
        return errors+['Each check needs a string ID.']
    if len(set(ids)) != len(ids):
        errors.append('Duplicate check IDs.')
    required=set(REQUIREMENTS[stage])
    if set(ids)!=required:
        errors.append(f'Check inventory mismatch. Missing={sorted(required-set(ids))}; extra={sorted(set(ids)-required)}')
    for record in records:
        ident=record['id']
        if record.get('status')!='PASS':
            errors.append(f'{ident}: status is not PASS.')
        author,reviewer=record.get('author'),record.get('reviewer')
        if not nonempty(author) or not nonempty(reviewer):
            errors.append(f'{ident}: author and independent reviewer are required.')
        elif author.strip().casefold()==reviewer.strip().casefold():
            errors.append(f'{ident}: author/reviewer labels must be distinct; actual independence still needs review.')
        evidence=record.get('evidence')
        if not isinstance(evidence,list) or not evidence:
            errors.append(f'{ident}: no evidence artifacts.')
            continue
        for item in evidence:
            try:
                if not isinstance(item,dict):
                    raise ValueError('Evidence must be an object.')
                expected=item.get('sha256')
                if not isinstance(expected,str) or not HASH_RE.fullmatch(expected):
                    raise ValueError('Missing/invalid evidence digest.')
                path=safe_path(root,item['path'])
                if not path.is_file() or path.stat().st_size==0:
                    raise ValueError('Evidence missing or empty.')
                if sha256(path)!=expected:
                    raise ValueError('Evidence content hash changed.')
            except (OSError,ValueError,KeyError,TypeError) as exc:
                errors.append(f'{ident}: {exc}')
    return errors

def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path('.'))
    parser.add_argument('--gate',required=True,help='Project-relative reviewed gate JSON path')
    args=parser.parse_args()
    try:
        root=args.root.resolve(strict=True)
        path=safe_path(root,args.gate)
        gate=json.loads(path.read_text(encoding='utf-8'))
        errors=check(root,gate)
        print(json.dumps({'integrity_status':'FAIL' if errors else 'PASS','problems':errors,
                          'limitation':'Checks records/hashes/freshness only. Does not prove scientific correctness, authenticate reviews, or authorize bypassing other project gates.'},indent=2))
        return 1 if errors else 0
    except (OSError,ValueError,TypeError) as exc:
        print(json.dumps({'integrity_status':'ERROR','message':str(exc)},indent=2))
        return 2

if __name__=='__main__':
    raise SystemExit(main())
