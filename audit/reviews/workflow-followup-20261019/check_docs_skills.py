"""Read-only maintenance checks; never launch or qualify the science worker."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'ecosys-audit/scripts'))
import doc_consistency
import autonomy_readiness
from workflow import load

errors=doc_consistency.check(root)
validator=Path('/Users/4sanalyticsnmodelling/.codex/skills/.system/skill-creator/scripts/quick_validate.py')
validated=[]
for skill in sorted((root/'.agents/skills').glob('*/SKILL.md')):
    p=subprocess.run([sys.executable,str(validator),str(skill.parent)],capture_output=True,text=True)
    if p.returncode:errors.append(str(skill)+': '+p.stdout+p.stderr)
    else:validated.append(skill.parent.name)
result={'document_errors':errors,'validated_skills':validated,
        'runtime_readiness_problems':autonomy_readiness.check(root,load(root/'.agent/worker.json')),
        'worker_launched':False,'science_qualified':False}
print(json.dumps(result,indent=2))
raise SystemExit(bool(errors))
