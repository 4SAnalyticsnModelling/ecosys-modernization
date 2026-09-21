#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Query the f77index.json navigation index. Read-only. Python 3.10+.

Built for this repository's actual shape: one very large program unit per file (REDIST is
13,094 lines in a single subroutine) with an almost empty call graph. The useful handles
are therefore the DO-loop nest and the comment runs, not the call tree, so `outline` is
the command that replaces paging through a source file.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import sys


class QueryError(Exception):
    """Refusal to answer from an index that cannot support the question."""


def load(index_path: Path) -> dict:
    if not index_path.is_file():
        raise QueryError(f'No index at {index_path}. Build it with f77index.py first.')
    data = json.loads(index_path.read_text(encoding='utf-8'))
    if data.get('schema_version') != 1:
        raise QueryError('Index schema is not version 1; rebuild with this f77index.py.')
    return data


def resolve_unit(data: dict, token: str) -> dict:
    """Accept a unit name (GROSUB), a file name (grosub.f) or a project path."""
    wanted = token.lower()
    matches = [unit for unit in data['units']
               if unit['name'].lower() == wanted
               or Path(unit['file']).name.lower() == wanted
               or unit['file'].lower() == wanted
               or Path(unit['file']).stem.lower() == wanted]
    if not matches:
        raise QueryError(f'No unit matches {token!r}. Try: f77query.py units')
    if len(matches) > 1:
        # redist.f and redist_utf8.f hold the same routine; make the caller choose.
        detail = ', '.join(f"{unit['name']} in {unit['file']}" for unit in matches)
        raise QueryError(f'{token!r} is ambiguous: {detail}. Name the file instead.')
    return matches[0]


def source_lines(root: Path, relative: str) -> list[str]:
    path = root / relative
    if not path.is_file():
        raise QueryError(f'Source file missing: {path}')
    return path.read_bytes().decode('latin-1').splitlines()


def emit_slice(root: Path, relative: str, start: int, end: int) -> None:
    lines = source_lines(root, relative)
    start = max(1, start)
    end = min(len(lines), end)
    width = len(str(end))
    print(f'--- {relative}:{start}-{end} ---')
    for number in range(start, end + 1):
        print(f'{number:>{width}}| {lines[number - 1].rstrip()}')


def in_build_warning(data: dict, unit: dict) -> None:
    """Warn when a unit lives in a file the legacy makefile never compiles."""
    entry = next((item for item in data['files'] if item['path'] == unit['file']), None)
    if entry is not None and not entry['in_build']:
        print(f'WARNING: {unit["file"]} is not in the makefile SRCS list. It is not part '
              f'of the legacy build and must not be used as the reference.', file=sys.stderr)


def cmd_units(data: dict, args: argparse.Namespace) -> int:
    rows = [unit for unit in data['units'] if args.all or unit['kind'] != 'include-fragment']
    rows.sort(key=lambda unit: -unit['statements'])
    print(f'{"unit":<26} {"kind":<18} {"file":<24} {"lines":>13} {"stmts":>7} {"exec":>7} {"loops":>6}  build')
    for unit in rows:
        entry = next((item for item in data['files'] if item['path'] == unit['file']), {})
        span = f'{unit["line_start"]}-{unit["line_end"]}'
        print(f'{unit["name"]:<26} {unit["kind"]:<18} {Path(unit["file"]).name:<24} '
              f'{span:>13} {unit["statements"]:>7} {unit["executable_statements"]:>7} '
              f'{len(unit["loops"]):>6}  {"yes" if entry.get("in_build") else "NO"}')
    return 0


def cmd_show(data: dict, args: argparse.Namespace) -> int:
    unit = resolve_unit(data, args.unit)
    in_build_warning(data, unit)
    start, end = unit['line_start'], unit['line_end']
    if args.lines:
        match = re.fullmatch(r'(\d+)(?:-(\d+))?', args.lines)
        if not match:
            raise QueryError('--lines expects N or N-M')
        start = int(match.group(1))
        end = int(match.group(2) or match.group(1))
    elif args.loop is not None:
        loops = [loop for loop in unit['loops'] if loop['label'] == args.loop]
        if not loops:
            raise QueryError(f'No loop labelled {args.loop} in {unit["name"]}')
        if len(loops) > 1:
            spans = ', '.join(f'{loop["line_start"]}-{loop["line_end"]}' for loop in loops)
            raise QueryError(f'Label {args.loop} terminates {len(loops)} nested loops '
                             f'({spans}); use --lines to pick one.')
        start, end = loops[0]['line_start'], loops[0]['line_end']
    elif end - start > args.max_lines:
        print(f'{unit["name"]} spans {end - start + 1} lines in {unit["file"]}. Showing the '
              f'header only; use `outline` to navigate, or --lines / --loop / '
              f'--max-lines to widen.', file=sys.stderr)
        end = min(end, start + args.max_lines)
    emit_slice(args.root, unit['file'], start, end)
    return 0


def cmd_outline(data: dict, args: argparse.Namespace) -> int:
    """Render loop nest and comment runs interleaved, as a navigable table of contents."""
    unit = resolve_unit(data, args.unit)
    in_build_warning(data, unit)
    events: list[tuple[int, int, str]] = []
    for loop in unit['loops']:
        if loop['depth'] > args.depth:
            continue
        label = f'DO {loop["label"]}' if loop['label'] else 'DO'
        span = f'{loop["line_start"]}-{loop["line_end"]}'
        events.append((loop['line_start'], 0,
                       f'{"  " * loop["depth"]}{label} {loop["variable"]}='
                       f'{loop["range"]}   [{span}]'))
    if not args.loops_only:
        marker = {'prose': '.', 'glossary': 'g', 'dormant-code': 'x'}
        for section in unit['sections']:
            if section['kind'] not in args.sections:
                continue
            events.append((section['line_start'], 1,
                           f'  {marker[section["kind"]]} {section["text"][:args.width]}'
                           f'   [L{section["line_start"]}]'))
    events.sort()
    print(f'=== {unit["name"]}  {unit["file"]}:{unit["line_start"]}-{unit["line_end"]}  '
          f'({unit["statements"]} statements, {len(unit["loops"])} loops) ===')
    if not events:
        print('(no loops or comment sections at this depth)')
    for _, _, text in events:
        print(text)
    return 0


def cmd_loops(data: dict, args: argparse.Namespace) -> int:
    unit = resolve_unit(data, args.unit)
    in_build_warning(data, unit)
    print(f'{"label":>8} {"var":<10} {"depth":>5} {"lines":>15} {"span":>7}  range')
    for loop in sorted(unit['loops'], key=lambda item: item['line_start']):
        span = (loop['line_end'] - loop['line_start'] + 1) if loop['line_end'] else 0
        where = f'{loop["line_start"]}-{loop["line_end"]}'
        print(f'{loop["label"] or "-":>8} {loop["variable"]:<10} {loop["depth"]:>5} '
              f'{where:>15} {span:>7}  {loop["range"]}')
    return 0


def cmd_callers(data: dict, args: argparse.Namespace) -> int:
    wanted = args.name.upper()
    inbound = [edge for edge in data['call_graph'] if edge['callee'] == wanted]
    outbound = [edge for edge in data['call_graph'] if edge['caller'].upper() == wanted]
    print(f'=== callers of {wanted} ({len(inbound)}) ===')
    for edge in inbound:
        print(f'  {edge["caller"]:<22} {edge["file"]}:{edge["line"]}')
    print(f'=== calls made by {wanted} ({len(outbound)}) ===')
    for edge in outbound:
        flag = '' if edge['resolved'] else '   (unresolved: intrinsic or C routine)'
        print(f'  -> {edge["callee"]:<19} {edge["file"]}:{edge["line"]}{flag}')
    if not inbound and not outbound:
        print('  none. Note this codebase is one large routine per file with an almost '
              'empty call graph; use `outline` instead.')
    return 0


def cmd_common(data: dict, args: argparse.Namespace) -> int:
    wanted = args.name.upper()
    blocks = [block for block in data['commons'] if block['name'].upper() == wanted]
    if not blocks:
        names = ', '.join(sorted({block['name'] for block in data['commons']}))
        raise QueryError(f'No COMMON block {wanted}. Known blocks: {names}')
    for block in blocks:
        print(f'=== COMMON /{block["name"]}/ declared in {block["declared_in"]}'
              f':{block["line_start"]}-{block["line_end"]} '
              f'({len(block["members"])} members) ===')
        print(f'{"member":<12} {"effective":<10} {"declared":<16} {"rank":>4} {"elements":>10}  bounds')
        for member in block['members']:
            bounds = ','.join(f'{axis["lower"]}:{axis["upper"]}' for axis in member['bounds'])
            declared = member['declared_type'] or f'implicit {member["implicit_type"]}'
            print(f'{member["name"]:<12} {member["effective_type"]:<10} {declared:<16} '
                  f'{member["rank"]:>4} {str(member["elements"]):>10}  {bounds}')
    if args.users:
        users = [unit for unit in data['units'] if wanted in [name.upper() for name in unit['commons']]]
        print(f'=== units declaring /{wanted}/ ({len(users)}) ===')
        for unit in users:
            print(f'  {unit["name"]:<22} {unit["file"]}')
        including = [unit for unit in data['units']
                     for include in unit['includes']
                     if include['name'].upper() == f'{wanted}.H']
        print(f'=== units including {wanted.lower()}.h ({len(including)}) ===')
        for unit in including:
            print(f'  {unit["name"]:<22} {unit["file"]}')
    return 0


def cmd_grep(data: dict, args: argparse.Namespace) -> int:
    """Search source text and report the enclosing unit and innermost loop for each hit."""
    pattern = re.compile(args.pattern, 0 if args.case_sensitive else re.IGNORECASE)
    targets = [resolve_unit(data, args.unit)] if args.unit else [
        unit for unit in data['units'] if unit['kind'] != 'include-fragment']
    hits = 0
    for unit in targets:
        entry = next((item for item in data['files'] if item['path'] == unit['file']), {})
        if not args.include_unbuilt and not entry.get('in_build'):
            continue
        lines = source_lines(args.root, unit['file'])
        for number in range(unit['line_start'], min(unit['line_end'], len(lines)) + 1):
            text = lines[number - 1]
            if not pattern.search(text):
                continue
            innermost = None
            for loop in unit['loops']:
                if loop['line_end'] and loop['line_start'] <= number <= loop['line_end']:
                    if innermost is None or loop['depth'] > innermost['depth']:
                        innermost = loop
            where = (f' [in DO {innermost["label"] or "-"} {innermost["variable"]}'
                     f' depth {innermost["depth"]}]') if innermost else ''
            print(f'{Path(unit["file"]).name}:{number}: {text.rstrip()[:args.width]}{where}')
            hits += 1
            if hits >= args.limit:
                print(f'... stopped at {args.limit} hits; raise --limit or narrow the pattern.',
                      file=sys.stderr)
                return 0
    if not hits:
        print('no matches')
    return 0


def cmd_stats(data: dict, args: argparse.Namespace) -> int:
    print(json.dumps({'dialect': data['dialect'], 'parameters': data['parameters'],
                      'totals': data['totals'], 'created_utc': data['created_utc']}, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--index', type=Path, default=None,
                        help='Defaults to <root>/audit/manifest/f77index.json')
    subparsers = parser.add_subparsers(dest='command', required=True)

    p = subparsers.add_parser('units', help='List program units, largest first')
    p.add_argument('--all', action='store_true', help='Include include-file fragments')
    p.set_defaults(handler=cmd_units)

    p = subparsers.add_parser('show', help='Print a unit, a line range, or one loop body')
    p.add_argument('unit')
    p.add_argument('--lines', help='N or N-M')
    p.add_argument('--loop', help='Show the body of the loop with this label')
    p.add_argument('--max-lines', type=int, default=400)
    p.set_defaults(handler=cmd_show)

    p = subparsers.add_parser('outline', help='Loop nest and comment sections as a contents page')
    p.add_argument('unit')
    p.add_argument('--depth', type=int, default=99, help='Maximum loop nesting depth to show')
    p.add_argument('--sections', default='prose',
                   help='Comma list of comment kinds to show: prose, glossary, dormant-code, '
                        'or all (default: prose)')
    p.add_argument('--loops-only', action='store_true')
    p.add_argument('--width', type=int, default=110)
    p.set_defaults(handler=cmd_outline)

    p = subparsers.add_parser('loops', help='Tabulate every loop in a unit')
    p.add_argument('unit')
    p.set_defaults(handler=cmd_loops)

    p = subparsers.add_parser('callers', help='Inbound and outbound CALL edges')
    p.add_argument('name')
    p.set_defaults(handler=cmd_callers)

    p = subparsers.add_parser('common', help='COMMON block members with effective types')
    p.add_argument('name')
    p.add_argument('--users', action='store_true', help='Also list declaring and including units')
    p.set_defaults(handler=cmd_common)

    p = subparsers.add_parser('grep', help='Search source, reporting enclosing unit and loop')
    p.add_argument('pattern')
    p.add_argument('--unit', help='Restrict to one unit')
    p.add_argument('--case-sensitive', action='store_true')
    p.add_argument('--include-unbuilt', action='store_true',
                   help='Also search files absent from makefile SRCS')
    p.add_argument('--limit', type=int, default=200)
    p.add_argument('--width', type=int, default=120)
    p.set_defaults(handler=cmd_grep)

    p = subparsers.add_parser('stats', help='Dialect, parameters and totals')
    p.set_defaults(handler=cmd_stats)

    args = parser.parse_args()
    # Several legacy files carry mojibake in comments (see redist.f vs redist_utf8.f).
    # Sources are decoded latin-1 so every byte round-trips, which can yield C1 control
    # characters such as U+0091 that the Windows console codepage cannot encode. Without
    # this, printing those lines raises UnicodeEncodeError and the tool exits 1.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors='replace')
        except (AttributeError, OSError):
            pass
    kinds = ('prose', 'glossary', 'dormant-code')
    if getattr(args, 'sections', None) is not None:
        args.sections = kinds if args.sections == 'all' else tuple(
            item.strip() for item in args.sections.split(','))
        unknown = [item for item in args.sections if item not in kinds]
        if unknown:
            parser.error(f'unknown --sections value(s): {", ".join(unknown)}')
    try:
        args.root = args.root.resolve(strict=True)
        index_path = args.index or (args.root / 'audit' / 'manifest' / 'f77index.json')
        return args.handler(load(index_path), args)
    except (OSError, QueryError, json.JSONDecodeError) as exc:
        print(f'Query stopped: {exc}', file=sys.stderr)
        return 2
    except BrokenPipeError:
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
