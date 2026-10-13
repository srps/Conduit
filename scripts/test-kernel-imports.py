#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(__file__).with_name('check-kernel-imports.py')
with tempfile.TemporaryDirectory(prefix='conduit-import-fence-') as directory:
    source = Path(directory) / 'Fixture.swift'
    cases = [
        ('import Foundation\nimport Dispatch\nimport NIOHTTP1\nimport Darwin\nimport Glibc\nimport ConduitShared\n', True),
        ('/* import Security /* nested */ */\nlet text = #"import Network"#\nimport Foundation', True),
        ('#if os(macOS)\n  @preconcurrency import Security\n#endif', False),
        ('@_exported import struct Security.SecKey', False),
        ('import UnlistedModule', False),
        ('import NIOTransportServices', False),
        ('import `Security`', False),
        ('import 模块', False),
        ('let child = Foundation.Process ()', False),
        ('let child = Process.init()', False),
        ('let child = Process /* explanation */ ()', False),
        ('let child = Process // explanation\n    ()', False),
        ('let child = Process /* a */ . /* b */ init()', False),
        ('let text = "Process (" // literal stays fenced', False),
        ('let url = "http://example"; let n = 1 // Process() in a comment', True),
        ('let r = #/a/*b/#\nimport Foundation', True),
        ('let r = #/a/*b/#\nimport Security', False),
        ('let r = ##/a/#b/##\nlet child = Process()', False),
        ('let r = #/\n  a/*b\n/#\nimport Security', False),
        ('/* never closed\nimport Security', False),
        ('let text = "never closed\nimport Security', False),
    ]
    for code, accepted in cases:
        source.write_text(code)
        result = subprocess.run([sys.executable, str(script), directory], capture_output=True, text=True)
        assert (result.returncode == 0) == accepted, (code, result.stdout, result.stderr)
    source.unlink()
    assert subprocess.run([sys.executable, str(script), directory], capture_output=True).returncode != 0
print('PASS: kernel allowlist, scoped/attributed imports, comments/literals, Process and missing sources')
