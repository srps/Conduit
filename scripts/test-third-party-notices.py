#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixtures for check-third-party-notices.py: a passing tree, then one
mutation per failure the check exists to catch."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(__file__).with_name('check-third-party-notices.py')


def make_tree(root):
    (root / 'Package.resolved').write_text(json.dumps({'pins': [{'identity': 'alpha'}, {'identity': 'beta'}]}))
    (root / 'NOTICE').write_text('ThirdPartyLicenses/alpha/\nThirdPartyLicenses/beta/\n')
    (root / 'bundle-app.sh').write_text(
        'cp "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/NOTICE" "$CONTENTS/Resources/"\n'
        'cp -R "$SCRIPT_DIR/Resources/ThirdPartyLicenses" "$CONTENTS/Resources/"\n')
    for name, files in (('alpha', {'LICENSE.txt': 'A', 'NOTICE.txt': 'N', 'Sources/CPart/LICENSE': 'C'}),
                        ('beta', {'LICENSE': 'B'})):
        vendored = root / 'Resources' / 'ThirdPartyLicenses' / name
        checkout = root / '.build' / 'checkouts' / name.capitalize()
        for file, text in files.items():
            for base in (vendored, checkout):
                (base / file).parent.mkdir(parents=True, exist_ok=True)
                (base / file).write_text(text)
        (checkout / '.git').mkdir()
        (checkout / '.git' / 'LICENSE-ignored').write_text('not shipped')


def vendored(root, name):
    return root / 'Resources' / 'ThirdPartyLicenses' / name


def only_nested_license(root):
    # Without a checkout to compare against, the top-level rule alone must
    # catch a package whose only license sits in a subdirectory.
    shutil.rmtree(root / '.build' / 'checkouts' / 'Beta')
    (vendored(root, 'beta') / 'sub').mkdir()
    (vendored(root, 'beta') / 'LICENSE').rename(vendored(root, 'beta') / 'sub' / 'LICENSE')


mutations = [
    ('missing vendored directory', lambda r: shutil.rmtree(vendored(r, 'beta'))),
    ('no license file', lambda r: (vendored(r, 'beta') / 'LICENSE').unlink()),
    ('missing NOTICE entry', lambda r: (r / 'NOTICE').write_text('ThirdPartyLicenses/alpha/\n')),
    ('stale vendored directory', lambda r: vendored(r, 'gamma').mkdir()),
    ('upstream NOTICE not vendored', lambda r: (vendored(r, 'alpha') / 'NOTICE.txt').unlink()),
    ('vendored text differs from checkout', lambda r: (vendored(r, 'alpha') / 'LICENSE.txt').write_text('old')),
    ('nested component license not vendored', lambda r: (vendored(r, 'alpha') / 'Sources/CPart/LICENSE').unlink()),
    ('nested component license differs', lambda r: (vendored(r, 'alpha') / 'Sources/CPart/LICENSE').write_text('old')),
    ('only a nested license, none at the top', only_nested_license),
    ('bundle stops copying', lambda r: (r / 'bundle-app.sh').write_text('')),
]


def run(root, *flags):
    return subprocess.run([sys.executable, str(script), *flags, str(root)], capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='conduit-notices-') as directory:
    base = Path(directory) / 'base'
    base.mkdir()
    make_tree(base)
    result = run(base)
    assert result.returncode == 0, ('passing tree failed', result.stderr)
    assert run(base, '--require-checkouts').returncode == 0, 'checkouts present'
    shutil.rmtree(base / '.build')
    assert run(base).returncode == 0, 'a tree without checkouts must still pass'
    assert run(base, '--require-checkouts').returncode != 0, 'bundling without checkouts must fail'
    for label, mutate in mutations:
        root = Path(directory) / label.replace(' ', '-')
        root.mkdir()
        make_tree(root)
        mutate(root)
        result = run(root)
        assert result.returncode != 0, (label, result.stdout)

repository = run(script.resolve().parent.parent)
assert repository.returncode == 0, ('repository', repository.stderr)
print(f'PASS: notices check accepts the repository and a fixture tree, rejects {len(mutations)} mutations')
