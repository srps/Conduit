#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixtures for check-kernel-imports.py: each is parsed for imports and
compiled to an object for the Process check, the way the build would.

The RuntimeEvents fence (decision 0013) is checked the same way, through the
script's --runtime-events option, against a temporary directory: each fixture is
a file the compiler parses per configuration, so a conditional import is judged
in the debug and the release configuration separately."""
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(__file__).with_name('check-kernel-imports.py')
cases = [
    ('import Foundation\nimport Dispatch\nimport Darwin\nimport Glibc\n', True),
    ('/* import Security /* nested */ */\nlet text = #"import Network"#\nimport Foundation', True),
    ('#if os(macOS)\n  @preconcurrency import Security\n#endif', False),
    ('#if DEBUG\nimport Security\n#endif', False),
    ('#if !DEBUG\nimport Security\n#endif', False),
    ('#if NEVER\nimport Security\n#endif\nimport Foundation', True),
    ('@_exported import struct Security.SecKey', False),
    ('import UnlistedModule', False),
    ('import NIOTransportServices', False),
    ('import `Security`', False),
    ('let r = #/a/*b/#\nimport Security', False),
    ('/* never closed\nimport Security', False),
    ('import Foundation\nfunc f() -> Any { Foundation.Process() }', False),
    ('import Foundation\nfunc f() -> Any { Foundation::Process.self }', False),
    ('import Foundation\n#if os(macOS)\nfunc f() { _ = Process() }\n#endif', False),
    ('import Foundation\ntypealias Child = Process\nfunc f() -> Any { Child() }', False),
    ('import Foundation\nfunc f() -> Int { ProcessInfo.processInfo.processorCount }\nlet s = "Process()"', True),
]

# RuntimeEvents is Foundation-only: each fixture is one file in a directory that
# stands in for Sources/RuntimeEvents, next to a clean kernel directory. The
# expected message names the fence that must fire, so a fixture cannot pass by
# failing for another reason.
FORBIDDEN = 'forbidden RuntimeEvents import'
UNPARSEABLE = 'the compiler could not parse it'
runtime_cases = [
    ('Foundation only', {'Ok.swift': 'import Foundation\nstruct Ok {}\n'}, True, None),
    ('Foundation with an attribute', {'Ok.swift': '@preconcurrency import Foundation\n'}, True, None),
    ('Security in a comment and a string', {'Ok.swift': '// import Security\nlet t = "import NIOCore"\nimport Foundation\n'}, True, None),
    ('an #if false block', {'Ok.swift': '#if false\nimport Security\n#endif\nimport Foundation\n'}, True, None),
    ('Dispatch is not Foundation', {'Bad.swift': 'import Foundation\nimport Dispatch\n'}, False, FORBIDDEN),
    ('Security unconditionally', {'Bad.swift': 'import Foundation\nimport Security\n'}, False, FORBIDDEN),
    ('NIO', {'Bad.swift': 'import Foundation\nimport NIOCore\n'}, False, FORBIDDEN),
    ('ConduitShared', {'Bad.swift': 'import Foundation\nimport ConduitShared\n'}, False, FORBIDDEN),
    ('ProxyKernel', {'Bad.swift': 'import ProxyKernel\nimport Foundation\n'}, False, FORBIDDEN),
    ('Security under #if DEBUG', {'Bad.swift': 'import Foundation\n#if DEBUG\nimport Security\n#endif\n'}, False, '(debug): Security'),
    ('Security under #if !DEBUG', {'Bad.swift': 'import Foundation\n#if !DEBUG\nimport Security\n#endif\n'}, False, '(release): Security'),
    ('Security under #if os(macOS)', {'Bad.swift': 'import Foundation\n#if os(macOS)\nimport Security\n#endif\n'}, False, FORBIDDEN),
    ('Security under canImport', {'Bad.swift': 'import Foundation\n#if canImport(Security)\nimport Security\n#endif\n'}, False, FORBIDDEN),
    ('NIO under #if DEBUG only', {'Bad.swift': 'import Foundation\n#if DEBUG\nimport NIOPosix\n#endif\n'}, False, '(debug): NIOPosix'),
    ('an exported Security re-export', {'Bad.swift': 'import Foundation\n@_exported import Security\n'}, False, FORBIDDEN),
    ('a forbidden import in a second file', {'Ok.swift': 'import Foundation\n', 'Bad.swift': 'import Security\n'}, False, FORBIDDEN),
    ('an unparseable file', {'Bad.swift': 'import Foundation\nlet x = (\n'}, False, UNPARSEABLE),
]


def run_fence(kernel_files, runtime_files):
    """Runs the script with the given kernel and RuntimeEvents fixtures; returns the result."""
    with tempfile.TemporaryDirectory(prefix='conduit-runtime-fence-') as directory:
        kernel, runtime = Path(directory) / 'ProxyKernel', Path(directory) / 'RuntimeEvents'
        kernel.mkdir()
        runtime.mkdir()
        (kernel / 'Clean.swift').write_text(kernel_files)
        for name, code in runtime_files.items():
            (runtime / name).write_text(code)
        return subprocess.run([sys.executable, str(script), str(kernel), '--runtime-events', str(runtime),
                               '--objects'], capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='conduit-import-fence-') as directory:
    sources = Path(directory) / 'Sources'
    sources.mkdir()
    source, obj = sources / 'Fixture.swift', Path(directory) / 'Fixture.o'
    for code, accepted in cases:
        source.write_text(code)
        obj.unlink(missing_ok=True)
        # A fixture the compiler rejects has no object; the import step
        # reports it. Compile in debug so `#if DEBUG` code is in the object.
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-D', 'DEBUG',
                        '-c', str(source), '-o', str(obj)], capture_output=True)
        objects = [str(obj)] if obj.exists() else []
        result = subprocess.run([sys.executable, str(script), str(sources), '--objects', *objects],
                                capture_output=True, text=True)
        assert (result.returncode == 0) == accepted, (code, result.stdout, result.stderr)
    source.unlink()
    assert subprocess.run([sys.executable, str(script), str(sources), '--objects'], capture_output=True).returncode != 0

for label, runtime_files, accepted, reason in runtime_cases:
    result = run_fence('import Foundation\n', runtime_files)
    if accepted:
        assert result.returncode == 0, (label, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (label, 'was accepted', result.stdout)
        assert reason in result.stderr, (label, 'failed for another reason', result.stderr)

# The directory itself: an empty or missing RuntimeEvents directory fails rather than passing vacuously.
with tempfile.TemporaryDirectory(prefix='conduit-runtime-fence-') as directory:
    kernel, empty = Path(directory) / 'ProxyKernel', Path(directory) / 'RuntimeEvents'
    kernel.mkdir()
    empty.mkdir()
    (kernel / 'Clean.swift').write_text('import Foundation\n')
    for runtime in (empty, Path(directory) / 'Missing'):
        result = subprocess.run([sys.executable, str(script), str(kernel), '--runtime-events', str(runtime),
                                 '--objects'], capture_output=True, text=True)
        assert result.returncode != 0 and 'No Swift sources found' in result.stderr, (runtime, result.stderr)

print(f'PASS: compiler-evaluated kernel imports per configuration, Process in objects, parse failures and missing sources; '
      f'RuntimeEvents limited to Foundation in {len(runtime_cases)} fixture directories')
