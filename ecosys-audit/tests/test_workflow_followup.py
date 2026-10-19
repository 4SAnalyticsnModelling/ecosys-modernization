"""Adversarial synthetic regressions for science-first qualification and loop recovery."""
import copy
import json
import subprocess
import sys
import threading
from pathlib import Path
import pytest
from test_autonomy import repo, ready
from test_qualification_contracts import evidence, put, report
from workflow import ProtocolError, artifact, load
import cycle_runner as cycles
import qualification_reports as qr
import performance_check as pc
import progress_watch as progress
import worker_supervisor as supervisor
import autonomy_readiness as autonomy
import raw_evidence


def rewrite(root,ref,edit):
    value=load(root/ref['path']);edit(value);return put(root,ref['path'],value)


def checked(root,r):return qr.validate(root,r['criterion'],r,r['source_digest'],r['binding_id'])


def test_omitting_source_from_both_inventory_and_results_still_fails(evidence):
    root,proof=evidence;r=report(root,proof,'F4')
    r['results'].pop();r['inventory']=rewrite(root,r['inventory'],lambda inv:inv['items'].pop())
    assert any('regenerated' in e for e in checked(root,r))


@pytest.mark.parametrize('defect',['breach','hour','nonfinite','storage'])
def test_raw_balance_recomputed_despite_passing_counters(evidence,defect):
    root,proof=evidence;r=report(root,proof,'F2');item=r['results'][0];ref=item['ledger']
    rows=[json.loads(x) for x in (root/ref['path']).read_text().splitlines()]
    if defect=='breach':rows[0]['new']=9
    if defect=='hour':rows[1]['hour']=1
    if defect=='nonfinite':rows[0]['sources']=[float('nan')]
    if defect=='storage':rows[1].update(old=2,new=2)
    (root/ref['path']).write_text(''.join(json.dumps(x)+'\n' for x in rows));item['ledger']=artifact(root,ref['path'])
    assert checked(root,r)


@pytest.mark.parametrize('defect',['value','column','file','key','time','late-policy'])
def test_raw_outputs_recomputed_and_scope_independent_of_passes(evidence,defect):
    root,proof=evidence;r=report(root,proof,'F3');spec=load(root/r['raw_evidence']['path']);ref=spec['pairs'][0]['zig']
    rows=[json.loads(x) for x in (root/ref['path']).read_text().splitlines()]
    if defect=='value':rows[1]['values']['fixture']=99
    if defect=='column':rows[0]['values']['extra']=1
    if defect=='key':rows[1]['key']=[1]
    if defect=='time':rows[1]['time']=0
    if defect=='file':(root/spec['legacy_directory']/'omitted.txt').write_text('unlisted real output')
    if defect=='late-policy':
        spec['evaluation_receipts'][0]=rewrite(root,spec['evaluation_receipts'][0],lambda v:v.update(started_unix=1))
    (root/ref['path']).write_text(''.join(json.dumps(x)+'\n' for x in rows))
    spec['pairs'][0]['zig']=artifact(root,ref['path']);r['raw_evidence']=put(root,r['raw_evidence']['path'],spec)
    assert checked(root,r)


def test_compensated_aggregation_preserves_small_terms():
    state={}
    for t,v in enumerate([1e16,1.,-1e16]):raw_evidence.accumulate(state,v,t,{'reducer':'sum'})
    assert raw_evidence.reduced(state,'sum')==1


def test_acceptance_metrics_cannot_be_silently_omitted(evidence):
    root,proof=evidence
    rule=load(root/'validation/rules/divcheck-rules.json')['variables']['fixture']
    rule['metrics'].pop('annual')
    with pytest.raises(ProtocolError):raw_evidence.metric_rules(rule)


@pytest.mark.parametrize('defect',['slow','equal','spread','short','overlap','duplicate','unoptimized','wrong-precision','science-gap'])
def test_speed_never_substitutes_for_science_or_comparable_measurement(evidence,defect):
    root,proof=evidence;r=report(root,proof,'F6')
    item=next(x for x in r['results'] if x['id']=='equivalent-work-performance')
    benchmark=load(root/item['benchmark']['path'])
    if defect=='science-gap':
        acceptance=load(root/benchmark['scientific_acceptance']['path'])
        acceptance['reports']['F4']=rewrite(root,acceptance['reports']['F4'],lambda v:v['results'].pop())
        benchmark['scientific_acceptance']=put(root,benchmark['scientific_acceptance']['path'],acceptance)
    elif defect=='duplicate':benchmark['pairs'][1]=benchmark['pairs'][0]
    else:
        role='legacy' if defect in ('unoptimized','wrong-precision') else 'zig'
        pair=benchmark['pairs'][0];run=load(root/pair[role]['path'])
        if defect in ('slow','equal','spread','overlap'):
            changes={'elapsed_seconds':21 if defect in ('slow','spread') else 20}
            if defect=='overlap':changes={'started_unix':1040}
            run['receipt']=rewrite(root,run['receipt'],lambda v:v.update(**changes))
        elif defect=='short':run['summary']=rewrite(root,run['summary'],lambda v:v.update(last_completed_hour=1))
        else:run['build_receipt']=rewrite(root,run['build_receipt'],lambda v:v.update(argv=['gfortran','-O3' if defect=='wrong-precision' else '-O0']))
        pair[role]=put(root,pair[role]['path'],run)
    result=pc.check(root,benchmark,r['binding_id'],r['source_digest'])
    assert result['status']=='FAIL'
    if defect=='science-gap':assert 'science precedes speed' in result['problem']


def test_publication_requires_all_compact_evidence_and_ignored_manifest(repo):
    data=ready(repo);data['owned_paths'].remove('proof.json')
    assert any('unpublished evidence' in e for e in cycles.blockers(repo,data))
    data['owned_paths'].append('proof.json')
    (repo/'.gitignore').write_text('payload.bin\n');(repo/'payload.bin').write_bytes(b'payload')
    ref=artifact(repo,'payload.bin');put(repo,'proof.json',{'payload':ref})
    for gate in cycles.REQUIRED:cycles.record_gate(repo,data,gate,'PASS',['proof.json'])
    assert any('retention manifest' in e for e in cycles.blockers(repo,data))
    put(repo,'retention.json',{'policy':'retain-through-F7-and-reproducibility','artifacts':[ref]})
    data.update(retention_manifest='retention.json',owned_paths=data['owned_paths']+['retention.json'])
    assert not cycles.blockers(repo,data)


def test_interrupted_push_retries_existing_commit_without_extra_commit(repo,tmp_path,monkeypatch):
    remote=tmp_path/'remote.git';subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
    subprocess.run(['git','branch','-M','main'],cwd=repo,check=True)
    subprocess.run(['git','remote','add','origin',str(remote)],cwd=repo,check=True)
    subprocess.run(['git','push','-q','origin','HEAD:main'],cwd=repo,check=True)
    data=ready(repo);original_push=cycles.push
    def unavailable(_):raise ProtocolError('synthetic network outage')
    monkeypatch.setattr(cycles,'push',unavailable)
    with pytest.raises(ProtocolError):cycles.close(repo,data,'verified')
    committed=cycles.head(repo)
    monkeypatch.setattr(cycles,'push',original_push)
    result=cycles.close(repo,load(repo/'.agent/cycle.json'),'retry after network restored')
    assert result['commit']==committed==cycles.head(repo)
    assert cycles.close(repo,load(repo/'.agent/cycle.json'),'already published')['commit']==committed


def test_restarts_logs_and_rotating_names_do_not_count_as_progress(repo):
    before=progress.signature(repo);(repo/'README.md').write_text('another plan')
    put(repo,'.agent/runtime/log.json',{'restart':4,'timestamp':999})
    assert progress.signature(repo)==before
    state={}
    for n in range(3):state.update(progress.observe(state,before,before))
    assert progress.action(state,before)=='REPLAN'
    state.update(progress.observe(state,before,before));assert progress.action(state,before)=='WAITING_FOR_CHANGE'
    state.update(progress.observe(state,before,'new-evidence'))
    assert progress.action(state,'new-evidence')=='RESUME'
    state.update(progress.observe(state,'new-evidence',before))
    assert state['no_progress_exits']==1  # A -> B -> A is not new progress.


def test_supervisor_parks_after_one_diagnostic_restart_and_resumes_on_new_source(repo,monkeypatch):
    monkeypatch.setattr(supervisor,'validate',lambda _:['unfinished'])
    code="""import json,pathlib,os
p=pathlib.Path('launches');p.write_text(str(int(p.read_text())+1) if p.exists() else '1')
r=json.loads(pathlib.Path(os.environ['ECOSYS_RECOVERY_PACKET']).read_text())
pathlib.Path('mode').write_text(r['mode'])
"""
    stop=threading.Event();waiting=[]
    def sleep(_):
        f=repo/'.agent/runtime/supervisor.json'
        if f.exists() and load(f).get('status')=='WAITING_FOR_CHANGE':
            waiting.append(load(f))
            if len(waiting)==1:(repo/'ecosys-ng/src/a.zig').write_text('pub fn new_evidence() void {}\n')
            else:stop.set()
    config={'command':[sys.executable,'-c',code],'recovery_command':[], 'backoff_initial_seconds':.001,'backoff_max_seconds':.002}
    assert supervisor.supervise(repo,config,stop_event=stop,sleep=sleep,max_launches=9)==130
    assert (repo/'launches').read_text()=='8' and len(waiting)==2 and (repo/'mode').read_text()=='REPLAN'


def test_runtime_readiness_rejects_missing_synthetic_and_stale_certificates(repo):
    config={'command':[sys.executable],'recovery_command':[],'storage_reserve_bytes':1}
    assert autonomy.check(repo,config)
    ident=autonomy.identity(repo,config);cases={}
    proof=put(repo,'fixture.json',{'synthetic':'not actual deployment evidence'})
    for case in autonomy.CASES:
        cases[case]=put(repo,case+'.json',{'case':case,'mode':'LIVE','identity':ident,'status':'PASS',
            'assertions':['fixture assertion'],'evidence':[proof]})
    # Only tests shape/hashes in a temporary fixture; cannot certify the actual deployment.
    cert={'mode':'SYNTHETIC','status':'PASS','identity':ident,'cases':cases}
    put(repo,'.agent/autonomy-readiness.json',cert);assert autonomy.check(repo,config)
    cert['mode']='LIVE';put(repo,'.agent/autonomy-readiness.json',cert);assert not autonomy.check(repo,config)
    assert autonomy.check(repo,{**config,'storage_reserve_bytes':2})
    cases.pop('reboot-service');put(repo,'.agent/autonomy-readiness.json',cert);assert autonomy.check(repo,config)


def test_new_logs_cannot_refresh_an_already_accepted_gate(repo):
    data=ready(repo);before=progress.signature(repo)
    put(repo,'proof.json',{'timing':'different but same accepted work'})
    for gate in cycles.REQUIRED:cycles.record_gate(repo,data,gate,'PASS',['proof.json'])
    assert progress.signature(repo)==before


def test_ottawa_experiment_guard_blocks_renamed_retry_and_allows_changed_cause(repo):
    import experiment_guard as guard
    definition={'binding':'same','start':0,'executable':'same'}
    key=guard.claim(repo,definition,'first')
    with pytest.raises(ProtocolError):guard.claim(repo,definition,'new-filename')
    put(repo,'failed-summary.json',{'run_id':'first','exit_code':1,'error':'BadNitrogen','failure_classification':'SCIENTIFIC'})
    guard.finish(repo,key,'failed-summary.json')
    with pytest.raises(ProtocolError):guard.claim(repo,definition,'third')
    assert guard.claim(repo,{**definition,'executable':'fixed-source'},'new-causal-experiment')!=key


def test_infrastructure_retry_requires_new_bound_recovery_and_rejects_heuristic_science(repo):
    import experiment_guard as guard
    definition={'binding':'same'};key=guard.claim(repo,definition,'first')
    put(repo,'failed-summary.json',{'run_id':'first','exit_code':1,'error':'PossibleScientificError'})
    guard.finish(repo,key,'failed-summary.json')
    evidence=put(repo,'diagnosis.json',{'observed':'synthetic disk fault and proven prior process exit'})
    decision={'classification':'INFRASTRUCTURE','experiment_key':key,'prior_run_id':'first',
        'diagnosis':'measured disk fault','resource_identity':'replacement disk identity',
        'prior_process_terminated':True,'evidence':[evidence]}
    put(repo,'recovery.json',decision)
    with pytest.raises(ProtocolError):guard.claim(repo,definition,'second','recovery.json')
    decision.update(scientific_failure_ruled_out=True,classification_evidence=[evidence])
    put(repo,'recovery.json',decision);assert guard.claim(repo,definition,'second','recovery.json')==key
    put(repo,'failed-summary-2.json',{'run_id':'second','exit_code':1});guard.finish(repo,key,'failed-summary-2.json')
    decision['prior_run_id']='second';put(repo,'recovery.json',decision)
    with pytest.raises(ProtocolError):guard.claim(repo,definition,'third','recovery.json')


@pytest.mark.parametrize('probe',['missing','identical'])
def test_probe_failure_or_repeated_identity_never_creates_unlimited_restarts(repo,monkeypatch,probe):
    monkeypatch.setattr(supervisor,'validate',lambda _:['unfinished'])
    stop=threading.Event()
    def sleep(_):
        p=repo/'.agent/runtime/supervisor.json'
        if p.exists():
            state=load(p)
            if state['status']=='WAITING_FOR_CHANGE' and state.get('no_progress_exits',0)>=4:stop.set()
    code="import pathlib;p=pathlib.Path('count');p.write_text(str(int(p.read_text())+1) if p.exists() else '1')"
    command=['no-such-fixture-probe'] if probe=='missing' else [sys.executable,'-c','print(\'{"ready": true, "identity": "same recovered provider"}\')']
    config={'command':[sys.executable,'-c',code],'recovery_command':command,'backoff_initial_seconds':.001,'backoff_max_seconds':.002}
    assert supervisor.supervise(repo,config,stop_event=stop,sleep=sleep,max_launches=9)==130
    assert (repo/'count').read_text()==('4' if probe=='missing' else '8')


def test_logged_benchmark_binds_conditions_and_preserves_direct_legacy_product(repo,monkeypatch):
    import platform
    import run_logged
    monkeypatch.setattr(run_logged,'toolchain',lambda:{})
    conditions=put(repo,'conditions.json',{'hardware':{'platform':platform.platform(),'machine':platform.machine()}})
    run_logged.run(repo,repo,repo/'audit/runs/measurement',[sys.executable,'-c','pass'],None,
                   benchmark_conditions='conditions.json')
    receipt=load(repo/'audit/runs/measurement/receipt.json')
    assert receipt['benchmark_conditions']==conditions
    compiler=repo/'gfortran';compiler.write_text('#!'+sys.executable+'\nimport pathlib,sys\npathlib.Path(sys.argv[sys.argv.index("-o")+1]).write_bytes(b"synthetic executable")\n')
    compiler.chmod(0o755)
    result=run_logged.run(repo,repo,repo/'audit/runs/legacy-build',[str(compiler),'-O3','-o','legacy-bin'],None)
    assert (repo/result['build_product']['path']).read_bytes()==b'synthetic executable'
    put(repo,'bad-conditions.json',{'hardware':{'platform':'different','machine':'different'}})
    with pytest.raises(ProtocolError):
        run_logged.run(repo,repo,repo/'audit/runs/wrong-host',[sys.executable,'-c','pass'],None,
                       benchmark_conditions='bad-conditions.json')
