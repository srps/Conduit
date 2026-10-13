#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixtures for check-kernel-imports.py: each is parsed for imports and
compiled to an object for the Process check, the way the build would."""
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
print('PASS: compiler-evaluated kernel imports per configuration, Process in objects, parse failures and missing sources')
