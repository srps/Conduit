#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check that the shipped license notices cover every pinned dependency (#187).

Every package in Package.resolved needs its license (and NOTICE, if it has
one) vendored verbatim under Resources/ThirdPartyLicenses/<package>/ and an
entry in NOTICE; no vendored directory may outlive its pin; bundle-app.sh must
copy the files into the app. When SwiftPM checkouts exist (after a build), the
vendored texts must match them byte for byte, so a dependency bump that
changes its license fails here instead of shipping the old text.

Usage: check-third-party-notices.py [ROOT]
"""
import json
import sys
from pathlib import Path

NOTICE_NAMES = ('LICENSE', 'LICENSE.txt', 'LICENSE.md', 'NOTICE', 'NOTICE.txt', 'NOTICE.md')


def notice_files(directory):
    return {p.name for p in directory.iterdir() if p.is_file() and p.name in NOTICE_NAMES}


def check(root):
    problems = []
    pins = {pin['identity'] for pin in json.loads((root / 'Package.resolved').read_text())['pins']}
    vendored_root = root / 'Resources' / 'ThirdPartyLicenses'
    vendored = {p.name for p in vendored_root.iterdir() if p.is_dir()} if vendored_root.is_dir() else set()
    notice = (root / 'NOTICE').read_text() if (root / 'NOTICE').is_file() else ''
    checkouts = root / '.build' / 'checkouts'
    checkout_dirs = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()} if checkouts.is_dir() else {}

    for pin in sorted(pins):
        directory = vendored_root / pin
        if pin not in vendored:
            problems.append(f'{pin}: no Resources/ThirdPartyLicenses/{pin}/')
            continue
        files = notice_files(directory)
        if not any(name.startswith('LICENSE') for name in files):
            problems.append(f'{pin}: Resources/ThirdPartyLicenses/{pin}/ has no LICENSE file')
        if f'ThirdPartyLicenses/{pin}/' not in notice:
            problems.append(f'{pin}: NOTICE does not list ThirdPartyLicenses/{pin}/')
        checkout = checkout_dirs.get(pin)
        if checkout is None:
            continue
        upstream = notice_files(checkout)
        for name in sorted(upstream - files):
            problems.append(f'{pin}: checkout has {name}, not vendored')
        for name in sorted(upstream & files):
            if (checkout / name).read_bytes() != (directory / name).read_bytes():
                problems.append(f'{pin}: vendored {name} differs from the checkout; re-copy it')
    for stale in sorted(vendored - pins):
        problems.append(f'{stale}: vendored but not pinned in Package.resolved')

    bundle = (root / 'bundle-app.sh').read_text() if (root / 'bundle-app.sh').is_file() else ''
    for needle in ('"$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/NOTICE"', '"$SCRIPT_DIR/Resources/ThirdPartyLicenses"'):
        if needle not in bundle:
            problems.append(f'bundle-app.sh does not copy {needle}')
    return problems


if __name__ == '__main__':
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
    problems = check(root)
    for problem in problems:
        print(f'FAIL: {problem}', file=sys.stderr)
    if problems:
        sys.exit(1)
    print('PASS: every pinned dependency has vendored license text, a NOTICE entry and a bundle copy')
