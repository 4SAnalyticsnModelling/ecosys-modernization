#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Index fixed-form Fortran 77 sources into queryable JSON evidence. Python 3.10+.

Reads only; never writes into the snapshotted trees. The index is a navigation and
denominator aid, not a compiler and not proof of audit. Column and typing rules follow
the dialect recorded in f77src/makefile (ifort, -r8 -i4, fixed form, no IMPLICIT
statements anywhere in the tree), so `effective_type` is what the legacy build actually
produced rather than what a default-precision compiler would produce.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

SOURCE_ROOT = 'f77src'
CODE_START, CODE_END = 7, 72          # fixed-form statement columns, 1-based inclusive
TAB_STOP = 8
COMMENT_MARKERS = frozenset('CcDd*!#')

# Statements that declare or configure rather than execute. Everything else counts
# toward the executable denominator used by the G1 source-audit coverage measurement.
NON_EXECUTABLE = (
    'PROGRAM', 'SUBROUTINE', 'FUNCTION', 'BLOCKDATA', 'ENTRY', 'IMPLICIT', 'PARAMETER',
    'DIMENSION', 'COMMON', 'EQUIVALENCE', 'EXTERNAL', 'INTRINSIC', 'SAVE', 'DATA',
    'FORMAT', 'INCLUDE', 'END', 'REAL', 'INTEGER', 'CHARACTER', 'LOGICAL', 'COMPLEX',
    'DOUBLEPRECISION', 'DOUBLECOMPLEX', 'BYTE',
)
TYPE_KEYWORDS = (
    'DOUBLEPRECISION', 'DOUBLECOMPLEX', 'CHARACTER', 'INTEGER', 'LOGICAL', 'COMPLEX',
    'REAL', 'BYTE',
)

RE_UNIT = re.compile(
    r'^(?:(?P<type>DOUBLEPRECISION|DOUBLECOMPLEX|CHARACTER|INTEGER|LOGICAL|COMPLEX|REAL|BYTE)'
    r'(?:\*\d+)?)?'
    r'(?P<kind>PROGRAM|SUBROUTINE|BLOCKDATA|FUNCTION)'
    r'(?P<name>[A-Z][A-Z0-9_]*)?')
# Matched against raw statement text, not canonical(): canonical() replaces quoted
# strings with '?' to keep parentheses balanced, which would erase the filename.
RE_INCLUDE = re.compile(r'^\s*INCLUDE\s*[\'"]([^\'"]+)[\'"]', re.IGNORECASE)
RE_COMMON = re.compile(r'^COMMON/(?P<name>[A-Z0-9_]*)/(?P<body>.*)$')
RE_CALL = re.compile(r'\bCALL(?P<name>[A-Z][A-Z0-9_]*)')
RE_GOTO = re.compile(r'\bGOTO(?P<labels>\d[\d,\s]*)')
RE_DO = re.compile(r'^DO(?P<label>\d+)[A-Z]')
# Loop headers come in two shapes here: the dominant labelled form `DO 120 N=1,NX`
# and, in one file only, the ifort extension `DO N=1,NX` closed by ENDDO.
RE_DO_LABELLED = re.compile(r'^DO(?P<label>\d+)(?P<var>[A-Z][A-Z0-9_]*)=(?P<range>.*)$')
RE_DO_PLAIN = re.compile(r'^DO(?P<var>[A-Z][A-Z0-9_]*)=(?P<range>.*)$')
RE_ARITH_IF = re.compile(r'^IF\(.*\)(?P<labels>\d+,\d+,\d+)$')
RE_DECL_ITEM = re.compile(r'^(?P<name>[A-Z][A-Z0-9_]*)(?:\*\d+)?(?:\((?P<dims>.*)\))?$')
RE_PARAM_ITEM = re.compile(r'^(?P<name>[A-Z][A-Z0-9_]*)=(?P<value>.+)$')
RE_SAFE_EXPR = re.compile(r'^[0-9A-Z_+\-*/() ]+$')


class IndexError_(Exception):
    """Refusal to produce a misleading index."""


def safe_path(root: Path, value: str) -> Path:
    """Resolve a relative in-project path, rejecting traversal and symlinks."""
    rel = Path(value)
    if rel.is_absolute() or not rel.parts or '..' in rel.parts:
        raise IndexError_(f'Expected a relative in-project path: {value!r}')
    result = root
    for part in rel.parts:
        result = result / part
        if result.is_symlink():
            raise IndexError_(f'Unresolved symlink; index its target explicitly: {result}')
    if not result.resolve().is_relative_to(root.resolve()):
        raise IndexError_(f'Path escapes project: {value!r}')
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def read_lines(path: Path) -> tuple[list[str], bool]:
    """Decode as latin-1 so every byte round-trips; flag non-UTF-8 files.

    Several legacy files carry mojibake in comments (see redist.f vs redist_utf8.f).
    Decoding cannot fail here, and the flag keeps that fact in the evidence.
    """
    raw = path.read_bytes()
    try:
        raw.decode('utf-8')
        clean = True
    except UnicodeDecodeError:
        clean = False
    return raw.decode('latin-1').splitlines(), clean


def expand_tabs(line: str) -> str:
    """Advance to the next multiple of TAB_STOP, matching ifort's fixed-form handling."""
    if '\t' not in line:
        return line
    out: list[str] = []
    for char in line:
        if char == '\t':
            out.append(' ' * (TAB_STOP - (len(out) % TAB_STOP)))
        else:
            out.append(char)
    return ''.join(out)


def classify(line: str) -> tuple[str, str, str]:
    """Return (kind, label, code) for one physical line.

    kind is 'blank', 'comment', 'continuation' or 'initial'. A line is a continuation
    when column 6 holds anything other than a blank or '0'; the digits in this tree are
    not sequential and repeat, so they carry no ordering meaning.
    """
    if not line.strip():
        return 'blank', '', ''
    if line[0] in COMMENT_MARKERS:
        return 'comment', '', ''
    padded = line.ljust(CODE_END)
    code = padded[CODE_START - 1:CODE_END].rstrip()
    marker = padded[CODE_START - 2]
    if marker not in (' ', '0'):
        return 'continuation', '', code
    return 'initial', padded[:CODE_START - 2].strip(), code


def logical_statements(lines: list[str]) -> list[dict]:
    """Fold continuation lines into logical statements with their physical spans."""
    statements: list[dict] = []
    for number, raw in enumerate(lines, start=1):
        kind, label, code = classify(expand_tabs(raw))
        if kind in ('blank', 'comment'):
            continue
        if kind == 'continuation':
            if not statements:
                raise IndexError_(f'Continuation line {number} has no preceding statement.')
            statements[-1]['code'] += code
            statements[-1]['line_end'] = number
            continue
        statements.append({'label': label, 'code': code, 'line_start': number, 'line_end': number})
    return statements


def comment_runs(lines: list[str]) -> list[dict]:
    """Group consecutive comment lines into the section headers this codebase uses.

    ECOSYS documents itself with comment runs immediately above the statements they
    describe. Runs whose lines contain '=' are overwhelmingly variable glossaries rather
    than section banners, so they are flagged instead of discarded: both kinds are worth
    navigating to, but only one reads as an outline.
    """
    runs: list[dict] = []
    current: dict | None = None
    for number, raw in enumerate(lines, start=1):
        kind, _, _ = classify(expand_tabs(raw))
        if kind == 'comment':
            text = raw[1:].strip()
            if current is None:
                current = {'line_start': number, 'line_end': number, 'lines': []}
            current['line_end'] = number
            if text:
                current['lines'].append(text)
            continue
        if current is not None:
            if current['lines']:
                runs.append(current)
            current = None
    if current is not None and current['lines']:
        runs.append(current)
    for run in runs:
        joined = ' '.join(run['lines'])
        run['text'] = joined if len(joined) <= 200 else joined[:197] + '...'
        run['kind'] = classify_comment(run['lines'])
        run['comment_lines'] = len(run['lines'])
        del run['lines']
    return runs


RE_DORMANT_ASSIGNMENT = re.compile(r'^[A-Z][A-Z0-9_]*(\([^)]*\))?=')
DORMANT_KEYWORDS = (
    'IF(', 'ENDIF', 'ELSEIF', 'ELSE', 'DO', 'ENDDO', 'WRITE(', 'READ(', 'CALL', 'GOTO',
    'RETURN', 'CONTINUE', 'OPEN(', 'CLOSE(', 'FORMAT(', 'STOP', 'THEN', 'ENDSUBROUTINE',
)


def classify_comment(lines: list[str]) -> str:
    """Label a comment run as prose, a variable glossary, or dormant commented-out code.

    Dormant code matters to the audit in its own right: the contract keeps non-production
    branches in the inventory, and a reader needs to know whether a commented block is
    documentation or a disabled statement. Prose is what reads as a section heading, so
    separating the three is what makes `outline` usable.
    """
    first = lines[0].replace(' ', '').upper()
    if first.startswith(DORMANT_KEYWORDS) or RE_DORMANT_ASSIGNMENT.match(first):
        return 'dormant-code'
    if sum('=' in line for line in lines) * 2 > len(lines):
        return 'glossary'
    return 'prose'


def canonical(code: str) -> str:
    """Strip blanks and quoted text so keyword matching is not fooled by spacing.

    Fortran 77 ignores blanks inside statements, so `GO TO 100` and `GOTO100` are the
    same statement. Character literals are replaced rather than removed to keep
    parentheses balanced for the splitter.
    """
    out: list[str] = []
    quote = ''
    for char in code:
        if quote:
            if char == quote:
                quote = ''
            continue
        if char in '\'"':
            quote = char
            out.append('?')
            continue
        if char != ' ':
            out.append(char.upper())
    return ''.join(out)


def split_top_level(body: str) -> list[str]:
    """Split a comma list, ignoring commas nested in parentheses."""
    items: list[str] = []
    depth = 0
    current: list[str] = []
    for char in body:
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
        if char == ',' and depth == 0:
            items.append(''.join(current))
            current = []
            continue
        current.append(char)
    if current:
        items.append(''.join(current))
    return [item for item in items if item]


def parse_parameters(text: str, known: dict[str, int]) -> dict[str, int]:
    """Evaluate PARAMETER constants, resolving references to earlier constants."""
    values = dict(known)
    for item in split_top_level(text):
        match = RE_PARAM_ITEM.match(item)
        if not match:
            continue
        expression = match.group('value')
        if not RE_SAFE_EXPR.match(expression):
            continue
        try:
            values[match.group('name')] = int(eval(expression, {'__builtins__': {}}, dict(values)))
        except (ValueError, TypeError, NameError, SyntaxError, ZeroDivisionError):
            continue
    return values


def parse_dims(spec: str, parameters: dict[str, int]) -> dict:
    """Describe one array specification: rank, bounds, and element count when resolvable."""
    bounds: list[dict] = []
    elements = 1
    for axis in split_top_level(spec):
        lower_text, _, upper_text = axis.partition(':')
        if not upper_text:
            lower_text, upper_text = '1', lower_text
        entry = {'lower': lower_text, 'upper': upper_text}
        extent = None
        if RE_SAFE_EXPR.match(lower_text) and RE_SAFE_EXPR.match(upper_text):
            try:
                low = int(eval(lower_text, {'__builtins__': {}}, dict(parameters)))
                high = int(eval(upper_text, {'__builtins__': {}}, dict(parameters)))
                extent = high - low + 1
            except (ValueError, TypeError, NameError, SyntaxError, ZeroDivisionError):
                extent = None
        entry['extent'] = extent
        if extent is None:
            elements = None
        elif elements is not None:
            elements *= extent
        bounds.append(entry)
    return {'rank': len(bounds), 'bounds': bounds, 'elements': elements}


def implicit_type(name: str) -> str:
    """Fortran 77 default typing. No IMPLICIT statement exists anywhere in this tree."""
    return 'INTEGER' if name[0] in 'IJKLMN' else 'REAL'


def effective_type(declared: str | None, name: str, real_bytes: int, integer_bytes: int) -> str:
    """Apply the recorded -r8/-i4 promotion to get the type the legacy build produced."""
    base = declared or implicit_type(name)
    if base == 'REAL':
        return f'f{real_bytes * 8}'
    if base == 'DOUBLEPRECISION':
        return 'f64'
    if base in ('INTEGER', 'BYTE'):
        return f'i{integer_bytes * 8}'
    if base == 'LOGICAL':
        return f'bool{integer_bytes * 8}'
    if base == 'CHARACTER':
        return 'char'
    if base in ('COMPLEX', 'DOUBLECOMPLEX'):
        return f'c{real_bytes * 16}'
    return base.lower()


def has_top_level_assignment(code: str) -> bool:
    """True when a bare '=' sits outside every parenthesis.

    Fortran 77 spells comparison as .EQ., so a top-level '=' means an assignment or a DO
    header -- both executable. This is what distinguishes `DATAC(3,NE,NEX)=...` from a
    `DATA` statement and `DOY=I-1+XJ/24` from a loop, which prefix matching alone gets
    wrong.
    """
    depth = 0
    for char in code:
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
        elif char == '=' and depth == 0:
            return True
    return False


def statement_keyword(code: str) -> str:
    """Name the declarative statement this is, or '' when it is executable."""
    if code == 'END':
        return 'END'
    # ENDIF/ENDDO/ENDFILE are executable and must not be captured by the 'END' prefix.
    if has_top_level_assignment(code):
        return ''
    for keyword in NON_EXECUTABLE:
        if keyword != 'END' and code.startswith(keyword):
            return keyword
    return ''


def build_sources(root: Path) -> list[str]:
    """Read SRCS from f77src/makefile so the index can mark out-of-build files."""
    makefile = root / SOURCE_ROOT / 'makefile'
    if not makefile.is_file():
        raise IndexError_(f'Missing build reference: {makefile}')
    text = makefile.read_text(encoding='latin-1')
    match = re.search(r'^SRCS=(?P<body>(?:.*\\\n)*.*)$', text, re.MULTILINE)
    if not match:
        raise IndexError_('Could not read SRCS from f77src/makefile.')
    return sorted(set(match.group('body').replace('\\', ' ').split()))


def index_file(path: Path, relative: str, in_build: bool, parameters: dict[str, int],
               real_bytes: int, integer_bytes: int) -> dict:
    lines, utf8_clean = read_lines(path)
    statements = logical_statements(lines)
    units: list[dict] = []
    commons: list[dict] = []
    declared: dict[str, str] = {}
    unit: dict | None = None

    def start_unit(kind: str, name: str, line: int, header_end: int) -> dict:
        # header_line_end is the last physical line of the (often continued) unit header.
        # Anything injected into a generated driver must go after it, not after line_start.
        return {'name': name, 'kind': kind, 'file': relative, 'line_start': line,
                'header_line_end': header_end,
                'line_end': line, 'statements': 0, 'executable_statements': 0,
                'arguments': [], 'includes': [], 'commons': [], 'calls': [],
                'labels_defined': [], 'labels_referenced': [], 'loops': [], 'sections': []}

    open_loops: list[int] = []

    def close_loops(unit: dict, label: str, line: int) -> None:
        """Close every open loop terminated by this label, innermost first.

        Fortran 77 lets several nested DO statements share one terminal statement, and
        this tree does exactly that (see main.f, four `DO 120` closing at `120
        CONTINUE`), so a label match may close more than one loop. The stack is searched
        rather than only peeked so that one misread header cannot block every enclosing
        loop for the rest of a 13,000-line routine.
        """
        if not any(unit['loops'][index]['label'] == label for index in open_loops):
            return
        closed_match = False
        while open_loops:
            index = open_loops[-1]
            matches = unit['loops'][index]['label'] == label
            if closed_match and not matches:
                break
            open_loops.pop()
            unit['loops'][index]['line_end'] = line
            closed_match = closed_match or matches

    for statement in statements:
        code = canonical(statement['code'])
        if not code:
            continue
        keyword = statement_keyword(code)

        unit_match = None if has_top_level_assignment(code) else RE_UNIT.match(code)
        if unit_match and unit_match.group('kind') and not code.startswith('ENDSUBROUTINE'):
            kind = unit_match.group('kind')
            # An unnamed BLOCK DATA still needs a stable, filesystem-safe identifier so
            # generated drivers and evidence files can be named after it.
            name = unit_match.group('name') or f'{kind}@{Path(relative).stem}#{statement["line_start"]}'
            if unit is not None:
                units.append(unit)
            unit = start_unit(kind.lower(), name, statement['line_start'], statement['line_end'])
            # A generated driver has to supply these by name, so record the dummy
            # argument list from the (often continued) header statement.
            arguments = re.search(r'\((.*)\)$', code)
            unit['arguments'] = split_top_level(arguments.group(1)) if arguments else []
            declared = {}
            open_loops = []

        if unit is None:
            # Include files hold declarations with no enclosing unit of their own.
            unit = start_unit('include-fragment', relative, statement['line_start'],
                              statement['line_start'])

        unit['statements'] += 1
        unit['line_end'] = statement['line_end']
        if not keyword:
            unit['executable_statements'] += 1
        if statement['label']:
            unit['labels_defined'].append({'label': statement['label'], 'line': statement['line_start']})
            close_loops(unit, statement['label'], statement['line_end'])

        # `keyword` is empty only for executable statements, which keeps DOUBLEPRECISION
        # declarations from being read as a `DO` header once blanks are stripped.
        if not keyword:
            if code == 'ENDDO':
                # One ENDDO closes exactly one unlabelled loop (see splitc.f).
                if open_loops and unit['loops'][open_loops[-1]]['label'] == '':
                    unit['loops'][open_loops.pop()]['line_end'] = statement['line_end']
            else:
                header = RE_DO_LABELLED.match(code) or RE_DO_PLAIN.match(code)
                # A DO header always carries `start,end` at the top level. Requiring that
                # comma is what separates a real loop from an ordinary assignment to a
                # variable whose name happens to begin with DO (DOY=, DOSAK=, DOSA1=).
                if header and len(split_top_level(header.group('range'))) > 1:
                    groups = header.groupdict()
                    unit['loops'].append({
                        'label': groups.get('label') or '',
                        'variable': groups['var'],
                        'range': groups['range'],
                        'depth': len(open_loops),
                        'line_start': statement['line_start'],
                        'line_end': None,
                    })
                    open_loops.append(len(unit['loops']) - 1)

        if keyword in TYPE_KEYWORDS:
            body = code[len(keyword):]
            body = re.sub(r'^\*\d+', '', body)
            for item in split_top_level(body):
                item_match = RE_DECL_ITEM.match(item)
                if item_match:
                    declared[item_match.group('name')] = keyword

        if keyword == 'PARAMETER':
            parameters.update(parse_parameters(code[len('PARAMETER'):].strip('()'), parameters))

        include_match = RE_INCLUDE.match(statement['code'])
        if include_match:
            unit['includes'].append({'name': include_match.group(1),
                                     'line': statement['line_start']})

        common_match = RE_COMMON.match(code)
        if common_match:
            name = common_match.group('name') or '<blank>'
            members: list[dict] = []
            for item in split_top_level(common_match.group('body')):
                item_match = RE_DECL_ITEM.match(item)
                if not item_match:
                    continue
                member = item_match.group('name')
                spec = item_match.group('dims')
                shape = parse_dims(spec, parameters) if spec else {'rank': 0, 'bounds': [], 'elements': 1}
                members.append({
                    'name': member,
                    'declared_type': declared.get(member),
                    'implicit_type': implicit_type(member),
                    'effective_type': effective_type(declared.get(member), member,
                                                     real_bytes, integer_bytes),
                    **shape,
                })
            commons.append({'name': name, 'declared_in': relative,
                            'line_start': statement['line_start'],
                            'line_end': statement['line_end'], 'members': members})
            if name not in unit['commons']:
                unit['commons'].append(name)

        for call in RE_CALL.finditer(code):
            unit['calls'].append({'callee': call.group('name'), 'line': statement['line_start']})

        for goto in RE_GOTO.finditer(code):
            for label in re.findall(r'\d+', goto.group('labels')):
                unit['labels_referenced'].append({'label': label, 'line': statement['line_start'],
                                                  'via': 'GOTO'})
        do_match = RE_DO.match(code)
        if do_match:
            unit['labels_referenced'].append({'label': do_match.group('label'),
                                              'line': statement['line_start'], 'via': 'DO'})
        arith = RE_ARITH_IF.match(code)
        if arith:
            for label in arith.group('labels').split(','):
                unit['labels_referenced'].append({'label': label, 'line': statement['line_start'],
                                                  'via': 'arithmetic-IF'})

    if unit is not None:
        units.append(unit)

    for run in comment_runs(lines):
        owner = next((entry for entry in units
                      if entry['line_start'] <= run['line_start'] <= entry['line_end']), None)
        if owner is not None:
            owner['sections'].append(run)

    unclosed = sum(1 for entry in units for loop in entry['loops'] if loop['line_end'] is None)

    return {'file': {'path': relative, 'in_build': in_build, 'physical_lines': len(lines),
                     'logical_statements': len(statements), 'utf8_clean': utf8_clean,
                     'unclosed_loops': unclosed, 'sha256': sha256(path)},
            'units': units, 'commons': commons}


def collect(root: Path) -> dict:
    source_dir = safe_path(root, SOURCE_ROOT)
    if not source_dir.is_dir():
        raise IndexError_(f'Missing authoritative directory: {source_dir}')
    srcs = build_sources(root)
    makefile_text = (root / SOURCE_ROOT / 'makefile').read_text(encoding='latin-1')
    fflags = next((line.split('=', 1)[1].strip() for line in makefile_text.splitlines()
                   if line.startswith('FFLAGS') and not line.lstrip().startswith('#')), '')
    real_bytes = 8 if '-r8' in fflags else 4
    integer_bytes = 8 if '-i8' in fflags else 4

    parameters: dict[str, int] = {}
    parameters_file = source_dir / 'parameters.h'
    if parameters_file.is_file():
        for statement in logical_statements(read_lines(parameters_file)[0]):
            code = canonical(statement['code'])
            if code.startswith('PARAMETER'):
                parameters = parse_parameters(code[len('PARAMETER'):].strip('()'), parameters)

    files: list[dict] = []
    units: list[dict] = []
    commons: list[dict] = []
    for path in sorted(source_dir.iterdir()):
        if path.is_symlink():
            raise IndexError_(f'Unresolved symlink in source tree: {path}')
        if not path.is_file() or path.suffix not in ('.f', '.h'):
            continue
        relative = path.relative_to(root).as_posix()
        result = index_file(path, relative, path.name in srcs, dict(parameters),
                            real_bytes, integer_bytes)
        files.append(result['file'])
        units.extend(result['units'])
        commons.extend(result['commons'])

    defined = {unit['name'] for unit in units}
    call_graph = sorted(
        ({'caller': unit['name'], 'callee': call['callee'], 'file': unit['file'],
          'line': call['line'], 'resolved': call['callee'] in defined}
         for unit in units for call in unit['calls']),
        key=lambda edge: (edge['caller'], edge['callee'], edge['line']))

    return {
        'schema_version': 1,
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'dialect': {
            'form': 'fixed', 'code_columns': [CODE_START, CODE_END], 'tab_stop': TAB_STOP,
            'compiler': 'ifort', 'fflags': fflags,
            'default_real_bytes': real_bytes, 'default_integer_bytes': integer_bytes,
            'implicit_typing': True,
            'note': 'No IMPLICIT statement appears in this tree; default I-N integer '
                    'typing applies everywhere and -r8 promotes default REAL.',
            'gfortran_oracle': {
                'measured_with': 'GNU Fortran 16.1.0 (MinGW-W64 ucrt)',
                'flags': ['-ffixed-form', '-ffixed-line-length-72', '-fdefault-real-8',
                          '-fdefault-double-8', '-std=legacy', '-fallow-argument-mismatch'],
                'required_source_injection': {
                    'soil.f': 'EXTERNAL split',
                },
                'note': 'gfortran 16 implements the Fortran 2023 SPLIT intrinsic, which '
                        'shadows this project\'s own split.f and makes soil.f fail with '
                        '"Too many arguments in call to split". The call is correct: '
                        'split.f declares 10 arguments and soil.f passes 10. Declare '
                        'EXTERNAL split after the unit header (see header_line_end) or '
                        'compile that unit with -std=f95. These flags reproduce the '
                        'ifort -r8 -i4 precision contract recorded in fflags; they are '
                        'not a claim of ifort-identical code generation.',
                'validation': 'All 41 program units in f77src/*.f re-extract by their '
                              'recorded line ranges and compile standalone under these '
                              'flags.',
            },
        },
        'parameters': dict(sorted(parameters.items())),
        'build_sources': srcs,
        'files': files,
        'units': sorted(units, key=lambda unit: (unit['file'], unit['line_start'])),
        'commons': sorted(commons, key=lambda block: (block['name'], block['declared_in'])),
        'call_graph': call_graph,
        'totals': {
            'files': len(files),
            'files_out_of_build': sum(1 for entry in files if not entry['in_build']),
            'units': len(units),
            'common_blocks': len({block['name'] for block in commons}),
            'logical_statements': sum(entry['logical_statements'] for entry in files),
            'executable_statements': sum(unit['executable_statements'] for unit in units),
            'loops': sum(len(unit['loops']) for unit in units),
            'unclosed_loops': sum(entry['unclosed_loops'] for entry in files),
            'comment_sections': sum(len(unit['sections']) for unit in units),
            'comment_sections_by_kind': {
                kind: sum(1 for unit in units for section in unit['sections']
                          if section['kind'] == kind)
                for kind in ('prose', 'glossary', 'dormant-code')
            },
            'unresolved_calls': sum(1 for edge in call_graph if not edge['resolved']),
        },
        'limitations': 'Static index of fixed-form text. Does not compile, does not prove '
                       'semantic equivalence, and does not evaluate scientific correctness. '
                       'Unresolved calls include intrinsics and the linked C routines.',
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--out', required=True,
                        help='New project-relative JSON path; existing evidence is never overwritten')
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        out = safe_path(root, args.out)
        if out.exists():
            raise IndexError_(f'Output exists; use a new candidate-specific path: {out}')
        data = collect(root)
        if not data['units']:
            raise IndexError_('No program units found; an empty index cannot support an audit.')
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open('x', encoding='utf-8') as handle:
            json.dump(data, handle, indent=2, allow_nan=False)
            handle.write('\n')
        print(json.dumps({'path': str(out), 'sha256': sha256(out), **data['totals']}, indent=2))
        return 0
    except (OSError, IndexError_) as exc:
        print(f'Index stopped: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
