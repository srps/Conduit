#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Live synthetic requests: wire queries survive, ordinary observations do not."""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/pm-proxy").resolve()
SECRETS = ["s06query", "s06fragment", "s06body", "s06failure"]
# The fixture's own files, kept on a failure for diagnosis. The summary prints their path.
KEPT_ON_FAILURE = ["config.json", "ready.json", "stdout.log", "stderr.log", "snapshot.json", "events.ndjson", "audit.ndjson"]


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError("Timed out: " + description)


def read_headers(connection):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        assert chunk, "Connection closed before headers"
        data.extend(chunk)
        assert len(data) <= 16384, "Fixture header bound exceeded"
    return bytes(data)


def assert_private(text):
    assert not any(secret in text for secret in SECRETS), "URL secret reached an observation"


def main():
    started = time.monotonic()
    state = {"phase": "startup", "since": started}

    def begin(phase):
        state["phase"], state["since"] = phase, time.monotonic()

    with tempfile.TemporaryDirectory(prefix="conduit-target-", dir="/tmp") as temporary:
        directory = Path(temporary)
        try:
            run(directory, begin)
        except BaseException as error:
            kept = Path(tempfile.mkdtemp(prefix="conduit-target-failure-", dir="/tmp"))
            for name in KEPT_ON_FAILURE:
                if (directory / name).exists():
                    shutil.copy2(directory / name, kept / name)
            now = time.monotonic()
            # Keep the summary short; the re-raised traceback retains synthetic assertion details.
            print(f"FAIL: phase={state['phase']} phaseElapsed={now - state['since']:.3f}s total={now - started:.3f}s "
                  f"error={type(error).__name__} kept={kept}", file=sys.stderr)
            raise
    print("PASS: unchanged wire queries; private active snapshots, stdout, stderr and events across success/body-limit/connect-failure paths")


def run(directory, begin):
    config = {"localHost": "127.0.0.1", "localPort": 0, "upstreams": [],
              "maxBufferedBodyBytes": 4, "maxSpooledBodyBytes": 8}
    (directory / "config.json").write_text(json.dumps(config))
    with (directory / "stdout.log").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
        process = subprocess.Popen([str(BINARY), "--state-dir", str(directory), "--port", "0",
                                    "--status-interval", "0.1", "--verbose"], stdout=stdout, stderr=stderr)
        try:
            ready = directory / "ready.json"
            wait_for(ready.exists, "proxy startup")
            port = json.loads(ready.read_text())["proxyPort"]
            for origin_form in [False, True]:
                begin("success-origin-form" if origin_form else "success-absolute-form")
                with socket.socket() as origin:
                    origin.bind(("127.0.0.1", 0))
                    origin.listen(1)
                    origin.settimeout(10)
                    authority = "127.0.0.1:" + str(origin.getsockname()[1])
                    wire_path = "/resource?sig=s06query&next=%2Fkeep%3Fx%3D1"
                    target = wire_path if origin_form else "http://" + authority + wire_path
                    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
                        client.sendall(f"GET {target} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n".encode())
                        peer, _ = origin.accept()
                        with peer:
                            peer.settimeout(10)
                            received = read_headers(peer)
                            assert received.split(b"\r\n", 1)[0] == f"GET {wire_path} HTTP/1.1".encode(), received

                            def active_snapshot():
                                path = directory / "snapshot.json"
                                if not path.exists():
                                    return False
                                snapshot = json.loads(path.read_text())
                                return bool(snapshot.get("activeConnections"))

                            wait_for(active_snapshot, "active request snapshot")
                            snapshot = (directory / "snapshot.json").read_text()
                            assert "resource" in snapshot
                            assert_private(snapshot)
                            peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
                            assert read_headers(client).startswith(b"HTTP/1.1 200")

            # Body rejection happens before the ordinary routing path.
            begin("body-limit")
            with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
                client.sendall(b"POST /upload?sig=s06body#s06fragment HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Length: 16\r\n\r\n0123456789abcdef")
                response = read_headers(client)
                assert response.startswith(b"HTTP/1.1 413"), response
                assert_private(response.decode())
            # Reserve an ephemeral port and release it, so the request targets a closed port that the kernel refuses. A socket bound
            # without listening is not a refusal: macOS may drop the SYN, and the connect then waits out the proxy's connect budget.
            begin("connect-failure")
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                closed_port = reservation.getsockname()[1]
            target = f"http://127.0.0.1:{closed_port}/failure?sig=s06failure#s06fragment"
            with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
                client.sendall(f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".encode())
                response = read_headers(client)
                assert response.startswith(b"HTTP/1.1 502"), response
                assert_private(response.decode())
            begin("observations")
            wait_for(lambda: "exceeded spool limit" in (directory / "stderr.log").read_text(), "body-limit log")
            for name in ["stdout.log", "stderr.log", "snapshot.json", "events.ndjson"]:
                path = directory / name
                if path.exists():
                    assert_private(path.read_text())
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
