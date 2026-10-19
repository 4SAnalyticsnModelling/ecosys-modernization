"""Run named suites with logged receipts; assess raw counts, roots, modes and skips."""
from __future__ import annotations
import argparse
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from workflow import ROOT, ProtocolError, artifact, atomic, encoded, inside, load
from dependencies import capture, verify
from run_logged import run

MANIFEST = 'ecosys-audit/suite_manifest.json'


def counts(root, result):
    ref=result['counts_artifact']
    if artifact(root,ref['path']) != ref: raise ProtocolError('stale counts artifact')
    path=inside(root,ref['path'])
    if result['parser']=='junit':
        tree=ET.parse(path)
        cases=list(tree.iter('testcase'))
        # Collection errors need to fail even when other tests ran successfully.
        failed=sum(c.find('failure') is not None or c.find('error') is not None for c in cases)
        skipped=sum(c.find('skipped') is not None for c in cases)
        return {'selected':len(cases),'executed':len(cases)-skipped,'skipped':skipped,'failed':failed}
    if result['parser']=='zig-summary':
        lines=re.findall(r'run test ([^\n]+)',path.read_text(errors='replace'))
        lines=[line for line in lines if re.search(r'\d+ pass\b',line)]
        if len(lines)!=1: raise ProtocolError('expected exactly one separately named Zig root summary')
        line=lines[0]
        number=lambda word:sum(int(n) for n in re.findall(r'(\d+) '+word+r'\b',line))
        passed,skipped,failed=number('pass'),number('skip'),number('fail')+number('crash')
        total=passed+skipped+failed
        declared=re.search(r'\((\d+) total\)',line)
        if declared and int(declared[1])!=total: raise ProtocolError('inconsistent Zig total')
        return {'selected':total,'executed':total-skipped,'skipped':skipped,'failed':failed}
    raise ProtocolError('unsupported count parser')


def assess(root, result):
    try:
        if result.get('schema_version')!=1: raise ProtocolError('unsupported suite result')
        manifest=load(inside(root,MANIFEST))
        spec=manifest['cases'][result['case']]
        if result['mode']!=spec['mode'] or result['root']!=spec['root'] or result['parser']!=spec['parser']:
            raise ProtocolError('suite root/mode/parser mismatch')
        errors=verify(root,result.get('dependencies'))
        ref=result['receipt']
        if artifact(root,ref['path'])!=ref: raise ProtocolError('stale receipt')
        receipt=load(inside(root,ref['path']))
        if receipt.get('status')!='EXITED' or receipt.get('exit_code')!=0:
            errors.append('suite process did not succeed')
        expected=[s.replace('{junit}', result.get('junit_path','')) for s in spec['argv']]
        if receipt.get('argv')!=expected or Path(receipt.get('cwd','')).resolve()!=inside(root,spec['cwd']):
            errors.append('suite invocation differs from manifest (filters require a separate diagnostic receipt)')
        if result['parser']=='zig-summary' and result['counts_artifact']!=receipt.get('stderr'):
            errors.append('Zig counts do not refer to receipt stderr')
        if result['parser']=='junit' and result['counts_artifact']['path']!=result.get('junit_path'):
            errors.append('JUnit path differs from invocation')
        measured=counts(root,result)
        if measured!=result.get('counts'): errors.append('recorded counts differ from raw result')
        if measured['selected']<=0 or measured['executed']<=0: errors.append('zero-test suite')
        if measured['failed']: errors.append('failed tests')
        if measured['skipped']:
            allowance=spec.get('skip_allowance',{})
            if measured['skipped']!=allowance.get('count') or not allowance.get('reason') or not allowance.get('evidence'):
                errors.append('unexplained skips')
            else:
                for ref in allowance['evidence']:
                    if artifact(root,ref['path'])!=ref: errors.append('stale skip justification')
        return errors
    except (OSError,ValueError,KeyError,TypeError,ET.ParseError,ProtocolError) as exc:
        return ['unassessed suite: '+str(exc)]


def run_case(root, case, out):
    spec=load(inside(root,MANIFEST))['cases'][case]
    out=inside(root,out)
    if not out.is_relative_to(root/'audit/runs'): raise ProtocolError('suite runs must be under audit/runs')
    out.mkdir(parents=True,exist_ok=False)
    junit=str((out/'junit.xml').relative_to(root))
    argv=[s.replace('{junit}',junit) for s in spec['argv']]
    before=capture(root)
    receipt=run(root,inside(root,spec['cwd']),out/'command',argv,None)
    result={'schema_version':1,'case':case,'root':spec['root'],'mode':spec['mode'],
            'parser':spec['parser'],'junit_path':junit,'dependencies':before,
            'receipt':artifact(root,receipt['receipt'])}
    try:
        result['counts_artifact']=artifact(root,junit) if spec['parser']=='junit' else receipt['stderr']
        result['counts']=counts(root,result)
    except (OSError,ValueError,KeyError,ET.ParseError,ProtocolError) as exc:
        result['count_error']=str(exc)
    result['problems']=assess(root,result)
    result['status']='PASS' if not result['problems'] else 'NOT_ACCEPTED'
    atomic(out/'result.json',encoded(result))
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='command',required=True)
    r=sub.add_parser('run');r.add_argument('--case',required=True);r.add_argument('--out',required=True)
    a=sub.add_parser('assess');a.add_argument('result')
    args=p.parse_args()
    if args.command=='run': result=run_case(ROOT,args.case,args.out);errors=result['problems']
    else: errors=assess(ROOT,load(inside(ROOT,args.result)));result={'problems':errors}
    print(json.dumps(result,indent=2));return bool(errors)


if __name__=='__main__': raise SystemExit(main())
