#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A tiny status interval stays quiet at rest and publishes writer-only changes."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/pm-proxy").resolve()


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError("Timed out: " + description)


def main():
    with tempfile.TemporaryDirectory(prefix="conduit-status-", dir="/tmp") as temporary:
        directory = Path(temporary)
        config = directory / "config.json"
        config.write_text(json.dumps({"localHost": "127.0.0.1", "localPort": 0, "upstreams": []}))
        output = directory / "stdout.log"

        def rows():
            assert output.stat().st_size < 512_000, "Tiny interval flooded status output"
            complete = output.read_bytes().split(b"\n")[:-1]
            return [json.loads(line) for line in complete if line]

        with output.open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
            process = subprocess.Popen([str(BINARY), "--state-dir", str(directory), "--port", "0",
                                        "--status-interval", "0.000001"], stdout=stdout, stderr=stderr)
            try:
                wait_for(lambda: any(row["kind"] == "ready" for row in rows()), "ready status")
                # Allow startup logging and its asynchronous writer drain to settle.
                time.sleep(0.6)
                before = rows()
                time.sleep(0.5)
                assert rows() == before, "Unchanged snapshot and writer statistics emitted more status rows"
                assert len(before) <= 8, "Requested tiny interval bypassed the 10 Hz ceiling"
                snapshot = before[-1]["snapshot"]
                previous_written = before[-1]["observability"]["events"]["writtenRecords"]

                # A rejected reload emits logs/events while keeping the runtime
                # snapshot intact. Writer-only changes must still be published.
                config.write_text("{invalid-json")
                process.send_signal(signal.SIGHUP)
                wait_for(lambda: any(row["observability"]["events"]["writtenRecords"] > previous_written
                                     for row in rows()[len(before):]), "writer-only status change")
                after = rows()
                assert all(row["snapshot"] == snapshot for row in after[len(before):]), \
                    "Rejected reload unexpectedly changed runtime snapshot"

                # Sustained writer changes still cannot schedule more than 10
                # heartbeat writes per second, even at a microsecond request.
                count_before_burst = len(after)
                burst_started = time.monotonic()
                for _ in range(30):
                    process.send_signal(signal.SIGHUP)
                    time.sleep(0.01)
                elapsed = time.monotonic() - burst_started
                # Allow one boundary tick and scheduling jitter on busy CI hosts.
                assert len(rows()) - count_before_burst <= int(elapsed / 0.1) + 2, \
                    "Writer changes bypassed heartbeat rate bound"
                process.send_signal(signal.SIGTERM)
                assert process.wait(timeout=8) == 0, "Proxy did not stop normally"
                print("PASS: microsecond status request stays quiet unchanged, publishes writer-only changes, and respects 10 Hz")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
