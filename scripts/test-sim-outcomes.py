#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise the real pm-sim reporting/exit path without sockets or long scenarios."""
import json
import subprocess
import sys


def run(binary, fixture, expected_code, statuses):
    process = subprocess.run(
        [binary, fixture, "--self-test-outcomes"],
        capture_output=True, text=True, timeout=10, check=False,
    )
    assert process.returncode == expected_code, (fixture, process.returncode, process.stdout, process.stderr)
    rows = [json.loads(line.removeprefix("SIM_NDJSON "))
            for line in process.stdout.splitlines() if line.startswith("SIM_NDJSON ")]
    assert [row["passed"] for row in rows] == statuses, (fixture, rows)
    for row, passed in zip(rows, statuses):
        assert row["status"] == ("passed" if passed else "failed"), row
        derived = bool(row["assertions"]) and all(a["passed"] for a in row["assertions"])
        assert derived == passed, row
        assert all(a["name"] for a in row["assertions"]), row
    return rows


def main():
    binary = sys.argv[1]
    passed = run(binary, "pass", 0, [True])[0]
    assert passed["earlyClose"] == 2 and "FAIL" in passed["notes"][0], passed
    failed = run(binary, "fail", 1, [False])[0]
    assert failed["notes"] == ["PASS is informational too"], failed
    run(binary, "throw", 1, [False])
    run(binary, "missing", 1, [False])
    run(binary, "empty", 1, [False])
    cleanup = run(binary, "cleanup", 1, [False, True])
    assert cleanup[1]["assertions"][0]["name"] == "partial setup cleaned before next scenario", cleanup
    timed_out = run(binary, "timeout", 1, [False])[0]
    assert timed_out["notes"] == ["scenario/cleanup deadline exceeded"], timed_out
    mixed = run(binary, "mixed", 1, [True, False, False, True])
    assert mixed[2]["notes"] == ["intentional fixture error"], mixed
    assert mixed[0]["scenario"] == mixed[-1]["scenario"] == "fixture-pass", mixed
    for scenario in ["health-check", "vpn-user-disconnect", "transparent-direct", "dns-doh-blocked",
                     "websocket-upgrade", "security-boundaries", "shared-inbound-budget"]:
        process = subprocess.run([binary, scenario, "--inject-failed-assertion"],
                                 capture_output=True, text=True, timeout=45, check=False)
        assert process.returncode == 1, (scenario, process.returncode, process.stdout, process.stderr)
        rows = [json.loads(line.removeprefix("SIM_NDJSON "))
                for line in process.stdout.splitlines() if line.startswith("SIM_NDJSON ")]
        assert len(rows) == 1, (scenario, rows)
        row = rows[0]
        assert row["passed"] is False and row["status"] == "failed", row
        assert row["assertions"] and row["assertions"][0]["passed"] is False, row
        assert row["assertions"][0]["name"] != "scenario completed without throwing", row
        assert row["notes"][-1] == "test-only assertion fault injection", row
    print("PASS: simulator failures, throws, missing assertions, continued reporting and informational notes")


if __name__ == "__main__":
    main()
