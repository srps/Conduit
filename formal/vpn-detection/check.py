#!/usr/bin/env python3
"""Model-check the VPN detection chain (VPNDetection.tla) with TLC.

    python3 formal/vpn-detection/check.py            # the checks CI runs
    python3 formal/vpn-detection/check.py --mutants  # also show each property catching its bug
    python3 formal/vpn-detection/check.py --only safety-core
    python3 formal/vpn-detection/check.py --full --mutants  # larger bounds, the `--full` checks and mutants
    python3 formal/vpn-detection/check.py --changed origin/main  # the covered files a branch changes

Fetches the pinned tla2tools.jar from the TLA+ GitHub releases into
formal/.tools/, verifies its SHA-256, and needs Java 11 or later. TLC output
lands in formal/vpn-detection/.out/<check>/tlc.out.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = HERE / "VPNDetection.tla"
TOOLS = HERE.parent / ".tools"
OUT = HERE / ".out"

TLA_VERSION = "1.7.4"
TLA_URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{TLA_VERSION}/tla2tools.jar"
TLA_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"

# The coverage record's files (.claude/skills/vpn-detection-model/SKILL.md), and the model's own.
# A change to any of them runs `--full --mutants` in CI (`--changed`).
COVERED = [
    "Sources/PlatformMac/VPNStatusMonitor.swift",
    "Sources/PlatformMac/ObserverStopBarrier.swift",
    "Sources/PlatformMac/StoreObserverClock.swift",
    "Sources/ProxyKernel/Network/StoreReadSchedule.swift",
    "Sources/ProxyKernel/Network/VPNFlapTimer.swift",
    "Sources/PlatformMac/SplitDNSVPNGate.swift",
    "Sources/PlatformMac/SplitDNSEntryFileRepair.swift",
    "Sources/ProxyKernel/Network/VPNObservationSequencer.swift",
    "Sources/ProxyKernel/Network/VPNReactionHistory.swift",
    "Sources/ConduitRuntime/RuntimeHost.swift",
    "Sources/ConduitRuntime/RuntimeHostLifecycle.swift",
    "Sources/PlatformMac/PlatformWork.swift",
    "Sources/PlatformMac/ObserverDeliveries.swift",
    "Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift",
]
MODEL = ["formal/vpn-detection/", ".claude/skills/vpn-detection-model/"]

SAFETY = ["TypeOK", "NoEntryFilesOffVPN", "GateFollowsLastPublished", "NothingPublishedAfterStop",
          "WakeRecoversOnlyWhenSeeing", "SweepsNotHeldWhenDefinite", "OrchestratorAfterEntryFiles",
          "OrchestratorFollowsLastPublished"]
LIVENESS = ["NoStuckUnknown", "FilesFollowVPN", "VPNReconnects"]

# The bounds: how much the environment may do in one behaviour. Every check runs two Starts,
# one tunnel drop and one store outage; each adds one more kind of trouble, because all of
# them at once is more states than a CI run affords.
BASE = dict(MaxStarts=2, MaxTunnelDrops=1, MaxSilentChanges=0, MaxStoreBreaks=1, MaxCancelFailures=0,
            MaxHelperOutages=0, MaxCallbackRestarts=0, MaxSystemWakes=0, WithOrchestrator="FALSE")
CORE = dict(BASE, MaxCancelFailures=1, MaxCallbackRestarts=1)
# Here the one tunnel change is the one whose notification is lost.
LOST_NOTIFICATION = dict(BASE, MaxTunnelDrops=0, MaxSilentChanges=1)
HELPER = dict(BASE, MaxHelperOutages=1)
ORCHESTRATOR = dict(BASE, WithOrchestrator="TRUE", MaxSystemWakes=1)
SAFETY_BOUNDS = BASE
LIVENESS_BOUNDS = BASE


class Check:
    def __init__(self, name, bounds, invariants=(), properties=(), expect=None, note="", full=None):
        self.name, self.bounds = name, bounds  # None: a `--full` check only
        self.full = full or bounds  # the bounds `--full` runs
        self.invariants, self.properties = list(invariants), list(properties)
        self.expect = expect  # None: must pass; otherwise the property that must break
        self.note = note

    def config(self):
        lines = ["SPECIFICATION Spec" if self.properties else "INIT Init\nNEXT Next", "CONSTANTS"]
        lines += [f"  {k} = {v}" for k, v in self.bounds.items()]
        lines.append("  GatewayUnderManagedDomain = TRUE")
        if self.invariants:
            lines.append("INVARIANTS " + " ".join(self.invariants))
        if self.properties:
            lines.append("PROPERTIES " + " ".join(self.properties))
        return "\n".join(lines) + "\n"


CHECKS = [
    Check("safety-core", CORE, invariants=SAFETY),
    Check("safety-lost-notification", LOST_NOTIFICATION, invariants=SAFETY),
    # The outcomes of operations queued around a helper outage, recorded in any order, are the
    # costliest interleavings: one Start here takes 30 s, two take 6 minutes (`--full`).
    Check("safety-helper-outage", dict(HELPER, MaxStarts=1), invariants=SAFETY, full=HELPER),
    Check("safety-orchestrator", ORCHESTRATOR, invariants=SAFETY),
    Check("liveness", LIVENESS_BOUNDS, invariants=["TypeOK"], properties=LIVENESS),
    Check("liveness-lost-notification", LOST_NOTIFICATION, invariants=["TypeOK"], properties=LIVENESS),
    # By default one Start and no store outage. `--full` adds the store outage, which is the case
    # where the repair must remove the files while the gate stays .unknown.
    Check("liveness-helper-outage", dict(HELPER, MaxStarts=1, MaxStoreBreaks=0), invariants=["TypeOK"],
          properties=LIVENESS, full=dict(HELPER, MaxStarts=1)),
    # Two Starts with the helper outage: a correction that a report kept across Stop and Start
    # queues, failing while the helper is down. `--full` only.
    Check("liveness-restart-helper-outage", None, invariants=["TypeOK"], properties=LIVENESS,
          full=dict(HELPER, MaxStoreBreaks=0)),
    Check("known-gap-u4", BASE, invariants=["ApplyOnlyFromCurrentSession"],
          expect="ApplyOnlyFromCurrentSession",
          note="A Start writes entry files from the verdict the last session left (design U4)."),
]

CHECK_NAMED = {check.name: check for check in CHECKS}


class Mutant:
    """A historical bug, mirrored in the spec. `swift` names the scratch change in the product code."""

    def __init__(self, name, swift, edits, expect, bounds=None, check=None):
        self.name, self.swift, self.edits, self.expect = name, swift, edits, expect
        live = expect in LIVENESS
        # `check`: the check that catches it, at the bounds `--full` runs it; a `--full` mutant only.
        self.check = check
        self.bounds = bounds or (CHECK_NAMED[check].full if check else LIVENESS_BOUNDS if live else SAFETY_BOUNDS)


MUTANTS = [
    Mutant("a1-no-prime",
           "VPNStatusMonitor.start: the queued block makes the session but never calls attempt(generation)",
           [("    THEN /\\ sess' = NewSession(g)\n         /\\ Attempt(g, NewSession(g))",
             "    THEN /\\ sess' = NewSession(g)\n         /\\ mon' = mon /\\ UNCHANGED <<lc, liveSubs>>")],
           "NoStuckUnknown"),
    Mutant("a2-no-retry",
           "VPNStatusMonitor.reconcile: `case .failed` sets readDue = nil instead of retry.due",
           [("ReadDue(reading) == TRUE", "ReadDue(reading) == reading # \"failed\"")],
           "NoStuckUnknown"),
    Mutant("b1-publish-after-stop",
           "VPNStatusMonitor.reconcile: the isCurrent checks inside barrier.deliver removed (before 54a5f254)",
           [("EnterCheck == IsCurrent(mon.gen)", "EnterCheck == TRUE"),
            ("VerdictCheckOK == IsCurrent(mon.gen)", "VerdictCheckOK == TRUE")],
           "NothingPublishedAfterStop"),
    Mutant("b2-stop-ignores-barrier",
           "VPNStatusMonitor.stop: the teardown runs outside barrier.stop",
           [("StopWaitsForBarrier == mon.pc \\notin BarrierPCs", "StopWaitsForBarrier == TRUE")],
           "NothingPublishedAfterStop"),
    Mutant("b3-failure-before-stop-dropped",
           "RuntimeHost.handleVPNStateChange: `guard networkPathObserving else { return }`, so a report "
           "that lands after the observers stopped is dropped (the 179b477f shape)",
           [("HostTakesReports == TRUE", "HostTakesReports == Observing")],
           "GateFollowsLastPublished"),
    Mutant("c-unknown-keeps-files",
           "SplitDNSVPNGate.entriesWanted: `.unknown` returns true (before 0048, c9df90bb)",
           [("Wanted(v) == v \\in {\"connected\", \"reasserting\"}",
             "Wanted(v) == v \\in {\"connected\", \"reasserting\", \"unknown\"}")],
           "NoEntryFilesOffVPN"),
    Mutant("c-bootstrap-deadlock",
           "SplitDNSVPNGate.entriesWanted: `.unknown` returns true, on a store that stays unreadable",
           [("Wanted(v) == v \\in {\"connected\", \"reasserting\"}",
             "Wanted(v) == v \\in {\"connected\", \"reasserting\", \"unknown\"}")],
           "VPNReconnects"),
    Mutant("ac-stuck-unknown-deadlock",
           "Both: no prime at start and `.unknown` keeps the files (July 2026, 853021fc)",
           [("    THEN /\\ sess' = NewSession(g)\n         /\\ Attempt(g, NewSession(g))",
             "    THEN /\\ sess' = NewSession(g)\n         /\\ mon' = mon /\\ UNCHANGED <<lc, liveSubs>>"),
            ("Wanted(v) == v \\in {\"connected\", \"reasserting\"}",
             "Wanted(v) == v \\in {\"connected\", \"reasserting\", \"unknown\"}")],
           "VPNReconnects"),
    Mutant("order-unchecked",
           "RuntimeHost.handleVPNStateChange: the gate takes every report, without splitDNSGateOrder.admit (#155)",
           [("GateAdmitsAt(r, applied) == r.seq > applied", "GateAdmitsAt(r, applied) == TRUE")],
           "GateFollowsLastPublished"),
    Mutant("wake-recovers-blind",
           "ProxyOrchestrator.handleSystemWake: `!vpn.blind` dropped from the recovery guard",
           [("WakeSeesStore == ~orch.blind", "WakeSeesStore == TRUE")],
           "WakeRecoversOnlyWhenSeeing", bounds=ORCHESTRATOR),
    Mutant("blinded-keeps-sweeps",
           "VPNReactionHistory.record: `wasBlind ||` dropped from the confirmed guard, so the same definite "
           "verdict after a blind reading returns nil and the held sweeps never resume",
           [("ConfirmsAfterBlind(o) == o.blind", "ConfirmsAfterBlind(o) == FALSE")],
           "SweepsNotHeldWhenDefinite", bounds=ORCHESTRATOR),
    Mutant("repair-takes-stale-outcome",
           "SplitDNSEntryFileRepair.record: the `startedAt < generation` guard removed, so an older success "
           "recorded after a newer failure forgets the failure",
           [("RecordKeeps(o) == ~(o.place < repair.generation)", "RecordKeeps(o) == TRUE")],
           "NoEntryFilesOffVPN", bounds=HELPER),
    Mutant("started-after-observers",
           "RuntimeHost.applyProxySurfaces: `runtimeStarted = true` moved after startObservers, so a report "
           "landing while the DNS and tunnel members start acts as for a stopped proxy",
           [("StartedAtSurfaces == TRUE", "StartedAtSurfaces == FALSE")],
           "FilesFollowVPN"),
    Mutant("orchestrator-before-files",
           "RuntimeHost.handleVPNStateChange: orchestrator.handleVPNStateChange called before "
           "`await reconcileEntryFiles`",
           [("OrchestratorAfterFiles == TRUE", "OrchestratorAfterFiles == FALSE")],
           "OrchestratorAfterEntryFiles", bounds=ORCHESTRATOR),
    Mutant("orchestrator-order-unchecked",
           "ProxyOrchestrator.handleVPNStateChange: the `vpnObservations.admit` check removed (#155)",
           [("OrchAdmits(r) == r.seq > orch.seq", "OrchAdmits(r) == TRUE")],
           "OrchestratorFollowsLastPublished", bounds=ORCHESTRATOR),
    Mutant("retry-skips-unknown",
           "SplitDNSEntryFileRepair.desiredOperation returns nil for an `.unknown` gate, so planRetry runs "
           "nothing: a removal that failed while the store was unreadable is never retried",
           [("    /\\ repair.pending /\\ helperUp /\\ ~repair.inFlight\n",
             "    /\\ repair.pending /\\ helperUp /\\ ~repair.inFlight /\\ host.gate # \"unknown\"\n")],
           "FilesFollowVPN", check="liveness-helper-outage"),
    Mutant("correction-failure-dropped",
           "RuntimeHost.applyProxySurfaces: the gate-moved correction runs its operation but does not "
           "record a failure, so nothing is pending and no retry comes",
           [("    LET keep    == RecordKeeps(o)\n",
             "    LET keep    == RecordKeeps(o) /\\ (o.ok \\/ o.owner # \"correction\")\n")],
           "FilesFollowVPN", check="liveness-restart-helper-outage"),
]


def tla_jar():
    jar = TOOLS / f"tla2tools-{TLA_VERSION}.jar"
    if jar.exists() and hashlib.sha256(jar.read_bytes()).hexdigest() == TLA_SHA256:
        return jar
    TOOLS.mkdir(parents=True, exist_ok=True)
    partial = jar.with_suffix(".partial")
    print(f"fetching {TLA_URL}", flush=True)
    with urllib.request.urlopen(TLA_URL, timeout=120) as response:
        partial.write_bytes(response.read())
    digest = hashlib.sha256(partial.read_bytes()).hexdigest()
    if digest != TLA_SHA256:
        partial.unlink()
        sys.exit(f"tla2tools.jar checksum mismatch: got {digest}, pinned {TLA_SHA256}")
    partial.replace(jar)
    return jar


def run_tlc(jar, name, spec_text, cfg_text):
    work = OUT / name
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / "VPNDetection.tla").write_text(spec_text)
    (work / "VPNDetection.cfg").write_text(cfg_text)
    cmd = ["java", "-XX:+UseParallelGC", "-Xss16m", "-cp", str(jar), "tlc2.TLC",
           "-workers", os.environ.get("TLC_WORKERS", "auto"), "-cleanup",
           "-metadir", str(work / "states"), "-config", "VPNDetection.cfg", "VPNDetection.tla"]
    started = time.monotonic()
    result = subprocess.run(cmd, cwd=work, capture_output=True, text=True)
    elapsed = time.monotonic() - started
    output = result.stdout + result.stderr
    (work / "tlc.out").write_text(output)
    shutil.rmtree(work / "states", ignore_errors=True)
    return output, result.returncode, elapsed, work


def summary(output):
    states = re.search(r"(\d[\d,]*) states generated, (\d[\d,]*) distinct states found", output)
    depth = re.search(r"The depth of the complete state graph search is (\d+)", output)
    parts = []
    if states:
        parts.append(f"{states.group(1)} generated, {states.group(2)} distinct")
    if depth:
        parts.append(f"depth {depth.group(1)}")
    return ", ".join(parts)


# TLC's exit statuses (tlc2.output.EC.ExitStatus in tla2tools 1.7.4).
EXIT_SUCCESS, EXIT_DEADLOCK, EXIT_SAFETY, EXIT_LIVENESS = 0, 11, 12, 13


def outcome(output, returncode):
    """What TLC found: "pass", the invariant it reports violated, "temporal" or "deadlock".
    None when its exit status and its output do not agree on one of those, which counts as
    TLC not finishing: a crash, a parse error, or an evaluation error mid-run."""
    if m := re.search(r"Invariant (\w+) is violated", output):
        return m.group(1) if returncode == EXIT_SAFETY else None
    if "Temporal properties were violated" in output:
        return "temporal" if returncode == EXIT_LIVENESS else None
    if "Deadlock reached" in output:
        return "deadlock" if returncode == EXIT_DEADLOCK else None
    if "Model checking completed. No error has been found." in output and returncode == EXIT_SUCCESS:
        return "pass"
    return None


def changed(ref):
    """The covered and model files that differ between `ref` and the working tree."""
    root = HERE.parent.parent
    for path in COVERED:
        if not (root / path).is_file():
            sys.exit(f"{path} is in COVERED but does not exist; update the coverage record and COVERED")
    result = subprocess.run(["git", "diff", "--name-only", ref, "--", *COVERED, *MODEL],
                            cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"git diff {ref} failed: {result.stderr.strip()}")
    return result.stdout.split()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mutants", action="store_true", help="also run every historical-bug mutant")
    parser.add_argument("--only", help="run only the named check or mutant")
    parser.add_argument("--full", action="store_true",
                        help="run the checks at their larger bounds, the `--full` checks, and with --mutants their mutants")
    parser.add_argument("--changed", metavar="REF",
                        help="print the covered and model files changed since REF, and run nothing")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    if args.changed:
        print("\n".join(changed(args.changed)))
        return

    jar = tla_jar()
    spec = SPEC.read_text()
    failures = []

    for check in CHECKS:
        if args.only and args.only != check.name:
            continue
        if args.full or check.bounds is None:
            if not (args.full or args.only):
                continue
            check.bounds = check.full
        output, code, elapsed, work = run_tlc(jar, check.name, spec, check.config())
        got = outcome(output, code)
        if got is None:
            failures.append(check.name)
            print(f"FAIL {check.name}: TLC did not finish (exit {code}), see {work / 'tlc.out'}")
            continue
        if check.expect is None:
            ok = got == "pass"
            verdict = "pass" if ok else f"FAIL, {got} violated"
        else:
            ok = got == check.expect
            verdict = f"still breaks {got} as recorded" if ok else f"FAIL, expected {check.expect} to break, got {got}"
        print(f"{'ok  ' if ok else 'FAIL'} {check.name}: {verdict} ({summary(output)}, {elapsed:.0f} s)")
        if check.note and ok:
            print(f"     {check.note}")
        if not ok:
            failures.append(check.name)
            print(f"     see {work / 'tlc.out'}")

    for mutant in MUTANTS:
        if not (args.mutants or args.only == mutant.name) or (args.only and args.only != mutant.name):
            continue
        if mutant.check and not (args.full or args.only):
            continue
        text = spec
        for old, new in mutant.edits:
            if text.count(old) != 1:
                sys.exit(f"mutant {mutant.name}: the spec no longer has exactly one copy of {old!r}; update it")
            text = text.replace(old, new)
        live = mutant.expect in LIVENESS
        cfg = Check(mutant.name, mutant.bounds, invariants=[] if live else [mutant.expect],
                    properties=[mutant.expect] if live else []).config()
        output, code, elapsed, work = run_tlc(jar, f"mutant-{mutant.name}", text, cfg)
        got = outcome(output, code)
        want = "temporal" if live else mutant.expect
        ok = got == want
        print(f"{'ok  ' if ok else 'FAIL'} mutant {mutant.name}: {mutant.expect} "
              f"{'caught' if ok else f'NOT caught ({got}, exit {code})'} ({summary(output)}, {elapsed:.0f} s)")
        print(f"     {mutant.swift}")
        if not ok:
            failures.append(mutant.name)
            print(f"     see {work / 'tlc.out'}")

    if failures:
        sys.exit(f"failed: {', '.join(failures)}")


if __name__ == "__main__":
    main()
