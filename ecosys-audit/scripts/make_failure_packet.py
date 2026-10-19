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
from dependencies import capture as capture_dependencies, verify as verify_dependencies


def build(root: Path, summary: str, signature: str, ranges=(), rejected=(), hypotheses=(), logs=(), state=None, falsifier=''):
    group=hashlib.sha256(signature.encode()).hexdigest()[:16]
    directory=root/'audit/issues/failures'/group;directory.mkdir(parents=True,exist_ok=True)
    summary_data = load(inside(root,summary))
    binding = (summary_data.get('binding') or {}).get('binding_id')
    fixture = artifact(root,state) if state else None
    dependencies = capture_dependencies(root)
    evidence = [artifact(root,x) for x in [summary,*logs]]
    prior=[]
    for path in directory.glob('*.json'):
        old=load(path)
        if 'rejection_records' in old: prior += old['rejection_records']
        else:
            prior += [{'hypothesis':h,'historical_reason':'legacy unbound rejection'}
                      for h in old.get('rejected_hypotheses',[])]
    prior += [{'hypothesis':h, 'binding_id':binding, 'fixture':fixture,
               'dependencies':dependencies, 'falsifier':falsifier, 'evidence':evidence,
               'invalidated_by':['source','input','toolchain','rule','validator','fixture','binding']}
              for h in rejected]
    records=[]; seen=set()
    for record in prior:
        record={k:v for k,v in record.items() if k not in ('current','stale_reason')}
        key=json.dumps(record,sort_keys=True)
        if key in seen: continue
        seen.add(key)
        current = bool(binding and fixture and record.get('binding_id') == binding and
                       record.get('fixture') == fixture and record.get('falsifier') and
                       not verify_dependencies(root,record.get('dependencies')))
        try:
            current = current and bool(record.get('evidence')) and all(artifact(root,r['path']) == r for r in record['evidence'])
        except (OSError,KeyError,ProtocolError): current=False
        records.append({**record,'current':bool(current),
                        'stale_reason':None if current else 'historical, incomplete or changed dependencies/binding/fixture/evidence'})
    reader=Reader(root);sources=[]
    for spec in ranges:
        m=re.fullmatch(r'(.+):(\d+)-(\d+)',spec)
        if not m:raise ProtocolError('source range must be path:N-M')
        sources.append(reader.query({'op':'show','path':m[1],'start':int(m[2]),'end':int(m[3])}))
    packet={'schema_version':2,'signature':signature,'at':datetime.now(timezone.utc).isoformat(),
            'summary':summary_data,'evidence':evidence,
            'sources':sources,'hypotheses':list(hypotheses),
            'rejection_records':records,
            'rejected_hypotheses':list(dict.fromkeys(r['hypothesis'] for r in records if r['current']))}
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
    p.add_argument('--falsifier',default='',help='Observed result that falsifies each new rejected hypothesis; without it rejection is historical only')
    a=p.parse_args()
    try:
        out=build(ROOT,a.summary,a.signature,a.range,a.rejected,a.hypothesis,a.log,a.state_values,a.falsifier)
        print(out.relative_to(ROOT));return 0
    except (OSError,ValueError,ProtocolError) as e:print(str(e));return 1
if __name__=='__main__':raise SystemExit(main())
