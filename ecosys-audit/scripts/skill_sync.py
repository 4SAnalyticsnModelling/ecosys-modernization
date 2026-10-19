"""Keep canonical skills, copied aliases and discovery index identical."""
import argparse
import json
from pathlib import Path
from workflow import ROOT, atomic


def sync(root=ROOT,apply=False):
    index=[];changes=[]
    for path in sorted((root/'.agents/skills').glob('*/SKILL.md')):
        text=path.read_text();line=next(x for x in text.splitlines() if x.startswith('description: '))
        desc=line[len('description: '):];desc=json.loads(desc) if desc.startswith('"') else desc
        index.append({'name':path.parent.name,'description':desc})
        alias=root/'.claude/skills'/path.parent.name/'SKILL.md'
        if not alias.is_file() or alias.read_text()!=text:
            changes.append(str(alias.relative_to(root)))
            if apply:atomic(alias,text.encode())
    path=root/'ecosys-audit/skill_index.json';text=json.dumps(index,indent=2)+'\n'
    if not path.is_file() or path.read_text()!=text:
        changes.append(str(path.relative_to(root)))
        if apply:atomic(path,text.encode())
    return changes

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--apply',action='store_true');a=p.parse_args()
    changes=sync(apply=a.apply);print(json.dumps({'changed' if a.apply else 'drift':changes}))
    raise SystemExit(0 if a.apply or not changes else 1)
