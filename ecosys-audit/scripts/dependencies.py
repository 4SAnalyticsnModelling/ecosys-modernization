"""Content-bound dependencies for verdict reuse; old records are historical only."""
from __future__ import annotations
import argparse
import json
from functools import lru_cache
from pathlib import Path
from workflow import ROOT, ProtocolError, inside, encoded, atomic, digest, file_digest
from project_runtime import SOURCE_SCOPE, toolchain

SCIENCE = SOURCE_SCOPE + ['f77src', 'f77example', 'ecosys-ng-prod-examples']
MANDATORY = ['ecosys-audit/scripts', 'ecosys-audit/adapters', 'ecosys-audit/tests', 'ecosys-audit/gate_requirements.json',
             'ecosys-audit/suite_manifest.json', 'validation/rules', '.agent/toolchain.json',
             'audit/output-provenance.csv', 'audit/traceability/bindings.csv',
             'audit/intentional-deviations.md']


def stat_key(path):
    s=path.stat()
    return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)


@lru_cache(maxsize=50000)
def cached_hash(path, identity):
    value=file_digest(path)
    if stat_key(path)!=identity: raise ProtocolError('Dependency changed while hashing: '+str(path))
    return value


def tree_hash(root, name):
    """Include ignored staged decks too; Git inventory cannot identify their contents."""
    path=inside(root,name)
    if not path.exists(): return None
    if path==root.resolve(): raise ProtocolError('List dependency roots explicitly; repository root includes mutable runs/caches')
    paths=[path] if path.is_file() else sorted(p for p in path.rglob('*') if p.is_file())
    files=[]
    for p in paths:
        inside(root,str(p))
        files.append([str(p.relative_to(root)),cached_hash(p,stat_key(p))])
    return digest(encoded(files))


def capture(root: Path, *, scope=None, justification='', context=None):
    if scope is not None and (not scope or not justification.strip()):
        raise ProtocolError('Narrow dependencies need explicit scope and justification')
    selected = sorted(set((SCIENCE if scope is None else scope) + MANDATORY))
    for path in selected:
        inside(root, path)
    compilers = toolchain()
    for info in compilers.values():
        path = Path(info['path'])
        info['sha256'] = cached_hash(path,stat_key(path))
    payload = {'schema_version': 1, 'selection': 'conservative' if scope is None else 'narrow',
               'scope': scope, 'justification': justification, 'context': context or {},
               'contents': {p: tree_hash(root,p) for p in selected},
               'toolchain': compilers}
    return {**payload, 'digest': digest(encoded(payload))}


def verify(root, record):
    if not isinstance(record, dict) or record.get('schema_version') != 1:
        return ['missing dependency manifest; historical evidence requires revalidation']
    try:
        current = capture(root, scope=record['scope'], justification=record['justification'], context=record['context'])
        return [] if current == record else ['dependency manifest is stale or incomplete']
    except (OSError, KeyError, TypeError, ValueError, ProtocolError) as exc:
        return ['invalid dependency manifest: ' + str(exc)]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--scope', action='append'); p.add_argument('--justification', default='')
    p.add_argument('--context', default='{}', help='JSON build options/target/fixture identities')
    p.add_argument('--out'); a = p.parse_args()
    result = capture(ROOT, scope=a.scope, justification=a.justification, context=json.loads(a.context))
    if a.out: atomic(inside(ROOT, a.out), encoded(result))
    else: print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
