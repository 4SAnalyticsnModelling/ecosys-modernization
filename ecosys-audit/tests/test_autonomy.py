"""Behavioral checks for closure, recovery, contained execution and source tools."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import pytest

SCRIPTS=Path(__file__).resolve().parents[1]/'scripts'
sys.path.insert(0,str(SCRIPTS))
import cycle_runner as cycles
import worker_supervisor as supervisor
import completion
import code_nav
import codemod
import project_runtime as runtime
import preflight
from workflow import ProtocolError, atomic, encoded, load

@pytest.fixture
def repo(tmp_path):
    root=tmp_path/'repo';root.mkdir()
    subprocess.run(['git','init','-q',str(root)],check=True)
    subprocess.run(['git','config','user.email','fixture@example.invalid'],cwd=root,check=True)
    subprocess.run(['git','config','user.name','Fixture'],cwd=root,check=True)
    (root/'ecosys-ng/src').mkdir(parents=True);(root/'.agent').mkdir()
    (root/'ecosys-ng/src/a.zig').write_text('pub fn main() void {}\n')
    subprocess.run(['git','add','.'],cwd=root,check=True)
    subprocess.run(['git','commit','-qm','base'],cwd=root,check=True)
    return root


def ready(root):
    (root/'proof.json').write_text('{"measured":"fixture evidence"}\n')
    d={'cycle':1,'status':'WORKING','base_commit':cycles.head(root),
       'owned_paths':['ecosys-ng/src/a.zig'],'scope':['ecosys-ng/src'],'gates':{}}
    for g in cycles.REQUIRED:cycles.record_gate(root,d,g,'PASS',['proof.json'])
    return d


def test_failed_g7_cannot_close(repo):
    d=ready(repo);cycles.record_gate(repo,d,'G7','FAIL',['proof.json'])
    assert any('G7' in x for x in cycles.blockers(repo,d))


def test_empty_or_invalid_verdict_refused(repo):
    d=ready(repo)
    with pytest.raises(ProtocolError):cycles.record_gate(repo,d,'G7','APPROVED',['proof.json'])
    with pytest.raises(ProtocolError):cycles.record_gate(repo,d,'G7','PASS',[])
    with pytest.raises(ProtocolError):cycles.record_gate(repo,d,'G7','NA',['proof.json'])


def test_source_change_invalidates_all_gates(repo):
    d=ready(repo);(repo/'ecosys-ng/src/a.zig').write_text('pub fn changed() void {}\n')
    assert sum('stale candidate' in x for x in cycles.blockers(repo,d))==8


def test_changed_evidence_invalidates_gate(repo):
    d=ready(repo);(repo/'proof.json').write_text('changed')
    assert any('stale evidence' in x for x in cycles.blockers(repo,d))


def test_dry_close_is_read_only(repo):
    d=ready(repo);before=(repo/'.agent/cycle.json').read_bytes()
    assert cycles.close(repo,d,'verified',True)=={'ready':True}
    assert (repo/'.agent/cycle.json').read_bytes()==before


def test_science_cannot_use_na(repo):
    d=ready(repo);(repo/'ecosys-ng/src/a.zig').write_text('pub fn fixed() void {}\n')
    for g in cycles.REQUIRED:cycles.record_gate(repo,d,g,'PASS',['proof.json'])
    cycles.record_gate(repo,d,'G7','NA',['proof.json'],'claimed not applicable')
    assert 'G7: scientific change requires PASS' in cycles.blockers(repo,d)


def test_entire_cycle_diff_detected_after_multiple_commits(repo):
    d=ready(repo);p=repo/'ecosys-ng/src/a.zig';p.write_text('pub fn changed() void {}\n')
    subprocess.run(['git','add',str(p)],cwd=repo,check=True)
    subprocess.run(['git','commit','-qm','science'],cwd=repo,check=True)
    (repo/'note.md').write_text('doc');subprocess.run(['git','add','note.md'],cwd=repo,check=True)
    subprocess.run(['git','commit','-qm','doc'],cwd=repo,check=True)
    assert 'ecosys-ng/src/a.zig' in cycles.changed(repo,d['base_commit'])


def test_close_pushes_ledger_and_leaves_no_owned_dirt(repo,tmp_path):
    remote=tmp_path/'remote.git';subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
    subprocess.run(['git','branch','-M','main'],cwd=repo,check=True)
    subprocess.run(['git','remote','add','origin',str(remote)],cwd=repo,check=True)
    subprocess.run(['git','push','-q','origin','HEAD:main'],cwd=repo,check=True)
    d=ready(repo);cycles.close(repo,d,'evidence')
    assert not subprocess.check_output(['git','diff','HEAD','--','.agent/cycle.json'],cwd=repo)
    assert cycles.head(repo)==subprocess.check_output(['git','rev-parse','origin/main'],cwd=repo,text=True).strip()


def test_source_identity_ignores_documentation_commit(repo):
    before=runtime.content_digest(repo,runtime.SOURCE_SCOPE)
    (repo/'note.md').write_text('documentation');subprocess.run(['git','add','note.md'],cwd=repo,check=True)
    subprocess.run(['git','commit','-qm','docs'],cwd=repo,check=True)
    assert runtime.content_digest(repo,runtime.SOURCE_SCOPE)==before


def test_batch_has_lines_hashes_and_explicit_truncation(repo):
    p=repo/'ecosys-ng/src/a.zig';p.write_text('pub fn a() void {}\npub fn b() void {}\n')
    out=code_nav.batch(repo,[{'op':'outline','path':'ecosys-ng/src/a.zig','limit':1},
                            {'op':'search','path':'ecosys-ng/src/a.zig','pattern':'b()'}])
    assert out[0]['truncated'] and out[0]['total_matches']==2
    assert out[1]['rows'][0]['line']==2
    assert out[0]['sha256']==hashlib.sha256(p.read_bytes()).hexdigest()


def test_batch_refuses_escape_without_losing_other_results(repo):
    out=code_nav.batch(repo,[{'op':'show','path':'../escape'}, {'op':'outline','path':'ecosys-ng/src/a.zig'}])
    assert 'error' in out[0] and 'rows' in out[1]


def spec(root,path='ecosys-ng/src/a.zig'):
    p=root/path
    return {'path':path,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
            'old':'main','new':'changed','count':1}


def test_codemod_preview_and_hash_guard(repo):
    e=spec(repo);p=repo/e['path'];before=p.read_bytes()
    assert '-pub fn main' in codemod.apply(repo,[e]) and p.read_bytes()==before
    codemod.apply(repo,[e],True);assert 'changed' in p.read_text()
    with pytest.raises(ProtocolError):codemod.apply(repo,[e],True)


def test_codemod_validates_all_files_before_mutation(repo):
    a=spec(repo);p=repo/'b.zig';p.write_text('main\n');b=spec(repo,'b.zig');b['count']=2
    with pytest.raises(ProtocolError):codemod.apply(repo,[a,b],True)
    assert 'main' in (repo/a['path']).read_text()


def test_codemod_never_changes_reference(repo):
    (repo/'f77src').mkdir();(repo/'f77src/a.f').write_text('main')
    with pytest.raises(ProtocolError):codemod.apply(repo,[spec(repo,'f77src/a.f')],True)


def test_preflight_handles_quoted_paths_and_assignment(repo):
    assert preflight.check_command('tool --out="/tmp/out side"',repo,repo)[0]['level']=='FAIL'
    assert preflight.check_command('TMPDIR=/tmp tool',repo,repo)[0]['level']=='FAIL'
    assert preflight.check_command('tool "./a b"',repo,repo)[0]['level']=='PASS'


def test_unconfigured_worker_never_launches():
    with pytest.raises(ProtocolError):supervisor.check_config({'command':[],'recovery_command':[]})


def test_worker_recovers_from_crash_and_from_early_success(repo,monkeypatch):
    # Real subprocess: first exits nonzero, then zero without mission evidence, then completes fixture objective.
    code="""import json,os,pathlib,sys
p=pathlib.Path('launches');n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))
r=json.loads(pathlib.Path(os.environ['ECOSYS_RECOVERY_PACKET']).read_text());assert 'pickup' in r
sys.exit(7 if n==1 else 0)
"""
    monkeypatch.setattr(supervisor,'validate',lambda root: [] if (root/'launches').exists() and int((root/'launches').read_text())>=3 else ['unfinished'])
    config={'command':[sys.executable,'-c',code],'recovery_command':[], 'backoff_initial_seconds':.001,'backoff_max_seconds':.002}
    assert supervisor.supervise(repo,config,sleep=lambda _:None,max_launches=4)==0
    assert (repo/'launches').read_text()=='3'
    assert load(repo/'.agent/runtime/supervisor.json')['status']=='EXITED'


def test_valid_pid_with_wrong_start_is_not_adopted(monkeypatch):
    monkeypatch.setattr(runtime,'process_identity',lambda pid:'different start')
    assert not runtime.owned_alive({'pid':123,'process_start':'old start'})


def test_missing_finish_never_completes(repo):
    assert completion.validate(repo)


def test_cache_environment_is_local(repo):
    env=runtime.environment(repo)
    assert all(Path(env[name]).is_relative_to(repo) for name in runtime.CACHE_DIRS)


def test_codemod_rejects_symbolic_alias(repo):
    (repo/'alias.zig').symlink_to(repo/'ecosys-ng/src/a.zig')
    with pytest.raises(ProtocolError):codemod.apply(repo,[spec(repo,'alias.zig')],True)


def test_worker_retains_inherited_lifetime_lease(repo,monkeypatch):
    code="""import fcntl,os,pathlib
fd=os.open('.agent/runtime/worker-lease.lock',os.O_RDWR)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 raise RuntimeError('supervisor failed to retain worker lifetime lease')
except BlockingIOError:
 pathlib.Path('lease-verified').write_text('yes')
"""
    monkeypatch.setattr(supervisor,'validate',lambda root:[] if (root/'lease-verified').exists() else ['unfinished'])
    config={'command':[sys.executable,'-c',code],'recovery_command':[], 'backoff_initial_seconds':.001,'backoff_max_seconds':.002}
    assert supervisor.supervise(repo,config,sleep=lambda _:None,max_launches=1)==0


def test_corrupt_supervisor_record_is_preserved_and_reconciled(repo,monkeypatch):
    r=repo/'.agent/runtime';r.mkdir();(r/'supervisor.json').write_text('{broken')
    code="import pathlib;pathlib.Path('recovered').write_text('yes')"
    monkeypatch.setattr(supervisor,'validate',lambda root:[] if (root/'recovered').exists() else ['unfinished'])
    config={'command':[sys.executable,'-c',code],'recovery_command':[], 'backoff_initial_seconds':.001,'backoff_max_seconds':.002}
    assert supervisor.supervise(repo,config,sleep=lambda _:None,max_launches=1)==0
    assert len(list(r.glob('supervisor-corrupt-*.json')))==1
    assert 'state_error' in load(r/'recovery.json')['previous_worker']


def test_comparison_interval_caps_frontier(tmp_path):
    import update_frontier as uf
    from test_update_frontier import make_test_env
    from stage_ottawa_deck import TARGET_BLOB
    s,d,r=make_test_env(tmp_path,runottawa_hash=TARGET_BLOB,completed_hour=100)
    report=load(d);report['last_verified_hour']=20;atomic(d,encoded(report))
    result=uf.promote(tmp_path,str(s.relative_to(tmp_path)),str(d.relative_to(tmp_path)),str(r.relative_to(tmp_path)))
    assert result['to']==20


def test_zig_outline_omits_local_values_and_import_preamble(repo):
    (repo/'ecosys-ng/src/a.zig').write_text('const std = @import("std");\npub const A = struct {\n    pub fn f() void {\n        const local = 1;\n    }\n};\n')
    result=code_nav.batch(repo,[{'op':'outline','path':'ecosys-ng/src/a.zig'}])[0]
    assert [x['line'] for x in result['rows']]==[2,3]


def test_stage_gate_accepts_same_model_separate_derivation(repo,monkeypatch):
    import snapshot
    import check_gate
    for name in ['f77src','f77example','ecosys-ng-prod-examples']:(repo/name).mkdir()
    (repo/'audit').mkdir();proof=repo/'audit/proof.json';proof.write_text('{"verified":"fixture"}')
    snap=repo/'audit/snapshot.json';atomic(snap,encoded(snapshot.collect(repo)))
    ref=lambda p:{'path':str(p.relative_to(repo)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
    monkeypatch.setattr(check_gate,'REQUIREMENTS',{'fixture':['one']})
    gate={'schema_version':1,'stage':'fixture','snapshot':ref(snap),'checks':[
        {'id':'one','status':'PASS','author':'one model','verification_method':'separate-derivation','evidence':[ref(proof)]}]}
    assert check_gate.check(repo,gate)==[]
    gate['checks'][0]['verification_method']='agreed with summary'
    assert any('re-derivation' in e for e in check_gate.check(repo,gate))


def test_help_cannot_certify_stale_build_product(repo):
    import run_logged
    tool=repo/'zig';tool.write_text('#!/bin/sh\nexit 0\n');tool.chmod(0o700)
    product=repo/'ecosys-ng/ecosys-ng-bin/ecosys_ng';product.parent.mkdir();product.write_bytes(b'stale binary')
    result=run_logged.run(repo,repo,repo/'audit/runs/help',[str(tool),'build','--help'],None)
    assert result['exit_code']==0 and 'build_product' not in result


def test_unbound_build_cannot_promote_frontier(tmp_path):
    import update_frontier as uf
    from test_update_frontier import make_test_env
    from stage_ottawa_deck import TARGET_BLOB
    s,d,r=make_test_env(tmp_path,runottawa_hash=TARGET_BLOB)
    report=load(s);report.pop('build_binding_verified');atomic(s,encoded(report))
    result=uf.promote(tmp_path,str(s.relative_to(tmp_path)),str(d.relative_to(tmp_path)),str(r.relative_to(tmp_path)))
    assert result['status']=='REFUSED'


def test_failure_packet_carries_rejections_without_empty_reports(repo):
    import make_failure_packet as packets
    (repo/'summary.json').write_text('{"failure_hour":42}')
    first=packets.build(repo,'summary.json','same failure',rejected=['wrong hypothesis'])
    second=packets.build(repo,'summary.json','same failure',ranges=['ecosys-ng/src/a.zig:1-1'])
    result=load(second)
    assert result['rejected_hypotheses']==[]
    assert result['rejection_records'][0]['hypothesis']=='wrong hypothesis'
    assert result['rejection_records'][0]['current'] is False
    assert result['sources'][0]['rows'][0]['line']==1
    assert len(list(second.parent.iterdir()))==2
