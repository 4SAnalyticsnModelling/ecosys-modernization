"""Synthetic acceptance/recovery tests; these never qualify the Ottawa model."""
import copy
import csv
import json
from pathlib import Path
import sys
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from test_autonomy import repo
import dependencies
import completion
import qualification_reports as qr
import suite_check
import project_runtime as runtime
import cycle_runner
import pickup
import make_failure_packet
import check_gate
import readiness
from workflow import artifact, atomic, encoded, load


def put(root,name,value):
    atomic(root/name, encoded(value));return artifact(root,name)


@pytest.fixture
def evidence(repo,monkeypatch):
    compiler=repo/'compiler';compiler.write_bytes(b'synthetic compiler')
    monkeypatch.setattr(dependencies,'toolchain',lambda:{'zig':{'path':str(compiler),'version':'0.17.test'}})
    proof=put(repo,'proof.json',{'fixture':'synthetic evidence, not Ottawa'})
    (repo/'audit').mkdir(exist_ok=True)
    (repo/'audit/intentional-deviations.md').write_text('| DEV-001 | synthetic fixture |\n')
    rules={'status':'ESTABLISHED','decision':'synthetic exact rule','evidence':[proof],
           'variables':{'fixture':{'abs':0,'rel':0,'rationale':'synthetic exact values'}}}
    put(repo,readiness.RULES,rules)
    def csvfile(path,fields,row):
        p=repo/path;p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('w',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerow(row)
    output_fields=['output_file','column','fortran_origin','zig_origin','units','time_basis','kind','aggregation',
                   'conversion','comparison_rule','status','evidence']
    row={k:'fixture' for k in output_fields};row.update(status='VERIFIED',evidence=json.dumps([proof]))
    csvfile(readiness.OUTPUT,output_fields,row)
    binding_fields=['id','legacy_origin','zig_origin','shape','lower_bounds','units','time_level',
                    'initialization','reset','checkpoint','status','evidence']
    row={k:'fixture' for k in binding_fields};row.update(status='VERIFIED',evidence=json.dumps([proof]))
    csvfile(readiness.BINDINGS,binding_fields,row)
    manifest=load(Path(__file__).resolve().parents[1]/'suite_manifest.json')
    put(repo,suite_check.MANIFEST,manifest)
    return repo,proof


def suite_result(root,proof,case='tests-module-Debug',summary='+- run test 3 pass (3 total) 1s\n',exit_code=0):
    spec=load(root/suite_check.MANIFEST)['cases'][case]
    log=root/(case+'.log');log.write_text(summary)
    receipt={'status':'EXITED','exit_code':exit_code,'argv':spec['argv'],'cwd':str(root/spec['cwd']),
             'stderr':artifact(root,log.name)}
    ref=put(root,case+'-receipt.json',receipt)
    r={'schema_version':1,'case':case,'root':spec['root'],'mode':spec['mode'],'parser':spec['parser'],
       'receipt':ref,'counts_artifact':receipt['stderr'],'dependencies':dependencies.capture(root)}
    try:r['counts']=suite_check.counts(root,r)
    except Exception:pass
    return r


def report(root,proof,gid):
    source=runtime.content_digest(root,runtime.SOURCE_SCOPE)
    inv=[];results=[]
    if gid=='F2':
        for q in ('water','heat','C','N','P'):
            for level in ('local','global'):
                ident=q+'-'+level
                inv.append({'id':ident,'quantity':q,'level':level,'location':'fixture','units':'fixture','rule':'fixture'})
                results.append({'id':ident,'first_hour':1,'last_hour':qr.HOURS,'hours_checked':qr.HOURS,
                                'independent_assembly':True,'missing_hours':0,'duplicate_hours':0,'nonfinite':0,'breaches':0})
    elif gid=='F3':
        inv=[{'id':'field','file':'fixture','column':'fixture','units':'fixture','time_basis':'fixture','rule':'fixture',
              'expected_rows':2,'terminal_key':'end'}]
        results=[{'id':'field','rows_compared':2,'terminal_key':'end','missing':0,'extra':0,'duplicates':0,'nonfinite':0,'outside_rule':0}]
    elif gid=='F4':
        for direction in ('legacy-to-zig','zig-to-legacy','state-binding'):
            inv.append({'id':direction,'direction':direction,'source':'ecosys-ng/src/a.zig',
                        'source_sha256':artifact(root,'ecosys-ng/src/a.zig')['sha256'],'dormant':True})
            results.append({'id':direction,'semantics_reviewed':True,'disposition':'equivalent',
                            'derivation':'fixture derivation','test_or_dormant_reason':'fixture case'})
    elif gid=='F5':
        inv=[{'id':'DEV-001','replacement_physics':False}]
        results=[{'id':'DEV-001','disposition':'retired','mechanism':'fixture','measured_impact':'fixture','decision':'removed'}]
    elif gid=='F6':
        for ident in sorted(qr.F6_CASES):
            inv.append({'id':ident});item={'id':ident}
            if ident.startswith('tests-'):
                item['suite_result']=put(root,ident+'-result.json',suite_result(root,proof,ident))
            elif ident.startswith('build-'):
                item['build_receipt']=put(root,ident+'-receipt.json',{'status':'EXITED','exit_code':0,'build_mode':ident[6:],
                    'source_digest':source,'source_changed_during_command':False,'build_product':proof,
                    'toolchain':{'zig':{'version':'0.17.test'}}})
            elif ident.startswith('restart-') or ident=='reproducibility':
                item.update(fields_checked=2,full_state=True,mismatches=0,missing_fields=0,nonfinite=0,
                            corrupt_rejected=True,truncated_rejected=True,atomic_rejection=True)
            elif ident=='releasefast-safety':item.update(bounds_checked=True,rollback_checked=True,allocation_failure_checked=True)
            elif ident=='equivalent-work-performance':item.update(repeats=3,equivalent_work=True,
                measurements=[{'wall_seconds':1,'cpu_seconds':1,'peak_rss_bytes':10,'accepted_hours':1} for _ in range(3)])
            results.append(item)
    for item in results:item.update(status='PASS',evidence=[proof])
    inventory=put(root,gid+'-inventory.json',{'schema_version':1,'criterion':gid,'scope_complete':True,
        'verification_method':'separate-derivation','evidence':[proof],'items':inv})
    return {'schema_version':1,'criterion':gid,'source_digest':source,'binding_id':'fixture-binding',
            'status':'PASS','unresolved':[],'verification_method':'separate-derivation','dependencies':dependencies.capture(root),
            'evidence':[proof],'inventory':inventory,'results':results}


@pytest.mark.parametrize('gid',['F2','F3','F4','F5','F6'])
def test_complete_synthetic_report_and_omitted_result(evidence,gid):
    root,proof=evidence;r=report(root,proof,gid)
    assert qr.validate(root,gid,r,r['source_digest'],r['binding_id'])==[]
    r['results'].pop()
    assert qr.validate(root,gid,r,r['source_digest'],r['binding_id'])


@pytest.mark.parametrize('gid,key,value',[('F2','hours_checked',262919),('F2','breaches',1),('F2','independent_assembly',False),
    ('F3','rows_compared',1),('F3','nonfinite',1),('F4','semantics_reviewed',False),('F5','disposition','pending')])
def test_correct_hashes_do_not_hide_failed_contents(evidence,gid,key,value):
    root,proof=evidence;r=report(root,proof,gid);r['results'][0][key]=value
    ref=put(root,'damaged-report.json',r)
    assert qr.validate(root,gid,qr.referenced(root,ref),r['source_digest'],r['binding_id'])


def test_finish_invokes_structured_reports(evidence,monkeypatch):
    root,proof=evidence;source=runtime.content_digest(root,runtime.SOURCE_SCOPE);binding='fixture-binding'
    checks={}
    for gid in ('F1','F2','F3','F4','F5','F6','F7'):
        checks[gid]={'status':'PASS','source_digest':source,'binding_id':binding,'evidence':[proof]}
        if gid in ('F2','F3','F4','F5','F6'):
            ref=put(root,gid+'.json',report(root,proof,gid));checks[gid].update(report=ref,evidence=[ref])
    campaign=put(root,'campaign.json',{'build_binding_verified':True,'status':'COMPLETE','mode':'strict',
        'start_hour':0,'last_completed_hour':qr.HOURS,'conservation_breaches':0,'solver_fallbacks_unexplained':0,
        'binding':{'binding_id':binding}})
    checks['F1']['evidence']=[campaign]
    c={'schema_version':2,'source_digest':source,'binding_id':binding,'checks':checks,'campaign_summary':'campaign.json'}
    put(root,'.agent/frontier.json',{'verified_frontier':qr.HOURS,'evidence_binding':{'binding_id':binding}})
    put(root,'.agent/finish.json',c)
    def git(_root,*args):
        if args[0]=='branch':return b'main'
        if args[0]=='status':return b''
        return b'fixture-commit'
    monkeypatch.setattr(completion,'git',git)
    assert completion.validate(root)==[]
    r=load(root/'F2.json');r['results'][0]['missing_hours']=1
    ref=put(root,'F2.json',r);c['checks']['F2'].update(report=ref,evidence=[ref]);put(root,'.agent/finish.json',c)
    assert any('missing_hours' in e for e in completion.validate(root))


@pytest.mark.parametrize('path',['ecosys-ng/src/a.zig',readiness.RULES,'ecosys-audit/scripts/validator.py','compiler',
                                'ecosys-ng-prod-examples/deck/input'])
def test_changed_dependencies_invalidate(evidence,path):
    root,_=evidence;before=dependencies.capture(root);p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('changed')
    assert dependencies.verify(root,before)


def test_unrelated_docs_do_not_invalidate_and_narrowing_needs_reason(evidence):
    root,_=evidence;before=dependencies.capture(root);(root/'README.md').write_text('orientation')
    assert not dependencies.verify(root,before)
    with pytest.raises(Exception):dependencies.capture(root,scope=['ecosys-ng/src/a.zig'])
    assert dependencies.verify(root,None)


def test_inconclusive_and_legacy_verdicts_do_not_close(evidence):
    root,proof=evidence
    from test_autonomy import ready
    data=ready(root);cycle_runner.record_gate(root,data,'G7','INCONCLUSIVE',[proof['path']])
    assert any('G7: missing or failed'==e for e in cycle_runner.blockers(root,data))
    data['gates']['G1'].pop('dependencies')
    assert any('historical evidence' in e for e in cycle_runner.blockers(root,data))


@pytest.mark.parametrize('summary,code',[('+- run test 0 pass (0 total)\n',0),('+- run test 2 pass, 1 skip (3 total)\n',0),
    ('+- run test cached\n',0),('+- run test 3 pass (3 total)\n',1)])
def test_suite_rejects_zero_skips_unknown_or_failure(evidence,summary,code):
    root,proof=evidence;r=suite_result(root,proof,summary=summary,exit_code=code)
    assert suite_check.assess(root,r)


def test_suite_checks_real_counts_mode_and_root(evidence):
    root,proof=evidence;r=suite_result(root,proof)
    assert suite_check.assess(root,r)==[]
    for field,value in [('counts',{'selected':99}),('mode','ReleaseFast'),('root','other')]:
        bad=copy.deepcopy(r);bad[field]=value;assert suite_check.assess(root,bad)


def test_missing_identity_never_allows_retry(evidence,monkeypatch):
    root,_=evidence
    monkeypatch.setattr(runtime,'process_identity',lambda pid:'observed')
    assert runtime.job_state({'pid':123})=='unknown'
    assert runtime.job_state({'pid':123,'process_start':'observed'})=='alive'
    assert runtime.job_state({'pid':123,'process_start':'different'})=='dead'
    put(root,'audit/runs/orphan/receipt.json',{'status':'RUNNING','pid':123})
    result=pickup.collect(root)['running_receipts'][0]
    assert result['state']=='unknown' and result['automatic_retry_allowed'] is False


def test_rejections_require_bound_falsification_and_expire(evidence):
    root,_=evidence;put(root,'summary.json',{'binding':{'binding_id':'fixture'}});put(root,'state.json',{'pool':1})
    first=make_failure_packet.build(root,'summary.json','signature',rejected=['hypothesis'],state='state.json',falsifier='measured term is zero')
    assert load(first)['rejected_hypotheses']==['hypothesis']
    second=make_failure_packet.build(root,'summary.json','signature',state='state.json')
    assert load(second)['rejected_hypotheses']==['hypothesis']
    put(root,'state.json',{'pool':2})
    third=make_failure_packet.build(root,'summary.json','signature',state='state.json')
    assert load(third)['rejected_hypotheses']==[] and load(third)['rejection_records']


def test_rule_and_register_readiness_do_not_invent_science(evidence):
    root,_=evidence;assert readiness.check(root)==[]
    (root/readiness.BINDINGS).write_text('id\n')
    assert readiness.check(root)


def test_stage_aliases_reach_same_validation(evidence):
    root,_=evidence
    for alias,canonical in check_gate.STAGE_ALIASES.items():
        assert check_gate.check(root,{'schema_version':1,'stage':alias})==check_gate.check(root,{'schema_version':1,'stage':canonical})


def test_ignored_staged_input_changes_invalidate(evidence):
    root,_=evidence;(root/'.gitignore').write_text('evidence/\n')
    p=root/'evidence/staged/input';p.parent.mkdir(parents=True);p.write_text('first input')
    before=dependencies.capture(root,scope=['evidence/staged'],justification='isolated matched-state fixture')
    p.write_text('other input')
    assert dependencies.verify(root,before)


def test_removed_root_from_inventory_still_blocks_f6(evidence):
    root,proof=evidence;r=report(root,proof,'F6')
    inv=qr.referenced(root,r['inventory']);inv['items']=[i for i in inv['items'] if i['id']!='tests-executable-ReleaseFast']
    r['inventory']=put(root,'F6-inventory.json',inv)
    r['results']=[i for i in r['results'] if i['id']!='tests-executable-ReleaseFast']
    assert any('missing required' in e for e in qr.validate(root,'F6',r,r['source_digest'],r['binding_id']))


def test_broken_restart_and_nonfinite_performance_block(evidence):
    root,proof=evidence;r=report(root,proof,'F6')
    for ident,field,value in [('restart-active-science','missing_fields',1),
                              ('equivalent-work-performance','measurements',[{'wall_seconds':float('nan')}]*3)]:
        bad=copy.deepcopy(r);next(i for i in bad['results'] if i['id']==ident)[field]=value
        assert qr.validate(root,'F6',bad,bad['source_digest'],bad['binding_id'])


def test_synthetic_suite_runner_accounts_for_actual_junit(evidence):
    root,_=evidence
    code="import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('<testsuites><testsuite><testcase name=\"synthetic\"/></testsuite></testsuites>')"
    spec={'schema_version':1,'cases':{'synthetic':{'root':'fixture','mode':'python','cwd':'.','parser':'junit',
                                               'argv':[sys.executable,'-c',code,'{junit}']}}}
    put(root,suite_check.MANIFEST,spec)
    result=suite_check.run_case(root,'synthetic','audit/runs/synthetic')
    assert result['status']=='PASS' and result['counts']['executed']==1


def test_rule_establishment_requires_current_evidence(evidence):
    import divcheck
    root,proof=evidence;rules=load(root/readiness.RULES);rules['default']={'abs':0,'rel':0}
    put(root,readiness.RULES,rules)
    assert divcheck.load_rules(root/readiness.RULES,root)['_decision_verified'] is True
    (root/proof['path']).write_text('changed evidence')
    with pytest.raises(divcheck.DumpError): divcheck.load_rules(root/readiness.RULES,root)


def test_legacy_approval_does_not_establish_rules(evidence):
    import divcheck
    root,_=evidence
    put(root,'old-rules.json',{'default':{'abs':0,'rel':0},'variables':{},'approved_by':'retired role','_decision_verified':True})
    assert divcheck.load_rules(root/'old-rules.json',root)['_decision_verified'] is False


def test_preserved_build_survives_next_mode_and_is_executable(evidence):
    import os
    import run_logged
    root,_=evidence;tool=root/'zig';tool.write_text('#!/bin/sh\nexit 0\n');tool.chmod(0o700)
    product=root/'ecosys-ng/ecosys-ng-bin/ecosys_ng';product.parent.mkdir();product.write_bytes(b'first mode');product.chmod(0o700)
    receipt=run_logged.run(root,root/'ecosys-ng',root/'audit/runs/build',[str(tool),'build'],None)
    product.write_bytes(b'next mode')
    ref=receipt['build_product']
    assert artifact(root,ref['path'])==ref and os.access(root/ref['path'],os.X_OK)
    other=run_logged.run(root,root,root/'audit/runs/unrelated-build',[str(tool),'build'],None)
    assert 'build_product' not in other
