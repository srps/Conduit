#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the decision records under docs/decisions/ (#177). Read-only.

A structural check catches mechanical drift only; review still judges whether
a record's evidence is enough. It checks that:

- every record is docs/decisions/NNNN-slug.md with a matching `# NNNN: Title`,
  and IDs are unique and run from 0001 with no gap;
- with git history, no commit (merges included) left an ID out of the tree
  unless a record with the same ID and title is back, so an ID is never
  reused for another decision. A slug rename keeps the ID in the tree and is
  fine, and so is a later title correction. Rewriting a record in place into another decision is left
  to review, since titles and facts are legitimately corrected in place. --require-history fails a tree without full history (CI
  checks out with fetch-depth 0);
- the front matter has exactly the fields of template.md, each status comes
  from its allowed set and the date is real;
- an accepted or superseded decision names its authorization, with a date and
  an issue, PR or commit;
- Supersedes / Superseded by name existing records, are reciprocal and
  acyclic, and a record is superseded exactly when it names a successor;
- the sections are the template's, in order;
- an implemented or partial record links at least one existing file outside
  docs/ from its Implementation evidence, and says what it does not prove;
- the index in README.md has one row per record, matching its link, title
  and statuses;
- every relative link (inline, with or without a title or <...>, and
  reference definitions) in the records, template and index resolves inside
  the repository.

Usage: check-decisions.py [--require-history] [ROOT]
"""
import datetime
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

DECISIONS = {'proposed', 'accepted', 'rejected', 'superseded'}
IMPLEMENTATIONS = {'planned', 'partial', 'implemented'}
VALIDATIONS = {'none', 'pending', 'passed'}
FIELDS = ['Date', 'Decision', 'Implementation', 'Validation', 'Supersedes', 'Superseded by']
SECTIONS = ['Context', 'Decision', 'Alternatives', 'Consequences', 'Invariants and verification',
            'Implementation evidence', 'Open questions']
NOT_RECORDS = {'README.md', 'template.md'}

FILENAME = re.compile(r'^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$')
TITLE = re.compile(r'^# (\d{4}): (\S.*)$')
FIELD = re.compile(r'^- ([A-Za-z ]+): (.*)$')
DECISION = re.compile(r'^([a-z]+)(?: \((.+)\))?$')
SOURCE_DATE = re.compile(r'\b\d{4}-\d{2}-\d{2}\b')
SOURCE_REFERENCE = re.compile(r'#\d+|\b[0-9a-f]{7,40}\b|https://github\.com/\S+/(?:issues|pull)/\d+')
ID_LIST = re.compile(r'^\d{4}(?:, \d{4})*$')
REFERENCE = re.compile(r'^ {0,3}\[([^\]\n]+)\]:\s*(<[^>\n]*>|\S+)', re.MULTILINE)
# [text][label], [label][] and a shortcut [label] that is not a definition.
REFERENCE_USE = re.compile(r'\[([^\]\n]+)\](?:\[([^\]\n]*)\]|(?![(:\[]))')
INDEX_ROW = re.compile(r'^\| \[(\d{4})\]\(([^)]+)\) \| (.+?) \| (\S+) \| (\S+) \| (\S+) \|$')
FENCE = re.compile(r'^```.*?^```', re.MULTILINE | re.DOTALL)
CODE_SPAN = re.compile(r'`[^`\n]*`')


def prose(text):
    return CODE_SPAN.sub('', FENCE.sub('', text))


def inline_targets(text):
    """Destinations of inline links and images: a <...> destination, or one
    with backslash escapes and balanced parentheses at any depth."""
    targets = []
    for start in (m.end() for m in re.finditer(r'\]\(', text)):
        index = start
        while index < len(text) and text[index] in ' \t\n':
            index += 1
        if text.startswith('<', index):
            end = text.find('>', index)
            if end != -1 and '\n' not in text[index:end]:
                targets.append(text[index:end + 1])
            continue
        depth, end = 0, index
        while end < len(text):
            character = text[end]
            if character == '\\' and end + 1 < len(text):
                end += 2
                continue
            if character.isspace() or (character == ')' and depth == 0):
                break
            depth += {'(': 1, ')': -1}.get(character, 0)
            end += 1
        if end > index:
            targets.append(text[index:end])
    return targets


def label_key(label):
    """Reference labels match case-insensitively, with whitespace collapsed."""
    return ' '.join(label.split()).lower()


def references(text):
    """Reference definitions by label; the first definition of a label wins."""
    definitions = {}
    for label, target in REFERENCE.findall(prose(text)):
        definitions.setdefault(label_key(label), target)
    return definitions


def paths(targets):
    """The targets that are relative paths, unescaped, without fragments."""
    for target in targets:
        if target.startswith('<') and target.endswith('>'):
            target = target[1:-1].strip()
        else:
            target = re.sub(r'\\(.)', r'\1', target)
        if not target or target.startswith('#') or re.match(r'^[a-z][a-z0-9+.-]*:', target, re.IGNORECASE):
            continue
        yield unquote(re.split(r'[?#]', target, maxsplit=1)[0])


def relative_links(text):
    """Every relative path a document links, inline or by reference definition."""
    return paths(inline_targets(prose(text)) + [target for _, target in REFERENCE.findall(prose(text))])


def used_links(section, definitions):
    """Relative paths a section links, inline or through the document's definitions."""
    text = prose(section)
    used = [definitions[label_key(label or text_label)]
            for text_label, label in REFERENCE_USE.findall(text)
            if label_key(label or text_label) in definitions]
    return paths(inline_targets(text) + used)


def resolve(root, source, target):
    """The path a relative link names, or None when it leaves the repository."""
    path = (source.parent / target).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return None
    return path


def ids(value):
    return [] if value == 'none' else value.split(', ')


def parse(path, problems):
    """One record's title, fields and sections, or None when unreadable."""
    name = path.name
    lines = path.read_text().splitlines()
    title = TITLE.match(lines[0]) if lines else None
    if title is None:
        problems.append(f'{name}: first line is not "# NNNN: Title"')
        return None
    fields = {}
    index = 1
    while index < len(lines) and not lines[index].strip():
        index += 1
    while index < len(lines) and lines[index].startswith('- '):
        field = FIELD.match(lines[index])
        if field is None:
            problems.append(f'{name}: front-matter line is not "- Field: value": {lines[index]!r}')
        elif field.group(1) in fields:
            problems.append(f'{name}: field {field.group(1)!r} appears twice')
        else:
            fields[field.group(1)] = field.group(2).strip()
        index += 1
    if list(fields) != FIELDS:
        problems.append(f'{name}: front matter must be exactly {", ".join(FIELDS)} in that order; found {", ".join(fields) or "nothing"}')
    sections, current = {}, None
    for line in lines[index:]:
        if line.startswith('## '):
            current = line[3:].strip()
            if current in sections:
                problems.append(f'{name}: section {current!r} appears twice')
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    if list(sections) != SECTIONS:
        problems.append(f'{name}: sections must be {", ".join(SECTIONS)} in that order; found {", ".join(sections) or "none"}')
    return {'id': title.group(1), 'title': title.group(2).strip(), 'fields': fields,
            'sections': {k: '\n'.join(v) for k, v in sections.items()}, 'text': '\n'.join(lines)}


def check_fields(name, record, problems):
    fields = record['fields']
    date = fields.get('Date', '')
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        problems.append(f'{name}: Date {date!r} is not YYYY-MM-DD')
    decision = DECISION.match(fields.get('Decision', ''))
    record['decision'] = decision.group(1) if decision else None
    if decision is None or decision.group(1) not in DECISIONS:
        problems.append(f'{name}: Decision must be one of {sorted(DECISIONS)}, optionally with "(source)"; found {fields.get("Decision")!r}')
    elif decision.group(1) in ('accepted', 'superseded'):
        source = decision.group(2) or ''
        if not (SOURCE_DATE.search(source) and SOURCE_REFERENCE.search(source)):
            problems.append(f'{name}: an {decision.group(1)} decision names its authorization with a date and an issue, PR or commit, as "(owner, YYYY-MM-DD, #N)"')
    if fields.get('Implementation') not in IMPLEMENTATIONS:
        problems.append(f'{name}: Implementation must be one of {sorted(IMPLEMENTATIONS)}; found {fields.get("Implementation")!r}')
    if fields.get('Validation') not in VALIDATIONS:
        problems.append(f'{name}: Validation must be one of {sorted(VALIDATIONS)}; found {fields.get("Validation")!r}')
    for field in ('Supersedes', 'Superseded by'):
        value = fields.get(field, '')
        if value != 'none' and not ID_LIST.match(value):
            problems.append(f'{name}: {field} must be "none" or IDs like "0001, 0002"; found {value!r}')
            fields[field] = 'none'


def check_supersession(records, problems):
    for record_id, record in records.items():
        name = record['file']
        supersedes = ids(record['fields']['Supersedes'])
        successors = ids(record['fields']['Superseded by'])
        for other in supersedes + successors:
            if other == record_id:
                problems.append(f'{name}: names itself in its supersession links')
            elif other not in records:
                problems.append(f'{name}: names {other}, which has no record')
        for other in supersedes:
            if other in records and record_id not in ids(records[other]['fields']['Superseded by']):
                problems.append(f'{name}: supersedes {other}, but {other} is not "Superseded by: {record_id}"')
        for other in successors:
            if other in records and record_id not in ids(records[other]['fields']['Supersedes']):
                problems.append(f'{name}: is superseded by {other}, but {other} does not list it in Supersedes')
        if (record['decision'] == 'superseded') != bool(successors):
            problems.append(f'{name}: a record is superseded exactly when it names its successor in "Superseded by"')
    state = {}

    def visit(record_id, trail):
        state[record_id] = 'visiting'
        for other in ids(records[record_id]['fields']['Supersedes']):
            if other not in records or other == record_id:
                continue
            if state.get(other) == 'visiting':
                problems.append(f'supersession cycle: {" -> ".join(trail + [record_id, other])}')
            elif other not in state:
                visit(other, trail + [record_id])
        state[record_id] = 'done'

    for record_id in sorted(records):
        if record_id not in state:
            visit(record_id, [])


def check_evidence(root, path, record, problems):
    name = path.name
    if record['fields'].get('Implementation') not in ('partial', 'implemented'):
        return
    evidence = record['sections'].get('Implementation evidence', '')
    docs = (root / 'docs').resolve()
    outside = []
    for target in used_links(evidence, references(record['text'])):
        resolved = resolve(root, path, target)
        if resolved is not None and resolved.exists() and resolved != docs and docs not in resolved.parents:
            outside.append(target)
    if not outside:
        problems.append(f'{name}: {record["fields"]["Implementation"]} needs an Implementation evidence link to a file outside docs/')
    if not re.search(r'^Does not prove: \S', evidence, re.MULTILINE):
        problems.append(f'{name}: Implementation evidence needs a "Does not prove: ..." line')


def check_index(directory, records, problems):
    readme = directory / 'README.md'
    if not readme.is_file():
        problems.append('docs/decisions/README.md is missing')
        return
    rows = {}
    for line in readme.read_text().splitlines():
        row = INDEX_ROW.match(line)
        if row is None:
            continue
        record_id, link, title, decision, implementation, validation = row.groups()
        if record_id in rows:
            problems.append(f'README.md: {record_id} has more than one index row')
        rows[record_id] = (link, title, decision, implementation, validation)
    for record_id in sorted(set(rows) - set(records)):
        problems.append(f'README.md: index row {record_id} has no record')
    for record_id, record in sorted(records.items()):
        if record_id not in rows:
            problems.append(f'README.md: no index row for {record["file"]}')
            continue
        link, title, decision, implementation, validation = rows[record_id]
        expected = (record['file'], record['title'], record['decision'],
                    record['fields'].get('Implementation'), record['fields'].get('Validation'))
        labels = ('link', 'title', 'decision', 'implementation', 'validation')
        for label, found, wanted in zip(labels, (link, title, decision, implementation, validation), expected):
            if found != wanted:
                problems.append(f'README.md: index {label} for {record_id} is {found!r}, record says {wanted!r}')


def git(root, *arguments):
    return subprocess.run(['git', '-C', str(root), *arguments], capture_output=True, text=True)


def check_history(root, require_history):
    """Records deleted in any commit must be back, with the same ID and title."""
    try:
        top = git(root, 'rev-parse', '--show-toplevel')
        shallow = git(root, 'rev-parse', '--is-shallow-repository')
    except FileNotFoundError:
        top = shallow = None
    if (top is None or top.returncode != 0 or Path(top.stdout.strip()).resolve() != root.resolve()
            or shallow.returncode != 0 or shallow.stdout.strip() != 'false'):
        if require_history:
            return ['no full git history to check that IDs are never reused (CI needs fetch-depth: 0)']
        return []
    # -m with --full-history diffs a merge against each parent, so a record
    # dropped while merging counts too; %P names the parents to read it from.
    log = git(root, 'log', '--full-history', '-m', '--no-renames', '--diff-filter=D', '--format=@%H %P',
              '--name-only', '--', 'docs/decisions')
    if log.returncode != 0:
        return [f'git log failed: {log.stderr.strip()}']
    problems, reported, commit, parents = [], set(), None, []
    for line in log.stdout.splitlines():
        if line.startswith('@'):
            commit, *parents = line[1:].split()
            continue
        path = Path(line)
        name = FILENAME.match(path.name)
        if not line or name is None or path.parent != Path('docs/decisions') or (commit, line) in reported:
            continue
        reported.add((commit, line))
        # The ID still in that commit's tree is a slug rename; like any
        # in-place edit, whether it is still the same decision is review's call.
        if title_in_tree(root, commit, name.group(1)) is not None:
            continue
        title = None
        for parent in parents:
            before = git(root, 'show', f'{parent}:{line}')
            first = before.stdout.splitlines()[0] if before.returncode == 0 and before.stdout else ''
            title = TITLE.match(first)
            if title:
                break
        # Gone from the tree: the first later commit that has the ID again must
        # restore the same title. Corrections after that are in-place edits.
        restored = None
        later = git(root, 'rev-list', '--reverse', '--ancestry-path', f'{commit}..HEAD')
        for revision in later.stdout.split():
            restored = title_in_tree(root, revision, name.group(1))
            if restored is not None:
                break
        if title is None or restored != title.group(2).strip():
            was = f' ("{title.group(2).strip()}")' if title else ''
            problems.append(f'{line}{was} was deleted in {commit[:7]}; records are never deleted and '
                            f'ID {name.group(1)} must not be reused, so restore it')
    return problems


def title_in_tree(root, revision, record_id):
    """The title of record `record_id` in a commit's tree, or None without one."""
    tree = git(root, 'ls-tree', '--name-only', revision, 'docs/decisions/')
    for entry in tree.stdout.splitlines():
        match = FILENAME.match(Path(entry).name)
        if match and match.group(1) == record_id:
            shown = git(root, 'show', f'{revision}:{entry}')
            title = TITLE.match(shown.stdout.splitlines()[0]) if shown.stdout else None
            return title.group(2).strip() if title else ''
    return None


def check(root, require_history=False):
    problems = []
    directory = root / 'docs' / 'decisions'
    if not directory.is_dir():
        return ['docs/decisions/ is missing']
    records = {}
    for path in sorted(directory.iterdir()):
        if path.name in NOT_RECORDS or path.name.startswith('.'):
            continue
        name_match = FILENAME.match(path.name)
        if not path.is_file() or name_match is None:
            problems.append(f'{path.name}: not a record; records are NNNN-lowercase-slug.md')
            continue
        record = parse(path, problems)
        if record is None:
            continue
        if record['id'] != name_match.group(1):
            problems.append(f'{path.name}: title ID {record["id"]} does not match the file name')
        record_id = name_match.group(1)
        if record_id in records:
            problems.append(f'{path.name}: ID {record_id} is already used by {records[record_id]["file"]}')
            continue
        record['file'] = path.name
        check_fields(path.name, record, problems)
        check_evidence(root, path, record, problems)
        records[record_id] = record
    expected = [f'{n:04d}' for n in range(1, len(records) + 1)]
    if sorted(records) != expected:
        problems.append(f'record IDs must run from 0001 with no gap; found {", ".join(sorted(records))}')
    check_supersession(records, problems)
    check_index(directory, records, problems)
    problems.extend(check_history(root, require_history))
    for path in sorted(directory.glob('*.md')):
        for target in relative_links(path.read_text()):
            resolved = resolve(root, path, target)
            if resolved is None:
                problems.append(f'{path.name}: link {target!r} leaves the repository')
            elif not resolved.exists():
                problems.append(f'{path.name}: link {target!r} does not resolve')
    return problems


if __name__ == '__main__':
    arguments = sys.argv[1:]
    require_history = '--require-history' in arguments
    arguments = [a for a in arguments if a != '--require-history']
    root = Path(arguments[0] if arguments else Path(__file__).resolve().parent.parent)
    problems = check(root, require_history=require_history)
    for problem in problems:
        print(f'FAIL: {problem}', file=sys.stderr)
    if problems:
        sys.exit(1)
    print('PASS: decision records, index and supersession links are consistent')
