"""Preview/apply exact, hash-bound literal edits. Protected references are immutable."""
from __future__ import annotations
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
from workflow import ROOT, ProtocolError, atomic, inside

PROTECTED=('f77src','f77example','ecosys-ng-prod-examples','.git')

def prepare(root: Path, edits: list) -> list:
    if not edits:raise ProtocolError('empty codemod')
    result=[];seen=set()
    for edit in edits:
        original=root/edit['path']
        if any(part.is_symlink() for part in [original,*original.parents] if part!=root.parent):
            raise ProtocolError('symbolic edit path refused')
        path=inside(root,edit['path']);rel=path.relative_to(root.resolve()).as_posix()
        if rel.split('/')[0] in PROTECTED:raise ProtocolError('protected reference: '+rel)
        if path.is_symlink() or path in seen:raise ProtocolError('duplicate or symbolic edit: '+rel)
        seen.add(path);before=path.read_bytes()
        if hashlib.sha256(before).hexdigest()!=edit['sha256']:raise ProtocolError('stale source: '+rel)
        old,new=edit['old'].encode(),edit['new'].encode();count=edit['count']
        if not old or type(count) is not int or count<1 or before.count(old)!=count:
            raise ProtocolError('replacement count mismatch: '+rel)
        after=before.replace(old,new)
        result.append((path,before,after))
    return result

def apply(root,edits,write=False):
    prepared=prepare(root,edits);diff=[]
    for path,before,after in prepared:
        rel=str(path.relative_to(root));diff.extend(difflib.unified_diff(before.decode().splitlines(True),after.decode().splitlines(True),fromfile=rel,tofile=rel))
    if write:
        # Validate all sources before the first mutation. Each publication is atomic; this
        # is not a multi-file transaction. On interruption compare hashes and resume remaining edits.
        for path,before,after in prepared:
            if path.read_bytes()!=before:raise ProtocolError('source changed during codemod: '+str(path))
        for path,before,after in prepared:
            mode=path.stat().st_mode
            atomic(path,after);os.chmod(path,mode)
    return ''.join(diff)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--spec',required=True)
    p.add_argument('--apply',action='store_true');a=p.parse_args()
    try:
        print(apply(ROOT,json.loads(inside(ROOT,a.spec).read_text()),a.apply),end='');return 0
    except (OSError,ValueError,KeyError,ProtocolError) as e:print(str(e));return 1
if __name__=='__main__':raise SystemExit(main())
