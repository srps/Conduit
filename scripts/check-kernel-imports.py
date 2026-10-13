#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / 'Sources' / 'ProxyKernel'
files = sorted(root.rglob('*.swift'))
if not files:
    sys.exit(f'No Swift sources found in {root}')

# Blank comments, and literals unless `keep_literals`, keeping newlines for
# locations. Nested block comments, raw/multiline strings and extended regex
# literals (`#/…/#`) are handled explicitly. A comment or literal still open at
# the end of the file fails the fence: an unrecognised construct must not
# blank the code after it.
literal_start = re.compile(r'(\#*)("""|")|(\#+)/')

class Unterminated(Exception):
    pass

def code_only(source, keep_literals=False):
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
            if depth:
                raise Unterminated(source.count('\n', 0, start) + 1, 'block comment')
        else:
            literal = literal_start.match(source, index)
            if not literal:
                index += 1
                continue
            hashes, quotes, regex_hashes = literal.groups()
            index += len(literal.group())
            if regex_hashes:
                # Extended regex: no escape can hide the closing delimiter.
                closing, escape = '/' + regex_hashes, None
            else:
                closing, escape = quotes + hashes, '\\' + hashes
            while index < len(source) and not source.startswith(closing, index):
                if escape and source.startswith(escape, index):
                    index += len(escape) + 1
                else:
                    index += 1
            if index >= len(source):
                raise Unterminated(source.count('\n', 0, start) + 1, 'literal')
            index += len(closing)
            if keep_literals:
                continue
        erase(start, index)
    return ''.join(chars)

# The NIO products ProxyKernel links in Package.swift, by name: a prefix
# match would admit NIOTransportServices, which brings in Network.
allowed = {
    'Foundation', 'Dispatch', 'Darwin', 'Glibc', 'ConduitShared',
    'NIOCore', 'NIOPosix', 'NIOHTTP1', 'NIOConcurrencyHelpers',
}
imports = re.compile(r'\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([^\s.;{}]+)')
failed = False
for file in files:
    source = file.read_text()
    try:
        code = code_only(source)
        uncommented = code_only(source, keep_literals=True)
    except Unterminated as error:
        line, construct = error.args
        print(f'{file}:{line}: unterminated {construct}; cannot check the rest of the file', file=sys.stderr)
        failed = True
        continue
    for match in imports.finditer(code):
        module = match.group(1).strip('`')
        if module not in allowed:
            line = code.count('\n', 0, match.start()) + 1
            print(f'{file}:{line}: forbidden kernel import: {module}', file=sys.stderr)
            failed = True
    # Conservative fence, including literals/interpolations: process creation
    # belongs behind a platform protocol, never in the kernel. Comments are
    # blanked so `Process /* why */ ()` cannot split the match.
    for match in re.finditer(r'\bProcess\s*(?:\.\s*init\s*)?\(', uncommented):
        line = uncommented.count('\n', 0, match.start()) + 1
        print(f'{file}:{line}: forbidden kernel Process construction', file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
print(f'Kernel import/Process fence passed ({len(files)} Swift files)')
