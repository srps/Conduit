#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise pm-proxy startup/reload boundaries using only a scratch directory.

Build pm-proxy first, then run: python3 scripts/test-security-boundaries.py
No company settings, credentials, or privileged operations are used.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time


BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/pm-proxy").resolve()


def control(directory, command):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(5)
        client.connect(str(directory / "control.sock"))
        client.sendall(json.dumps({"protocolVersion": 1, "command": command}).encode() + b"\n")
        response = bytearray()
        while b"\n" not in response:
            chunk = client.recv(8192)
            if not chunk:
                break
            response.extend(chunk)
            assert len(response) < 1_048_576, "Unbounded control response"
        return json.loads(response)


def wait_until(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError(f"Timed out: {description}")


def startup(directory, args, succeeds=False):
    result = subprocess.run(
        [str(BINARY), "--state-dir", str(directory), "--port", "0", "--exit-after-ready", *args],
        capture_output=True, text=True, timeout=15,
    )
    assert (result.returncode == 0) == succeeds, result.stderr
    if succeeds:
        assert '"kind":"ready"' in result.stdout, result.stdout
    else:
        assert '"kind":"ready"' not in result.stdout, result.stdout
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="conduit-sec-", dir="/tmp") as temporary:
        directory = Path(temporary)
        config_file = directory / "config.json"
        for args in [["--config-json", "{"], ["--config", str(directory / "missing.json")]]:
            result = startup(directory, args)
            assert '"event":"config.load_rejected"' in result.stderr
        config_file.write_text("{")
        startup(directory, [])
        assert config_file.read_text() == "{"
        config_file.unlink()
        startup(directory, [], succeeds=True)  # Genuine first run.
        startup(directory, [])  # Reused runtime state is no longer a first run.
        startup(directory, ["--minimal"], succeeds=True)
        for host in ["192.0.2.1", "10.0.0.1", "::", "host.example.test"]:
            startup(directory, ["--minimal", "--host", host])
        startup(directory, ["--minimal", "--host", "localhost", "--dns-port", "0", "--socks-port", "0"], succeeds=True)
        bindings = json.loads((directory / "ready.json").read_text())
        assert all(bindings[name] == "127.0.0.1" for name in ["proxyHost", "socksHost", "dnsHost"])

        config = {
            "profileName": "Security regression original",
            "localPort": 0,
            "health": {"checkInterval": 3600},
            "upstreams": [{"id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "name": "Synthetic",
                           "host": "127.0.0.1", "port": 9, "enabled": True, "priority": 0}],
        }
        config_file.write_text(json.dumps(config))
        (directory / "ready.json").unlink(missing_ok=True)
        with (directory / "stdout.log").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
            process = subprocess.Popen([str(BINARY), "--state-dir", str(directory), "--port", "0"],
                                       stdout=stdout, stderr=stderr)
            try:
                wait_until(lambda: (directory / "ready.json").exists(), "runtime startup")
                original = control(directory, "status")["status"]
                assert original["configGeneration"] == 0
                assert original["profileName"] == config["profileName"]
                assert original["directModeCause"] != "noUpstreamsConfigured"

                def unchanged():
                    current = control(directory, "status")["status"]
                    for field in ["configGeneration", "profileName", "bindings", "isDirectMode", "directModeCause", "activeUpstream"]:
                        assert current.get(field) == original.get(field), (field, current, original)

                for invalid in ["{", json.dumps({"localPort": "broken"}), json.dumps({"localHost": "192.0.2.1"})]:
                    config_file.write_text(invalid)
                    response = control(directory, "reload")
                    assert not response["success"] and response["errorCode"] == "invalid_request", response
                    unchanged()
                    assert config_file.read_text() == invalid
                config_file.unlink()
                assert not control(directory, "reload")["success"]
                unchanged()
                events_file = directory / "events.ndjson"

                def rejections():
                    return events_file.read_text().count('"event":"config.reload_rejected"') if events_file.exists() else 0

                wait_until(lambda: rejections() >= 4, "control rejection events")
                count = rejections()
                os.kill(process.pid, signal.SIGHUP)
                wait_until(lambda: rejections() > count, "SIGHUP rejection event")
                unchanged()
                config["profileName"] = "Security regression repaired"
                config_file.write_text(json.dumps(config))
                assert control(directory, "reload")["success"]
                repaired = control(directory, "status")["status"]
                assert repaired["configGeneration"] == 1
                assert repaired["profileName"] == config["profileName"]
                assert repaired["directModeCause"] == original["directModeCause"]
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        print("PASS: rejected startup, first run, loopback binds, failed control/SIGHUP reload preservation, repaired reload")


if __name__ == "__main__":
    main()
