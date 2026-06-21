#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="${SWIFT:-xcrun swift}"
READY_BUDGET_MS="${PM_READY_BUDGET_MS:-200}"
MAX_RSS_BYTES="${PM_PERF_MAX_RSS_BYTES:-209715200}"
MAX_WALL_SECONDS="${PM_PERF_MAX_WALL_SECONDS:-20}"

cd "$ROOT_DIR"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  $SWIFT build --product pm-proxy --product pm-sim

state_dir="$(mktemp -d /tmp/pm-perf-XXXXXX)"
trap 'rm -rf "$state_dir"' EXIT

ready_output="$(
  .build/debug/pm-proxy \
    --minimal \
    --state-dir "$state_dir" \
    --port 0 \
    --exit-after-ready \
    --assert-ready-under-ms "$READY_BUDGET_MS"
)"

echo "$ready_output"

perf_output="$(
  python3 - <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["./.build/debug/pm-sim", "--perf-baseline"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=60,
        check=False,
    )
except subprocess.TimeoutExpired as error:
    output = error.stdout or ""
    sys.stdout.write(output)
    sys.stderr.write("pm-sim --perf-baseline exceeded 60s watchdog\n")
    sys.exit(124)

sys.stdout.write(result.stdout)
sys.exit(result.returncode)
PY
)"

echo "$perf_output"

PERF_OUTPUT="$perf_output" MAX_RSS_BYTES="$MAX_RSS_BYTES" MAX_WALL_SECONDS="$MAX_WALL_SECONDS" python3 - <<'PY'
import json
import os
import sys

perf = None
sim = None
for line in os.environ["PERF_OUTPUT"].splitlines():
    if line.startswith("PERF_NDJSON "):
        perf = json.loads(line[len("PERF_NDJSON "):])
    if line.startswith("SIM_NDJSON "):
        sim = json.loads(line[len("SIM_NDJSON "):])

if perf is None or sim is None:
    sys.stderr.write("missing PERF_NDJSON or SIM_NDJSON output\n")
    sys.exit(1)

failures = []
if sim["opened"] != sim["clients"]:
    failures.append(f"opened {sim['opened']}/{sim['clients']} clients")
if sim["firstByte"] != sim["clients"]:
    failures.append(f"firstByte {sim['firstByte']}/{sim['clients']} clients")
if sim["earlyClose"] != 0:
    failures.append(f"earlyClose={sim['earlyClose']}")

max_rss = int(os.environ["MAX_RSS_BYTES"])
if int(perf["maxResidentSetSizeBytes"]) > max_rss:
    failures.append(
        f"max RSS {perf['maxResidentSetSizeBytes']} exceeded {max_rss} bytes"
    )

max_wall = float(os.environ["MAX_WALL_SECONDS"])
if float(perf["wallSeconds"]) > max_wall:
    failures.append(f"wallSeconds {perf['wallSeconds']:.2f} exceeded {max_wall:.2f}s")

if failures:
    for failure in failures:
        sys.stderr.write(f"perf gate failed: {failure}\n")
    sys.exit(1)

print(
    "perf gate passed: "
    f"wall={perf['wallSeconds']:.2f}s "
    f"rss={perf['maxResidentSetSizeBytes']} bytes "
    f"cpu={perf['cpuPercent']:.1f}%"
)
PY
