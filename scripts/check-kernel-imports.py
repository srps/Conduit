#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""ProxyKernel import and Process fence. Run after `swift build`.

The compiler does the parsing, so no Swift syntax can hide code from it:

- Imports: `swiftc -frontend -emit-imported-modules` lists each file's
  imports with `#if` evaluated, once per configuration SwiftPM builds.
- Process: `Sources/ProxyKernel/Support/ProcessUnavailable.swift` makes an
  unqualified `Process` a compile error. A qualified `Foundation.Process`
  still compiles, so the built kernel object must not reference NSTask.

A file the compiler cannot parse fails. Needs `xcrun` (set DEVELOPER_DIR).
Usage: check-kernel-imports.py [SOURCE_DIR] [--configuration debug|release]
                               [--objects OBJECT...]
Without --objects, checks the kernel object of that configuration's build.
"""
import re
import subprocess
import sys
from pathlib import Path

repository = Path(__file__).resolve().parent.parent
arguments = sys.argv[1:]
objects = None
configuration = 'debug'
if '--objects' in arguments:
    split = arguments.index('--objects')
    arguments, objects = arguments[:split], [Path(o) for o in arguments[split + 1:]]
if '--configuration' in arguments:
    split = arguments.index('--configuration')
    configuration = arguments[split + 1]
    del arguments[split:split + 2]
root = Path(arguments[0]) if arguments else repository / 'Sources' / 'ProxyKernel'
files = sorted(root.rglob('*.swift'))
if not files:
    sys.exit(f'No Swift sources found in {root}')

# The NIO products ProxyKernel links in Package.swift, by name: a prefix
# match would admit NIOTransportServices, which brings in Network.
allowed = {
    'Foundation', 'Dispatch', 'Darwin', 'Glibc', 'ConduitShared',
    'NIOCore', 'NIOPosix', 'NIOHTTP1', 'NIOConcurrencyHelpers',
}
# The compilation conditions of SwiftPM's debug and release builds, in the
# package's Swift 6 language mode.
configurations = {
    'debug': ['-D', 'SWIFT_PACKAGE', '-D', 'DEBUG'],
    'release': ['-D', 'SWIFT_PACKAGE'],
}
if '.define(' in (repository / 'Package.swift').read_text():
    sys.exit('Package.swift defines compilation conditions; add them to the fence configurations')

failed = False
for file in files:
    for name, defines in configurations.items():
        command = ['xcrun', 'swiftc', '-frontend', '-emit-imported-modules', '-swift-version', '6',
                   *defines, '-o', '-', str(file)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(f'{file}: the compiler could not parse it ({name})\n{result.stderr}', file=sys.stderr)
            failed = True
            continue
        for module in result.stdout.split():
            if module not in allowed:
                print(f'{file}: forbidden kernel import ({name}): {module}', file=sys.stderr)
                failed = True

if objects is None:
    bin_path = subprocess.run(['xcrun', 'swift', 'build', '-c', configuration, '--show-bin-path'], cwd=repository,
                              capture_output=True, text=True, check=True).stdout.strip()
    objects = [Path(bin_path) / 'ProxyKernel.o'] + sorted(Path(bin_path).glob('ProxyKernel.build/*.o'))
    objects = [o for o in objects if o.exists()]
    if not objects:
        sys.exit(f'No ProxyKernel object files under {bin_path}; run swift build -c {configuration} first')
for obj in objects:
    undefined = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
    if '_OBJC_CLASS_$_NSTask' in undefined.split():
        print(f'{obj}: the kernel references Foundation.Process (NSTask)', file=sys.stderr)
        failed = True

if failed:
    sys.exit(1)
print(f'Kernel import/Process fence passed ({len(files)} Swift files, {len(objects)} object files)')
