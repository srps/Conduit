#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Regression for the app's process entry: order, refusals, and callbacks that must run.

Compiles the real entry, Sources/Conduit/App/ConduitMain.swift, unchanged, as module `Conduit`, beside the
stand-ins in scripts/app-entry-fixtures/. The stand-ins are compiled only here and stand in for:

- ProxyAuth and PlatformMac: modules the entry imports. Each provides only the worker entry the entry calls.
- DevLaunch, PreparedAppLaunch and ConduitApp.main: the app-module collaborators. PreparedAppLaunch models a background
  hop and a refusal. ConduitApp.main schedules a main Dispatch block and a MainActor task, then pumps the main
  Foundation RunLoop for three seconds. It does not start AppKit.

No real state root, lease, helper, Keychain, WindowServer or machine is touched. Each run is a child process with an
empty environment (except the one stand-in switch) and an external timeout. The fixtures print a fixed, finite number
of lines. Failure messages quote only an excerpt, so they stay readable; the captured output itself is not capped.

Negative controls compile a mutated copy of the entry in the scratch directory (the checked-in source is never edited).
Each must fail the child with "present callbacks missing", which is what the real starvation does:
- async-entry: the entry becomes `async` and yields before its body, the shape that starved the main queue.
- dispatch-to-main: the `ConduitApp.main()` call is queued with DispatchQueue.main.async, and dispatchMain() then runs
  it inside a main-queue block.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = ROOT / "Sources/Conduit/App/ConduitMain.swift"
FIXTURES = ROOT / "scripts/app-entry-fixtures"
COMPILE_TIMEOUT = 300
CHILD_TIMEOUT = 20
EXCERPT_LIMIT = 2000
MISSING_CALLBACKS_EXIT = 3

PREPARE_PREFIX = ["prepare begin", "prepare background", "prepare end"]
PRESENT_PREFIX = ["present begin main=true"]
CALLBACKS = ["dispatch callback", "main actor callback"]
PRESENT_SUFFIX = ["present callbacks ok"]

MUTANTS = {
    "async-entry": (
        "    static func main() {\n",
        "    static func main() async {\n        await Task.yield()\n",
    ),
    "dispatch-to-main": (
        "        ConduitApp.main()\n",
        "        DispatchQueue.main.async { MainActor.assumeIsolated { ConduitApp.main() } }\n"
        "        dispatchMain()\n",
    ),
}

failures = []
passes = []


def excerpt(data):
    text = data.decode("utf-8", "replace")
    return text if len(text) <= EXCERPT_LIMIT else text[:EXCERPT_LIMIT] + "...[excerpt cut]"


def xcrun_output(arguments):
    """The stdout of one `xcrun` query. A failed query stops the script with its diagnostic; nothing is guessed."""
    try:
        found = subprocess.run(["xcrun", *arguments], capture_output=True, text=True, timeout=60, check=True)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"xcrun {' '.join(arguments)} failed with status {error.returncode}: {error.stderr.strip()[:500]}")
    except (subprocess.SubprocessError, OSError) as error:
        raise SystemExit(f"xcrun {' '.join(arguments)} could not run: {error}")
    value = found.stdout.strip()
    if not value:
        raise SystemExit(f"xcrun {' '.join(arguments)} printed no path")
    return value


def toolchain():
    """The swiftc that resolves from DEVELOPER_DIR, and the macOS SDK it compiles against."""
    return xcrun_output(["--find", "swiftc"]), xcrun_output(["--sdk", "macosx", "--show-sdk-path"])


def compile_swift(tools, arguments, label):
    swiftc, sdk = tools
    try:
        result = subprocess.run([swiftc, "-sdk", sdk, *arguments], capture_output=True, timeout=COMPILE_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        failures.append(f"{label}: compile timed out after {COMPILE_TIMEOUT}s")
        return False
    if result.returncode != 0:
        failures.append(f"{label}: compile failed with status {result.returncode}\n{excerpt(result.stderr)}")
        return False
    return True


def build_standins(tools, out):
    for name in ["ProxyAuth", "PlatformMac"]:
        if not compile_swift(tools, [
            "-swift-version", "6", "-parse-as-library", "-emit-library", "-emit-module",
            "-module-name", name,
            "-emit-module-path", str(out / f"{name}.swiftmodule"),
            "-module-cache-path", str(out / "cache"),
            "-o", str(out / f"lib{name}.dylib"),
            str(FIXTURES / f"{name}.swift"),
        ], f"stand-in {name}"):
            return False
    return True


def build_entry(tools, out, entry_source, binary):
    return compile_swift(tools, [
        "-swift-version", "6", "-parse-as-library", "-module-name", "Conduit",
        "-I", str(out), "-L", str(out), "-lProxyAuth", "-lPlatformMac",
        "-Xlinker", "-rpath", "-Xlinker", str(out),
        "-module-cache-path", str(out / "cache"),
        "-o", str(binary),
        str(entry_source),
        str(FIXTURES / "ConduitStandIns.swift"),
    ], f"entry {binary.name}")


def run_child(binary, arguments=(), standin=None):
    environment = {"CONDUIT_APP_ENTRY_STANDIN": standin} if standin else {}
    try:
        return subprocess.run([str(binary), *arguments], env=environment, capture_output=True,
                              timeout=CHILD_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        failures.append(f"{binary.name} {' '.join(arguments)} {standin or ''}: timed out after {CHILD_TIMEOUT}s")
        return None


def check_child(label, completed, status, expected_stdout=None, stdout_check=None, stderr_contains=None):
    if completed is None:
        return
    stdout = completed.stdout.decode("utf-8", "replace").splitlines()
    stderr = completed.stderr.decode("utf-8", "replace")
    problems = []
    if completed.returncode != status:
        problems.append(f"exit {completed.returncode}, expected {status}")
    if expected_stdout is not None and stdout != expected_stdout:
        problems.append(f"stdout {stdout!r}, expected {expected_stdout!r}")
    if stdout_check is not None and not stdout_check(stdout):
        problems.append(f"stdout {stdout!r} failed the order check")
    if stderr_contains is not None and stderr_contains not in stderr:
        problems.append(f"stderr lacks {stderr_contains!r}")
    if problems:
        failures.append(f"{label}: " + "; ".join(problems) + f"\nstdout:\n{excerpt(completed.stdout)}\nstderr:\n{excerpt(completed.stderr)}")
    else:
        passes.append(label)


def is_positive_order(stdout):
    if stdout[:3] != PREPARE_PREFIX or stdout[3:4] != PRESENT_PREFIX or stdout[6:] != PRESENT_SUFFIX:
        return False
    return sorted(stdout[4:6]) == sorted(CALLBACKS)


def main():
    tools = toolchain()
    with tempfile.TemporaryDirectory(prefix="conduit-app-entry-") as scratch:
        out = pathlib.Path(scratch)
        (out / "cache").mkdir()
        if not build_standins(tools, out):
            return report()

        entry = out / "entry"
        if build_entry(tools, out, ENTRY, entry):
            # Positive: prepare runs and finishes before present; both callbacks run on the main thread.
            check_child("production order", run_child(entry), 0, stdout_check=is_positive_order)
            # Worker modes run before preparation, and their own status is the exit.
            check_child("kerberos worker first", run_child(entry, ["--conduit-kerberos-ticket"]), 7,
                        expected_stdout=["worker kerberos"])
            check_child("update helper worker first", run_child(entry, ["--conduit-update-helper-preflight"]), 9,
                        expected_stdout=["worker updater"])
            # A dev request with a worker mode is refused before any worker or preparation.
            check_child("dev worker refusal first", run_child(entry, ["--dev", "--conduit-kerberos-ticket"]), 64,
                        expected_stdout=[], stderr_contains="worker modes are not available in the dev instance")
            # A refused root exits in preparation: nothing is presented.
            check_child("refused root exits before present", run_child(entry, standin="refuse-prepare"), 75,
                        expected_stdout=PREPARE_PREFIX[:2], stderr_contains="config.state_root_busy")

        original = ENTRY.read_text(encoding="utf-8")
        for name, (anchor, replacement) in MUTANTS.items():
            if original.count(anchor) != 1:
                failures.append(f"negative control {name}: anchor found {original.count(anchor)} times, expected 1")
                continue
            mutant_dir = out / "mutants" / name
            mutant_dir.mkdir(parents=True)
            source = mutant_dir / "ConduitMain.swift"
            source.write_text(original.replace(anchor, replacement, 1), encoding="utf-8")
            binary = out / f"entry-{name}"
            if not build_entry(tools, out, source, binary):
                continue
            completed = run_child(binary)
            if completed is None:
                continue
            stdout = completed.stdout.decode("utf-8", "replace").splitlines()
            starved = any(line.startswith("present callbacks missing") for line in stdout)
            if completed.returncode == MISSING_CALLBACKS_EXIT and starved:
                passes.append(f"negative control {name} fails with missing callbacks")
            else:
                failures.append(
                    f"negative control {name}: expected missing callbacks (exit {MISSING_CALLBACKS_EXIT}), "
                    f"got exit {completed.returncode}\nstdout:\n{excerpt(completed.stdout)}\nstderr:\n{excerpt(completed.stderr)}"
                )
    return report()


def report():
    for line in passes:
        print(f"PASS {line}")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        print(f"app entry regression: {len(failures)} failure(s), {len(passes)} pass(es)", file=sys.stderr)
        return 1
    print("App entry runs prepare before present, refuses before preparation, and delivers main callbacks; "
          "the async and dispatch-to-main mutants fail as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
