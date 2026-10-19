"""Require reproducibly faster full Ottawa ReleaseFast runs than optimized Fortran."""
from __future__ import annotations
import argparse
import json
import math
from statistics import median
from workflow import ROOT, ProtocolError, artifact, inside, load

HOURS = 262920
CONDITIONS = ('hardware', 'allocated_cores', 'effective_inputs_sha256', 'output_contract_sha256', 'precision')


def read_ref(root, ref):
    if artifact(root,ref['path']) != ref: raise ProtocolError('stale artifact: '+ref['path'])
    return load(inside(root,ref['path']))


def check(root, benchmark, binding, source):
    """No trusted speedup field: derive wall times from distinct immutable run receipts."""
    try:
        if benchmark.get('schema_version')!=1: raise ProtocolError('unsupported benchmark schema')
        # Scientific qualification precedes optimization; a fast incomplete model earns nothing.
        acceptance=read_ref(root,benchmark['scientific_acceptance'])
        if acceptance.get('source_digest')!=source or acceptance.get('binding_id')!=binding:
            raise ProtocolError('scientific acceptance is for a different candidate')
        campaign=read_ref(root,acceptance['campaign_summary'])
        if (campaign.get('status')!='COMPLETE' or campaign.get('mode')!='strict'
                or campaign.get('start_hour')!=0 or campaign.get('last_completed_hour')!=HOURS
                or campaign.get('build_binding_verified') is not True
                or campaign.get('binding',{}).get('binding_id')!=binding
                or campaign.get('conservation_breaches')!=0 or campaign.get('solver_fallbacks_unexplained')!=0):
            raise ProtocolError('full strict scientific campaign must pass before performance acceptance')
        from qualification_reports import validate
        for gid in ('F2','F3','F4','F5'):
            problems=validate(root,gid,read_ref(root,acceptance['reports'][gid]),source,binding)
            if problems:raise ProtocolError('science precedes speed: '+'; '.join(problems))
        conditions=benchmark['conditions']
        if any(not conditions.get(k) for k in CONDITIONS) or conditions['precision']!='f64-i32':
            raise ProtocolError('missing comparable benchmark conditions')
        if type(conditions['allocated_cores']) is not int or conditions['allocated_cores']<1:
            raise ProtocolError('invalid allocated cores')
        pairs=benchmark['pairs']
        if len(pairs)<3: raise ProtocolError('at least three paired full Ottawa runs required')
        times={'zig':[],'legacy':[]};used=set();intervals=[];build_ids={}
        for pair in pairs:
            for language in ('zig','legacy'):
                run=read_ref(root,pair[language])
                if run['conditions']!=conditions: raise ProtocolError('unequal benchmark workloads/resources')
                receipt=read_ref(root,run['receipt']);summary=read_ref(root,run['summary'])
                if read_ref(root,receipt['benchmark_conditions'])!=conditions:
                    raise ProtocolError('measured run conditions differ from benchmark')
                if any(receipt.get(k)!=conditions['hardware'].get(k) for k in ('platform','machine')):
                    raise ProtocolError('benchmark host differs from raw receipt')
                build=read_ref(root,run['build_receipt'])
                binary=run['executable']
                if artifact(root,binary['path'])!=binary: raise ProtocolError('stale benchmark executable')
                if run['receipt']['path'] in used: raise ProtocolError('reused benchmark receipt')
                used.add(run['receipt']['path'])
                if receipt.get('exit_code')!=0 or receipt.get('status')!='EXITED' or receipt.get('executable_sha256')!=binary['sha256']:
                    raise ProtocolError('benchmark process/executable not verified')
                if build.get('exit_code')!=0 or build.get('build_product',{}).get('sha256')!=binary['sha256']:
                    raise ProtocolError('benchmark binary not bound to successful build')
                build_id=run['build_receipt']['sha256']
                if language in build_ids and build_ids[language]!=build_id: raise ProtocolError('build changed across benchmark repeats')
                build_ids[language]=build_id
                if summary.get('status')!='COMPLETE' or summary.get('start_hour')!=0 or summary.get('last_completed_hour')!=HOURS:
                    raise ProtocolError('partial or incomplete Ottawa benchmark')
                if summary.get('normal_exit') is not True or summary.get('output_complete') is not True:
                    raise ProtocolError('unverified benchmark terminal outputs/normal exit')
                if language=='zig':
                    if (build.get('build_mode')!='ReleaseFast' or build.get('source_digest')!=source
                            or build.get('source_changed_during_command') is not False
                            or not str(build.get('toolchain',{}).get('zig',{}).get('version','')).startswith('0.17.')
                            or summary.get('binding',{}).get('binding_id')!=binding
                            or summary.get('mode')!='strict' or summary.get('conservation_breaches')!=0
                            or summary.get('solver_fallbacks_unexplained')!=0):
                        raise ProtocolError('Zig benchmark is not the accepted strict ReleaseFast candidate')
                else:
                    argv=build.get('argv',[])
                    if not any(x in argv for x in ('-O2','-O3')) or any(x in argv for x in ('-O0','-Ofast','-ffast-math')):
                        raise ProtocolError('legacy benchmark must use the verified optimized precision-preserving build')
                    if not {'-fdefault-real-8','-fdefault-double-8'}<=set(argv) or '-fdefault-integer-8' in argv:
                        raise ProtocolError('legacy compiler flags do not establish the f64/i32 precision contract')
                    if any(x in argv for x in ('-funsafe-math-optimizations','-ffinite-math-only','-fassociative-math','-freciprocal-math')):
                        raise ProtocolError('unsafe legacy arithmetic flags are not comparable scientific work')
                value=receipt.get('elapsed_seconds');start=receipt.get('started_unix')
                if any(type(v) not in (int,float) or not math.isfinite(v) or v<=0 for v in (value,start)):
                    raise ProtocolError('invalid raw benchmark timing')
                intervals.append((start,start+value));times[language].append(value)
        intervals.sort()
        if any(b[0]<a[1] for a,b in zip(intervals,intervals[1:])): raise ProtocolError('benchmark runs overlapped')
        ratio=median(times['zig'])/median(times['legacy'])
        # A conservative noise criterion: the observed runtime ranges must not overlap.
        if not math.isfinite(ratio) or ratio>=1 or max(times['zig'])>=min(times['legacy']):
            raise ProtocolError('ReleaseFast speed advantage not established beyond observed spread')
        return {'status':'PASS','median_ratio':ratio,'zig_seconds':times['zig'],'legacy_seconds':times['legacy']}
    except (OSError,KeyError,TypeError,ValueError,AttributeError,ProtocolError) as exc:
        return {'status':'FAIL','problem':str(exc)}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('benchmark');p.add_argument('--binding',required=True);p.add_argument('--source',required=True)
    a=p.parse_args();result=check(ROOT,load(inside(ROOT,a.benchmark)),a.binding,a.source)
    print(json.dumps(result,indent=2));raise SystemExit(result['status']!='PASS')
