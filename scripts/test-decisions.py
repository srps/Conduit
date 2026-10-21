#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixtures for check-decisions.py: a passing tree, then one mutation per
failure the check exists to catch (#177)."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(__file__).with_name('check-decisions.py')

SECTIONS = """
## Context

Why.

## Decision

What.

## Alternatives

None credible.

## Consequences

Some.

## Invariants and verification

A test.

## Implementation evidence

{evidence}

## Open questions

None.
"""

EVIDENCE = """See [the code](../../Sources/Thing.swift) and [the design](../design.md).

Does not prove: behaviour on a real machine."""


def record(record_id, title, decision, implementation, validation, supersedes='none', superseded_by='none',
           evidence=EVIDENCE, tail=''):
    return (f'# {record_id}: {title}\n\n- Date: 2026-01-0{int(record_id)}\n- Decision: {decision}\n'
            f'- Implementation: {implementation}\n- Validation: {validation}\n'
            f'- Supersedes: {supersedes}\n- Superseded by: {superseded_by}\n' + SECTIONS.format(evidence=evidence)
            + tail)


# Evidence by reference, defined at the end of the document.
REFERENCE_EVIDENCE = 'See [the code][code  label].\n\nDoes not prove: behaviour on a real machine.'
REFERENCE_TAIL = '\n[Code Label]: ../../Sources/Thing.swift\n'


def make_tree(root):
    decisions = root / 'docs' / 'decisions'
    decisions.mkdir(parents=True)
    (root / 'Sources').mkdir()
    (root / 'Sources' / 'Thing.swift').write_text('// thing\n')
    (root / 'Sources' / 'Thing(1).swift').write_text('// thing\n')
    (root / 'docs' / 'design.md').write_text('# Design\n')
    # Every link form the check reads, all resolving.
    (decisions / 'template.md').write_text(
        '# NNNN: Decision title\n\n[index](README.md), [titled](README.md "Index"), [angled](<README.md>),\n'
        '![image](../design.md), [encoded](../design%2Emd), [anchor](#index), [line](../design.md?plain=1#L1),\n'
        '[site](https://example.com/x),\n'
        '[parenthesized](../../Sources/Thing(1).swift), [escaped](../../Sources/Thing\\(1\\).swift)\n'
        'and [a reference][ref].\n\n[ref]: README.md\n')
    (decisions / '0001-new-way.md').write_text(record(
        '0001', 'The new way', 'accepted (owner, 2026-01-01, #1)', 'implemented', 'pending', supersedes='0002'))
    (decisions / '0002-old-way.md').write_text(record(
        '0002', 'The old way',
        'superseded (owner, 2026-01-02, https://github.com/example/repo/pull/2; superseded 2026-01-03)',
        'partial', 'none', superseded_by='0001', evidence=REFERENCE_EVIDENCE, tail=REFERENCE_TAIL))
    (decisions / '0003-later.md').write_text(record(
        '0003', 'Something later', 'proposed', 'planned', 'none', evidence='None yet.'))
    (decisions / 'README.md').write_text(
        '# Decision records\n\nSee [the template](template.md).\n\n'
        '| ID | Title | Decision | Implementation | Validation |\n| --- | --- | --- | --- | --- |\n'
        '| [0001](0001-new-way.md) | The new way | accepted | implemented | pending |\n'
        '| [0002](0002-old-way.md) | The old way | superseded | partial | none |\n'
        '| [0003](0003-later.md) | Something later | proposed | planned | none |\n')


def edit(root, name, old, new):
    path = root / 'docs' / 'decisions' / name
    text = path.read_text()
    assert old in text, (name, old)
    path.write_text(text.replace(old, new))


def rename(root, old, new):
    directory = root / 'docs' / 'decisions'
    (directory / old).rename(directory / new)


def gap(root):
    rename(root, '0003-later.md', '0004-later.md')
    edit(root, '0004-later.md', '# 0003:', '# 0004:')
    edit(root, 'README.md', '[0003](0003-later.md)', '[0004](0004-later.md)')


def cycle(root):
    edit(root, '0001-new-way.md', 'Decision: accepted', 'Decision: superseded')
    edit(root, '0001-new-way.md', 'Superseded by: none', 'Superseded by: 0002')
    edit(root, '0002-old-way.md', 'Supersedes: none', 'Supersedes: 0001')
    edit(root, 'README.md', '| The new way | accepted |', '| The new way | superseded |')


def extra_index_row(root):
    edit(root, 'README.md', '| Something later | proposed | planned | none |\n',
         '| Something later | proposed | planned | none |\n| [0004](0004-x.md) | X | proposed | planned | none |\n')


# (label, text the failure must contain, mutation)
mutations = [
    ('bad decision status', 'Decision must be one of',
     lambda r: edit(r, '0001-new-way.md', 'Decision: accepted', 'Decision: approved')),
    ('bad implementation status', 'Implementation must be one of',
     lambda r: edit(r, '0003-later.md', 'Implementation: planned', 'Implementation: done')),
    ('bad validation status', 'Validation must be one of',
     lambda r: edit(r, '0001-new-way.md', 'Validation: pending', 'Validation: ok')),
    ('bad date', 'is not YYYY-MM-DD',
     lambda r: edit(r, '0003-later.md', 'Date: 2026-01-03', 'Date: 2026-13-03')),
    ('accepted without authorization', 'names its authorization',
     lambda r: edit(r, '0001-new-way.md', 'accepted (owner, 2026-01-01, #1)', 'accepted')),
    ('authorization without a reference', 'names its authorization',
     lambda r: edit(r, '0001-new-way.md', '(owner, 2026-01-01, #1)', '(owner, 2026-01-01)')),
    ('one-way supersession', 'does not list it in Supersedes',
     lambda r: edit(r, '0001-new-way.md', 'Supersedes: 0002', 'Supersedes: none')),
    ('successor does not list it', 'is not "Superseded by: 0001"',
     lambda r: edit(r, '0002-old-way.md', 'Superseded by: 0001', 'Superseded by: 0003')),
    ('superseded without a successor', 'superseded exactly when', lambda r: (
        edit(r, '0001-new-way.md', 'Supersedes: 0002', 'Supersedes: none'),
        edit(r, '0002-old-way.md', 'Superseded by: 0001', 'Superseded by: none'))),
    ('successor named but not superseded', 'superseded exactly when', lambda r: (
        edit(r, '0002-old-way.md', 'Decision: superseded', 'Decision: accepted'),
        edit(r, 'README.md', '| The old way | superseded |', '| The old way | accepted |'))),
    ('supersession names a missing record', 'names 0009, which has no record',
     lambda r: edit(r, '0003-later.md', 'Supersedes: none', 'Supersedes: 0009')),
    ('supersession cycle', 'supersession cycle', cycle),
    ('missing evidence', 'link to a file outside docs/',
     lambda r: edit(r, '0001-new-way.md', 'See [the code](../../Sources/Thing.swift) and ', 'See ')),
    ('evidence only under docs', 'link to a file outside docs/',
     lambda r: edit(r, '0002-old-way.md', '[Code Label]: ../../Sources/Thing.swift', '[Code Label]: ../design.md')),
    ('evidence reference without a definition', 'link to a file outside docs/',
     lambda r: edit(r, '0002-old-way.md', '[Code Label]: ../../Sources/Thing.swift', '')),
    ('a first definition under docs wins over a later one', 'link to a file outside docs/',
     lambda r: edit(r, '0002-old-way.md', '[Code Label]: ../../Sources/Thing.swift',
                    '[code label]: ../design.md\n[Code Label]: ../../Sources/Thing.swift')),
    ('broken nested parenthesized link', "'../../Sources/Missing(1(2)).swift' does not resolve",
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [gone](../../Sources/Missing(1(2)).swift).')),
    ('broken parenthesized link',"'../../Sources/Thing(2).swift' does not resolve",
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [gone](../../Sources/Thing(2).swift).')),
    ('evidence without what it does not prove', '"Does not prove: ..." line',
     lambda r: edit(r, '0001-new-way.md', 'Does not prove: behaviour on a real machine.', '')),
    ('broken link', "'../../Sources/Gone.swift' does not resolve",
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [gone](../../Sources/Gone.swift).')),
    ('broken link with a title', "'../../Sources/Gone.swift' does not resolve",
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [gone](../../Sources/Gone.swift "Gone").')),
    ('broken angled link', "'../../Sources/Gone.swift' does not resolve",
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [gone](<../../Sources/Gone.swift>).')),
    ('broken reference link', "'../../Sources/Gone.swift' does not resolve",
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [gone][g].\n\n[g]: ../../Sources/Gone.swift')),
    ('broken link in the index',"'templates.md' does not resolve",
     lambda r: edit(r, 'README.md', '[the template](template.md)', '[the template](templates.md)')),
    ('link leaves the repository', 'leaves the repository',
     lambda r: edit(r, '0003-later.md', 'None yet.', 'See [outside](../../../elsewhere.md).')),
    ('title ID differs from the file name', 'does not match the file name',
     lambda r: edit(r, '0003-later.md', '# 0003:', '# 0004:')),
    ('duplicate ID', 'is already used by',
     lambda r: shutil.copy(r / 'docs/decisions/0003-later.md', r / 'docs/decisions/0003-again.md')),
    ('gap in IDs', 'with no gap', gap),
    ('file name not NNNN-slug', 'not a record', lambda r: rename(r, '0003-later.md', '0003_Later.md')),
    ('unknown front-matter field', 'front matter must be exactly',
     lambda r: edit(r, '0003-later.md', '- Supersedes:', '- Owner: me\n- Supersedes:')),
    ('missing front-matter field', 'front matter must be exactly',
     lambda r: edit(r, '0003-later.md', '- Validation: none\n', '')),
    ('missing section', 'sections must be',
     lambda r: edit(r, '0003-later.md', '## Alternatives\n\nNone credible.\n', '')),
    ('index title differs', 'index title for 0001',
     lambda r: edit(r, 'README.md', '| The new way |', '| A new way |')),
    ('index status differs', 'index validation for 0001',
     lambda r: edit(r, 'README.md', '| implemented | pending |', '| implemented | passed |')),
    ('index link differs', 'index link for 0003',
     lambda r: edit(r, 'README.md', '[0003](0003-later.md)', '[0003](0002-old-way.md)')),
    ('index row missing', 'no index row for 0003-later.md',
     lambda r: edit(r, 'README.md', '| [0003](0003-later.md) | Something later | proposed | planned | none |\n', '')),
    ('index row without a record', 'index row 0004 has no record', extra_index_row),
]


def run(root, *flags):
    return subprocess.run([sys.executable, str(script), *flags, str(root)], capture_output=True, text=True)


def git(root, *arguments):
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    '-c', 'commit.gpgsign=false', *arguments], check=True, capture_output=True, text=True)


def commit(root, message):
    git(root, 'add', '-A')
    git(root, 'commit', '-q', '-m', message)


def git_tree(root):
    make_tree(root)
    git(root, 'init', '-q')
    commit(root, 'records')


def delete_later(root):
    (root / 'docs/decisions/0003-later.md').unlink()
    edit(root, 'README.md', '| [0003](0003-later.md) | Something later | proposed | planned | none |\n', '')
    commit(root, 'delete 0003')


def reuse_later(root):
    text = (root / 'docs/decisions/0003-later.md').read_text()
    delete_later(root)
    (root / 'docs/decisions/0003-other.md').write_text(text.replace('Something later', 'Something else'))
    with (root / 'docs/decisions/README.md').open('a') as index:
        index.write('| [0003](0003-other.md) | Something else | proposed | planned | none |\n')
    commit(root, 'reuse 0003')


def restore_later(root):
    text = (root / 'docs/decisions/0003-later.md').read_text()
    delete_later(root)
    (root / 'docs/decisions/0003-later.md').write_text(text)
    with (root / 'docs/decisions/README.md').open('a') as index:
        index.write('| [0003](0003-later.md) | Something later | proposed | planned | none |\n')
    commit(root, 'restore 0003')
    edit(root, '0003-later.md', '# 0003: Something later', '# 0003: Something later, corrected')
    edit(root, 'README.md', '| Something later |', '| Something later, corrected |')
    commit(root, 'correct the title of 0003')


def drop_while_merging(root):
    # A branch adds 0004; the merge commit drops it and its index row.
    git(root, 'checkout', '-q', '-b', 'side')
    (root / 'docs/decisions/0004-side.md').write_text(record('0004', 'A side decision', 'proposed', 'planned', 'none',
                                                             evidence='None yet.'))
    with (root / 'docs/decisions/README.md').open('a') as index:
        index.write('| [0004](0004-side.md) | A side decision | proposed | planned | none |\n')
    commit(root, 'add 0004')
    git(root, 'checkout', '-q', '-')
    git(root, 'merge', '-q', '--no-ff', '--no-commit', 'side')
    (root / 'docs/decisions/0004-side.md').unlink()
    edit(root, 'README.md', '| [0004](0004-side.md) | A side decision | proposed | planned | none |\n', '')
    commit(root, 'merge side without 0004')


def rename_slug(root):
    rename(root, '0003-later.md', '0003-renamed.md')
    edit(root, 'README.md', '[0003](0003-later.md)', '[0003](0003-renamed.md)')
    commit(root, 'rename 0003')
    edit(root, '0003-renamed.md', '# 0003: Something later', '# 0003: Something later, corrected')
    edit(root, 'README.md', '| Something later |', '| Something later, corrected |')
    commit(root, 'correct the title of 0003')


# (label, history change, whether the check passes)
history_cases = [
    ('history: a record deleted with its index row', delete_later, False),
    ('history: an ID reused for another decision', reuse_later, False),
    ('history: a record dropped in a merge', drop_while_merging, False),
    ('history: a deleted record restored, then the title corrected', restore_later, True),
    ('history: a slug renamed, then the title corrected', rename_slug, True),
]


with tempfile.TemporaryDirectory(prefix='conduit-decisions-') as directory:
    base = Path(directory) / 'base'
    make_tree(base)
    result = run(base)
    assert result.returncode == 0, ('passing tree failed', result.stderr)
    for label, expected, mutate in mutations:
        root = Path(directory) / label.replace(' ', '-')
        make_tree(root)
        mutate(root)
        result = run(root)
        assert result.returncode != 0, (label, result.stdout)
        assert expected in result.stderr, (label, expected, result.stderr)
    assert run(base).returncode == 0, 'a tree without git history passes without --require-history'
    result = run(base, '--require-history')
    assert result.returncode != 0 and 'no full git history' in result.stderr, ('--require-history', result.stderr)
    for label, change, passes in history_cases:
        root = Path(directory) / label.replace(' ', '-').replace(':', '')
        git_tree(root)
        assert run(root, '--require-history').returncode == 0, (label, 'before the change')
        change(root)
        result = run(root, '--require-history')
        assert (result.returncode == 0) == passes, (label, result.stderr)
        if not passes:
            assert 'must not be reused' in result.stderr, (label, result.stderr)

repository = run(script.resolve().parent.parent)
assert repository.returncode == 0, ('repository', repository.stderr)
print(f'PASS: decisions check accepts the repository and a fixture tree, rejects {len(mutations)} mutations, '
      f'and judges {len(history_cases)} history changes')
