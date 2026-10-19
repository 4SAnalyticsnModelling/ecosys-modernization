"""Minimal evidence-bound cycles for one autonomous worker; no accounting reports."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
from workflow import ROOT, ProtocolError, artifact, atomic, encoded, inside, load
from project_runtime import content_digest, environment, git
from run_logged import run as execute
from dependencies import capture as capture_dependencies, verify as verify_dependencies

GATES=tuple('G'+str(i) for i in range(1,10))
RESULTS=('PASS','FAIL','NA','INCONCLUSIVE')
REQUIRED=tuple(x for x in GATES if x!='G8')
FORBIDDEN=[r'unreachable\s*\(',r'@setRuntimeSafety\s*\(\s*false',r'\bDEV-\d+',
           r'(?i)\b(?:tol\w*|eps\w*|max\w*(?:iter|step|ceiling))\s*=\s*[0-9]']


def now():return datetime.now(timezone.utc).isoformat()
def ledger(root):return load(root/'.agent/cycle.json')
def save(root,data):atomic(root/'.agent/cycle.json',encoded(data))
def head(root):return git(root,'rev-parse','HEAD').decode().strip()

def changed(root,base):
    names=git(root,'diff','--name-only',base).decode().splitlines()
    names+=git(root,'ls-files','--others','--exclude-standard').decode().splitlines()
    return sorted(set(names))

def science(paths):
    return any(x.startswith(('ecosys-ng/src/','ecosys-ng/build.zig')) for x in paths)

def fingerprint(root,data):return content_digest(root,data.get('scope'))

def record_gate(root,data,gid,result,evidence,reason=''):
    if gid not in REQUIRED:raise ProtocolError('record G1–G7/G9; G8 is derived after push')
    if result not in RESULTS:raise ProtocolError('result must be PASS, FAIL, NA or INCONCLUSIVE')
    if not evidence:raise ProtocolError('all verdicts require evidence files')
    if result=='NA' and not reason.strip():raise ProtocolError('NA requires scope reason')
    refs=[artifact(root,p) for p in evidence]
    data.setdefault('gates',{})[gid]={'result':result,'evidence':refs,'reason':reason,
                                  'candidate_digest':fingerprint(root,data),
                                  'dependencies':capture_dependencies(root, **data.get('dependency_spec', {}))}
    if result in ('FAIL','INCONCLUSIVE'):data['status']='WORKING'
    save(root,data)

def blockers(root,data):
    problems=[];digest=fingerprint(root,data)
    base=data.get('base_commit')
    if not base:return ['cycle base_commit missing; reconcile cycle before closing']
    paths=changed(root,base)
    # Scope can isolate unrelated existing edits, but it must include every owned source path.
    owned=data.get('owned_paths',[])
    if not owned:return ['owned_paths missing; list explicit paths before close']
    touched=[p for p in paths if any(p==o or p.startswith(o.rstrip('/')+'/') for o in owned)]
    if science(touched):
        scopes=data.get('scope') or []
        for p in touched:
            if p.startswith('ecosys-ng/') and not any(p==s or p.startswith(s.rstrip('/')+'/') for s in scopes):
                problems.append('owned source omitted from evidence scope: '+p)
    dependency_checks = {}
    for gid in REQUIRED:
        g=data.get('gates',{}).get(gid,{})
        dependency_key = json.dumps(g.get('dependencies'), sort_keys=True)
        if dependency_key not in dependency_checks:
            dependency_checks[dependency_key] = verify_dependencies(root, g.get('dependencies'))
        problems.extend(gid + ': ' + e for e in dependency_checks[dependency_key])
        if g.get('result') not in ['PASS','NA']:problems.append(gid+': missing or failed')
        if g.get('candidate_digest')!=digest:problems.append(gid+': stale candidate')
        if not g.get('evidence'):problems.append(gid+': missing evidence')
        for ref in g.get('evidence',[]):
            try:
                if artifact(root,ref['path'])!=ref:problems.append(gid+': stale evidence '+ref['path'])
            except (OSError,KeyError,ProtocolError):problems.append(gid+': invalid evidence')
        if g.get('result')=='NA' and not g.get('reason'):problems.append(gid+': NA without reason')
    if science(touched):
        for gid in ['G1','G2','G3','G4','G5','G7']:
            if data.get('gates',{}).get(gid,{}).get('result')!='PASS':problems.append(gid+': scientific change requires PASS')
    return problems

def scan(root,base):
    text=git(root,'diff','-U0',base).decode(errors='replace')
    return [line[1:][:220] for line in text.splitlines() if line.startswith('+') and not line.startswith('+++')
            and any(re.search(pattern,line[1:]) for pattern in FORBIDDEN)]

def push(root):
    # Never mutate the ledger after push: sync is a derived read-only property.
    for argv in [['git','fetch','origin','main'],['git','push','origin','HEAD:main']]:
        p=subprocess.run(argv,cwd=root,capture_output=True,text=True)
        if p.returncode:raise ProtocolError((p.stdout+p.stderr)[-1500:])
    remote=git(root,'ls-remote','origin','refs/heads/main').split()
    if not remote or remote[0].decode()!=head(root):raise ProtocolError('remote verification mismatch')

def close(root,data,summary,dry_run=False):
    errors=blockers(root,data)
    if errors:raise ProtocolError('; '.join(errors))
    if dry_run:return {'ready':True}
    if git(root,'branch','--show-current').strip()!=b'main':raise ProtocolError('cycle closure requires main')
    owned=data['owned_paths'];controls=['.agent/cycle.json']
    record=data.get('record')
    if record:controls.append(record)
    for p in owned+controls:
        inside(root,p)
        if p in ['.','']:raise ProtocolError('explicit owned files/directories required')
    staged=git(root,'diff','--cached','--name-only').decode().splitlines()
    allowed=owned+controls
    if any(not any(p==a or p.startswith(a.rstrip('/')+'/') for a in allowed) for p in staged):
        raise ProtocolError('unrelated paths already staged; preserve index and reconcile')
    # Prepare durable closure before commit. After crash, G8 is independently checked at pickup.
    data.update(status='DECIDED',sync_status='PENDING',closure={'at':now(),'summary':summary})
    save(root,data)
    git(root,'add','--',*owned,*controls)
    p=subprocess.run(['git','commit','-m',f"cycle {data['cycle']:05d}: {summary}"],cwd=root,capture_output=True,text=True)
    if p.returncode:raise ProtocolError((p.stdout+p.stderr)[-1000:])
    push(root)
    return {'status':'PUSHED','commit':head(root),'note':'G8 derived; no post-push file mutation'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT)
    sub=p.add_subparsers(dest='cmd',required=True)
    sub.add_parser('status')
    o=sub.add_parser('open');o.add_argument('--target',required=True);o.add_argument('--paths',nargs='+',required=True)
    o.add_argument('--scope',nargs='+',help='all source dependencies checked by this cycle; default owned paths')
    g=sub.add_parser('gate');g.add_argument('gate',choices=REQUIRED);g.add_argument('--result',choices=RESULTS,required=True)
    g.add_argument('--evidence',action='append',required=True);g.add_argument('--reason',default='')
    c=sub.add_parser('close');c.add_argument('--summary',required=True);c.add_argument('--dry-run',action='store_true')
    sub.add_parser('push')
    s=sub.add_parser('set');s.add_argument('--target');s.add_argument('--next-target');s.add_argument('--base-commit')
    s.add_argument('--paths',nargs='+');s.add_argument('--scope',nargs='+');s.add_argument('--note')
    s.add_argument('--dependencies', help='JSON file with scope, justification and context; omit scope for conservative capture')
    gates=sub.add_parser('gates');gates.add_argument('--build',action='store_true');gates.add_argument('--tests',action='store_true')
    gates.add_argument('--diff-ref')
    a=p.parse_args();root=a.root.resolve();data=ledger(root) if (root/'.agent/cycle.json').exists() else {}
    try:
        if a.cmd=='status':
            print(json.dumps({'cycle':data,'head':head(root),'changed':changed(root,data.get('base_commit','HEAD'))},indent=2))
        elif a.cmd=='open':
            if data and data.get('status') not in ['PUSHED','IDLE']:
                if data.get('status')!='DECIDED' or not data.get('closure'):raise ProtocolError('resume existing open cycle')
                committed=json.loads(git(root,'show','HEAD:.agent/cycle.json'))
                if committed!=data or git(root,'diff','HEAD','--',*data.get('owned_paths',[])).strip():
                    raise ProtocolError('closure not committed; retry close before opening another cycle')
                push(root)
            no=max([data.get('cycle',0)]+[int(x.stem.split('_')[1]) for x in (root/'.agent/cycles').glob('cycle_*.md')])+1
            path=f'.agent/cycles/cycle_{no:05d}.md'
            text=(root/'.agent/templates/cycle.md').read_text().replace('{{CYCLE_ID}}',f'{no:05d}').replace('{{DATE}}',now()[:10]).replace('{{TARGET}}',a.target)
            atomic(root/path,text.encode())
            data={'schema_version':2,'cycle':no,'status':'PLANNING','target':a.target,'base_commit':head(root),
                  'owned_paths':a.paths,'scope':a.scope or a.paths,'record':path,'gates':{}}
            save(root,data);print(path)
        elif a.cmd=='set':
            for key in ['target','next_target','base_commit','scope']:
                if getattr(a,key,None) is not None:data[key]=getattr(a,key)
            if a.paths:data['owned_paths']=a.paths
            if a.note:data['next_action']=a.note
            if a.dependencies:
                spec=load(inside(root,a.dependencies));capture_dependencies(root,**spec)
                data['dependency_spec']=spec
            save(root,data)
        elif a.cmd=='gate':record_gate(root,data,a.gate,a.result,a.evidence,a.reason)
        elif a.cmd=='close':print(json.dumps(close(root,data,a.summary,a.dry_run)))
        elif a.cmd=='push':push(root);print(head(root))
        elif a.cmd=='gates':
            failures=[];receipts=[];env=environment(root)
            from suite_check import run_case
            if a.build:
                for mode in ('Debug','ReleaseSafe','ReleaseFast'):
                    out=root/'audit/runs'/('cycle-build-'+mode+'-'+datetime.now().strftime('%Y%m%d%H%M%S%f'))
                    result=execute(root,root/'ecosys-ng',out,['zig','build','-Doptimize='+mode,'--cache-dir','.zig-cache'],None)
                    receipts.append(str((out/'receipt.json').relative_to(root)))
                    if result['exit_code']!=0: failures.append('build-'+mode)
            cases=([f'tests-{r}-{m}' for r in ('module','executable') for m in ('Debug','ReleaseSafe','ReleaseFast')] if a.build else [])
            if a.tests: cases.append('tooling')
            for case in cases:
                out='audit/runs/cycle-suite-'+case+'-'+datetime.now().strftime('%Y%m%d%H%M%S%f')
                result=run_case(root,case,out);receipts.append(out+'/result.json')
                if result['status']!='PASS': failures.append(case)
            flags=scan(root,a.diff_ref or data.get('base_commit','HEAD'))
            report={'failed_suites':failures,'receipts':receipts,'forbidden_candidates':flags,
                    'note':'Check test counts/skips and justify every flagged line; record gates explicitly.'}
            print(json.dumps(report,indent=2));return 1 if failures or flags else 0
        return 0
    except (OSError,ValueError,ProtocolError) as e:print(str(e),file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
