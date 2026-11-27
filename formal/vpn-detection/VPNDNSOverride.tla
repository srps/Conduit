--------------------------- MODULE VPNDNSOverride ---------------------------
(***************************************************************************)
(* Decision 0049's resolver override: the helper's own temporary key in   *)
(* front of a full-tunnel VPN's resolver, served by a fail-safe relay.    *)
(* SKILL.md maps actions to the Swift. Each helper event is one step: the *)
(* helper serves one event at a time, and each store call is atomic.      *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxVersions,
    MaxDisconnects,
    MaxGateFlaps,
    MaxIPv4Flaps,
    MaxLoopbackLists,
    MaxConfigdRestarts,
    MaxOwnerExits,
    MaxHelperCrashes,
    MaxRelayDeaths,
    MaxForwarderFaults,
    MaxDNSStops,
    MaxLostReplies,
    MaxRemovalRefusals,
    MaxProbeSocketFailures,
    MaxBusyCommands

ABSENT == 0
NONE == 0
LO == 100
LB == 101
NOHELD == 102
Versions == 1..MaxVersions
NEVER == <<ABSENT, FALSE, FALSE>>

KeyTargetsRelay == TRUE
PerQueryFailover == TRUE
FiltersLoopback == TRUE
NoticesOwnKey == TRUE
WritesVPNKey == FALSE
WithdrawsOnExit == TRUE
WatchOwner == TRUE
IgnoresOwnKey == TRUE
ServersInUse == TRUE
HoldBeforeDisarm == TRUE
ReleasesUnconfirmed == TRUE
TracksPendingCleanup == TRUE
KeepsRelayWhilePending == TRUE
ProbeBounded == TRUE
SticksRealQueryFailure == TRUE
StopsBeforePublish == TRUE
AgeGate == TRUE
Watchdog == TRUE
\* unverifiedSecondsToWithdraw over tickSeconds: the ticks a key may go without a confirmed answer.
UnverifiedTicks == 3

VARIABLES
    vkey,
    svc,
    ver,
    vgate,
    okey,
    h,
    watch,
    relay,
    rwant,
    fwd,
    app,
    budget,
    ghost

vars == <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, app, budget, ghost>>

HFresh(up, seen) == [up |-> up, pub |-> FALSE, armN |-> NONE, owner |-> 0, seen |-> seen,
                     probeOK |-> FALSE, refused |-> 0, silent |-> 0, unverified |-> 0,
                     pending |-> FALSE, sockFails |-> FALSE, failing |-> FALSE, stopPending |-> FALSE,
                     busy |-> FALSE]
FreshApp(id, dns) == [alive |-> TRUE, id |-> id, dns |-> dns, view |-> NONE, snap |-> NEVER,
                      live |-> NONE, held |-> NOHELD, taken |-> NONE, known |-> NONE, unArm |-> NONE,
                      req |-> "none", reqN |-> NONE]

Init ==
    /\ vkey = 1 /\ svc = TRUE /\ ver = 1 /\ vgate = TRUE /\ okey = FALSE
    /\ h = HFresh(TRUE, <<1, TRUE>>) /\ watch = FALSE
    /\ relay = "conduit" /\ rwant = TRUE /\ fwd = "answers"
    /\ app = FreshApp(1, "on")
    /\ budget = [disc |-> MaxDisconnects, flaps |-> MaxGateFlaps, v4flaps |-> MaxIPv4Flaps, inflap |-> FALSE,
                 lb |-> MaxLoopbackLists, cfg |-> MaxConfigdRestarts, exits |-> MaxOwnerExits,
                 crashes |-> MaxHelperCrashes, relay |-> MaxRelayDeaths, fwd |-> MaxForwarderFaults,
                 stops |-> MaxDNSStops, lost |-> MaxLostReplies, refusals |-> MaxRemovalRefusals,
                 sock |-> MaxProbeSocketFailures, busy |-> MaxBusyCommands]
    /\ ghost = [vwritten |-> FALSE]

OwnerAlive == app.alive /\ app.id = h.owner
ExitPending == watch /\ ~OwnerAlive
\* The helper's one loop, unless a command holds it.
LoopFree == h.up /\ ~h.busy
HelperFree == LoopFree /\ ~ExitPending
HelperCurrent == h.seen = <<vkey, svc>>
RelayUp == relay \in {"conduit", "vpn"}
ConduitServes == fwd = "answers"
VPNUsable == svc /\ vkey \in Versions
\* The relay reads the VPN's servers live from its key and drops loopback ones.
FailoverTarget ==
    IF vkey \in Versions THEN vkey ELSE IF ~FiltersLoopback /\ vkey = LB THEN LB ELSE NONE
Failover == "vpn"
ToFailover == relay' = IF RelayUp THEN Failover ELSE relay
\* A query the relay sends to a Conduit that refuses or stays silent goes to the VPN's servers instead. A forwarder
\* that answers only the probe name ("probeOnly") passes the relay's own probe, so its lookups wait and are lost.
UsingFailover ==
    \/ relay = "vpn"
    \/ (relay = "conduit" /\ fwd \in {"refuses", "silent"} /\ PerQueryFailover)
Answers ==
    IF ~KeyTargetsRelay THEN ConduitServes
    ELSE CASE relay = "vpn" -> FailoverTarget \in Versions
           [] relay = "conduit" -> ConduitServes \/ (PerQueryFailover /\ fwd # "probeOnly" /\ FailoverTarget \in Versions)
           [] OTHER -> FALSE
Serving == h.up /\ relay = "conduit" /\ ConduitServes
Ready ==
    /\ h.armN \in Versions /\ vkey = h.armN /\ svc /\ RelayUp /\ h.probeOK
    /\ (~AgeGate \/ h.unverified < UnverifiedTicks)
    /\ ~(StopsBeforePublish /\ h.stopPending)
Snap == IF IgnoresOwnKey THEN <<vkey, svc, FALSE>> ELSE <<vkey, svc, okey>>
AppAwake == app.alive /\ fwd # "silent"

-----------------------------------------------------------------------------

MayArm(a) == a.known # NONE \/ (ReleasesUnconfirmed /\ a.unArm # NONE) \/ a.req = "arm"
Want(a) ==
    /\ a.dns = "on" /\ vgate /\ a.view \in Versions /\ (a.live = a.view \/ ~ServersInUse)
    /\ RelayUp /\ rwant /\ fwd = "answers" /\ a.held = NOHELD

Done(a) == [a EXCEPT !.req = "none", !.reqN = NONE]
ArmOK(a) == Done([a EXCEPT !.known = a.reqN, !.unArm = NONE])
ArmUnknown(a) == Done([a EXCEPT !.unArm = a.reqN])
DisarmOK(a) == Done([a EXCEPT !.known = NONE, !.unArm = NONE,
                              !.dns = IF @ = "stop_wait_disarm" THEN "stop_relay" ELSE @])
RelayStopped(a) == Done([a EXCEPT !.dns = "off", !.live = NONE, !.held = NOHELD, !.taken = NONE, !.view = NONE])
Failed(a) == CASE a.req = "arm" -> ArmUnknown(a)
               [] a.req = "disarm" -> Done([a EXCEPT !.dns = IF @ = "stop_wait_disarm" THEN "stop_relay" ELSE @])
               [] a.req = "stopRelay" -> RelayStopped(a)
               [] OTHER -> Done(a)

Withdrawn(hh) == [hh EXCEPT !.armN = NONE, !.owner = 0, !.pub = FALSE]

\* A removal the store refuses, which closing the session does not complete either, leaves the key in place and
\* the cleanup pending until a later try succeeds or a read shows the key gone.
Refusals == IF okey /\ budget.refusals > 0 THEN BOOLEAN ELSE {FALSE}
Spend(r) == IF r THEN [budget EXCEPT !.refusals = @ - 1] ELSE budget
Removed(hh, r) == [Withdrawn(hh) EXCEPT !.pending = r /\ TracksPendingCleanup]
\* A key that should be gone but is not keeps naming the relay; its lookups go to the VPN's servers, as without it.
PendingMode(r) == relay' = IF r /\ TracksPendingCleanup /\ RelayUp THEN Failover ELSE relay
\* An unanswered tick counts toward the bound whatever it says; the bound alone withdraws a key whose probe socket fails.
Unverified(hh) == IF hh.unverified < UnverifiedTicks THEN hh.unverified + 1 ELSE hh.unverified
WithinBound(hh) == ~ProbeBounded \/ hh.unverified + 1 < UnverifiedTicks

-----------------------------------------------------------------------------

ClientRewrite ==
    /\ svc /\ vkey # ABSENT /\ ver < MaxVersions
    /\ ver' = ver + 1 /\ vkey' = ver + 1
    /\ UNCHANGED <<svc, vgate, okey, h, watch, relay, rwant, fwd, app, budget, ghost>>

ClientLoopback ==
    /\ svc /\ vkey \in Versions /\ budget.lb > 0
    /\ vkey' = LB /\ budget' = [budget EXCEPT !.lb = @ - 1]
    /\ UNCHANGED <<svc, ver, vgate, okey, h, watch, relay, rwant, fwd, app, ghost>>

ClientDelete ==
    /\ svc /\ budget.disc > 0
    /\ svc' = FALSE /\ vkey' = ABSENT /\ vgate' = FALSE
    /\ budget' = [budget EXCEPT !.disc = @ - 1]
    /\ UNCHANGED <<ver, okey, h, watch, relay, rwant, fwd, app, ghost>>

ClientPublishDNS ==
    /\ ~svc /\ ~budget.inflap /\ vkey = ABSENT /\ ver < MaxVersions
    /\ ver' = ver + 1 /\ vkey' = ver + 1
    /\ UNCHANGED <<svc, vgate, okey, h, watch, relay, rwant, fwd, app, budget, ghost>>

ClientPublishIPv4 ==
    /\ ~svc /\ ~budget.inflap /\ vkey \in Versions
    /\ svc' = TRUE /\ vgate' = TRUE
    /\ UNCHANGED <<vkey, ver, okey, h, watch, relay, rwant, fwd, app, budget, ghost>>

ClientIPv4Flap ==
    /\ svc /\ vkey # ABSENT /\ budget.v4flaps > 0
    /\ svc' = FALSE /\ budget' = [budget EXCEPT !.v4flaps = @ - 1, !.inflap = TRUE]
    /\ UNCHANGED <<vkey, ver, vgate, okey, h, watch, relay, rwant, fwd, app, ghost>>

ClientIPv4Back ==
    /\ budget.inflap
    /\ svc' = TRUE /\ budget' = [budget EXCEPT !.inflap = FALSE]
    /\ UNCHANGED <<vkey, ver, vgate, okey, h, watch, relay, rwant, fwd, app, ghost>>

GateFlap ==
    /\ vgate /\ budget.flaps > 0
    /\ vgate' = FALSE /\ budget' = [budget EXCEPT !.flaps = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, okey, h, watch, relay, rwant, fwd, app, ghost>>

GateBack ==
    /\ ~vgate /\ svc
    /\ vgate' = TRUE
    /\ UNCHANGED <<vkey, svc, ver, okey, h, watch, relay, rwant, fwd, app, budget, ghost>>

\* configd drops every temporary key when it restarts; the client writes its own keys back unchanged.
ConfigdRestart ==
    /\ okey /\ budget.cfg > 0
    /\ okey' = FALSE /\ budget' = [budget EXCEPT !.cfg = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, h, watch, relay, rwant, fwd, app, ghost>>

-----------------------------------------------------------------------------

OwnerExit ==
    /\ app.alive /\ budget.exits > 0
    /\ app' = [FreshApp(app.id, "off") EXCEPT !.alive = FALSE]
    /\ fwd' = "refuses" /\ budget' = [budget EXCEPT !.exits = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, ghost>>

AppLaunch ==
    /\ ~app.alive
    /\ app' = FreshApp(app.id + 1, "off")
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

\* A crash or SIGTERM. configd removes a dead session's temporary keys as the session's port dies.
HelperDown ==
    /\ h.up /\ budget.crashes > 0
    /\ h' = HFresh(FALSE, h.seen) /\ okey' = FALSE /\ relay' = "off" /\ rwant' = FALSE /\ watch' = FALSE
    /\ budget' = [budget EXCEPT !.crashes = @ - 1]
    /\ app' = IF app.alive /\ app.req # "none" THEN Failed(app) ELSE app
    /\ fwd' = IF app.alive /\ app.req = "stopRelay" THEN "refuses" ELSE fwd
    /\ UNCHANGED <<vkey, svc, ver, vgate, ghost>>

RelayDies ==
    /\ RelayUp /\ budget.relay > 0
    /\ relay' = "dead" /\ budget' = [budget EXCEPT !.relay = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, rwant, fwd, app, ghost>>

ForwarderFault(f) ==
    /\ app.alive /\ app.dns # "off" /\ fwd = "answers" /\ budget.fwd > 0
    /\ fwd' = f /\ budget' = [budget EXCEPT !.fwd = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, app, ghost>>

\* A synchronous command holds the helper's loop: no tick, sync or request runs until it ends, but time passes.
HBusy ==
    /\ HelperFree /\ budget.busy > 0
    /\ h' = [h EXCEPT !.busy = TRUE] /\ budget' = [budget EXCEPT !.busy = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, relay, rwant, fwd, app, ghost>>

HBusyEnd ==
    /\ h.up /\ h.busy
    /\ h' = [h EXCEPT !.busy = FALSE]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, relay, rwant, fwd, app, budget, ghost>>

\* A tick's worth of time while the loop is held. The watchdog thread removes a published key once it has gone the
\* bound without a confirmed answer; the loop sees it gone when it is free.
Elapse ==
    /\ h.up /\ h.busy /\ h.armN # NONE /\ h.unverified <= UnverifiedTicks
    /\ h' = [h EXCEPT !.unverified = @ + 1]
    /\ okey' = IF Watchdog /\ okey /\ h.pub /\ h.unverified + 1 >= UnverifiedTicks THEN FALSE ELSE okey
    /\ UNCHANGED <<vkey, svc, ver, vgate, watch, relay, rwant, fwd, app, budget, ghost>>

\* The helper's own probe socket fails (EMFILE, say) until it recovers; the environment is not fair.
ProbeSocketFails ==
    /\ h.up /\ ~h.sockFails /\ budget.sock > 0
    /\ h' = [h EXCEPT !.sockFails = TRUE] /\ budget' = [budget EXCEPT !.sock = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, relay, rwant, fwd, app, ghost>>

ProbeSocketRecovers ==
    /\ h.up /\ h.sockFails
    /\ h' = [h EXCEPT !.sockFails = FALSE]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, relay, rwant, fwd, app, budget, ghost>>

ForwarderRecovers ==
    /\ app.alive /\ app.dns # "off" /\ fwd # "answers"
    /\ fwd' = "answers"
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, app, budget, ghost>>

-----------------------------------------------------------------------------

\* Arming records intent only; the helper publishes in HSync once Ready holds.
HAccept(lost) ==
    /\ HelperFree /\ app.alive /\ app.req # "none"
    /\ lost => (app.req = "arm" /\ budget.lost > 0)
    /\ CASE app.req = "arm" ->
              \* The arm's probe is screened as a tick's is: a failure to answer real queries needs the recheck.
              /\ h' = [h EXCEPT !.armN = app.reqN, !.owner = app.id,
                                !.probeOK = (fwd = "answers" \/ (fwd = "probeOnly" /\ ~h.failing)) /\ ~h.sockFails,
                                !.failing = @ /\ (h.sockFails \/ fwd # "answers"),
                                !.refused = 0, !.silent = 0, !.unverified = 0]
              /\ watch' = WatchOwner
              /\ app' = IF lost THEN ArmUnknown(app) ELSE ArmOK(app)
              /\ budget' = IF lost THEN [budget EXCEPT !.lost = @ - 1] ELSE budget
              /\ UNCHANGED <<okey, relay, rwant, fwd>>
         [] app.req = "disarm" ->
              /\ \E r \in Refusals : h' = Removed(h, r) /\ okey' = r /\ budget' = Spend(r) /\ PendingMode(r)
              /\ watch' = FALSE /\ app' = DisarmOK(app)
              /\ UNCHANGED <<rwant, fwd>>
         [] app.req = "startRelay" ->
              \* A Start supersedes a stop deferred for a pending cleanup.
              /\ relay' = IF (h.armN # NONE /\ h.owner # app.id) \/ h.pending \/ h.failing THEN Failover ELSE "conduit"
              /\ h' = IF StopsBeforePublish THEN [h EXCEPT !.stopPending = FALSE] ELSE h
              /\ rwant' = TRUE /\ app' = Done(app)
              /\ UNCHANGED <<okey, watch, fwd, budget>>
         [] app.req = "stopRelay" ->
              \* A key whose cleanup is pending keeps the relay up on the VPN's servers until the cleanup completes.
              /\ \E r \in Refusals :
                   /\ LET kept == r /\ TracksPendingCleanup /\ KeepsRelayWhilePending
                      IN /\ h' = [Removed(h, r) EXCEPT !.stopPending = kept]
                         /\ relay' = IF kept THEN (IF relay = "dead" THEN "dead" ELSE Failover) ELSE "off"
                   /\ okey' = r /\ budget' = Spend(r)
              /\ rwant' = FALSE /\ app' = RelayStopped(app) /\ fwd' = "refuses" /\ watch' = FALSE
    /\ UNCHANGED <<vkey, svc, ver, vgate, ghost>>

\* A store notification, or any event that changes Ready: publish, republish or withdraw the own key.
\* Nothing is published while a cleanup is pending; HCleanup finishes it first.
HSync ==
    /\ HelperFree /\ ~h.pending
    /\ \/ ~HelperCurrent
       \/ h.pub # Ready
       \/ (NoticesOwnKey /\ h.pub /\ ~okey)
    /\ \E r \in (IF Ready THEN {FALSE} ELSE Refusals) :
         /\ h' = [h EXCEPT !.seen = <<vkey, svc>>, !.pub = Ready, !.pending = r /\ TracksPendingCleanup]
         /\ okey' = CASE Ready /\ (~h.pub \/ NoticesOwnKey) -> TRUE
                      [] Ready -> okey
                      [] OTHER -> r
         /\ budget' = Spend(r) /\ PendingMode(r)
    /\ vkey' = IF WritesVPNKey /\ Ready /\ ~h.pub THEN LO ELSE vkey
    /\ ghost' = [ghost EXCEPT !.vwritten = @ \/ (WritesVPNKey /\ Ready /\ ~h.pub)]
    /\ UNCHANGED <<svc, ver, vgate, watch, rwant, fwd, app>>

\* The relay's mode follows each probe; the key is withdrawn after two refused or three silent ticks.
\* A failed probe socket leaves the streaks and the mode alone but confirms nothing.
\* Real queries a probe-only forwarder lost while the relay sent them to it count the tick as silent, and so does
\* every later answered probe until the recheck, a real question asked of the forwarder directly, is answered.
HTick ==
    /\ HelperFree /\ h.armN # NONE
    /\ LET lost == fwd = "probeOnly" /\ (relay = "conduit" \/ (SticksRealQueryFailure /\ h.failing))
           probe == CASE h.sockFails -> "failed" [] fwd = "probeOnly" -> IF lost THEN "silent" ELSE "answers"
                      [] OTHER -> fwd
       IN CASE probe = "failed" ->
              /\ h' = [h EXCEPT !.unverified = Unverified(h), !.probeOK = @ /\ WithinBound(h)]
              /\ relay' = relay
         [] probe = "refuses" ->
              /\ h' = [h EXCEPT !.refused = IF @ < 2 THEN @ + 1 ELSE 2, !.silent = 0, !.unverified = Unverified(h),
                                !.probeOK = @ /\ h.refused + 1 < 2 /\ WithinBound(h)]
              /\ ToFailover
         [] probe = "silent" ->
              /\ h' = [h EXCEPT !.silent = IF @ < 3 THEN @ + 1 ELSE 3, !.refused = 0, !.unverified = Unverified(h),
                                !.probeOK = @ /\ h.silent + 1 < 3 /\ WithinBound(h),
                                !.failing = IF SticksRealQueryFailure THEN @ \/ lost ELSE lost]
              /\ ToFailover
         [] OTHER ->
              /\ h' = [h EXCEPT !.refused = 0, !.silent = 0, !.unverified = 0, !.probeOK = TRUE, !.failing = FALSE]
              /\ relay' = IF RelayUp /\ ~h.pending THEN "conduit" ELSE relay
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, rwant, fwd, app, budget, ghost>>

\* Each tick while a cleanup is pending tries the removal again; once it is done, a relay stop deferred for it runs
\* in the same step, before anything can be published.
HCleanup ==
    /\ LoopFree /\ h.pending
    /\ \E r \in Refusals :
         /\ LET stops == ~r /\ h.stopPending /\ StopsBeforePublish
            IN /\ h' = [h EXCEPT !.pending = r, !.stopPending = IF stops THEN FALSE ELSE @]
               /\ relay' = IF stops /\ RelayUp THEN "off" ELSE relay
         /\ okey' = r /\ budget' = Spend(r)
    /\ UNCHANGED <<vkey, svc, ver, vgate, watch, rwant, fwd, app, ghost>>

\* Without StopsBeforePublish: the helper stopped a deferred relay after the event that completed the cleanup,
\* whatever that event had published, and a Start did not cancel it.
HDeferredStop ==
    /\ LoopFree /\ h.stopPending /\ ~h.pending
    /\ h' = [h EXCEPT !.stopPending = FALSE]
    /\ relay' = IF RelayUp THEN "off" ELSE relay
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, rwant, fwd, app, budget, ghost>>

HRelayRestart ==
    /\ LoopFree /\ relay = "dead"
    /\ relay' = IF h.armN # NONE \/ h.pending \/ h.failing THEN Failover ELSE IF rwant THEN "conduit" ELSE "off"
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, rwant, fwd, app, budget, ghost>>

HOwnerExit ==
    /\ LoopFree /\ ExitPending
    /\ watch' = FALSE
    /\ IF WithdrawsOnExit
       THEN \E r \in Refusals : h' = Removed(h, r) /\ okey' = r /\ budget' = Spend(r) /\ ToFailover
       ELSE UNCHANGED <<h, okey, relay, budget>>
    /\ UNCHANGED <<vkey, svc, ver, vgate, rwant, fwd, app, ghost>>

HStart ==
    /\ ~h.up
    /\ h' = HFresh(TRUE, <<vkey, svc>>)
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, relay, rwant, fwd, app, budget, ghost>>

-----------------------------------------------------------------------------

\* The monitor reads the VPN's own key as it is; the parser ignores Conduit's key by its service id.
ReadingOf ==
    IF ~IgnoresOwnKey /\ okey THEN LO
    ELSE IF svc /\ vkey \in Versions THEN vkey ELSE NONE

AppRead ==
    /\ AppAwake /\ app.dns # "off" /\ app.snap # Snap
    /\ app' = [app EXCEPT !.view = ReadingOf, !.snap = Snap]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

NewSet == IF app.dns # "on" \/ ~vgate THEN NONE
          ELSE IF app.view # NONE THEN app.view
          ELSE app.taken

\* While the own key may be armed, a new set waits for the disarm.
AppTake ==
    /\ AppAwake /\ NewSet # app.taken
    /\ LET hold == HoldBeforeDisarm /\ MayArm(app)
       IN app' = [app EXCEPT !.taken = NewSet,
                             !.held = IF hold THEN NewSet ELSE @,
                             !.live = IF hold THEN @ ELSE NewSet]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

AppPass ==
    /\ AppAwake /\ app.req = "none"
    /\ CASE Want(app) /\ app.known # app.view ->
              app' = [app EXCEPT !.req = "arm", !.reqN = app.view]
         [] ~Want(app) /\ MayArm(app) ->
              app' = [app EXCEPT !.req = "disarm"]
         [] OTHER ->
              /\ ~MayArm(app) /\ app.held # NOHELD
              /\ app' = [app EXCEPT !.live = app.held, !.held = NOHELD]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

AppPoll ==
    /\ AppAwake /\ app.req = "none" /\ MayArm(app) /\ HelperFree
    /\ app' = [app EXCEPT !.known = IF h.owner = app.id /\ h.armN \in {app.known, app.unArm} \ {NONE}
                                    THEN h.armN ELSE NONE,
                          !.unArm = NONE]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

AppCallFails ==
    /\ app.alive /\ app.req # "none" /\ ~h.up
    /\ app' = Failed(app)
    /\ fwd' = IF app.req = "stopRelay" THEN "refuses" ELSE fwd
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, budget, ghost>>

AppRestartRelay ==
    /\ AppAwake /\ app.dns = "on" /\ (~rwant \/ ~RelayUp) /\ app.req = "none"
    /\ app' = [app EXCEPT !.req = "startRelay"]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

AppStartDNS ==
    /\ AppAwake /\ app.dns = "off" /\ app.req = "none"
    /\ app' = [app EXCEPT !.dns = "on", !.req = "startRelay", !.snap = NEVER]
    /\ fwd' = "answers"
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, budget, ghost>>

AppStop ==
    /\ AppAwake /\ app.dns = "on" /\ budget.stops > 0
    /\ app' = [app EXCEPT !.dns = "stop_disarm"] /\ budget' = [budget EXCEPT !.stops = @ - 1]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, ghost>>

AppTdDisarm ==
    /\ AppAwake /\ app.dns = "stop_disarm" /\ app.req = "none"
    /\ app' = IF MayArm(app) THEN [app EXCEPT !.dns = "stop_wait_disarm", !.req = "disarm"]
              ELSE [app EXCEPT !.dns = "stop_relay"]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

AppTdRelay ==
    /\ AppAwake /\ app.dns = "stop_relay" /\ app.req = "none"
    /\ app' = [app EXCEPT !.dns = "stop_wait_relay", !.req = "stopRelay"]
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, fwd, budget, ghost>>

-----------------------------------------------------------------------------

ClientNext == ClientRewrite \/ ClientLoopback \/ ClientDelete \/ ClientPublishDNS \/ ClientPublishIPv4
              \/ ClientIPv4Flap \/ ClientIPv4Back \/ GateFlap \/ GateBack \/ ConfigdRestart
EnvNext == OwnerExit \/ AppLaunch \/ HelperDown \/ RelayDies \/ ForwarderRecovers
           \/ ForwarderFault("refuses") \/ ForwarderFault("silent") \/ ForwarderFault("probeOnly")
           \/ ProbeSocketFails \/ ProbeSocketRecovers \/ HBusy \/ Elapse
HelperNext == HAccept(FALSE) \/ HAccept(TRUE) \/ HSync \/ HTick \/ HCleanup \/ HDeferredStop \/ HRelayRestart
              \/ HOwnerExit \/ HStart \/ HBusyEnd
AppNext == AppRead \/ AppTake \/ AppPass \/ AppPoll \/ AppCallFails \/ AppRestartRelay
           \/ AppStartDNS \/ AppStop \/ AppTdDisarm \/ AppTdRelay

Terminal == ~ENABLED (ClientNext \/ EnvNext \/ HelperNext \/ AppNext) /\ UNCHANGED vars

Next == ClientNext \/ EnvNext \/ HelperNext \/ AppNext \/ Terminal

\* Only the helper is fair: a crashed or stalled app may never act.
Fairness ==
    /\ WF_vars(HSync) /\ WF_vars(HTick) /\ WF_vars(HCleanup) /\ WF_vars(HRelayRestart) /\ WF_vars(HOwnerExit)
    /\ WF_vars(HStart) /\ WF_vars(HBusyEnd) /\ WF_vars(HDeferredStop)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------

TypeOK ==
    /\ vkey \in {ABSENT, LB} \cup Versions /\ svc \in BOOLEAN /\ ver \in Versions /\ vgate \in BOOLEAN
    /\ okey \in BOOLEAN /\ h.up \in BOOLEAN /\ h.pub \in BOOLEAN /\ h.armN \in {NONE} \cup Versions
    /\ h.refused \in 0..2 /\ h.silent \in 0..3 /\ h.unverified \in 0..(UnverifiedTicks + 1)
    /\ h.pending \in BOOLEAN /\ h.sockFails \in BOOLEAN /\ h.failing \in BOOLEAN /\ h.stopPending \in BOOLEAN
    /\ h.busy \in BOOLEAN
    /\ relay \in {"off", "conduit", "vpn", "dead"} /\ rwant \in BOOLEAN
    /\ fwd \in {"answers", "refuses", "silent", "probeOnly"}
    /\ app.dns \in {"on", "stop_disarm", "stop_wait_disarm", "stop_relay", "stop_wait_relay", "off"}
    /\ app.req \in {"none", "arm", "disarm", "startRelay", "stopRelay"}

\* Whenever the own key is in the store, the helper and its relay run and the VPN publishes servers,
\* every lookup is answered by Conduit or by the VPN's servers. A dead relay is the helper's fault, like a crash.
\* Lookups to a probe-only forwarder are lost until the next tick sees it: that window is the one exception.
Unnoticed == relay = "conduit" /\ fwd = "probeOnly" /\ ~h.failing
KeyAnswered == (okey /\ h.up /\ relay # "dead" /\ VPNUsable /\ ~Unnoticed) => Answers

\* A published key never outlives the bound without a confirmed answer, ticks or none.
BoundHeld == (okey /\ h.pub) => h.unverified <= UnverifiedTicks

VPNKeyUntouched == ~ghost.vwritten

NoLoopbackTarget == (okey /\ UsingFailover) => FailoverTarget # LB

\* Once the helper has handled every event, a pending cleanup included, its key is in the store only for a live
\* owner and a usable VPN.
KeyWithdrawn == (h.up /\ HelperCurrent /\ ~ExitPending /\ ~h.pending /\ okey) => (OwnerAlive /\ VPNUsable)

\* While the relay sends the key's lookups to Conduit, Conduit's set in use has the VPN's servers.
InternalNamesServed == (okey /\ Serving /\ HelperCurrent /\ ~ExitPending) => app.live = vkey

NoSelfReference == app.view # LO /\ app.live # LO /\ app.held # LO

EventuallyWithdrawn == (okey /\ ~(ConduitServes /\ OwnerAlive)) ~> (~okey \/ (ConduitServes /\ OwnerAlive))

CanServe ==
    /\ h.up /\ OwnerAlive /\ h.armN \in Versions /\ vkey = h.armN /\ svc /\ RelayUp /\ h.probeOK
    /\ fwd = "answers"
KeyReturns == CanServe ~> (okey \/ ~CanServe)

=============================================================================
