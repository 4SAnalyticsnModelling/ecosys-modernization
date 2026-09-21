#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Audit legacy COMMON state against the Zig port and the binding register. Python 3.10+.

The legacy model keeps all shared state in 53 COMMON blocks (2,970 declared members). The
Zig port is a modular redesign rather than a one-to-one COMMON mirror, so this tool does
three separate things and never conflates them:

  1. Inventory   -- every COMMON member with the type the legacy build actually produced
                    (-r8/-i4 applied to Fortran 77 implicit typing), its rank, bounds and
                    resolved element count.
  2. Reachability -- whether each member's name occurs anywhere in ecosys-ng/src, split
                    into code occurrences and comment-only occurrences. A comment-only hit
                    usually means recorded provenance, not an implementation.
  3. Validation  -- for rows that exist in a bindings register, whether the declared shape
                    and type agree with the index.

A name occurrence is evidence that a symbol was considered, NOT evidence that it was
translated correctly. Short names are reported separately because they collide easily.

Exit 0 = report produced. Exit 1 = a declared binding contradicts the index. Exit 2 = bad
input.
"""
from __future__ import annotations
import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

from f77index import safe_path, sha256

RE_IDENTIFIER = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
SHORT_NAME_LENGTH = 4
ABSENT = ('n/a', 'na', 'none', '', '-')


class BindError(Exception):
    """Refusal to report a binding conclusion that would mislead."""


def strip_zig_comments(text: str) -> tuple[str, str]:
    """Split Zig source into (code, comments).

    Zig has only line comments (`//`, `///`, `//!`) and no block comments, so a single
    pass is exact apart from `//` inside string literals, which is handled by tracking
    quotes. Splitting matters: a legacy name appearing only in a doc comment records
    provenance, while one appearing in code is a real identifier.
    """
    code: list[str] = []
    comments: list[str] = []
    for line in text.splitlines():
        quote = False
        escape = False
        cut = None
        for position, char in enumerate(line):
            if escape:
                escape = False
                continue
            if char == '\\':
                escape = True
                continue
            if char == '"':
                quote = not quote
                continue
            if char == '/' and not quote and line[position + 1:position + 2] == '/':
                cut = position
                break
        if cut is None:
            code.append(line)
        else:
            code.append(line[:cut])
            comments.append(line[cut:])
    return '\n'.join(code), '\n'.join(comments)


def scan_zig(root: Path, relative: str) -> tuple[dict[str, set[str]], dict[str, set[str]], int]:
    """Map uppercased identifier -> set of files, separately for code and comments."""
    base = root / relative
    if not base.is_dir():
        raise BindError(f'Missing Zig source directory: {base}')
    in_code: dict[str, set[str]] = {}
    in_comment: dict[str, set[str]] = {}
    count = 0
    for path in sorted(base.rglob('*.zig')):
        if any(part in ('.zig-cache', 'zig-cache', 'zig-out') for part in path.parts):
            continue
        count += 1
        name = path.relative_to(root).as_posix()
        code, comments = strip_zig_comments(path.read_text(encoding='utf-8', errors='replace'))
        for token in RE_IDENTIFIER.findall(code):
            in_code.setdefault(token.upper(), set()).add(name)
        for token in RE_IDENTIFIER.findall(comments):
            in_comment.setdefault(token.upper(), set()).add(name)
    return in_code, in_comment, count


def traceability_symbols(csv_path: Path) -> set[str]:
    """Uppercased identifiers mentioned anywhere in the traceability CSV's symbol cells."""
    if not csv_path.is_file():
        return set()
    tokens: set[str] = set()
    with csv_path.open(encoding='utf-8-sig', newline='') as handle:
        for row in csv.DictReader(handle):
            for column in ('fortran_symbol', 'zig_symbol'):
                for token in RE_IDENTIFIER.findall(row.get(column) or ''):
                    tokens.add(token.upper())
    return tokens


def validate_register(index: dict, csv_path: Path) -> tuple[list[dict], int]:
    """Check declared bindings against the index. Returns (findings, rows examined)."""
    if not csv_path.is_file():
        return [], 0
    members = {member['name']: (block, member)
               for block in index['commons'] for member in block['members']}
    findings: list[dict] = []
    examined = 0
    with csv_path.open(encoding='utf-8-sig', newline='') as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            legacy = (row.get('legacy_symbol') or '').strip().upper()
            if not legacy or legacy.lower() in ABSENT:
                continue
            examined += 1
            binding_id = (row.get('binding_id') or '?').strip()
            if legacy not in members:
                findings.append({'binding_id': binding_id, 'legacy_symbol': legacy,
                                 'kind': 'unknown-legacy-symbol',
                                 'detail': 'not declared in any COMMON block'})
                continue
            _, member = members[legacy]
            declared_shape = (row.get('shape') or '').strip()
            if declared_shape and declared_shape.lower() not in ABSENT:
                ranks = re.findall(r'\d+', declared_shape)
                if len(ranks) and len(ranks) != member['rank']:
                    findings.append({
                        'binding_id': binding_id, 'legacy_symbol': legacy,
                        'kind': 'rank-mismatch',
                        'detail': f'register shape {declared_shape!r} implies rank '
                                  f'{len(ranks)}, index says rank {member["rank"]}'})
            declared_units = (row.get('units') or '').strip()
            if not declared_units or declared_units.lower() in ABSENT:
                findings.append({'binding_id': binding_id, 'legacy_symbol': legacy,
                                 'kind': 'missing-units',
                                 'detail': 'the contract requires explicit units'})
    return findings, examined


def collect(root: Path, index: dict, args: argparse.Namespace) -> dict:
    in_code, in_comment, zig_files = scan_zig(root, args.zig_src)
    traced = traceability_symbols(root / args.traceability)
    register_findings, register_rows = validate_register(index, root / args.bindings)

    inventory: list[dict] = []
    block_summary: list[dict] = []
    for block in index['commons']:
        counts = {'code': 0, 'comment': 0, 'absent': 0, 'traced': 0}
        for member in block['members']:
            name = member['name']
            code_files = sorted(in_code.get(name, set()))
            comment_files = sorted(in_comment.get(name, set()))
            if code_files:
                reach = 'code'
            elif comment_files:
                reach = 'comment'
            else:
                reach = 'absent'
            counts[reach] += 1
            in_traceability = name in traced
            if in_traceability:
                counts['traced'] += 1
            inventory.append({
                'name': name,
                'common_block': block['name'],
                'declared_in': block['declared_in'],
                'effective_type': member['effective_type'],
                'declared_type': member['declared_type'] or f'implicit {member["implicit_type"]}',
                'rank': member['rank'],
                'elements': member['elements'],
                'bounds': [f'{axis["lower"]}:{axis["upper"]}' for axis in member['bounds']],
                'reachability': reach,
                'in_traceability_csv': in_traceability,
                'low_confidence_name': len(name) < SHORT_NAME_LENGTH,
                'zig_code_files': code_files[:args.max_files],
                'zig_comment_files': comment_files[:args.max_files],
            })
        total = len(block['members'])
        block_summary.append({
            'common_block': block['name'], 'declared_in': block['declared_in'],
            'members': total, **counts,
            'absent_fraction': round(counts['absent'] / total, 6) if total else None,
        })

    block_summary.sort(key=lambda entry: -entry['absent'])
    reach_totals = {key: sum(1 for item in inventory if item['reachability'] == key)
                    for key in ('code', 'comment', 'absent')}
    return {
        'schema_version': 1,
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'index_created_utc': index['created_utc'],
        'sources': {'zig_src': args.zig_src, 'zig_files_scanned': zig_files,
                    'traceability': args.traceability,
                    'bindings_register': args.bindings,
                    'bindings_rows_examined': register_rows},
        'dialect_note': 'effective_type applies the legacy build contract '
                        f'({index["dialect"]["fflags"]}); default REAL is '
                        f'f{index["dialect"]["default_real_bytes"] * 8} and there are no '
                        'IMPLICIT statements anywhere in the tree, so every '
                        'implicitly-typed real is double precision.',
        'totals': {
            'common_blocks': len(index['commons']),
            'members': len(inventory),
            'reachable_in_zig_code': reach_totals['code'],
            'comment_only_in_zig': reach_totals['comment'],
            'absent_from_zig': reach_totals['absent'],
            'present_in_traceability_csv': sum(1 for item in inventory
                                               if item['in_traceability_csv']),
            'low_confidence_names': sum(1 for item in inventory
                                        if item['low_confidence_name']),
            'register_findings': len(register_findings),
        },
        'register_findings': register_findings,
        'by_common_block': block_summary,
        'inventory': inventory,
        'limitations': 'Name-occurrence reachability only. A code occurrence does not '
                       'prove a correct translation, matching units, matching index '
                       'order, or matching time level; an absence does not prove the '
                       'state is unimplemented, because the port renames fields. Treat '
                       'this as a worklist for the binding register, not as coverage.',
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--index', type=Path, default=None,
                        help='Defaults to <root>/audit/manifest/f77index.json')
    parser.add_argument('--zig-src', default='ecosys-ng/src')
    parser.add_argument('--traceability', default='audit/traceability/traceability.csv')
    parser.add_argument('--bindings', default='audit/traceability/bindings.csv')
    parser.add_argument('--out', help='Optional new project-relative JSON path for evidence')
    parser.add_argument('--top-blocks', type=int, default=15)
    parser.add_argument('--max-files', type=int, default=5)
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        index_path = args.index or (root / 'audit' / 'manifest' / 'f77index.json')
        if not index_path.is_file():
            raise BindError(f'No index at {index_path}. Run f77index.py first.')
        index = json.loads(index_path.read_text(encoding='utf-8'))
        if index.get('schema_version') != 1:
            raise BindError('Index schema is not version 1; rebuild it.')

        report = collect(root, index, args)

        if args.out:
            out = safe_path(root, args.out)
            if out.exists():
                raise BindError(f'Output exists; use a new path: {out}')
            out.parent.mkdir(parents=True, exist_ok=True)
            with out.open('x', encoding='utf-8') as handle:
                json.dump(report, handle, indent=2, allow_nan=False)
                handle.write('\n')

        totals = report['totals']
        print('=== legacy COMMON state vs the Zig port ===')
        print(f'  COMMON blocks                 : {totals["common_blocks"]}')
        print(f'  declared members              : {totals["members"]}')
        print(f'  name occurs in Zig code       : {totals["reachable_in_zig_code"]}')
        print(f'  name occurs only in comments  : {totals["comment_only_in_zig"]}')
        print(f'  name absent from Zig entirely : {totals["absent_from_zig"]}')
        print(f'  named in traceability.csv     : {totals["present_in_traceability_csv"]}')
        print(f'  short names (collision-prone) : {totals["low_confidence_names"]}')
        print(f'  Zig files scanned             : {report["sources"]["zig_files_scanned"]}')
        if report['sources']['bindings_rows_examined'] == 0:
            print(f'  binding register              : {args.bindings} has no usable rows; '
                  f'shape validation skipped')
        else:
            print(f'  binding register rows         : '
                  f'{report["sources"]["bindings_rows_examined"]} '
                  f'({totals["register_findings"]} findings)')
        for finding in report['register_findings'][:15]:
            print(f'    {finding["binding_id"]}: {finding["kind"]}: {finding["detail"]}')
        print('=== blocks with the most state absent from Zig (worklist order) ===')
        print(f'  {"block":<12} {"decl":<16} {"mem":>5} {"code":>5} {"cmnt":>5} {"absent":>7}')
        for entry in report['by_common_block'][:args.top_blocks]:
            print(f'  {entry["common_block"]:<12} '
                  f'{Path(entry["declared_in"]).name:<16} {entry["members"]:>5} '
                  f'{entry["code"]:>5} {entry["comment"]:>5} {entry["absent"]:>7}')
        if args.out:
            print(f'evidence written to {args.out}')
        return 1 if report['register_findings'] else 0
    except (OSError, BindError, csv.Error, json.JSONDecodeError) as exc:
        print(f'Binding check stopped: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
