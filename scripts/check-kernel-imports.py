#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""ProxyKernel import and Process fence.

The Swift compiler does the parsing: `-emit-imported-modules` lists what each
file imports with `#if` evaluated for the build target, and `-dump-parse`
shows every identifier outside comments and string text. A file the compiler
cannot parse fails the fence. Needs `xcrun swiftc` (set DEVELOPER_DIR).
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / 'Sources' / 'ProxyKernel'
files = sorted(root.rglob('*.swift'))
if not files:
    sys.exit(f'No Swift sources found in {root}')

# The NIO products ProxyKernel links in Package.swift, by name: a prefix
# match would admit NIOTransportServices, which brings in Network.
allowed = {
    'Foundation', 'Dispatch', 'Darwin', 'Glibc', 'ConduitShared',
    'NIOCore', 'NIOPosix', 'NIOHTTP1', 'NIOConcurrencyHelpers',
}
# The package builds in Swift 6 mode, which changes what parses as a regex.
language_mode = ['-swift-version', '6']
# Any identifier `Process` (`name=`, `field=`, `id=`, a declaration or a
# module selector), but not a string's `value=`.
process_reference = re.compile(r'(?<!value=)"(?:\w+::)?Process"')
dump_location = re.compile(r'range=\[[^\]]*?:(\d+):\d+')

def compile_step(arguments, file):
    command = ['xcrun', 'swiftc'] + arguments + language_mode + [str(file)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print(f'{file}: the compiler could not parse it\n{result.stderr}', file=sys.stderr)
        return None
    return result.stdout

failed = False
for file in files:
    imported = compile_step(['-frontend', '-emit-imported-modules', '-o', '-'], file)
    dump = compile_step(['-dump-parse'], file)
    if imported is None or dump is None:
        failed = True
        continue
    for module in imported.split():
        if module not in allowed:
            print(f'{file}: forbidden kernel import: {module}', file=sys.stderr)
            failed = True
    # The kernel never names Process, so no spelling of a construction
    # (`.init`, `.self.init`, backticks, `Foundation::`, a typealias) passes.
    for match in process_reference.finditer(dump):
        # The dump gives ranges per declaration or statement, not per name.
        lines = dump_location.findall(dump, 0, match.start())
        near = f' near line {lines[-1]}' if lines else ''
        print(f'{file}: forbidden kernel Process reference{near}', file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
print(f'Kernel import/Process fence passed ({len(files)} Swift files)')
