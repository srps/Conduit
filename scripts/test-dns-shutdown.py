#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify standalone DNS signal shutdown using scratch state and loopback only.

Build pm-dns first, then run: python3 scripts/test-dns-shutdown.py [binary]
No DNS requests leave the machine, and only the child process is signalled.
"""
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time


BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/pm-dns").resolve()
DEADLINE_SECONDS = 5


def read_log(path):
    with path.open("r") as output:
        text = output.read(65_537)
    assert len(text) <= 65_536, "Unexpectedly large standalone DNS output"
    return text


def exercise(signals):
    with tempfile.TemporaryDirectory(prefix="conduit-dns-shutdown-", dir="/tmp") as temporary:
        directory = Path(temporary)
        log = directory / "output.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [str(BINARY), "--minimal", "--state-dir", str(directory),
                 "--host", "127.0.0.1", "--port", "0"],
                stdout=output, stderr=output,
            )
            connection = None
            try:
                deadline = time.monotonic() + DEADLINE_SECONDS
                while True:
                    text = read_log(log)
                    match = re.search(r"DNS forwarder listening on 127\.0\.0\.1:(\d+) \(UDP and TCP\)", text)
                    if match and "pm-dns running" in text:
                        break
                    assert process.poll() is None, text
                    assert time.monotonic() < deadline, f"Startup timed out: {text}"
                    time.sleep(0.025)

                port = int(match[1])
                assert 0 < port <= 65535, text
                connection = socket.create_connection(("127.0.0.1", port), timeout=DEADLINE_SECONDS)
                # An incomplete DNS/TCP length keeps an admitted child channel
                # open without initiating any upstream DNS or DoH operation.
                connection.sendall(b"\x00")
                # Ensure startup's task has returned; this is the lifetime bug.
                time.sleep(0.1)
                for number in signals:
                    try:
                        os.kill(process.pid, number)
                    except ProcessLookupError:
                        # A fast clean exit between repeated signals is valid.
                        break
                try:
                    result = process.wait(timeout=DEADLINE_SECONDS)
                except subprocess.TimeoutExpired as error:
                    raise AssertionError(f"Signal shutdown exceeded {DEADLINE_SECONDS}s: {read_log(log)}") from error
                text = read_log(log)
                assert result == 0, f"Expected orderly exit, got {result}: {text}"
                assert text.count("DNS forwarder stopped.") == 1, text
                assert connection.recv(1) == b"", "Accepted TCP connection survived shutdown"
                connection.close()
                connection = None
                # Rebinding proves both listeners released their socket. No
                # SO_REUSEADDR on UDP: an existing listener must not be hidden.
                for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
                    with socket.socket(socket.AF_INET, kind) as listener:
                        if kind == socket.SOCK_STREAM:
                            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                        listener.bind(("127.0.0.1", port))
                print("PASS: " + ", ".join(signal.Signals(number).name for number in signals))
            finally:
                if connection is not None:
                    connection.close()
                if process.poll() is None:
                    # Failure cleanup only; a forced kill can never pass.
                    process.kill()
                    process.wait(timeout=DEADLINE_SECONDS)


if __name__ == "__main__":
    exercise([signal.SIGTERM])
    exercise([signal.SIGINT])
    exercise([signal.SIGTERM, signal.SIGINT, signal.SIGTERM])
