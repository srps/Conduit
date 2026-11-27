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

# A change to any covered or model file needs that spec's full tier (`--full-for`); CI runs the full tiers nightly and on a tag.
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
    "Sources/HelperSupport/VPNDNSOverridePublisher.swift",
    "Sources/ConduitShared/VPNDNSOverrideValidation.swift",
    "Sources/HelperSupport/VPNDNSOverrideLegacyRestore.swift",
    "Sources/ConduitHelper/HelperDaemon.swift",
    "Sources/ConduitHelper/HelperEventLoop.swift",
    "Sources/ConduitHelper/VPNDNSOverrideAdapters.swift",
    "Sources/ProxyKernel/Network/DNSFailoverRelay.swift",
    "Sources/PlatformMac/VPNResolverOverridePolicy.swift",
    "Sources/PlatformMac/VPNResolverOverrideController.swift",
    "Sources/PlatformMac/ResolverOrder.swift",
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
OVERRIDE_SAFETY = ["TypeOK", "KeyAnswered", "VPNKeyUntouched", "NoLoopbackTarget", "KeyWithdrawn",
                   "InternalNamesServed", "NoSelfReference", "BoundHeld"]
OVERRIDE_LIVENESS = ["EventuallyWithdrawn", "KeyReturns"]
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
OVERRIDE_NONE = dict(MaxVersions=1, MaxDisconnects=0, MaxGateFlaps=0, MaxIPv4Flaps=0, MaxLoopbackLists=0,
                     MaxConfigdRestarts=0, MaxOwnerExits=0, MaxHelperCrashes=0, MaxRelayDeaths=0,
                     MaxForwarderFaults=0, MaxDNSStops=0, MaxLostReplies=0, MaxRemovalRefusals=0,
                     MaxProbeSocketFailures=0, MaxBusyCommands=0)
OVERRIDE_CLIENT = dict(OVERRIDE_NONE, MaxVersions=3, MaxDisconnects=1, MaxGateFlaps=1, MaxIPv4Flaps=1,
                       MaxLoopbackLists=1, MaxConfigdRestarts=1, MaxDNSStops=1)
OVERRIDE_PROCESS = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxIPv4Flaps=1, MaxOwnerExits=1,
                        MaxHelperCrashes=1, MaxDNSStops=1, MaxLostReplies=1, MaxRemovalRefusals=1)
OVERRIDE_RELAY = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxGateFlaps=1, MaxLoopbackLists=1,
                      MaxRelayDeaths=1, MaxForwarderFaults=1, MaxDNSStops=1)
OVERRIDE_LIVE = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxIPv4Flaps=1, MaxConfigdRestarts=1,
                     MaxOwnerExits=1, MaxRelayDeaths=1, MaxForwarderFaults=1)
OVERRIDE_HELPER_FAULTS = dict(OVERRIDE_NONE, MaxVersions=1, MaxDisconnects=1, MaxOwnerExits=1, MaxForwarderFaults=1,
                              MaxDNSStops=1, MaxRemovalRefusals=1, MaxProbeSocketFailures=1, MaxBusyCommands=1)
CHECKS += [
    Check("override-safety-client", OVERRIDE_CLIENT, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_CLIENT, MaxVersions=4, MaxOwnerExits=1), spec=OVERRIDE),
    Check("override-safety-process", OVERRIDE_PROCESS, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_PROCESS, MaxVersions=3, MaxConfigdRestarts=1), spec=OVERRIDE),
    Check("override-safety-relay", OVERRIDE_RELAY, invariants=OVERRIDE_SAFETY,
          full=dict(OVERRIDE_RELAY, MaxVersions=3, MaxOwnerExits=1), spec=OVERRIDE),
    Check("override-liveness", OVERRIDE_LIVE, invariants=["TypeOK"], properties=OVERRIDE_LIVENESS,
          full=dict(OVERRIDE_LIVE, MaxGateFlaps=1, MaxLostReplies=1), spec=OVERRIDE),
    Check("override-helper-faults", OVERRIDE_HELPER_FAULTS, invariants=OVERRIDE_SAFETY, properties=OVERRIDE_LIVENESS,
          full=dict(OVERRIDE_HELPER_FAULTS, MaxRelayDeaths=1, MaxIPv4Flaps=1), spec=OVERRIDE),
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


OVERRIDE_MUTANT = dict(OVERRIDE_NONE, MaxVersions=2, MaxDisconnects=1, MaxGateFlaps=1, MaxIPv4Flaps=1,
                       MaxOwnerExits=1, MaxHelperCrashes=1, MaxDNSStops=1, MaxForwarderFaults=1)
OVERRIDE_FORWARDER_ONLY = dict(OVERRIDE_NONE, MaxVersions=2, MaxForwarderFaults=1)
OVERRIDE_LOOPBACK = dict(OVERRIDE_NONE, MaxVersions=2, MaxLoopbackLists=1, MaxForwarderFaults=1)
OVERRIDE_CONFIGD = dict(OVERRIDE_NONE, MaxVersions=2, MaxConfigdRestarts=1)
OVERRIDE_LOST_REPLY = dict(OVERRIDE_NONE, MaxVersions=2, MaxGateFlaps=1, MaxLostReplies=1)
# Two refusals: the app's disarm before the stop, and the stop's own try.
OVERRIDE_REFUSED_STOP = dict(OVERRIDE_NONE, MaxVersions=1, MaxDNSStops=1, MaxRemovalRefusals=2)
OVERRIDE_REFUSED_EXIT = dict(OVERRIDE_NONE, MaxVersions=1, MaxOwnerExits=1, MaxRemovalRefusals=1)
OVERRIDE_SOCKET_FAILS = dict(OVERRIDE_NONE, MaxVersions=1, MaxForwarderFaults=1, MaxProbeSocketFailures=1)
OVERRIDE_BUSY = dict(OVERRIDE_NONE, MaxVersions=1, MaxBusyCommands=1)

# The combined design (0049 as revised in #330): each `swift` text names the change in the code that breaks it.
MUTANTS += [
    override_mutant(
        "ov-no-per-query-failover",
        "DNSFailoverUDPRelay.receiveFromConduit and .expire, DNSFailoverTCPRelay.serve: fail over to the VPN's "
        "servers only when the publisher's tick sets the mode, so a lookup to a forwarder that refuses or stays "
        "silent goes unanswered until the next probe",
        [("PerQueryFailover == TRUE", "PerQueryFailover == FALSE")],
        "KeyAnswered", bounds=OVERRIDE_FORWARDER_ONLY),
    override_mutant(
        "ov-key-points-at-conduit",
        "VPNDNSOverridePublisher.sync: publish `ownKey(port:)` with the forwarder's port instead of "
        "`relay.listeningPort`, so a forwarder that is gone or silent leaves every lookup unanswered",
        [("KeyTargetsRelay == TRUE", "KeyTargetsRelay == FALSE")],
        "KeyAnswered", bounds=OVERRIDE_FORWARDER_ONLY),
    override_mutant(
        "ov-failover-to-loopback",
        "DNSFailoverRoute.setServers: keep the loopback servers that `DNSFailoverServers.usable` "
        "drops, so a failed-over lookup is sent to a loopback address",
        [("FiltersLoopback == TRUE", "FiltersLoopback == FALSE")],
        "NoLoopbackTarget", bounds=OVERRIDE_LOOPBACK),
    override_mutant(
        "ov-key-kept-after-owner-exit",
        "VPNDNSOverridePublisher.ownerExited: forget the arm but delete `withdraw(.ownerExited)`, so the key "
        "stays published",
        [("WithdrawsOnExit == TRUE", "WithdrawsOnExit == FALSE")],
        "KeyWithdrawn"),
    override_mutant(
        "ov-no-note-exit",
        "HelperDaemon.run: delete `loop.watchOwner(...)`, so the key outlives an owner that exited",
        [("WatchOwner == TRUE", "WatchOwner == FALSE")],
        "KeyWithdrawn"),
    override_mutant(
        "ov-no-republish-after-configd-restart",
        "VPNDNSOverridePublisher.sync: `guard !published || store.ownKeyState() == .absent` becomes `guard !published`, "
        "so after configd restarts and drops the key it stays gone while the helper believes it published",
        [("NoticesOwnKey == TRUE", "NoticesOwnKey == FALSE")],
        "KeyReturns", bounds=OVERRIDE_CONFIGD),
    override_mutant(
        "ov-writes-vpn-key",
        "VPNDNSOverridePublisher.sync: also write 127.0.0.1 into the VPN's own "
        "`State:/Network/Service/<id>/DNS`, as the rewrite did",
        [("WritesVPNKey == FALSE", "WritesVPNKey == TRUE")],
        "VPNKeyUntouched"),
    override_mutant(
        "ov-reads-own-key",
        "PushedResolverReading.parse: delete `where serviceID != HelperConstants.vpnDNSOverrideServiceID`, "
        "so Conduit's own key is read as a pushed resolver and 127.0.0.1 enters the live split-DNS set",
        [("IgnoresOwnKey == TRUE", "IgnoresOwnKey == FALSE")],
        "NoSelfReference"),
    override_mutant(
        "ov-arm-before-live-set",
        "VPNResolverOverridePolicy.wanted: delete `guard tunnel.servers.allSatisfy(input.serversInUse.contains)`, "
        "so the key is armed before the live set has the VPN's servers",
        [("ServersInUse == TRUE", "ServersInUse == FALSE")],
        "InternalNamesServed"),
    override_mutant(
        "ov-set-dropped-before-disarm",
        "RuntimeHostSplitDNSDetection.applyPendingSplitDNSDetection: apply a new set while "
        "`vpnDNSOverrideReleases(before:)` holds, before the disarm returns",
        [("HoldBeforeDisarm == TRUE", "HoldBeforeDisarm == FALSE")],
        "InternalNamesServed"),
    override_mutant(
        "ov-unconfirmed-arm-kept",
        "VPNResolverOverrideController.decide and .mayArm: decide on `armed` alone, so an arm whose reply was "
        "lost is not disarmed before the set changes",
        [("ReleasesUnconfirmed == TRUE", "ReleasesUnconfirmed == FALSE")],
        "InternalNamesServed", bounds=OVERRIDE_LOST_REPLY),
    override_mutant(
        "ov-tick-ignores-refused",
        "VPNDNSOverridePublisher.tick: a refusal never clears `probeOK`, so the streak of "
        "`refusedTicksToWithdraw` (2) never withdraws the key, with the `unverifiedSecondsToWithdraw` "
        "backstop removed too, in the tick and in `hold`, since it alone would still withdraw",
        [("!.probeOK = @ /\\ h.refused + 1 < 2", "!.probeOK = @"), ("ProbeBounded == TRUE", "ProbeBounded == FALSE"),
         ("AgeGate == TRUE", "AgeGate == FALSE")],
        "EventuallyWithdrawn", bounds=OVERRIDE_FORWARDER_ONLY),
    override_mutant(
        "ov-tick-ignores-silent",
        "VPNDNSOverridePublisher.tick: a silence never clears `probeOK`, so the streak of "
        "`silentTicksToWithdraw` (3) never withdraws the key, with the `unverifiedSecondsToWithdraw` "
        "backstop removed too, in the tick and in `hold`, since it alone would still withdraw",
        [("!.probeOK = @ /\\ h.silent + 1 < 3", "!.probeOK = @"), ("ProbeBounded == TRUE", "ProbeBounded == FALSE"),
         ("AgeGate == TRUE", "AgeGate == FALSE")],
        "EventuallyWithdrawn", bounds=OVERRIDE_FORWARDER_ONLY),
    override_mutant(
        "ov-stop-ignores-pending-cleanup",
        "HelperDaemon.stopDNSRelay: stop the failover relay even while `vpnDNSOverride.cleanupPending`, so a key "
        "whose removal the store refused names a relay that is gone",
        [("KeepsRelayWhilePending == TRUE", "KeepsRelayWhilePending == FALSE")],
        "KeyAnswered", bounds=OVERRIDE_REFUSED_STOP),
    override_mutant(
        "ov-pending-cleanup-forgotten",
        "VPNDNSOverridePublisher.withdraw: after a refused removal and `closeSession`, report the key withdrawn "
        "without a read showing it gone, so a key the closed session still holds is never removed",
        [("TracksPendingCleanup == TRUE", "TracksPendingCleanup == FALSE")],
        "KeyWithdrawn", bounds=OVERRIDE_REFUSED_EXIT),
    override_mutant(
        "ov-failed-probe-keeps-key",
        "VPNDNSOverridePublisher.tick: a `.failed` probe keeps `probeOK` and nothing bounds the time since the "
        "last confirmed answer, in the tick or in `hold`, so a helper whose probe socket keeps failing holds the key "
        "for a silent Conduit",
        [("ProbeBounded == TRUE", "ProbeBounded == FALSE"),
         ("AgeGate == TRUE", "AgeGate == FALSE")],
        "EventuallyWithdrawn", bounds=OVERRIDE_SOCKET_FAILS),
    override_mutant(
        "ov-real-query-failure-per-interval",
        "VPNDNSOverridePublisher.tick: `realQueriesFailing = answered == 0 && unanswered > 0`, judged one interval "
        "at a time, so once the relay is on the VPN's servers the next answered probe sends the lookups back to a "
        "forwarder that answers only the probe name, and the key is never withdrawn",
        [("SticksRealQueryFailure == TRUE", "SticksRealQueryFailure == FALSE")],
        "EventuallyWithdrawn"),
    override_mutant(
        "ov-relay-stopped-after-publish",
        "VPNDNSOverridePublisher.stopRelay and .withdraw: the helper stops a relay deferred for a pending cleanup "
        "after the sync that completed the cleanup, with no hold on publishing and no cancel by a Start, so a key "
        "published by an arm during the deferred stop names a relay that is then stopped",
        [("StopsBeforePublish == TRUE", "StopsBeforePublish == FALSE")],
        "KeyAnswered", bounds=OVERRIDE_REFUSED_STOP),
    override_mutant(
        "ov-no-expiry-watchdog",
        "HelperDaemon.run: delete `VPNDNSOverrideWatchdog.start`, so a command that holds the loop keeps a key past "
        "`unverifiedSecondsToWithdraw` with no confirmed answer",
        [("Watchdog == TRUE", "Watchdog == FALSE")],
        "BoundHeld", bounds=OVERRIDE_BUSY),
    override_mutant(
        "ov-no-age-gate",
        "VPNDNSOverridePublisher.hold: `guard probeOK, confirmedWithinBound` becomes `guard probeOK`, so the sync "
        "after a held loop republishes the key the watchdog removed, on an answer older than the bound",
        [("AgeGate == TRUE", "AgeGate == FALSE")],
        "BoundHeld", bounds=OVERRIDE_BUSY),
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
