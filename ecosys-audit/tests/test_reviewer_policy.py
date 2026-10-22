"""Reviewer gates cannot return through new documents or machine-readable policy."""
import json

import pytest
from test_autonomy import repo
from workflow_documents import (HISTORICAL_NOTICE, check_documents, configuration_errors,
                                document_paths, reviewer_prerequisites)


@pytest.mark.parametrize('text',[
    'Implementation requires a reviewer decision.',
    'A reviewer must approve the tolerance policy.',
    'Reviewer sign-off is required before publication.',
    'The worker must obtain an independent reviewer decision.',
    'Do not continue without a reviewer decision.',
    'The cycle is blocked until a reviewer decides.',
    'Release requires\nindependent review.',
    'FORGE diff needs SAGE review.',
])
def test_live_reviewer_gate_is_rejected(text):
    assert reviewer_prerequisites(text)


@pytest.mark.parametrize('text',[
    'No reviewer decision or sign-off is required.',
    'The leader must not wait for reviewer approval.',
    'Never require an independent reviewer decision.',
    'The leader independently assembles the conservation ledger.',
    'The leader verifies scientific evidence in a separate derivation.',
    'This checker requires retirement notices, and checks leader/reviewer policy.',
])
def test_leader_verification_and_prohibition_of_gates_are_allowed(text):
    assert reviewer_prerequisites(text)==[]


def test_new_untracked_document_is_checked_and_historical_label_cannot_hide_live_gate(repo):
    new=repo/'new-workflow.md'
    new.write_text(HISTORICAL_NOTICE+'\nRelease requires a reviewer decision.\n')
    assert 'new-workflow.md' in document_paths(repo)
    errors,_=check_documents(repo)
    assert any('new-workflow.md: reviewer prerequisite' in error for error in errors)


def test_historical_dossier_needs_explicit_retirement_and_retained_evidence_stays_data(repo):
    issue=repo/'audit/issues/history.md'
    issue.parent.mkdir(parents=True)
    original='Historical status: do not continue without a reviewer decision.\n'
    issue.write_text(original)
    retained=repo/'audit/runs/original.md'
    retained.parent.mkdir(parents=True)
    retained.write_text(original)
    errors,_=check_documents(repo)
    assert any('history.md: historical reviewer requirements' in error for error in errors)
    assert not any('original.md' in error for error in errors)
    issue.write_text(HISTORICAL_NOTICE+'\n'+original)
    assert check_documents(repo)[0]==[]


def test_machine_readable_reviewer_gate_cannot_return(repo):
    mission=repo/'.agent/mission.json'
    value={'agent':{'leaders':1,'reviewer_approval_required':False,'reviewer_decision_required':False}}
    mission.write_text(json.dumps(value))
    assert configuration_errors(repo)==[]
    value['agent']['reviewer_decision_required']=True
    mission.write_text(json.dumps(value))
    assert any('reviewer_decision_required' in error for error in configuration_errors(repo))
    gate=repo/'ecosys-audit/gate_requirements.json'
    gate.parent.mkdir(exist_ok=True)
    gate.write_text(json.dumps({'RELEASE':['independent-release-review']}))
    assert any('retired reviewer gate ID' in error for error in configuration_errors(repo))


def test_register_notes_cannot_reintroduce_a_reviewer_decision(repo):
    register=repo/'audit/traceability/traceability.csv'
    register.parent.mkdir(parents=True)
    register.write_text('id,notes\none,pending reviewer disposition confirmation\n')
    assert any('reviewer prerequisite' in error for error in configuration_errors(repo))
    register.write_text('id,notes\none,pending leader evidence verification\n')
    assert configuration_errors(repo)==[]
