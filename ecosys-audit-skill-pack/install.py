#!/usr/bin/env python3
"""Install portable ecosys skills without changing model source. Python 3.10+."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import sys

ROOTS = ('f77src', 'f77example', 'ecosys-ng', 'ecosys-ng-prod-examples')
BEGIN = '<!-- ecosys-audit-skill-pack:begin -->'
END = '<!-- ecosys-audit-skill-pack:end -->'
BLOCK = f'''{BEGIN}
## ecosys Fortran-to-Zig audit
For this project, read `ecosys-audit/PROJECT_CONTRACT.md` and
`ecosys-audit/EVIDENCE_GUIDE.md` before source changes or scientific claims.
Start or resume with the `ecosys-release-orchestrator` skill.
Canonical portable skills are in `.agents/skills/`; shared resources are in
`ecosys-audit/`. Preserve the four authoritative directories in the contract.
Run focused tests during source audit; do not enter repetitive full production
ReleaseFast runs before the evidence gates pass. Preserve references and user
changes. Skills are instructions, not proof that this model has been audited.
{END}
'''

class InstallError(ValueError):
    pass

def safe_destination(root: Path, destination: Path, allow_leaf_symlink: bool = False) -> None:
    """Reject redirection through existing symlinks, including in parent folders."""
    relative = destination.relative_to(root)
    node = root
    for index, part in enumerate(relative.parts):
        node = node / part
        is_leaf = index == len(relative.parts) - 1
        if node.is_symlink() and not (is_leaf and allow_leaf_symlink):
            raise InstallError(f'Refusing symlinked destination: {node}')
        if not is_leaf and node.exists() and not node.is_dir():
            raise InstallError(f'Destination parent is not a directory: {node}')

def instruction_content(destination: Path) -> bytes | None:
    original = destination.read_bytes() if destination.exists() else b''
    try:
        text = original.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise InstallError(f'Instruction file is not UTF-8; merge manually: {destination}') from exc
    if BEGIN in text or END in text:
        if text.count(BEGIN) != 1 or text.count(END) != 1:
            raise InstallError(f'Malformed/duplicate managed block in {destination}')
        start = text.index(BEGIN)
        end = text.index(END) + len(END)
        if text[start:end] != BLOCK.rstrip('\n'):
            raise InstallError(f'Existing managed block differs; review manually: {destination}')
        return None
    separator = b'' if not original else (b'\n' if original.endswith(b'\n') else b'\n\n')
    return original + separator + BLOCK.encode('utf-8')

def install(root: Path, package: Path, *, apply: bool, mode: str,
            pi_legacy_alias: bool = False) -> list[str]:
    root = root.expanduser().resolve(strict=True)
    package = package.resolve(strict=True)
    if not root.is_dir():
        raise InstallError(f'Not a project directory: {root}')
    for name in ROOTS:
        if not (root / name).is_dir():
            raise InstallError(f'Missing authoritative directory: {root / name}')
    if root == package or package.is_relative_to(root / '.agents'):
        raise InstallError('Extract the distribution outside its installation destinations.')
    if mode == 'auto':
        mode = 'copy' if os.name == 'nt' else 'link'
    operations: list[tuple[str, Path, object]] = []
    messages: list[str] = []

    def add_file(source: Path, destination: Path) -> None:
        safe_destination(root, destination)
        data = source.read_bytes()
        if destination.exists():
            if not destination.is_file() or destination.read_bytes() != data:
                raise InstallError(f'Existing file differs; nothing overwritten: {destination}')
            return
        operations.append(('file', destination, data))

    for folder in ('.agents/skills', 'ecosys-audit'):
        base = package / folder
        if not base.is_dir():
            raise InstallError(f'Distribution is incomplete: {base}')
        for source in sorted(base.rglob('*')):
            if '__pycache__' in source.parts or source.suffix == '.pyc':
                continue
            if source.is_symlink():
                raise InstallError(f'Unexpected symlink in distribution: {source}')
            if source.is_file():
                add_file(source, root / source.relative_to(package))

    alias_roots = [Path('.claude/skills')]
    if pi_legacy_alias:
        alias_roots.append(Path('.pi/skills'))
        messages.append('Legacy Pi alias enabled; do not enable this for Pi versions already discovering .agents/skills.')
    for skill_dir in sorted((package / '.agents/skills').iterdir()):
        if not (skill_dir / 'SKILL.md').is_file():
            continue
        canonical = root / '.agents/skills' / skill_dir.name
        for alias_root in alias_roots:
            destination = root / alias_root / skill_dir.name
            safe_destination(root, destination, allow_leaf_symlink=True)
            if destination.is_symlink():
                if destination.resolve() == canonical.resolve():
                    continue
                raise InstallError(f'Alias already points elsewhere: {destination}')
            if mode == 'link':
                if destination.exists():
                    # An identical copy is a valid non-destructive alias. Do not replace it.
                    for source in skill_dir.rglob('*'):
                        if source.is_file():
                            add_file(source, destination / source.relative_to(skill_dir))
                    messages.append(f'Preserved existing copy: {destination.relative_to(root)}')
                    continue
                target = os.path.relpath(canonical, destination.parent)
                operations.append(('link', destination, target))
            else:
                for source in sorted(skill_dir.rglob('*')):
                    if source.is_file():
                        add_file(source, destination / source.relative_to(skill_dir))
    for name in ('AGENTS.md', 'CLAUDE.md'):
        destination = root / name
        safe_destination(root, destination)
        if destination.exists() and not destination.is_file():
            raise InstallError(f'Instruction destination is not a file: {destination}')
        data = instruction_content(destination)
        if data is not None:
            operations.append(('instructions', destination, data))

    # All conflicts were checked before any writes. Run with harnesses stopped so
    # user files cannot change between this check and the explicit installation.
    messages.insert(0, f'{"APPLY" if apply else "DRY RUN"}: {len(operations)} additions/managed appends; alias mode={mode}')
    for kind, destination, payload in operations:
        messages.append(f'{kind:12s} {destination.relative_to(root)}')
        if not apply:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        if kind == 'link':
            destination.symlink_to(str(payload), target_is_directory=True)
        elif kind == 'instructions':
            # Preserve existing bytes; write only the preflighted append. A backup
            # is not needed because this never rewrites the existing prefix.
            old = destination.read_bytes() if destination.exists() else b''
            new = bytes(payload)
            if not new.startswith(old):
                raise InstallError(f'Instruction file changed during install: {destination}')
            if destination.exists():
                with destination.open('ab') as handle:
                    handle.write(new[len(old):])
            else:
                with destination.open('xb') as handle:
                    handle.write(new)
        else:
            with destination.open('xb') as handle:
                handle.write(bytes(payload))
    return messages

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path, help='Existing ecosys_modernization directory')
    parser.add_argument('--apply', action='store_true', help='Apply the preflighted installation; default is dry run')
    parser.add_argument('--mode', choices=['auto','link','copy'], default='auto',
                        help='auto: symlinks on POSIX, copies on Windows; copies need no admin rights')
    parser.add_argument('--pi-legacy-alias', action='store_true',
                        help='Only for a verified older Pi that does not discover .agents/skills')
    args = parser.parse_args()
    try:
        for message in install(args.root, Path(__file__).parent, apply=args.apply,
                               mode=args.mode, pi_legacy_alias=args.pi_legacy_alias):
            print(message)
        print('Model source/reference/deck files were not edited. Restart harnesses after applying.')
        return 0
    except (OSError, ValueError) as exc:
        print(f'Installation stopped: {exc}', file=sys.stderr)
        return 2

if __name__ == '__main__':
    raise SystemExit(main())
