#!/usr/bin/env python3
"""Reject malformed recovery requests before composing either runtime host."""
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="conduit-worker-") as scratch:
    for binary in sys.argv[1:]:
        state = pathlib.Path(scratch) / pathlib.Path(binary).name
        for arguments in [
            ["--conduit-kerberos-ticket"],
            ["--conduit-kerberos-ticket", "bad host"],
            ["--conduit-kerberos-ticket", "--help"],
            ["--conduit-kerberos-ticket", "proxy.example", "--dev", "--dev-state-dir", str(state)],
            ["--conduit-kerberos-ticket", "proxy.example", "--state-dir", str(state)],
        ]:
            result = subprocess.run([binary, *arguments], capture_output=True, timeout=5)
            assert result.returncode == 64, (binary, result.returncode, result.stderr)
            assert not result.stdout, (binary, result.stdout)
            assert not state.exists(), (binary, state)
print("Kerberos worker entry points reject malformed requests without runtime startup")
