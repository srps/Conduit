#!/usr/bin/env python3
"""Reproduce a bounded Release before/after sanitizer lifetime probe."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[4])
parser.add_argument("--output", type=Path)
args = parser.parse_args()
root = args.repo.resolve()
out = args.output or Path(tempfile.mkdtemp(prefix="conduit-sanitize-"))
out.mkdir(parents=True, exist_ok=True)
source = "Sources/ProxyKernel/Support/SensitiveValueSanitizer.swift"
before_commit = "21a6f96c7ead18e4028ec04d57171630e9675b2d"
versions = {
    "before": subprocess.check_output(["git", "show", before_commit + ":" + source], cwd=root),
    "after": (root / source).read_bytes(),
}
env = os.environ.copy()
env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
metadata = {"baseline": before_commit, "source_sha256": {},
            "swift": subprocess.check_output(["xcrun", "swiftc", "--version"], env=env, text=True)}
for name, content in versions.items():
    metadata["source_sha256"][name] = hashlib.sha256(content).hexdigest()
    (out / (name + ".swift")).write_bytes(content)
    command = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-package-name", "Conduit",
               "-module-cache-path", str(out / "module-cache"), str(out / (name + ".swift")),
               str(Path(__file__).with_name("Probe.swift")), "-o", str(out / name)]
    with (out / (name + "-build.log")).open("w") as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    with (out / (name + "-results.txt")).open("w") as log:
        subprocess.run([str(out / name)], env=env, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=60)
    print(name + ":\n" + (out / (name + "-results.txt")).read_text(), flush=True)
(out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
print("Artifacts: " + str(out))
