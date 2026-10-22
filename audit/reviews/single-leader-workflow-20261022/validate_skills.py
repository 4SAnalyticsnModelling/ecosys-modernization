"""Validate canonical and copied skill metadata using the skill-creator validator."""
import importlib.util
import json
from pathlib import Path

root=Path(__file__).resolve().parents[3]
validator=Path.home()/'.codex/skills/.system/skill-creator/scripts/quick_validate.py'
spec=importlib.util.spec_from_file_location('skill_validator',validator)
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
results=[]
for base in ['.agents/skills','.claude/skills']:
    for skill in sorted((root/base).glob('*/SKILL.md')):
        valid,message=module.validate_skill(skill.parent)
        results.append({'skill':str(skill.parent.relative_to(root)),'valid':valid,'message':message})
print(json.dumps({'count':len(results),'results':results},indent=2))
raise SystemExit(any(not result['valid'] for result in results))
