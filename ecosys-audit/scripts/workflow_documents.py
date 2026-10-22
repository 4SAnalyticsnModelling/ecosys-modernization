"""Discover project documents and reject live reviewer-approval prerequisites."""
from pathlib import Path
import csv
import json
import re
import subprocess

HISTORICAL_NOTICE = '<!-- workflow-policy: historical; reviewer-gates=retired -->'
HISTORICAL = ('audit/issues/','audit/features/','audit/release/','audit/analysis/',
              'audit/experiments/','.agent/cycles/')
RETAINED = ('audit/runs/','audit/reviews/','evidence/')
PROTECTED = ('f77src/','f77example/','ecosys-ng-prod-examples/')
ROLE = r'(?:reviewer|peer reviewer|human reviewer|independent reviewer|adversar\w*|SAGE)'
MENTIONS = re.compile(r'reviewer|sign[- ]?off|adversar|peer review|\bSAGE\b|human.{0,30}(?:decision|approval)|independent.{0,30}review',re.I)
PREREQUISITES = [
    re.compile(r'\b(?:require(?:s|d)?|needs?|await(?:ing)?|wait(?:ing)? for|pending|blocked (?:on|until)|must (?:obtain|secure|receive))\b[^,;:.]{0,90}\b'+ROLE+r'\b',re.I),
    re.compile(r'\b'+ROLE+r'\b.{0,80}\b(?:must|shall|has to|needs to|required to)\b.{0,50}\b(?:approv\w*|decid\w*|sign\w*|authoriz\w*)',re.I),
    re.compile(r'\b'+ROLE+r'\b.{0,50}\b(?:decision|approval|sign[- ]?off)\b.{0,35}\b(?:(?:is )?required|is needed|must be obtained|before proceeding)\b',re.I),
    re.compile(r'\b(?:do not|must not|cannot|never)\b.{0,70}\b(?:proceed|continue|publish|implement|merge)\b.{0,60}\b(?:without|until)\b.{0,60}\b'+ROLE+r'\b',re.I),
    re.compile(r'\b(?:require[sd]?|mandatory)\b.{0,40}\b(?:peer review|independent review|reviewer sign[- ]?off)\b',re.I),
]
NEGATED = re.compile(r'\b(?:no|never|not|without)\b.{0,80}\b(?:reviewer|review|approval|sign[- ]?off)\b|\b(?:is not required|are not required|not a prerequisite|are superseded|are retired|not active)\b',re.I)


def document_paths(root):
    """Include newly added documents as well as tracked files; ignore generated caches."""
    result=subprocess.run(['git','ls-files','--cached','--others','--exclude-standard','-z'],
                          cwd=root,capture_output=True,check=True)
    names=set(result.stdout.decode().split('\0'))
    # This machine-local runbook is intentionally Git-ignored but still guides work.
    if (root/'SYNC-LOCAL.md').is_file(): names.add('SYNC-LOCAL.md')
    return sorted(name for name in names if name and Path(name).suffix.lower() in
                  {'.md','.rst','.txt'} and (root/name).is_file())


def kind(name):
    if name in ('evidence/README.md','evidence/manifest/README.md'): return 'active-document'
    if name.startswith(PROTECTED): return 'protected-reference'
    if name.startswith(RETAINED): return 'retained-evidence'
    if name.startswith(HISTORICAL): return 'historical-dossier'
    return 'active-document'


def reviewer_prerequisites(text):
    """Check complete wrapped clauses, preserving prohibitions on reviewer gates."""
    problems=[]
    for paragraph in re.split(r'\n\s*\n',text):
        normalized=' '.join(paragraph.split())
        for clause in re.split(r'(?<=[.!?;])\s+',normalized):
            # Negation is checked around each match, not across a whole document.
            for pattern in PREREQUISITES:
                for match in pattern.finditer(clause):
                    context=clause[max(0,match.start()-50):match.end()+45]
                    # "Do not proceed without a reviewer" is itself a gate,
                    # whereas "do not wait for a reviewer" prohibits one.
                    if pattern is PREREQUISITES[3] or not NEGATED.search(context):
                        problems.append(match.group())
    return list(dict.fromkeys(problems))


def check_documents(root):
    errors=[];inventory=[]
    for name in document_paths(root):
        category=kind(name)
        text=(root/name).read_text(errors='replace')
        row={'path':name,'kind':category,'reviewer_mentions':bool(MENTIONS.search(text))}
        if category=='active-document':
            row['problems']=reviewer_prerequisites(text)
            errors.extend(name+': reviewer prerequisite: '+p for p in row['problems'])
        elif category=='historical-dossier' and row['reviewer_mentions']:
            if HISTORICAL_NOTICE not in text[:1600]:
                errors.append(name+': historical reviewer requirements need an explicit retirement notice')
        inventory.append(row)
    return errors,inventory


def configuration_errors(root):
    """Prevent descriptive machine-readable policy from reinstating a reviewer gate."""
    errors=[]
    mission=root/'.agent/mission.json'
    if mission.is_file():
        agent=json.loads(mission.read_text()).get('agent',{})
        if agent.get('leaders')!=1: errors.append('mission must name one accountable leader')
        for flag in ['reviewer_approval_required','reviewer_decision_required']:
            if agent.get(flag) is not False: errors.append('mission must explicitly disable '+flag)
    for name in ['ecosys-audit/gate_requirements.json','ecosys-audit/templates/release.json']:
        p=root/name
        if p.is_file() and re.search(r'independent-release-review|reviewer-(?:approval|signoff|decision)|adversarial-review',p.read_text(),re.I):
            errors.append(name+': retired reviewer gate ID')
    for name in ['audit/validation-ledger.csv','audit/traceability/traceability.csv',
                 'audit/output-provenance.csv','audit/traceability/bindings.csv']:
        p=root/name
        if p.is_file():
            with p.open(newline='') as handle:
                for number,row in enumerate(csv.reader(handle),1):
                    for value in row:
                        errors.extend(f'{name}: record {number}: reviewer prerequisite: '+problem
                                      for problem in reviewer_prerequisites(value))
    return errors
