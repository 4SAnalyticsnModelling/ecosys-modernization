"""Re-derive F4's denominator from sources, never from successful review rows."""
import argparse
import json
from workflow import ROOT, ProtocolError, artifact, inside
from project_runtime import git
import f77index


def collect(root):
    index=f77index.collect(root);items={};hashes={}
    def add(path,start,end,direction,dormant=False,suffix=''):
        ident=f'{direction}:{path}:{start}-{end}'+suffix
        if path not in hashes:hashes[path]=artifact(root,path)['sha256']
        items[ident]={'id':ident,'source':path,'source_sha256':hashes[path],
                     'line_start':start,'line_end':end,'direction':direction,'dormant':dormant}
    for f in index['files']:
        lines=f77index.read_lines(inside(root,f['path']))[0]
        for s in f77index.logical_statements(lines):
            add(f['path'],s['line_start'],s['line_end'],'legacy-to-zig',not f['in_build'])
        for s in f77index.comment_runs(lines):
            if s['kind']=='dormant-code':add(f['path'],s['line_start'],s['line_end'],'legacy-to-zig',True,':comment')
    for b in index['commons']:
        for member in b['members']:
            add(b['declared_in'],b['line_start'],b['line_end'],'state-binding',False,':'+b['name']+':'+member['name'])
    # Conservative physical-line coverage also includes helpers, comments and build logic.
    # It is a denominator, not a substitute for parsing/reviewing Zig semantics.
    paths=git(root,'ls-files','--cached','--others','--exclude-standard','--','ecosys-ng','f77src').decode().splitlines()
    indexed={f['path'] for f in index['files']}
    for path in sorted(set(paths)):
        p=inside(root,path)
        direction='zig-to-legacy' if path.endswith('.zig') and path.startswith('ecosys-ng/') else 'legacy-to-zig'
        if path in indexed or not p.is_file():continue
        if direction=='legacy-to-zig' and not (path.startswith('f77src/') and p.suffix.lower() in ('.c','.h','.f','.for','.f90','.inc')):continue
        if direction=='zig-to-legacy' or path.startswith('f77src/'):
            for n,line in enumerate(p.read_text(encoding='latin-1').splitlines(),1):
                if line.strip():add(path,n,n,direction)
    if not items:raise ProtocolError('empty generated source scope')
    return items


def check(root,required):
    try:expected=collect(root)
    except f77index.IndexError_ as exc:raise ProtocolError(str(exc)) from exc
    if set(required)!=set(expected):raise ProtocolError('source inventory differs from regenerated statement/COMMON/Zig denominator')
    for key,item in expected.items():
        if any(required[key].get(k)!=v for k,v in item.items()):raise ProtocolError('source inventory location/hash mismatch: '+key)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True);a=p.parse_args()
    with inside(ROOT,a.out).open('x') as f:json.dump({'items':list(collect(ROOT).values()),'status':'UNREVIEWED'},f,indent=2)
