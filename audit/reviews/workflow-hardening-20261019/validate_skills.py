import subprocess,sys
from pathlib import Path
validator=Path('/Users/4sanalyticsnmodelling/.codex/skills/.system/skill-creator/scripts/quick_validate.py')
for skill in sorted(Path('.agents/skills').glob('*/SKILL.md')):
    subprocess.run([sys.executable,'-B',str(validator),str(skill.parent)],check=True)
print('Validated 17 canonical skills')
