#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
kernel_dir="${1:-$(cd "$(dirname "$0")/.." && pwd)/Sources/ProxyKernel}"
python3 - "$kernel_dir" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(root.rglob('*.swift'))
if not files:
    sys.exit(f'No Swift sources found in {root}')

# Ignore comments and literals when finding imports. Keep newlines for locations.
# Nested Swift block comments and raw/multiline strings are handled explicitly.
literal_start = re.compile(r'(\#*)("""|")')

def code_only(source):
    chars = list(source)
    index = 0
    def erase(start, end):
        for pos in range(start, end):
            if chars[pos] != '\n':
                chars[pos] = ' '
    while index < len(source):
        start = index
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end
        elif source.startswith('/*', index):
            index += 2
            depth = 1
            while index < len(source) and depth:
                if source.startswith('/*', index):
                    depth += 1
                    index += 2
                elif source.startswith('*/', index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            literal = literal_start.match(source, index)
            if not literal:
                index += 1
                continue
            hashes, quotes = literal.groups()
            index += len(literal.group())
            closing = quotes + hashes
            while index < len(source) and not source.startswith(closing, index):
                if source.startswith('\\' + hashes, index):
                    index += len(hashes) + 2
                else:
                    index += 1
            index = min(len(source), index + len(closing))
        erase(start, index)
    return ''.join(chars)

allowed = {'Foundation', 'Dispatch', 'Darwin', 'Glibc', 'ConduitShared'}
imports = re.compile(r'\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([^\s.;{}]+)')
failed = False
for file in files:
    source = file.read_text()
    code = code_only(source)
    for match in imports.finditer(code):
        module = match.group(1).strip('`')
        if module not in allowed and not module.startswith('NIO'):
            line = code.count('\n', 0, match.start()) + 1
            print(f'{file}:{line}: forbidden kernel import: {module}', file=sys.stderr)
            failed = True
    # Conservative source fence, including literals/interpolations: process
    # creation belongs behind a platform protocol, never in the kernel.
    for match in re.finditer(r'\bProcess\s*(?:\.\s*init\s*)?\(', source):
        line = source.count('\n', 0, match.start()) + 1
        print(f'{file}:{line}: forbidden kernel Process construction', file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
print(f'Kernel import/Process fence passed ({len(files)} Swift files)')
PY
