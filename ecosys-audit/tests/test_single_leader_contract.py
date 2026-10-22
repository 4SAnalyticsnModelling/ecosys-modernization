"""One leader can complete evidence checks without a reviewer actor; bad evidence fails."""
import copy
import hashlib

import pytest
from test_autonomy import repo
import check_gate
import compare_outputs
import snapshot
from workflow import atomic, encoded


def test_release_accepts_one_leader_and_still_requires_complete_valid_evidence(repo):
    for name in ['f77src','f77example','ecosys-ng-prod-examples']:
        (repo/name).mkdir()
    (repo/'audit').mkdir()
    proof=repo/'audit/proof.json'
    proof.write_text('{"verified":"fixture"}')
    snap=repo/'audit/snapshot.json'
    atomic(snap,encoded(snapshot.collect(repo)))
    def ref(p):
        return {'path':str(p.relative_to(repo)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
    gate={'schema_version':1,'stage':'RELEASE','snapshot':ref(snap),'checks':[
        {'id':ident,'status':'PASS','author':'leader','verification_method':'separate-derivation',
         'evidence':[ref(proof)]} for ident in check_gate.REQUIREMENTS['RELEASE']]}
    assert check_gate.check(repo,gate)==[]
    missing=copy.deepcopy(gate)
    missing['checks']=[r for r in missing['checks'] if r['id']!='leader-release-verification']
    assert any('inventory mismatch' in error for error in check_gate.check(repo,missing))
    proof.write_text('{"changed":"fixture"}')
    assert any('hash changed' in error for error in check_gate.check(repo,gate))


@pytest.mark.parametrize('owner_field',['decision_owner','approved_by'])
def test_same_leader_can_establish_comparison_policy_without_a_reviewer(tmp_path,owner_field):
    reference=tmp_path/'reference.csv'
    candidate=tmp_path/'candidate.csv'
    reference.write_text('time,carbon\n1,2\n')
    candidate.write_text(reference.read_text())
    schema={'schema_version':1,'status':'APPROVED',owner_field:'leader','keys':['time'],
        'columns':{'carbon':{'kind':'number','units':'g C','semantics':'instantaneous',
            'atol':0,'rtol':0,'scale_floor':0,'rationale':'Unchanged exact fixture.'}}}
    assert compare_outputs.compare(reference,candidate,schema)['status']=='PASS'
    invalid=copy.deepcopy(schema)
    invalid.pop(owner_field)
    with pytest.raises(compare_outputs.ComparisonError,match='leader responsible'):
        compare_outputs.validate_schema(invalid)
    candidate.write_text('time,carbon\n1,3\n')
    assert compare_outputs.compare(reference,candidate,schema)['status']=='FAIL'
    candidate.write_text('time,carbon\n1,NaN\n')
    with pytest.raises(compare_outputs.ComparisonError,match='nonfinite'):
        compare_outputs.compare(reference,candidate,schema)
