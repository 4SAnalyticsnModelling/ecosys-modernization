"""Check active workflow vocabulary/resources; historical scientific records are data."""
import json
import re
from workflow import ROOT, load
from check_gate import STAGE_ALIASES
from skill_sync import sync
from cycle_runner import RESULTS
from workflow_documents import check_documents, configuration_errors

ACTIVE = ['AGENTS.md','PROMPT.md','README.md','CLAUDE.md','.agent/protocol.md','.agent/backlog.md',
          '.agent/README.md','.agent/continuous-autonomy.md','.agent/briefs/verifier.md',
          '.agent/playbooks/convergence-and-balance.md','.agent/templates/cycle.md',
          'ecosys-ng_ottawa_qualification_execution_plan.md','ecosys-audit/PROJECT_CONTRACT.md',
          'ecosys-audit/EVIDENCE_GUIDE.md','ecosys-audit/START_PROMPT.md',
          'ecosys-audit/qualification-evidence.md','validation/README.md','tools/autonomy/README.md']
REQUIRED = ['audit/output-provenance.csv','audit/traceability/bindings.csv',
            'validation/rules/divcheck-rules.json','ecosys-audit/suite_manifest.json',
            'ecosys-audit/qualification-evidence.md']
STAGES = ['BASELINE','SOURCE','ENTRY','CAMPAIGN','RELEASE']
FORBIDDEN = [r'(?i)user (?:approves|has signed|must approve)',r'(?i)pending human review',
             r'(?i)SAGE (?:drafts|approves|signs)',r'(?i)push only when asked',r'(?i)unlimited (?:crash recovery|capped-backoff retries)',
             r'(?i)profiled accepted windows → strict integrated campaign']


def check(root=ROOT):
    errors=[]
    document_errors,_=check_documents(root)
    errors.extend(document_errors)
    files=ACTIVE+[str(p.relative_to(root)) for p in (root/'.agents/skills').glob('*/SKILL.md')]
    for name in files:
        p=root/name
        if not p.is_file(): errors.append('missing active document: '+name);continue
        text=p.read_text()
        if any(re.search(pattern,text) for pattern in FORBIDDEN): errors.append('obsolete approval instruction: '+name)
        # Local Markdown links are executable guidance; external and fragment links are excluded.
        for target in re.findall(r'\]\(([^)]+)\)',text):
            if '://' in target or target.startswith('#'): continue
            target=target.split('#')[0]
            if not (p.parent/target).exists(): errors.append(name+': missing linked resource '+target)
    for name in REQUIRED:
        if not (root/name).is_file(): errors.append('missing required resource: '+name)
    try:
        errors.extend(configuration_errors(root))
        if list(load(root/'ecosys-audit/gate_requirements.json'))!=STAGES:
            errors.append('canonical stage inventory differs from active contract')
        if set(STAGE_ALIASES.values())-set(STAGES): errors.append('stage alias has unknown destination')
        contract=(root/'ecosys-audit/qualification-evidence.md').read_text()
        if ' → '.join(STAGES) not in contract: errors.append('documented stage sequence differs')
        if ' | '.join(RESULTS) not in contract: errors.append('documented gate results differ')
        rules=load(root/'validation/rules/divcheck-rules.json')
        if any(re.search(pattern,json.dumps(rules)) for pattern in FORBIDDEN): errors.append('obsolete rule approval instruction')
        errors += ['skill alias drift: '+p for p in sync(root)]
    except (OSError,ValueError,KeyError) as exc: errors.append(str(exc))
    return errors


if __name__=='__main__':
    errors=check();print(json.dumps({'consistent':not errors,'problems':errors},indent=2))
    raise SystemExit(bool(errors))
