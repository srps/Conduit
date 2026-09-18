#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Assert exact HTTP/Upgrade request targets against ephemeral loopback peers."""
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/pm-proxy").resolve()
CASES = [
    ("", "/"), ("?", "/?"), ("/?", "/?"),
    ("/a%2Fb/%3F/%23/%25", "/a%2Fb/%3F/%23/%25"),
    ("/a%2fb?key=1&key=2&next=%2F%3F&empty=", "/a%2fb?key=1&key=2&next=%2F%3F&empty="),
    ("/safe%20HTTP/1.1%0D%0AX-Injected:%20yes", "/safe%20HTTP/1.1%0D%0AX-Injected:%20yes"),
    ("/caf%C3%A9?q=%0D%0A#discard", "/caf%C3%A9?q=%0D%0A"),
    ("/#discard", "/"),
]


def read_headers(peer):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = peer.recv(4096)
        assert chunk, "Peer closed before headers"
        data.extend(chunk)
        assert len(data) <= 16384, "Fixture header bound exceeded"
    return bytes(data)


def main():
    checked = 0
    with tempfile.TemporaryDirectory(prefix="conduit-wire-target-") as temporary:
        state = Path(temporary)
        with (state / "proxy.log").open("w") as log:
            process = subprocess.Popen(
                [str(BINARY), "--minimal", "--state-dir", temporary, "--port", "0"], stdout=log, stderr=log)
            try:
                ready = state / "ready.json"
                deadline = time.monotonic() + 10
                while not ready.exists():
                    assert process.poll() is None, (state / "proxy.log").read_text()
                    assert time.monotonic() < deadline, "Proxy startup timed out"
                    time.sleep(0.025)
                port = json.loads(ready.read_text())["proxyPort"]
                for upgrade in [False, True]:
                    for origin_form in [False, True]:
                        for suffix, expected in CASES:
                            if origin_form and not suffix.startswith("/"):
                                continue
                            with socket.socket() as origin:
                                origin.bind(("127.0.0.1", 0))
                                origin.listen(1)
                                origin.settimeout(5)
                                authority = f"127.0.0.1:{origin.getsockname()[1]}"
                                target = suffix if origin_form else f"http://{authority}{suffix}"
                                headers = "Connection: Upgrade\r\nUpgrade: websocket\r\n" if upgrade else "Connection: close\r\n"
                                with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
                                    client.sendall(f"GET {target} HTTP/1.1\r\nHost: {authority}\r\n{headers}\r\n".encode())
                                    try:
                                        accepted, _ = origin.accept()
                                    except TimeoutError as error:
                                        raise AssertionError(
                                            f"Origin not reached: upgrade={upgrade}, target={target!r}; "
                                            + (state / "proxy.log").read_text()
                                        ) from error
                                    with accepted as peer:
                                        peer.settimeout(5)
                                        received = read_headers(peer)
                                        assert received.split(b"\r\n", 1)[0] == f"GET {expected} HTTP/1.1".encode(), repr(received)
                                        assert b"\r\nX-Injected:" not in received, repr(received)
                                        assert received.count(b"\r\n\r\n") == 1, repr(received)
                                        # A refusal still exercises Upgrade request serialization.
                                        peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                                        assert read_headers(client).startswith(b"HTTP/1.1 200")
                                    checked += 1
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    print(f"PASS: {checked} exact wire targets across HTTP/Upgrade and absolute/origin forms")


if __name__ == "__main__":
    main()
