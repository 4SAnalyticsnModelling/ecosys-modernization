#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Generate a matched-state gfortran oracle for one legacy routine. Python 3.10+.

The contract requires matched-state kernel tests and first-divergence diagnosis. This
builds the legacy half of that: for a chosen routine it emits

  * a standalone Fortran driver that restores the routine's COMMON state from a snapshot
    file, calls the routine once, and writes the post-call state back out, and
  * a JSON layout manifest describing every dumped item (name, effective type, rank,
    extents, element count, byte offset and order) so the Zig side can read and write the
    identical byte stream.

Scoping matters. The full COMMON state for this model is about 258 MB, and a single
routine like UPTAKE has 33 includes covering ~237 MB of it, so dumping everything a
routine *could* see is not a usable default. By default this tool dumps only the COMMON
members the routine's own statements actually reference, and always reports the resulting
size so the scope is a deliberate choice rather than an accident.

This generates the legacy oracle and the interchange format only. It deliberately does
not generate the Zig counterpart: the port is a renamed modular redesign, not a COMMON
mirror, so the legacy-to-Zig field correspondence has to come from the binding register
(see bindcheck.py), not from name matching.

Exit 0 = generated. Exit 2 = bad input or a routine whose state cannot be laid out.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

from f77index import (CODE_END, CODE_START, canonical, logical_statements, read_lines,
                      safe_path, sha256)

RE_IDENTIFIER = re.compile(r'[A-Z][A-Z0-9_]*')
# Intel's -r8/-i4 contract, reproduced under gfortran. Kept beside the generated code so
# a driver can never be compiled with a different precision than it was laid out for.
PRECISION_FLAGS = ('-ffixed-form', '-ffixed-line-length-72', '-fdefault-real-8',
                   '-fdefault-double-8')
# The legacy unit needs a permissive dialect that also hides the Fortran 2023 SPLIT
# intrinsic. For diagnostic safety, -fcheck=bounds catches any out-of-bounds subscripts immediately.
# The driver needs ACCESS='STREAM', which is Fortran 2003 and therefore
# rejected under -std=legacy, so the two are compiled as separate translation units with
# the same precision contract and then linked.
LEGACY_FLAGS = PRECISION_FLAGS + ('-std=legacy', '-fallow-argument-mismatch', '-fcheck=bounds')
DRIVER_FLAGS = PRECISION_FLAGS + ('-fcheck=bounds',)
ORACLE_FLAGS = LEGACY_FLAGS
TYPE_BYTES = {'f64': 8, 'f32': 4, 'i32': 4, 'i64': 8, 'bool32': 4, 'char': 1}
FORTRAN_KEYWORDS = frozenset({
    'IF', 'THEN', 'ELSE', 'ENDIF', 'DO', 'ENDDO', 'CONTINUE', 'GOTO', 'GO', 'TO', 'CALL',
    'RETURN', 'END', 'WRITE', 'READ', 'OPEN', 'CLOSE', 'FORMAT', 'STOP', 'COMMON',
    'DIMENSION', 'DATA', 'REAL', 'INTEGER', 'CHARACTER', 'LOGICAL', 'DOUBLE', 'PRECISION',
    'PARAMETER', 'SAVE', 'EQUIVALENCE', 'EXTERNAL', 'INTRINSIC', 'SUBROUTINE', 'FUNCTION',
    'BLOCKDATA', 'INCLUDE', 'AND', 'OR', 'NOT', 'EQ', 'NE', 'GT', 'GE', 'LT', 'LE',
    'TRUE', 'FALSE', 'AMAX1', 'AMIN1', 'MAX', 'MIN', 'ABS', 'SQRT', 'EXP', 'LOG', 'LOG10',
    'SIN', 'COS', 'TAN', 'ATAN', 'ASIN', 'ACOS', 'INT', 'NINT', 'FLOAT', 'REAL8', 'MOD',
    'SIGN', 'DIM', 'AINT', 'ANINT', 'MAX0', 'MIN0', 'IABS', 'ENTRY', 'ELSEIF',
})


class KernelError(Exception):
    """Refusal to emit a driver that could not faithfully restore state."""


def referenced_identifiers(root: Path, unit: dict) -> set[str]:
    """Uppercased identifiers appearing in the routine's own executable text."""
    lines, _ = read_lines(root / unit['file'])
    names: set[str] = set()
    for statement in logical_statements(lines):
        if not (unit['line_start'] <= statement['line_start'] <= unit['line_end']):
            continue
        for token in RE_IDENTIFIER.findall(canonical(statement['code'])):
            if token not in FORTRAN_KEYWORDS:
                names.add(token)
    return names


def build_layout(index: dict, unit: dict, referenced: set[str] | None) -> list[dict]:
    """Order the dumped items and assign byte offsets.

    Order is the declaration order of the COMMON blocks the routine includes, so the
    layout is reproducible from the source rather than from a dictionary's iteration
    order. Members with symbolic extents that the index could not resolve are refused
    rather than guessed, because a wrong extent silently corrupts every later offset.
    """
    included = {Path(entry['name']).stem.upper() for entry in unit['includes']}
    blocks = [block for block in index['commons']
              if block['name'].upper() in included
              or Path(block['declared_in']).stem.upper() in included]
    if not blocks:
        raise KernelError(
            f'{unit["name"]} includes {sorted(included)} but none of those declare a '
            f'COMMON block in the index. A driver cannot restore state it cannot name.')
    layout: list[dict] = []
    offset = 0
    unresolved: list[str] = []
    for block in blocks:
        for member in block['members']:
            if referenced is not None and member['name'] not in referenced:
                continue
            width = TYPE_BYTES.get(member['effective_type'])
            if width is None:
                unresolved.append(f'{member["name"]} (type {member["effective_type"]})')
                continue
            if member['elements'] is None:
                unresolved.append(f'{member["name"]} (unresolved extents '
                                  f'{[axis["upper"] for axis in member["bounds"]]})')
                continue
            size = width * member['elements']
            layout.append({
                'name': member['name'], 'common_block': block['name'],
                'declared_in': block['declared_in'],
                'effective_type': member['effective_type'],
                'element_bytes': width, 'rank': member['rank'],
                'elements': member['elements'],
                'bounds': [{'lower': axis['lower'], 'upper': axis['upper'],
                            'extent': axis['extent']} for axis in member['bounds']],
                'byte_offset': offset, 'byte_size': size,
            })
            offset += size
    if unresolved:
        raise KernelError(
            'Cannot lay out these members without guessing, which would corrupt every '
            'later byte offset: ' + '; '.join(sorted(unresolved)[:8]) +
            (f' (+{len(unresolved) - 8} more)' if len(unresolved) > 8 else '') +
            '. Resolve their extents in parameters.h or exclude them with --blocks.')
    if not layout:
        raise KernelError(
            f'No COMMON members selected for {unit["name"]}. With --scope referenced, the '
            f'routine referenced none of the members in its included blocks; try '
            f'--scope included.')
    return layout


def emit_fixed(add, text: str) -> None:
    """Append one logical statement, wrapped into legal fixed-form continuation lines.

    Columns 7-72 carry code, so a statement longer than 66 characters must continue with a
    marker in column 6. Wrapping happens only at commas outside quotes: a split inside a
    character literal would silently change the literal, which is exactly how
    ACCESS='STREAM' once became ACCESS='STREAM.
    """
    limit = CODE_END - CODE_START + 1
    pieces: list[str] = []
    depth = 0
    quote = False
    current: list[str] = []
    for char in text:
        current.append(char)
        if char == "'":
            quote = not quote
            continue
        if quote:
            continue
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
        elif char == ',' and depth <= 1:
            pieces.append(''.join(current))
            current = []
    if current:
        pieces.append(''.join(current))

    lines: list[str] = []
    buffer = ''
    for piece in pieces:
        if buffer and len(buffer) + len(piece) > limit:
            lines.append(buffer)
            buffer = piece
        else:
            buffer += piece
    if buffer:
        lines.append(buffer)
    for position, line in enumerate(lines):
        if len(line) > limit:
            raise KernelError(
                f'Cannot wrap this statement within fixed-form columns '
                f'{CODE_START}-{CODE_END} without splitting a literal: {line!r}')
        add((' ' * (CODE_START - 1) if position == 0 else ' ' * (CODE_START - 2) + '2') + line)


# Standard subscript upper bounds from f77src/parameters.h
KNOWN_ARG_BOUNDS = {
    'NX': (1, 'JX'),
    'NY': (1, 'JY'),
    'NZ': (1, 'JP'),
    'NHW': (1, 'JC'),
    'NHE': (1, 'JC'),
    'NVN': (1, 'JC'),
    'NVS': (1, 'JC'),
    'I': (1, 366),
    'J': (1, 24),
    'NFZ': (1, 100),
}


def fortran_driver(unit: dict, layout: list[dict], stream: str) -> str:
    """Emit a fixed-form driver. All state travels through COMMON, not arguments."""
    includes = [entry['name'] for entry in unit['includes']]
    arguments = unit['arguments']
    call = f'CALL {unit["name"]}'
    if arguments:
        call += '(' + ','.join(arguments) + ')'
    lines: list[str] = []
    add = lines.append
    add('C     GENERATED BY ecosys-audit/scripts/kernelgen.py -- DO NOT EDIT BY HAND.')
    add(f'C     Matched-state oracle for {unit["name"]} ({unit["file"]}:'
        f'{unit["line_start"]}-{unit["line_end"]}).')
    add('C     Reads pre-call state, calls the routine once, writes post-call state.')
    add(f'C     Layout: {len(layout)} items, '
        f'{sum(item["byte_size"] for item in layout)} bytes, see the JSON manifest.')
    emit_fixed(add, 'PROGRAM KERNEL')
    for name in includes:
        emit_fixed(add, f'include "{name}"')
    # Fortran requires every declaration before the first executable statement, so all
    # declarations are emitted together here. Dummy arguments are loop and grid indices
    # in this codebase, so they are integers under -i4.
    if arguments:
        emit_fixed(add, f'INTEGER {",".join(arguments)}')
        emit_fixed(add, f'CHARACTER*32 CARG')
        emit_fixed(add, f'INTEGER NARGS, IARG')
    emit_fixed(add, 'INTEGER IOS')
    if arguments:
        # Default all scalar arguments to sentinel -9999 so unsupplied arguments trip bounds check
        for name in arguments:
            emit_fixed(add, f'{name}=-9999')
        # Check command line arguments first via GET_COMMAND_ARGUMENT
        emit_fixed(add, 'NARGS=COMMAND_ARGUMENT_COUNT()')
        emit_fixed(add, f'IF(NARGS.GE.{len(arguments)})THEN')
        for idx, name in enumerate(arguments, start=1):
            emit_fixed(add, f'CALL GET_COMMAND_ARGUMENT({idx},CARG)')
            emit_fixed(add, f'READ(CARG,*,IOSTAT=IOS) {name}')
            emit_fixed(add, 'IF(IOS.NE.0)THEN')
            emit_fixed(add, f"WRITE(*,*)'kernelgen: bad argv integer for {name}',CARG")
            emit_fixed(add, 'STOP 2')
            emit_fixed(add, 'ENDIF')
        emit_fixed(add, 'ELSE')
        # Fallback to .args binary sidecar file if present
        emit_fixed(add, f"OPEN(82,FILE='{stream}.args',FORM='UNFORMATTED',"
                        f"ACCESS='STREAM',STATUS='OLD',IOSTAT=IOS)")
        emit_fixed(add, 'IF(IOS.EQ.0)THEN')
        for name in arguments:
            emit_fixed(add, f'READ(82) {name}')
        emit_fixed(add, 'CLOSE(82)')
        emit_fixed(add, 'ELSE')
        emit_fixed(add, f"WRITE(*,*)'kernelgen: missing required arguments'")
        emit_fixed(add, f"WRITE(*,*)'supply {len(arguments)} args: {','.join(arguments)}'")
        emit_fixed(add, 'STOP 2')
        emit_fixed(add, 'ENDIF')
        emit_fixed(add, 'ENDIF')

        # Bounds checks for all known arguments to prevent silent out-of-bounds indexing
        for name in arguments:
            uname = name.upper()
            if uname in KNOWN_ARG_BOUNDS:
                low, high = KNOWN_ARG_BOUNDS[uname]
                emit_fixed(add, f'IF({name}.LT.{low}.OR.{name}.GT.{high})THEN')
                emit_fixed(add, f"WRITE(*,*)'kernelgen: argument {name} out of bounds [{low},{high}]:',{name}")
                emit_fixed(add, 'STOP 2')
                emit_fixed(add, 'ENDIF')

    emit_fixed(add, f"OPEN(81,FILE='{stream}.in',FORM='UNFORMATTED',"
                    f"ACCESS='STREAM',STATUS='OLD',IOSTAT=IOS)")
    emit_fixed(add, 'IF(IOS.NE.0)THEN')
    emit_fixed(add, "WRITE(*,*)'kernelgen: cannot open input snapshot',IOS")
    emit_fixed(add, 'STOP 2')
    emit_fixed(add, 'ENDIF')
    for item in layout:
        emit_fixed(add, f'READ(81) {item["name"]}')
    emit_fixed(add, 'CLOSE(81)')
    emit_fixed(add, call)
    emit_fixed(add, f"OPEN(83,FILE='{stream}.out',FORM='UNFORMATTED',"
                    f"ACCESS='STREAM',STATUS='REPLACE',IOSTAT=IOS)")
    emit_fixed(add, 'IF(IOS.NE.0)THEN')
    emit_fixed(add, "WRITE(*,*)'kernelgen: cannot open output snapshot',IOS")
    emit_fixed(add, 'STOP 2')
    emit_fixed(add, 'ENDIF')
    for item in layout:
        emit_fixed(add, f'WRITE(83) {item["name"]}')
    emit_fixed(add, 'CLOSE(83)')
    emit_fixed(add, "WRITE(*,*)'kernelgen: ok'")
    emit_fixed(add, 'END')
    return '\n'.join(lines) + '\n'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('routine', help='Unit name (UPTAKE) or file name (uptake.f)')
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--index', type=Path, default=None)
    parser.add_argument('--outdir', default='audit/tests/kernels',
                        help='Project-relative directory for generated artifacts')
    parser.add_argument('--scope', choices=('referenced', 'included'), default='referenced',
                        help='referenced (default): only members the routine mentions. '
                             'included: every member of every included COMMON block.')
    parser.add_argument('--blocks', help='Comma list of COMMON blocks to restrict to')
    parser.add_argument('--force', action='store_true',
                        help='Overwrite generated artifacts for this routine')
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        index_path = args.index or (root / 'audit' / 'manifest' / 'f77index.json')
        if not index_path.is_file():
            raise KernelError(f'No index at {index_path}. Run f77index.py first.')
        index = json.loads(index_path.read_text(encoding='utf-8'))
        if index.get('schema_version') != 1:
            raise KernelError('Index schema is not version 1; rebuild it.')

        wanted = args.routine.lower()
        candidates = [unit for unit in index['units']
                      if unit['kind'] != 'include-fragment'
                      and (unit['name'].lower() == wanted
                           or Path(unit['file']).name.lower() == wanted
                           or Path(unit['file']).stem.lower() == wanted)]
        in_build = {entry['path'] for entry in index['files'] if entry['in_build']}
        preferred = [unit for unit in candidates if unit['file'] in in_build]
        if not candidates:
            raise KernelError(f'No routine matches {args.routine!r}.')
        if len(preferred) > 1:
            raise KernelError(f'{args.routine!r} is ambiguous across '
                              f'{[unit["file"] for unit in preferred]}; name the file.')
        unit = (preferred or candidates)[0]
        if unit['file'] not in in_build:
            raise KernelError(f'{unit["file"]} is not in the makefile SRCS list, so it is '
                              f'not the legacy reference. Refusing to build an oracle '
                              f'from it.')

        referenced = referenced_identifiers(root, unit) if args.scope == 'referenced' else None
        layout = build_layout(index, unit, referenced)
        if args.blocks:
            keep = {name.strip().upper() for name in args.blocks.split(',')}
            layout = [item for item in layout if item['common_block'].upper() in keep]
            if not layout:
                raise KernelError(f'No members left after --blocks {sorted(keep)}.')
            offset = 0
            for item in layout:
                item['byte_offset'] = offset
                offset += item['byte_size']

        total = sum(item['byte_size'] for item in layout)
        outdir = safe_path(root, args.outdir)
        outdir.mkdir(parents=True, exist_ok=True)
        stem = f'kernel_{unit["name"].lower()}'
        driver_path = outdir / f'{stem}.f'
        manifest_path = outdir / f'{stem}.layout.json'
        build_path = outdir / f'{stem}.build.ps1'
        for path in (driver_path, manifest_path, build_path):
            if path.exists() and not args.force:
                raise KernelError(f'{path} exists; pass --force to regenerate.')

        driver_path.write_text(fortran_driver(unit, layout, stem), encoding='ascii')
        manifest = {
            'schema_version': 1,
            'created_utc': datetime.now(timezone.utc).isoformat(),
            'routine': unit['name'],
            'source': f'{unit["file"]}:{unit["line_start"]}-{unit["line_end"]}',
            'source_sha256': next(entry['sha256'] for entry in index['files']
                                  if entry['path'] == unit['file']),
            'arguments': unit['arguments'],
            'includes': [entry['name'] for entry in unit['includes']],
            'scope': args.scope,
            'blocks_restricted_to': sorted({item['common_block'] for item in layout}),
            'stream': {
                'format': 'Fortran unformatted stream access, one record per item, in '
                          'the order given below. Element order is Fortran column-major.',
                'endianness': 'native (little-endian on this x86_64 host)',
                'total_bytes': total,
                'items': len(layout),
            },
            'build': {
                'compiler': 'gfortran',
                'driver_flags': list(DRIVER_FLAGS),
                'legacy_flags': list(LEGACY_FLAGS),
                'include_path': 'f77src',
                'note': "The driver and the legacy unit are separate translation units: "
                        "the driver needs ACCESS='STREAM' (Fortran 2003, rejected by "
                        "-std=legacy) and the legacy unit needs -std=legacy. Both carry "
                        "the same -fdefault-real-8 precision contract. "
                        + index['dialect']['gfortran_oracle']['note'],
            },
            'layout': layout,
            'limitations': 'Restoring and dumping COMMON state proves state-in/state-out '
                           'equivalence for the members listed here only. Members outside '
                           'this scope are left at whatever the driver initialised, so a '
                           'routine that reads them will not be exercised faithfully. '
                           'This is the legacy oracle only; the Zig counterpart needs the '
                           'binding register, not name matching.',
        }
        with manifest_path.open('w', encoding='utf-8') as handle:
            json.dump(manifest, handle, indent=2, allow_nan=False)
            handle.write('\n')

        calls_split = 'SPLIT' in [call['callee'] for call in unit['calls']]
        build_script = f'''# GENERATED BY ecosys-audit/scripts/kernelgen.py -- DO NOT EDIT BY HAND.
# Builds the matched-state oracle for {unit["name"]}. Run from the project root.
# The driver and the legacy unit are compiled separately on purpose: the driver needs
# ACCESS='STREAM' (Fortran 2003) and the legacy unit needs -std=legacy. Both use the
# same -fdefault-real-8/-fdefault-double-8 precision contract recorded in the manifest.
$ErrorActionPreference = 'Stop'
$out = if ($args.Count -ge 1) {{ $args[0] }} else {{ Join-Path $PWD 'audit/tests/kernels/build' }}
New-Item -ItemType Directory -Path $out -Force | Out-Null
{'# NOTE: this unit calls SPLIT, which gfortran 16 resolves to the Fortran 2023 intrinsic.' if calls_split else ''}
{'# Declare `EXTERNAL split` after the unit header, or compile it with -std=f95 instead.' if calls_split else ''}
& gfortran -c {' '.join(DRIVER_FLAGS)} -I f77src `
  -o (Join-Path $out '{stem}.o') '{driver_path.relative_to(root).as_posix()}'
if ($LASTEXITCODE -ne 0) {{ throw "driver compile failed" }}
& gfortran -c {' '.join(LEGACY_FLAGS)} -I f77src `
  -o (Join-Path $out '{unit["name"].lower()}.o') '{unit["file"]}'
if ($LASTEXITCODE -ne 0) {{ throw "legacy unit compile failed" }}
& gfortran -o (Join-Path $out '{stem}.exe') `
  (Join-Path $out '{stem}.o') (Join-Path $out '{unit["name"].lower()}.o')
if ($LASTEXITCODE -ne 0) {{ throw "link failed" }}
Write-Output "built $(Join-Path $out '{stem}.exe')"
Write-Output "run it in a directory holding {stem}.in ({total} bytes); it writes {stem}.out"
'''
        build_path.write_text(build_script, encoding='utf-8')

        print(f'=== matched-state oracle for {unit["name"]} ===')
        print(f'  source          : {manifest["source"]}')
        print(f'  scope           : {args.scope}')
        print(f'  includes        : {len(unit["includes"])}')
        print(f'  COMMON blocks   : {len(manifest["blocks_restricted_to"])}')
        print(f'  items dumped    : {len(layout)}')
        print(f'  snapshot size   : {total / 1024 / 1024:.2f} MB per side '
              f'({total} bytes)')
        print(f'  driver          : {driver_path.relative_to(root).as_posix()}')
        print(f'  layout manifest : {manifest_path.relative_to(root).as_posix()}')
        print(f'  build script    : {build_path.relative_to(root).as_posix()}')
        print(f'  build with      : pwsh -File '
              f'{build_path.relative_to(root).as_posix()}')
        if calls_split:
            print('    NOTE: this unit calls SPLIT, which gfortran 16 resolves to the '
                  'Fortran 2023 intrinsic. Add `EXTERNAL split` after the unit header '
                  'or compile that unit with -std=f95.')
        return 0
    except (OSError, KernelError, json.JSONDecodeError) as exc:
        print(f'Kernel generation stopped: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
