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
    MaxLostReplies

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
                     probeOK |-> FALSE, refused |-> 0, silent |-> 0]
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
                 stops |-> MaxDNSStops, lost |-> MaxLostReplies]
    /\ ghost = [vwritten |-> FALSE]

OwnerAlive == app.alive /\ app.id = h.owner
ExitPending == watch /\ ~OwnerAlive
HelperFree == h.up /\ ~ExitPending
HelperCurrent == h.seen = <<vkey, svc>>
RelayUp == relay \in {"conduit", "vpn"}
ConduitServes == fwd = "answers"
VPNUsable == svc /\ vkey \in Versions
\* The relay reads the VPN's servers live from its key and drops loopback ones.
FailoverTarget ==
    IF vkey \in Versions THEN vkey ELSE IF ~FiltersLoopback /\ vkey = LB THEN LB ELSE NONE
Failover == "vpn"
ToFailover == relay' = IF RelayUp THEN Failover ELSE relay
\* A query the relay sends to a Conduit that refuses or stays silent goes to the VPN's servers instead.
UsingFailover ==
    \/ relay = "vpn"
    \/ (relay = "conduit" /\ ~ConduitServes /\ PerQueryFailover)
Answers ==
    IF ~KeyTargetsRelay THEN ConduitServes
    ELSE CASE relay = "vpn" -> FailoverTarget \in Versions
           [] relay = "conduit" -> ConduitServes \/ (PerQueryFailover /\ FailoverTarget \in Versions)
           [] OTHER -> FALSE
Serving == h.up /\ relay = "conduit" /\ ConduitServes
Ready == h.armN \in Versions /\ vkey = h.armN /\ svc /\ RelayUp /\ h.probeOK
Snap == IF IgnoresOwnKey THEN <<vkey, svc, FALSE>> ELSE <<vkey, svc, okey>>
AppAwake == app.alive /\ fwd # "silent"

-----------------------------------------------------------------------------

MayArm(a) == a.known # NONE \/ (ReleasesUnconfirmed /\ a.unArm # NONE) \/ a.req = "arm"
Want(a) ==
    /\ a.dns = "on" /\ vgate /\ a.view \in Versions /\ (a.live = a.view \/ ~ServersInUse)
    /\ relay = "conduit" /\ fwd = "answers" /\ a.held = NOHELD

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

ForwarderRecovers ==
    /\ app.alive /\ app.dns # "off" /\ fwd # "answers"
    /\ fwd' = "answers"
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, relay, rwant, app, budget, ghost>>

-----------------------------------------------------------------------------

\* Arming records intent only; the helper publishes in HSync once Ready holds.
HAccept(lost) ==
    /\ HelperFree /\ app.alive /\ app.req # "none"
    /\ lost => (app.req = "arm" /\ budget.lost > 0)
    /\ budget' = IF lost THEN [budget EXCEPT !.lost = @ - 1] ELSE budget
    /\ CASE app.req = "arm" ->
              /\ h' = [h EXCEPT !.armN = app.reqN, !.owner = app.id, !.probeOK = (fwd = "answers"),
                                !.refused = 0, !.silent = 0]
              /\ watch' = WatchOwner
              /\ app' = IF lost THEN ArmUnknown(app) ELSE ArmOK(app)
              /\ UNCHANGED <<okey, relay, rwant, fwd>>
         [] app.req = "disarm" ->
              /\ h' = Withdrawn(h) /\ okey' = FALSE /\ watch' = FALSE /\ app' = DisarmOK(app)
              /\ UNCHANGED <<relay, rwant, fwd>>
         [] app.req = "startRelay" ->
              /\ relay' = IF h.armN # NONE /\ h.owner # app.id THEN Failover ELSE "conduit"
              /\ rwant' = TRUE /\ app' = Done(app)
              /\ UNCHANGED <<okey, h, watch, fwd>>
         [] app.req = "stopRelay" ->
              /\ relay' = "off" /\ rwant' = FALSE /\ app' = RelayStopped(app) /\ fwd' = "refuses"
              /\ h' = Withdrawn(h) /\ okey' = FALSE /\ watch' = FALSE
    /\ UNCHANGED <<vkey, svc, ver, vgate, ghost>>

\* A store notification, or any event that changes Ready: publish, republish or withdraw the own key.
HSync ==
    /\ HelperFree
    /\ \/ ~HelperCurrent
       \/ h.pub # Ready
       \/ (NoticesOwnKey /\ h.pub /\ ~okey)
    /\ h' = [h EXCEPT !.seen = <<vkey, svc>>, !.pub = Ready]
    /\ okey' = CASE Ready /\ (~h.pub \/ NoticesOwnKey) -> TRUE
                 [] Ready -> okey
                 [] OTHER -> FALSE
    /\ vkey' = IF WritesVPNKey /\ Ready /\ ~h.pub THEN LO ELSE vkey
    /\ ghost' = [ghost EXCEPT !.vwritten = @ \/ (WritesVPNKey /\ Ready /\ ~h.pub)]
    /\ UNCHANGED <<svc, ver, vgate, watch, relay, rwant, fwd, app, budget>>

\* The relay's mode follows each probe; the key is withdrawn after two refused or three silent ticks.
HTick ==
    /\ HelperFree /\ h.armN # NONE
    /\ CASE fwd = "refuses" ->
              /\ h' = [h EXCEPT !.refused = IF @ < 2 THEN @ + 1 ELSE 2, !.silent = 0,
                                !.probeOK = @ /\ h.refused + 1 < 2]
              /\ ToFailover
         [] fwd = "silent" ->
              /\ h' = [h EXCEPT !.silent = IF @ < 3 THEN @ + 1 ELSE 3, !.refused = 0,
                                !.probeOK = @ /\ h.silent + 1 < 3]
              /\ ToFailover
         [] OTHER ->
              /\ h' = [h EXCEPT !.refused = 0, !.silent = 0, !.probeOK = TRUE]
              /\ relay' = IF RelayUp THEN "conduit" ELSE relay
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, watch, rwant, fwd, app, budget, ghost>>

HRelayRestart ==
    /\ h.up /\ relay = "dead"
    /\ relay' = IF h.armN # NONE THEN Failover ELSE IF rwant THEN "conduit" ELSE "off"
    /\ UNCHANGED <<vkey, svc, ver, vgate, okey, h, watch, rwant, fwd, app, budget, ghost>>

HOwnerExit ==
    /\ h.up /\ ExitPending
    /\ watch' = FALSE
    /\ IF WithdrawsOnExit
       THEN h' = Withdrawn(h) /\ okey' = FALSE /\ ToFailover
       ELSE UNCHANGED <<h, okey, relay>>
    /\ UNCHANGED <<vkey, svc, ver, vgate, rwant, fwd, app, budget, ghost>>

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
           \/ ForwarderFault("refuses") \/ ForwarderFault("silent")
HelperNext == HAccept(FALSE) \/ HAccept(TRUE) \/ HSync \/ HTick \/ HRelayRestart \/ HOwnerExit \/ HStart
AppNext == AppRead \/ AppTake \/ AppPass \/ AppPoll \/ AppCallFails \/ AppRestartRelay
           \/ AppStartDNS \/ AppStop \/ AppTdDisarm \/ AppTdRelay

Terminal == ~ENABLED (ClientNext \/ EnvNext \/ HelperNext \/ AppNext) /\ UNCHANGED vars

Next == ClientNext \/ EnvNext \/ HelperNext \/ AppNext \/ Terminal

\* Only the helper is fair: a crashed or stalled app may never act.
Fairness ==
    /\ WF_vars(HSync) /\ WF_vars(HTick) /\ WF_vars(HRelayRestart) /\ WF_vars(HOwnerExit) /\ WF_vars(HStart)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------

TypeOK ==
    /\ vkey \in {ABSENT, LB} \cup Versions /\ svc \in BOOLEAN /\ ver \in Versions /\ vgate \in BOOLEAN
    /\ okey \in BOOLEAN /\ h.up \in BOOLEAN /\ h.pub \in BOOLEAN /\ h.armN \in {NONE} \cup Versions
    /\ h.refused \in 0..2 /\ h.silent \in 0..3
    /\ relay \in {"off", "conduit", "vpn", "dead"} /\ rwant \in BOOLEAN
    /\ fwd \in {"answers", "refuses", "silent"}
    /\ app.dns \in {"on", "stop_disarm", "stop_wait_disarm", "stop_relay", "stop_wait_relay", "off"}
    /\ app.req \in {"none", "arm", "disarm", "startRelay", "stopRelay"}

\* Whenever the own key is in the store, the helper and its relay run and the VPN publishes servers,
\* every lookup is answered by Conduit or by the VPN's servers. A dead relay is the helper's fault, like a crash.
KeyAnswered == (okey /\ h.up /\ relay # "dead" /\ VPNUsable) => Answers

VPNKeyUntouched == ~ghost.vwritten

NoLoopbackTarget == (okey /\ UsingFailover) => FailoverTarget # LB

\* Once the helper has handled every event, its key is in the store only for a live owner and a usable VPN.
KeyWithdrawn == (h.up /\ HelperCurrent /\ ~ExitPending /\ okey) => (OwnerAlive /\ VPNUsable)

\* While the relay sends the key's lookups to Conduit, Conduit's set in use has the VPN's servers.
InternalNamesServed == (okey /\ Serving /\ HelperCurrent /\ ~ExitPending) => app.live = vkey

NoSelfReference == app.view # LO /\ app.live # LO /\ app.held # LO

EventuallyWithdrawn == (okey /\ ~(ConduitServes /\ OwnerAlive)) ~> (~okey \/ (ConduitServes /\ OwnerAlive))

CanServe ==
    /\ h.up /\ OwnerAlive /\ h.armN \in Versions /\ vkey = h.armN /\ svc /\ RelayUp /\ h.probeOK
    /\ fwd = "answers"
KeyReturns == CanServe ~> (okey \/ ~CanServe)

=============================================================================
