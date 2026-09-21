#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Compute traceability coverage from evidence instead of asserting it. Python 3.10+.

Joins audit/traceability/traceability.csv against the f77index to answer, for the legacy
scope the makefile actually builds: which executable statements have a recorded Zig
counterpart, which do not, whether each row's recorded source hash still matches the
file it cites, and how the dispositions tally. Reuses f77index.py's parser so the
statement boundaries here and in the index can never drift apart.

Exit 0 = report produced. Exit 1 = a gate-blocking condition (stale evidence, unresolved
disposition, or a row citing a file/line range that does not exist). Exit 2 = invalid
input. Producing a report is not a gate decision; check_gate.py owns that.
"""
from __future__ import annotations
import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

from f77index import (canonical, expand_tabs, logical_statements, read_lines, safe_path,
                      sha256, statement_keyword)

RE_RANGE = re.compile(r'^(\d+)\s*-\s*(\d+)$')
RE_SINGLE = re.compile(r'^(\d+)$')
RE_FILE_PREFIX = re.compile(r'^([A-Za-z0-9_.-]+\.(?:f|h))\s*:\s*(.*)$')
RE_ANNOTATION = re.compile(r'\([^)]*\)')
RE_WHOLE_FILE = re.compile(r'\bwhole\s+file\b', re.IGNORECASE)
ABSENT = ('n/a', 'na', 'none', '', '-')
BLOCKING_DISPOSITIONS = ('unresolved',)


class CoverageError(Exception):
    """Refusal to report a coverage number that would mislead."""


def split_paths(cell: str) -> tuple[list[str], list[str]]:
    """Split a ';'-separated path cell, letting bare names inherit the previous directory.

    The CSV writes `ecosys-ng/src/stages/hourly_process_driver.zig;
    hourly_heat_water_solute.zig`, so the second segment means the same directory as the
    first. Returns (usable paths, unusable segments).
    """
    paths: list[str] = []
    bad: list[str] = []
    directory = ''
    for piece in cell.split(';'):
        piece = piece.strip().replace('\\', '/')
        if not piece or piece.lower() in ABSENT:
            continue
        if '...' in piece:
            bad.append(piece)
            continue
        if '/' in piece:
            directory = piece.rsplit('/', 1)[0]
        elif directory:
            piece = f'{directory}/{piece}'
        paths.append(piece)
    return paths, bad


def parse_line_spec(value: str, default_path: str) -> dict:
    """Parse the fortran_lines cell into concrete (path, low, high) ranges.

    Handles every shape present in the CSV: plain `1636-1712`; multi-range
    `33-285;484-564`; file-qualified `13054-13173;extract.f:949-951`, where later bare
    ranges inherit the most recently named file; `whole file (orchestration only)`; and
    trailing parenthetical annotations, which are stripped rather than treated as errors.
    """
    text = (value or '').strip()
    result: dict = {'ranges': [], 'whole_file': [], 'bad': [], 'annotated': False,
                    'absent': False}
    if text.lower() in ABSENT:
        result['absent'] = True
        return result
    if RE_ANNOTATION.search(text):
        result['annotated'] = True
    whole = bool(RE_WHOLE_FILE.search(text))
    text = RE_ANNOTATION.sub(' ', text)
    current = default_path
    if whole:
        result['whole_file'].append(current)
        # `whole file` carries no ranges; any residue is annotation prose.
        return result
    for piece in text.split(';'):
        piece = piece.strip()
        if not piece:
            continue
        match = RE_FILE_PREFIX.match(piece)
        if match:
            current = f'f77src/{match.group(1)}'
            piece = match.group(2).strip()
            if not piece:
                continue
        for part in piece.split(','):
            part = part.strip()
            if not part:
                continue
            range_match = RE_RANGE.match(part)
            if range_match:
                low, high = int(range_match.group(1)), int(range_match.group(2))
                if low > high:
                    result['bad'].append(part)
                else:
                    result['ranges'].append((current, low, high))
                continue
            single = RE_SINGLE.match(part)
            if single:
                result['ranges'].append((current, int(single.group(1)), int(single.group(1))))
                continue
            result['bad'].append(part)
    return result


def executable_lines(root: Path, relative: str) -> set[int]:
    """Start lines of every executable statement in a file, per the index's own rules."""
    lines, _ = read_lines(root / relative)
    result: set[int] = set()
    for statement in logical_statements(lines):
        code = canonical(statement['code'])
        if code and not statement_keyword(code):
            result.add(statement['line_start'])
    return result


def gap_ranges(uncovered: set[int]) -> list[tuple[int, int]]:
    """Collapse uncovered statement lines into contiguous blocks, largest first."""
    blocks: list[tuple[int, int]] = []
    for line in sorted(uncovered):
        if blocks and line - blocks[-1][1] <= 1:
            blocks[-1] = (blocks[-1][0], line)
        else:
            blocks.append((line, line))
    return blocks


def collect(root: Path, index: dict, csv_path: Path, top_gaps: int) -> dict:
    by_path = {entry['path']: entry for entry in index['files']}
    in_build = {path for path, entry in by_path.items()
                if entry['in_build'] and path.endswith('.f')}
    if not in_build:
        raise CoverageError('Index records no in-build Fortran files.')

    with csv_path.open(encoding='utf-8-sig', newline='') as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise CoverageError(f'{csv_path} has no rows; coverage would be vacuous.')
    required = {'unit_id', 'fortran_path', 'fortran_lines', 'fortran_sha256', 'zig_path',
                'zig_sha256', 'disposition'}
    missing = required - set(rows[0])
    if missing:
        raise CoverageError(f'{csv_path} is missing columns: {", ".join(sorted(missing))}')

    covered: dict[str, set[int]] = {path: set() for path in in_build}
    problems: list[dict] = []
    dispositions: dict[str, int] = {}
    unscoped: dict[str, int] = {}
    annotated_rows: list[str] = []
    whole_file_out_of_scope: list[dict] = []

    for row in rows:
        unit_id = (row.get('unit_id') or '?').strip()
        disposition = (row.get('disposition') or '').strip() or '<blank>'
        dispositions[disposition] = dispositions.get(disposition, 0) + 1

        fortran_paths, bad_fortran = split_paths(row.get('fortran_path') or '')
        for piece in bad_fortran:
            problems.append({'unit_id': unit_id, 'kind': 'unusable-fortran-path',
                             'detail': piece})
        default_path = fortran_paths[0] if fortran_paths else ''
        spec = parse_line_spec(row.get('fortran_lines', ''), default_path)
        for piece in spec['bad']:
            problems.append({'unit_id': unit_id, 'kind': 'unparseable-fortran-lines',
                             'detail': piece})
        if spec['annotated']:
            annotated_rows.append(unit_id)

        recorded = (row.get('fortran_sha256') or '').strip().lower()
        if recorded in ABSENT:
            recorded = ''
        for path in fortran_paths:
            if path not in by_path:
                problems.append({'unit_id': unit_id, 'kind': 'unknown-fortran-path',
                                 'detail': path})
                continue
            actual = by_path[path]['sha256'].lower()
            # A single hash cell cannot speak for several files; only check the 1:1 case.
            if recorded and len(fortran_paths) == 1 and recorded != actual:
                problems.append({'unit_id': unit_id, 'kind': 'stale-fortran-sha256',
                                 'detail': f'{path}: row cites {recorded[:12]}..., '
                                           f'file is {actual[:12]}...'})
            if path not in in_build:
                unscoped[path] = unscoped.get(path, 0) + 1

        for path in spec['whole_file']:
            if path in covered:
                covered[path].update(range(1, by_path[path]['physical_lines'] + 1))
            elif path:
                whole_file_out_of_scope.append({'unit_id': unit_id, 'path': path})

        for path, low, high in spec['ranges']:
            if path not in by_path:
                problems.append({'unit_id': unit_id, 'kind': 'unknown-fortran-path',
                                 'detail': f'{path} (from fortran_lines)'})
                continue
            limit = by_path[path]['physical_lines']
            if low > limit:
                problems.append({'unit_id': unit_id, 'kind': 'fortran-range-past-eof',
                                 'detail': f'{path}:{low}-{high} but file has {limit} lines'})
                continue
            if path in covered:
                covered[path].update(range(low, min(high, limit) + 1))

        zig_paths, bad_zig = split_paths(row.get('zig_path') or '')
        for piece in bad_zig:
            problems.append({'unit_id': unit_id, 'kind': 'unusable-zig-path',
                             'detail': piece})
        zig_hashes = [piece.strip().lower() for piece in (row.get('zig_sha256') or '').split(';')
                      if piece.strip() and piece.strip().lower() not in ABSENT]
        paired = len(zig_hashes) == len(zig_paths)
        if zig_hashes and not paired:
            problems.append({'unit_id': unit_id, 'kind': 'zig-path-hash-count-mismatch',
                             'detail': f'{len(zig_paths)} paths vs {len(zig_hashes)} hashes; '
                                       f'cannot attribute hashes to files'})
        for position, zig_path in enumerate(zig_paths):
            target = root / zig_path
            if not target.is_file():
                problems.append({'unit_id': unit_id, 'kind': 'missing-zig-path',
                                 'detail': zig_path})
                continue
            if paired and zig_hashes[position] != sha256(target).lower():
                problems.append({'unit_id': unit_id, 'kind': 'stale-zig-sha256',
                                 'detail': f'{zig_path}: row cites '
                                           f'{zig_hashes[position][:12]}..., file is '
                                           f'{sha256(target).lower()[:12]}...'})

    per_file: list[dict] = []
    total_exec = 0
    total_covered = 0
    all_gaps: list[dict] = []
    for path in sorted(in_build):
        statements = executable_lines(root, path)
        hit = statements & covered[path]
        total_exec += len(statements)
        total_covered += len(hit)
        uncovered = statements - hit
        blocks = gap_ranges(uncovered)
        per_file.append({
            'path': path,
            'executable_statements': len(statements),
            'covered': len(hit),
            'uncovered': len(uncovered),
            'coverage_fraction': round(len(hit) / len(statements), 6) if statements else None,
            'largest_gap': (f'{blocks[0][0]}-{blocks[0][1]}'
                            if blocks else None) if blocks else None,
        })
        for low, high in blocks:
            all_gaps.append({'path': path, 'lines': f'{low}-{high}',
                             'statements': sum(1 for line in statements if low <= line <= high)})

    all_gaps.sort(key=lambda gap: -gap['statements'])
    blocking = sum(count for name, count in dispositions.items()
                   if name in BLOCKING_DISPOSITIONS)

    return {
        'schema_version': 1,
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'index_created_utc': index['created_utc'],
        'traceability_csv': {'path': csv_path.name, 'rows': len(rows),
                             'sha256': sha256(csv_path)},
        'scope': {
            'basis': 'Executable statements in files listed in f77src/makefile SRCS. '
                     'Out-of-build files (for example redist_utf8.f) are excluded from '
                     'both numerator and denominator.',
            'in_build_files': len(in_build),
            'excluded_out_of_build': sorted(
                path for path, entry in by_path.items()
                if path.endswith('.f') and not entry['in_build']),
        },
        'coverage': {
            'executable_statements': total_exec,
            'covered': total_covered,
            'uncovered': total_exec - total_covered,
            'fraction': round(total_covered / total_exec, 6) if total_exec else None,
        },
        'dispositions': dict(sorted(dispositions.items())),
        'blocking_disposition_rows': blocking,
        'rows_citing_out_of_scope_files': dict(sorted(unscoped.items())),
        'rows_with_stripped_annotations': annotated_rows,
        'whole_file_claims_out_of_scope': whole_file_out_of_scope,
        'problems': problems,
        'per_file': per_file,
        'largest_gaps': all_gaps[:top_gaps],
        'limitations': 'Line-range coverage only. A covered statement means a row claims a '
                       'Zig counterpart for those lines; it does not mean the counterpart '
                       'is correct, tested, or scientifically justified. Statement counts '
                       'come from static parsing, not from the compiler.',
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--index', type=Path, default=None,
                        help='Defaults to <root>/audit/manifest/f77index.json')
    parser.add_argument('--csv', type=Path, default=None,
                        help='Defaults to <root>/audit/traceability/traceability.csv')
    parser.add_argument('--out', help='Optional new project-relative JSON path for evidence')
    parser.add_argument('--top-gaps', type=int, default=20)
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        index_path = args.index or (root / 'audit' / 'manifest' / 'f77index.json')
        csv_path = args.csv or (root / 'audit' / 'traceability' / 'traceability.csv')
        if not index_path.is_file():
            raise CoverageError(f'No index at {index_path}. Run f77index.py first.')
        if not csv_path.is_file():
            raise CoverageError(f'No traceability CSV at {csv_path}.')
        index = json.loads(index_path.read_text(encoding='utf-8'))
        if index.get('schema_version') != 1:
            raise CoverageError('Index schema is not version 1; rebuild it.')

        report = collect(root, index, csv_path, args.top_gaps)

        if args.out:
            out = safe_path(root, args.out)
            if out.exists():
                raise CoverageError(f'Output exists; use a new path: {out}')
            out.parent.mkdir(parents=True, exist_ok=True)
            with out.open('x', encoding='utf-8') as handle:
                json.dump(report, handle, indent=2, allow_nan=False)
                handle.write('\n')

        coverage = report['coverage']
        print(f'=== traceability coverage (in-build legacy scope) ===')
        print(f'  executable statements : {coverage["executable_statements"]}')
        print(f'  covered by a row      : {coverage["covered"]}')
        print(f'  uncovered             : {coverage["uncovered"]}')
        percent = f'{coverage["fraction"] * 100:.2f}%' if coverage['fraction'] is not None else 'n/a'
        print(f'  coverage              : {percent}')
        print(f'  traceability rows     : {report["traceability_csv"]["rows"]}')
        print(f'=== dispositions ===')
        for name, count in report['dispositions'].items():
            flag = '   <-- blocks its gate' if name in BLOCKING_DISPOSITIONS else ''
            print(f'  {name:<34} {count}{flag}')
        if report['problems']:
            kinds: dict[str, int] = {}
            for problem in report['problems']:
                kinds[problem['kind']] = kinds.get(problem['kind'], 0) + 1
            print(f'=== problems ({len(report["problems"])}) ===')
            for kind, count in sorted(kinds.items()):
                print(f'  {kind:<34} {count}')
            for problem in report['problems'][:10]:
                print(f'    {problem["unit_id"]}: {problem["kind"]}: {problem["detail"]}')
            if len(report['problems']) > 10:
                print(f'    ... {len(report["problems"]) - 10} more (see --out JSON)')
        print(f'=== largest uncovered blocks ===')
        for gap in report['largest_gaps'][:args.top_gaps]:
            print(f'  {gap["statements"]:>6} statements  {gap["path"]}:{gap["lines"]}')
        if args.out:
            print(f'evidence written to {args.out}')

        return 1 if (report['problems'] or report['blocking_disposition_rows']) else 0
    except (OSError, CoverageError, csv.Error, json.JSONDecodeError) as exc:
        print(f'Coverage stopped: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
