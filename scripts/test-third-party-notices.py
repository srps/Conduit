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
    for name, files in (('alpha', {'LICENSE.txt': 'A', 'NOTICE.txt': 'N'}), ('beta', {'LICENSE': 'B'})):
        vendored = root / 'Resources' / 'ThirdPartyLicenses' / name
        checkout = root / '.build' / 'checkouts' / name.capitalize()
        vendored.mkdir(parents=True)
        checkout.mkdir(parents=True)
        for file, text in files.items():
            (vendored / file).write_text(text)
            (checkout / file).write_text(text)


def vendored(root, name):
    return root / 'Resources' / 'ThirdPartyLicenses' / name


mutations = [
    ('missing vendored directory', lambda r: shutil.rmtree(vendored(r, 'beta'))),
    ('no license file', lambda r: (vendored(r, 'beta') / 'LICENSE').unlink()),
    ('missing NOTICE entry', lambda r: (r / 'NOTICE').write_text('ThirdPartyLicenses/alpha/\n')),
    ('stale vendored directory', lambda r: vendored(r, 'gamma').mkdir()),
    ('upstream NOTICE not vendored', lambda r: (vendored(r, 'alpha') / 'NOTICE.txt').unlink()),
    ('vendored text differs from checkout', lambda r: (vendored(r, 'alpha') / 'LICENSE.txt').write_text('old')),
    ('bundle stops copying', lambda r: (r / 'bundle-app.sh').write_text('')),
]


def run(root):
    return subprocess.run([sys.executable, str(script), str(root)], capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='conduit-notices-') as directory:
    base = Path(directory) / 'base'
    base.mkdir()
    make_tree(base)
    result = run(base)
    assert result.returncode == 0, ('passing tree failed', result.stderr)
    shutil.rmtree(base / '.build')
    assert run(base).returncode == 0, 'a tree without checkouts must still pass'
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
