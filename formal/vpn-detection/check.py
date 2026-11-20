#!/usr/bin/env python3
"""Model-check the VPN detection chain (VPNDetection.tla) and the 0049 resolver override
(VPNDNSOverride.tla) with TLC.

    python3 formal/vpn-detection/check.py            # the checks CI runs
    python3 formal/vpn-detection/check.py --mutants  # also show each property catching its bug
    python3 formal/vpn-detection/check.py --only safety-core
    python3 formal/vpn-detection/check.py --spec override --mutants  # one spec's checks and mutants
    python3 formal/vpn-detection/check.py --full --mutants  # larger bounds, the `--full` checks and mutants
    python3 formal/vpn-detection/check.py --full=override --mutants  # the full tier for one spec only
    python3 formal/vpn-detection/check.py --changed origin/main  # the covered files a branch changes
    python3 formal/vpn-detection/check.py --full-for origin/main # the specs those files belong to

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
TOOLS = HERE.parent / ".tools"
OUT = HERE / ".out"

TLA_VERSION = "1.7.4"
TLA_URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{TLA_VERSION}/tla2tools.jar"
TLA_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"

# A change to any covered or model file runs that spec's full tier in CI (`--full-for`).
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
MODEL = ["formal/vpn-detection/VPNDetection.tla", "formal/vpn-detection/check.py",
         ".claude/skills/vpn-detection-model/"]

OVERRIDE_COVERED = [
    "Sources/ConduitShared/VPNDNSOverrideLedger.swift",
    "Sources/ConduitHelper/HelperDaemon.swift",
    "Sources/ConduitHelper/HelperEventLoop.swift",
    "Sources/PlatformMac/VPNResolverOverridePolicy.swift",
    "Sources/PlatformMac/VPNResolverOverrideController.swift",
    "Sources/PlatformMac/PushedResolver.swift",
    "Sources/PlatformMac/PushedResolverMonitor.swift",
    "Sources/ConduitRuntime/RuntimeHostVPNDNSOverride.swift",
    "Sources/ConduitRuntime/RuntimeHostSplitDNSDetection.swift",
]
OVERRIDE_MODEL = ["formal/vpn-detection/VPNDNSOverride.tla", "formal/vpn-detection/check.py",
                  ".claude/skills/vpn-dns-override-model/"]


class Spec:
    def __init__(self, name, module, covered, model, constants):
        self.name, self.module, self.covered, self.model = name, module, covered, model
        self.constants = constants
        # Open bugs as (old, new) edits: checks run with the fix; the spec's text runs as a `bug-` mutant that must fail.
        self.fixes = []

    def text(self):
        text = (HERE / f"{self.module}.tla").read_text()
        for old, new in self.fixes:
            if text.count(old) != 1:
                sys.exit(f"{self.name}: open-bug fix {old!r} is no longer in the spec exactly once; "
                         "if the code was fixed, flip the switch in the spec and turn the bug into a mutant")
            text = text.replace(old, new)
        return text


DETECTION = Spec("detection", "VPNDetection", COVERED, MODEL, {"GatewayUnderManagedDomain": "TRUE"})
OVERRIDE = Spec("override", "VPNDNSOverride", OVERRIDE_COVERED, OVERRIDE_MODEL, {})
SPECS = {spec.name: spec for spec in (DETECTION, OVERRIDE)}

SAFETY = ["TypeOK", "NoEntryFilesOffVPN", "GateFollowsLastPublished", "NothingPublishedAfterStop",
          "WakeRecoversOnlyWhenSeeing", "SweepsNotHeldWhenDefinite", "OrchestratorAfterEntryFiles",
          "OrchestratorFollowsLastPublished", "ApplyOnlyFromCurrentSession"]
LIVENESS = ["NoStuckUnknown", "FilesFollowVPN", "VPNReconnects"]
OVERRIDE_SAFETY = ["TypeOK", "NoClobber", "NoSelfReference", "NoServerlessDefault", "ReleaseBeforeUnset",
                   "NoLoopbackWithoutService", "ClientKeyKept", "OneRefusalPerTrigger", "LandedNoted"]
OVERRIDE_LIVENESS = ["EventuallyReleased", "SuspensionEnds"]
TEMPORAL = set(LIVENESS) | set(OVERRIDE_LIVENESS)

# The bounds: how much the environment may do in one behaviour. Every check runs two Starts,
# one of whose Stops may take the proxy alone down, one tunnel drop and one store outage;
# each adds one more kind of trouble, because all of them at once is more states than a CI
# run affords.
BASE = dict(MaxStarts=2, MaxProxyStops=1, MaxTunnelDrops=1, MaxSilentChanges=0, MaxStoreBreaks=1, MaxCancelFailures=0,
            MaxHelperOutages=0, MaxCallbackRestarts=0, MaxSystemWakes=0, WithOrchestrator="FALSE")
CORE = dict(BASE, MaxCancelFailures=1, MaxCallbackRestarts=1)
# Here the one tunnel change is the one whose notification is lost.
LOST_NOTIFICATION = dict(BASE, MaxTunnelDrops=0, MaxSilentChanges=1)
HELPER = dict(BASE, MaxHelperOutages=1)
ORCHESTRATOR = dict(BASE, WithOrchestrator="TRUE", MaxSystemWakes=1)
SAFETY_BOUNDS = BASE
LIVENESS_BOUNDS = BASE


class Check:
    def __init__(self, name, bounds, invariants=(), properties=(), full=None, spec=DETECTION):
        self.name, self.bounds = name, bounds  # None: a `--full` check only
        self.full = full or bounds  # the bounds `--full` runs
        self.invariants, self.properties = list(invariants), list(properties)
        self.spec = spec

    def config(self):
        lines = ["SPECIFICATION Spec" if self.properties else "INIT Init\nNEXT Next", "CONSTANTS"]
        lines += [f"  {k} = {v}" for k, v in {**self.bounds, **self.spec.constants}.items()]
        if self.invariants:
            lines.append("INVARIANTS " + " ".join(self.invariants))
        if self.properties:
            lines.append("PROPERTIES " + " ".join(self.properties))
        return "\n".join(lines) + "\n"


CHECKS = [
    Check("safety-core", CORE, invariants=SAFETY),
    Check("safety-lost-notification", LOST_NOTIFICATION, invariants=SAFETY),
    # The outcomes of operations queued around a helper outage, recorded in any order, are the
    # costliest interleavings: one Start by default, two with `--full`.
    Check("safety-helper-outage", dict(HELPER, MaxStarts=1), invariants=SAFETY, full=HELPER),
    Check("safety-orchestrator", ORCHESTRATOR, invariants=SAFETY),
    Check("liveness", LIVENESS_BOUNDS, invariants=["TypeOK"], properties=LIVENESS),
    Check("liveness-lost-notification", LOST_NOTIFICATION, invariants=["TypeOK"], properties=LIVENESS),
    # By default one Start and no store outage. `--full` adds the store outage: the repair must
    # then remove the files while the proxy runs and the gate stays .unknown.
    Check("liveness-helper-outage", dict(HELPER, MaxStarts=1, MaxStoreBreaks=0), invariants=["TypeOK"],
          properties=LIVENESS, full=dict(HELPER, MaxStarts=1)),
    # Two Starts with the helper outage and no store outage: after a Stop of the proxy alone the
    # monitor runs on, so a report landing while the next Start applies queues a correction,
    # which can fail while the helper is down. `--full` only; with the store outage as well it
    # ran past 70 minutes and 12 GB of TLC state on a 12-core laptop without finishing, before
    # the proxy-alone Stop was in the model.
    Check("liveness-restart-helper-outage", None, invariants=["TypeOK"], properties=LIVENESS,
          full=dict(HELPER, MaxStoreBreaks=0)),
]

# Each override safety check takes one class of trouble: all of them at once exhausts TLC's memory.
OVERRIDE_NONE = dict(MaxVersions=1, MaxDisconnects=0, MaxGateFlaps=0, MaxRepublishes=0, MaxIPv4Flaps=0,
                     MaxSameRewrites=0, MaxOwnerExits=0, MaxHelperCrashes=0, MaxRelayDeaths=0,
                     MaxForwarderFaults=0, MaxDNSStops=0, MaxWriteFails=0, MaxLostReplies=0, ApplyCap=3,
                     Endless="FALSE")
OVERRIDE_CLIENT = dict(OVERRIDE_NONE, MaxVersions=3, MaxDisconnects=1, MaxGateFlaps=1, MaxIPv4Flaps=1,
                       MaxDNSStops=1)
OVERRIDE_PROCESS = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxIPv4Flaps=1, MaxOwnerExits=1,
                        MaxHelperCrashes=1, MaxDNSStops=1)
OVERRIDE_RELAY = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxGateFlaps=1, MaxRelayDeaths=1,
                      MaxForwarderFaults=1, MaxDNSStops=1)
OVERRIDE_LIVE = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxOwnerExits=1,
                     MaxRelayDeaths=1, MaxForwarderFaults=1)
OVERRIDE_MUTANT = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxGateFlaps=1, MaxIPv4Flaps=1,
                       MaxOwnerExits=1, MaxHelperCrashes=1, MaxDNSStops=1)
OVERRIDE_FLAPS = dict(OVERRIDE_NONE, MaxIPv4Flaps=3)
OVERRIDE_SAME_REWRITE = dict(OVERRIDE_NONE, MaxSameRewrites=1, MaxIPv4Flaps=1)
OVERRIDE_ENDLESS = dict(OVERRIDE_NONE, MaxSameRewrites=1, MaxIPv4Flaps=1, Endless="TRUE")
OVERRIDE_SUSPENSION = dict(OVERRIDE_NONE, MaxVersions=3, ApplyCap=1)
OVERRIDE_FAULTS = dict(OVERRIDE_NONE, MaxVersions=2, MaxGateFlaps=1, MaxOwnerExits=1,
                       MaxForwarderFaults=1, MaxDNSStops=1, MaxWriteFails=1, MaxLostReplies=1)
OVERRIDE_FAULTS_LIVE = dict(OVERRIDE_NONE, MaxVersions=2, MaxRelayDeaths=1, MaxForwarderFaults=1,
                            MaxWriteFails=1, MaxLostReplies=1)
CHECKS += [
    Check("override-safety-client", OVERRIDE_CLIENT, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_CLIENT, MaxVersions=4), spec=OVERRIDE),
    Check("override-safety-process", OVERRIDE_PROCESS, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_PROCESS, MaxVersions=3), spec=OVERRIDE),
    Check("override-safety-relay", OVERRIDE_RELAY, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_RELAY, MaxVersions=3), spec=OVERRIDE),
    Check("override-liveness", OVERRIDE_LIVE, invariants=["TypeOK"], properties=OVERRIDE_LIVENESS,
          full=dict(OVERRIDE_LIVE, MaxIPv4Flaps=1), spec=OVERRIDE),
    Check("override-flaps", OVERRIDE_FLAPS, invariants=OVERRIDE_SAFETY + ["NeverSuspended"],
          full=dict(OVERRIDE_FLAPS, MaxVersions=2), spec=OVERRIDE),
    Check("override-same-rewrite", OVERRIDE_SAME_REWRITE, invariants=OVERRIDE_SAFETY + ["NeverLost"],
          full=dict(OVERRIDE_SAME_REWRITE, MaxSameRewrites=2), spec=OVERRIDE),
    Check("override-same-endless", OVERRIDE_ENDLESS, invariants=OVERRIDE_SAFETY + ["NeverSuspended", "NeverLost"],
          full=dict(OVERRIDE_ENDLESS, MaxVersions=2), spec=OVERRIDE),
    Check("override-suspension-expires", OVERRIDE_SUSPENSION, invariants=["TypeOK"], properties=["SuspensionEnds"],
          full=dict(OVERRIDE_SUSPENSION, MaxIPv4Flaps=1), spec=OVERRIDE),
    Check("override-store-faults", OVERRIDE_FAULTS, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_FAULTS, MaxWriteFails=2), spec=OVERRIDE),
    Check("override-store-faults-liveness", OVERRIDE_FAULTS_LIVE, invariants=["TypeOK"],
          properties=["EventuallyReleased"], full=dict(OVERRIDE_FAULTS_LIVE, MaxWriteFails=2), spec=OVERRIDE),
]

CHECK_NAMED = {check.name: check for check in CHECKS}


class Mutant:
    """A historical bug, mirrored in the spec. `swift` names the scratch change in the product code."""

    def __init__(self, name, swift, edits, expect, bounds=None, check=None, spec=DETECTION):
        self.name, self.swift, self.edits, self.expect = name, swift, edits, expect
        self.spec = spec
        live = expect in TEMPORAL
        # `check`: the check that catches it, at that check's bounds in each tier (`bounds_for`).
        self.check = check
        self.bounds = bounds or (LIVENESS_BOUNDS if live else SAFETY_BOUNDS)

    def bounds_for(self, full, only):
        """The bounds this run uses, or None when the tier does not run this mutant."""
        if not self.check:
            return self.bounds
        check = CHECK_NAMED[self.check]
        return check.full if full or (only and check.bounds is None) else check.bounds


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
           "RuntimeHost.handleVPNStateChange: `guard networkPathObserving else { return }` (the 179b477f shape), "
           "so a report that lands after a whole-host Stop never reaches the orchestrator: a store failure "
           "published just before the Stop leaves it on the last definite verdict",
           [("HostTakesReports == TRUE", "HostTakesReports == ObserversRunning")],
           "OrchestratorFollowsLastPublished", check="safety-orchestrator"),
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
           "nothing: a removal that failed while the gate is .unknown, after a Stop or on an unreadable store, "
           "is never retried",
           [("    /\\ repair.pending /\\ helperUp /\\ ~repair.inFlight\n",
             "    /\\ repair.pending /\\ helperUp /\\ ~repair.inFlight /\\ host.gate # \"unknown\"\n")],
           "FilesFollowVPN", check="liveness-helper-outage"),
    Mutant("correction-failure-dropped",
           "RuntimeHost.applyProxySurfaces: the gate-moved correction runs its operation but does not "
           "record a failure, so nothing is pending and no retry comes",
           [("    LET keep    == RecordKeeps(o)\n",
             "    LET keep    == RecordKeeps(o) /\\ (o.ok \\/ o.owner # \"correction\")\n")],
           "FilesFollowVPN", check="liveness-restart-helper-outage"),
    Mutant("u4-gate-kept-at-stop",
           "RuntimeHost.stopVPNMonitor: `splitDNSGate = SplitDNSVPNGate()` removed, so the next Start applies "
           "entry files from the stopped session's verdict (before #324)",
           [("GateForgetsAtStop == TRUE", "GateForgetsAtStop == FALSE")],
           "ApplyOnlyFromCurrentSession"),
    Mutant("u4-no-fence-at-stop",
           "RuntimeHost.stopVPNMonitor: `splitDNSGateOrder.skip(through: vpnSequencer.issued)` removed, so a "
           "report stamped before the stop lands after it and restores the verdict",
           [("FenceAtStop == TRUE", "FenceAtStop == FALSE")],
           "ApplyOnlyFromCurrentSession"),
]


def override_mutant(name, swift, edits, expect, bounds=None):
    live = expect in TEMPORAL
    check = "override-liveness" if live and not bounds else None
    bounds = bounds or (None if live else OVERRIDE_MUTANT)
    return Mutant(name, swift, edits, expect, bounds=bounds, check=check, spec=OVERRIDE)


OVERRIDE_FORWARDER_ONLY = dict(OVERRIDE_NONE, MaxVersions=2, MaxForwarderFaults=1)
OVERRIDE_WRITE_FAILS = dict(OVERRIDE_NONE, MaxVersions=2, MaxForwarderFaults=1, MaxWriteFails=1)
OVERRIDE_LOST_REPLY = dict(OVERRIDE_NONE, MaxVersions=2, MaxLostReplies=1)


MUTANTS += [
    override_mutant(
        "ov-release-no-compare",
        "VPNDNSOverrideLedger.restore: delete `guard dns[\"ServerAddresses\"] == .strings(Self.relayServers) "
        "else { return .keyChanged }`, so the originals are written over whatever the key holds",
        [("ReleaseCompares == TRUE", "ReleaseCompares == FALSE")],
        "NoClobber"),
    override_mutant(
        "ov-apply-gone-no-compare",
        "VPNDNSOverrideLedger.apply: on a missing IPv4 key, write the originals back without the "
        "`store.dns(service:) == overridden` check, so a value the client wrote since is overwritten",
        [("ApplyGoneCompares == TRUE", "ApplyGoneCompares == FALSE")],
        "NoClobber"),
    override_mutant(
        "ov-removes-key-without-ipv4",
        "VPNDNSOverrideLedger.restore ends `guard !store.ipv4Exists(service:) else { return "
        ".restored }; return store.removeDNS(service:) ? ...`, and apply's no-IPv4 path removes its key, so "
        "a flap of the IPv4 key deletes the client's DNS key",
        [("RemovesGoneKey == FALSE", "RemovesGoneKey == TRUE")],
        "ClientKeyKept"),
    override_mutant(
        "ov-apply-no-service-check",
        "VPNDNSOverrideLedger.apply: delete `guard store.ipv4Exists(service:)` after setDNS, so a client "
        "delete between check and setDNS leaves a recreated key at 127.0.0.1 on a removed service",
        [("ApplyChecksService == TRUE", "ApplyChecksService == FALSE")],
        "NoLoopbackWithoutService"),
    override_mutant(
        "ov-apply-before-live-set",
        "VPNResolverOverridePolicy.wanted: delete `guard tunnel.servers.allSatisfy(input.serversInUse.contains)`, "
        "so an apply goes out before the live set has the tunnel's servers",
        [("ServersInUse == TRUE", "ServersInUse == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-set-dropped-before-release",
        "RuntimeHostSplitDNSDetection.applyPendingSplitDNSDetection: delete `|| vpnDNSOverrideReleases(before: set)`, "
        "so the set without the tunnel's servers is applied before the release",
        [("HoldBeforeRelease == TRUE", "HoldBeforeRelease == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-parser-no-substitution",
        "PushedResolverReading.parseResolver: `if overridden, let substitution { stored = substitution }` "
        "removed and 127.0.0.1 not dropped as self-referential, so the override reads as a tunnel server",
        [("ParseLoopback(box) == box", "ParseLoopback(box) == LO")],
        "NoSelfReference"),
    override_mutant(
        "ov-no-note-exit",
        "HelperDaemon.run: delete `loop.watchOwner(...)` after each event, so an owner's exit releases only "
        "through tick(), which a relaunched app's answering forwarder satisfies",
        [("WatchOwner == TRUE", "WatchOwner == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-exits-after-connection",
        "HelperEventLoop.ordered: return `(connection ? [.connection] : []) + signals + exits`, so the "
        "relaunched app's connection is served before the dead owner's exit",
        [("ExitsFirst == TRUE", "ExitsFirst == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-record-kept-at-start",
        "VPNDNSOverrideLedger.start: `case .record(let persisted)` keeps `record = persisted` without "
        "`release(reason: .helperStart)`; the fresh helper watches no owner",
        [("ReleaseAtStart == TRUE", "ReleaseAtStart == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-tick-ignores-refused",
        "VPNDNSOverrideLedger.tick: `case .refused` never reaches the streak of 2 that releases with "
        "target_refused, so a stopped forwarder's 127.0.0.1 waits on the app's own release",
        [("IF h.refused + 1 >= 2 THEN StartRelease(\"none\", 0)", "IF h.refused + 1 >= 2 THEN UNCHANGED h")],
        "EventuallyReleased", bounds=OVERRIDE_FORWARDER_ONLY),
    override_mutant(
        "ov-tick-ignores-silent",
        "VPNDNSOverrideLedger.tick: `case .silent` never reaches the streak of 3 that releases with "
        "target_silent, so a hung app's 127.0.0.1 is never given back",
        [("IF h.silent + 1 >= 3 THEN StartRelease(\"none\", 0)", "IF h.silent + 1 >= 3 THEN UNCHANGED h")],
        "EventuallyReleased", bounds=OVERRIDE_FORWARDER_ONLY),
    override_mutant(
        "ov-held-set-applied-unchecked",
        "RuntimeHostVPNDNSOverride.runVPNDNSOverride: apply vpnDNSOverrideHeldSet after the pass without "
        "asking vpnDNSOverrideReleases(before:) again, so a set held while an apply was out drops the "
        "tunnel's servers before the release that follows",
        [("HeldSetRechecked == TRUE", "HeldSetRechecked == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-hold-reads-live-set",
        "VPNResolverOverridePolicy.holds: test the record's originals against the orchestrator's live set "
        "(orchestrator.detectedSplitDNSRules) instead of the serversInUse decide is handed, so "
        "vpnDNSOverrideReleases(before:) no longer sees the set about to drop them",
        [("HoldOnSetInUse == TRUE", "HoldOnSetInUse == FALSE")],
        "ReleaseBeforeUnset"),
    override_mutant(
        "ov-same-servers-capped",
        "VPNResolverOverridePolicy.decide: check `recent(input.applies) < maximumApplies` whatever "
        "`last?.servers`, and VPNResolverOverrideController.apply: `note(service, in: &applies)` on every landed "
        "apply, so a client writing its own servers back is suspended after maximumApplies re-applies",
        [("SameServersUncapped == TRUE", "SameServersUncapped == FALSE")],
        "NeverSuspended", bounds=OVERRIDE_ENDLESS),
    override_mutant(
        "ov-refusals-capped",
        "VPNResolverOverridePolicy.decide: suspend once `recent(input.refusals)` reaches a cap, so a client that "
        "flaps without end and is refused each time suspends the override",
        [("RefusalsCapped == FALSE", "RefusalsCapped == TRUE")],
        "NeverSuspended", bounds=OVERRIDE_ENDLESS),
    override_mutant(
        "ov-refusal-retries-at-once",
        "VPNResolverOverrideController.apply: a refused apply asks for another pass at once, so the helper is "
        "sent the refused apply again with no new reading, tick or wake in between",
        [("RefusalRetriesAtOnce == FALSE", "RefusalRetriesAtOnce == TRUE")],
        "OneRefusalPerTrigger"),
    override_mutant(
        "ov-suspension-never-expires",
        "VPNResolverOverrideController.observe: drop the loop that removes a suspension older than "
        "suspensionLifetime, so a suspension lasts until the gate turns off or DNS restarts",
        [("SuspensionsExpire == TRUE", "SuspensionsExpire == FALSE")],
        "SuspensionEnds", bounds=OVERRIDE_SUSPENSION),
    override_mutant(
        "ov-refusals-count-as-applies",
        "VPNResolverOverrideController.apply: every apply sent counts toward "
        "maximumApplies, refused or not, so three IPv4 flaps that each refuse an apply in flight suspend",
        [("RefusalsSeparate == TRUE", "RefusalsSeparate == FALSE")],
        "NeverSuspended", bounds=OVERRIDE_FLAPS),
    override_mutant(
        "ov-same-rewrite-kept",
        "VPNResolverOverrideController.confirm: never set keyRewritten, so a client that writes the same "
        "servers back over 127.0.0.1 leaves decide matching the record, and nothing re-applies",
        [("SameRewriteReapplies == TRUE", "SameRewriteReapplies == FALSE")],
        "NeverLost", bounds=OVERRIDE_SAME_REWRITE),
    override_mutant(
        "ov-failed-restore-forgotten",
        "VPNDNSOverrideLedger.release: `forgetRecord()` whatever `restore` returned, so a restore the store "
        "refused leaves the key at 127.0.0.1 with no record and nothing to retry it",
        [("KeepsFailedRestore == TRUE", "KeepsFailedRestore == FALSE")],
        "NoServerlessDefault", bounds=OVERRIDE_WRITE_FAILS),
    override_mutant(
        "ov-confirmed-apply-uncounted",
        "VPNResolverOverrideController.confirm: adopt an unconfirmed apply the status holds without "
        "`landed(...)`, so it skips noteLanded, the cap and the spacing",
        [("AdoptCounts == TRUE", "AdoptCounts == FALSE")],
        "LandedNoted", bounds=OVERRIDE_LOST_REPLY),
    override_mutant(
        "ov-unconfirmed-apply-kept",
        "VPNResolverOverrideController.decide: decide on `record` alone, so an apply whose reply was lost is not "
        "released when it stops being wanted, and the set without the tunnel's servers is applied over it",
        [("ReleasesUnconfirmed == TRUE", "ReleasesUnconfirmed == FALSE")],
        "ReleaseBeforeUnset", bounds=dict(OVERRIDE_LOST_REPLY, MaxGateFlaps=1)),
    override_mutant(
        "ov-apply-before-status",
        "VPNResolverOverrideController.pass: apply without asking the helper's status first while an apply may "
        "be unconfirmed, so a stale reading re-applies over a record the helper already holds",
        [("StatusBeforeApply == TRUE", "StatusBeforeApply == FALSE")],
        "ReleaseBeforeUnset", bounds=OVERRIDE_FAULTS),
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


def run_tlc(jar, name, module, spec_text, cfg_text):
    work = OUT / name
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / f"{module}.tla").write_text(spec_text)
    (work / f"{module}.cfg").write_text(cfg_text)
    cmd = ["java", "-XX:+UseParallelGC", "-Xss16m", "-cp", str(jar), "tlc2.TLC",
           "-workers", os.environ.get("TLC_WORKERS", "auto"), "-cleanup",
           "-metadir", str(work / "states"), "-config", f"{module}.cfg", f"{module}.tla"]
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


def changed(ref, specs=SPECS.values()):
    """The covered and model files of `specs` that differ between `ref` and the working tree."""
    root = HERE.parent.parent
    paths = []
    for spec in specs:
        for path in spec.covered:
            if not (root / path).is_file():
                sys.exit(f"{path} is in {spec.name}'s coverage list but does not exist; "
                         "update the coverage record and the list")
        paths += [p for p in spec.covered + spec.model if p not in paths]
    result = subprocess.run(["git", "diff", "--name-only", ref, "--", *paths],
                            cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"git diff {ref} failed: {result.stderr.strip()}")
    return result.stdout.split()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mutants", action="store_true", help="also run every historical-bug mutant")
    parser.add_argument("--only", help="run only the named check or mutant")
    parser.add_argument("--spec", choices=sorted(SPECS), help="run only this spec's checks and mutants")
    parser.add_argument("--full", nargs="?", const="all", metavar="SPECS",
                        help="run the checks at their larger bounds, the `--full` checks, and with --mutants their "
                             "mutants; `--full=override` (comma-separated spec names) does so for those specs only")
    parser.add_argument("--changed", metavar="REF",
                        help="print the covered and model files changed since REF, and run nothing")
    parser.add_argument("--full-for", metavar="REF",
                        help="print the specs (comma-separated) whose covered or model files changed since REF")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    if args.changed:
        print("\n".join(changed(args.changed)))
        return
    if args.full_for:
        print(",".join(spec.name for spec in SPECS.values() if changed(args.full_for, [spec])))
        return
    full_specs = set(SPECS) if args.full == "all" else set((args.full or "").split(",")) - {""}
    if full_specs - set(SPECS):
        sys.exit(f"--full: unknown spec {', '.join(sorted(full_specs - set(SPECS)))}")

    jar = tla_jar()
    texts = {name: spec.text() for name, spec in SPECS.items()}
    failures = []

    for check in CHECKS:
        if args.only and args.only != check.name or args.spec and args.spec != check.spec.name:
            continue
        full = check.spec.name in full_specs
        if full or check.bounds is None:
            if not (full or args.only):
                continue
            check.bounds = check.full
        output, code, elapsed, work = run_tlc(jar, check.name, check.spec.module, texts[check.spec.name],
                                              check.config())
        got = outcome(output, code)
        if got is None:
            failures.append(check.name)
            print(f"FAIL {check.name}: TLC did not finish (exit {code}), see {work / 'tlc.out'}")
            continue
        ok = got == "pass"
        verdict = "pass" if ok else f"FAIL, {got} violated"
        print(f"{'ok  ' if ok else 'FAIL'} {check.name}: {verdict} ({summary(output)}, {elapsed:.0f} s)")
        if not ok:
            failures.append(check.name)
            print(f"     see {work / 'tlc.out'}")

    for mutant in MUTANTS:
        if not (args.mutants or args.only == mutant.name) or (args.only and args.only != mutant.name):
            continue
        if args.spec and args.spec != mutant.spec.name:
            continue
        bounds = mutant.bounds_for(mutant.spec.name in full_specs, args.only)
        if bounds is None:
            continue
        text = texts[mutant.spec.name]
        for old, new in mutant.edits:
            if text.count(old) != 1:
                sys.exit(f"mutant {mutant.name}: the spec no longer has exactly one copy of {old!r}; update it")
            text = text.replace(old, new)
        live = mutant.expect in TEMPORAL
        cfg = Check(mutant.name, bounds, invariants=[] if live else [mutant.expect],
                    properties=[mutant.expect] if live else [], spec=mutant.spec).config()
        output, code, elapsed, work = run_tlc(jar, f"mutant-{mutant.name}", mutant.spec.module, text, cfg)
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
