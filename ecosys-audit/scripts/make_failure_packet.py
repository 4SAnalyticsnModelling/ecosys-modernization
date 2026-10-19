"""One compact failure packet with source ranges, evidence and rejected hypotheses."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import uuid
from workflow import ROOT, ProtocolError, artifact, atomic, encoded, inside, load
from project_runtime import git
from code_nav import Reader


def build(root: Path, summary: str, signature: str, ranges=(), rejected=(), hypotheses=(), logs=(), state=None):
    group=hashlib.sha256(signature.encode()).hexdigest()[:16]
    directory=root/'audit/issues/failures'/group;directory.mkdir(parents=True,exist_ok=True)
    prior=[]
    for path in directory.glob('*.json'):
        prior+=load(path).get('rejected_hypotheses',[])
    reader=Reader(root);sources=[]
    for spec in ranges:
        m=re.fullmatch(r'(.+):(\d+)-(\d+)',spec)
        if not m:raise ProtocolError('source range must be path:N-M')
        sources.append(reader.query({'op':'show','path':m[1],'start':int(m[2]),'end':int(m[3])}))
    packet={'signature':signature,'at':datetime.now(timezone.utc).isoformat(),
            'summary':load(inside(root,summary)),'evidence':[artifact(root,x) for x in [summary,*logs]],
            'sources':sources,'hypotheses':list(hypotheses),
            'rejected_hypotheses':list(dict.fromkeys([*prior,*rejected]))}
    if state:packet['state']=load(inside(root,state))
    out=directory/(str(uuid.uuid4())+'.json')
    diff=git(root,'diff','--binary','HEAD','--','ecosys-ng/src','ecosys-ng/build.zig')
    if diff:
        path=out.with_suffix('.patch');atomic(path,diff);packet['candidate_diff']=artifact(root,str(path.relative_to(root)))
    atomic(out,encoded(packet));return out


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--summary',required=True)
    p.add_argument('--signature',required=True);p.add_argument('--range',action='append',default=[])
    p.add_argument('--hypothesis',action='append',default=[]);p.add_argument('--rejected',action='append',default=[])
    p.add_argument('--log',action='append',default=[]);p.add_argument('--state-values')
    a=p.parse_args()
    try:
        out=build(ROOT,a.summary,a.signature,a.range,a.rejected,a.hypothesis,a.log,a.state_values)
        print(out.relative_to(ROOT));return 0
    except (OSError,ValueError,ProtocolError) as e:print(str(e));return 1
if __name__=='__main__':raise SystemExit(main())
