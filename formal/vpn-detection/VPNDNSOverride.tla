--------------------------- MODULE VPNDNSOverride ---------------------------
(***************************************************************************)
(* Decision 0049's resolver override; SKILL.md maps actions to the Swift.  *)
(* Atomicity: an event is a run of helper steps (h.pc # "idle"); each      *)
(* helper call on the dynamic store is its own step, since the VPN client  *)
(* writes between them; the monitor's box read and store read are two.     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxVersions,
    MaxDisconnects,
    MaxGateFlaps,
    MaxRepublishes,
    MaxIPv4Flaps,
    MaxSameRewrites,
    MaxOwnerExits,
    MaxHelperCrashes,
    MaxRelayDeaths,
    MaxForwarderFaults,
    MaxDNSStops,
    ApplyCap,
    Endless

ABSENT == 0
NONE == 0
LO == 100
NOHELD == 101
NOBOX == 102
NEVER == <<NOBOX, FALSE>>
Versions == 1..MaxVersions
Keys == {ABSENT, LO} \cup Versions
Views == {NONE, LO} \cup Versions

ReleaseCompares == TRUE
ApplyChecksService == TRUE
ApplyGoneCompares == TRUE
RemovesGoneKey == FALSE
ServersInUse == TRUE
WatchOwner == TRUE
ExitsFirst == TRUE
ReleaseAtStart == TRUE
HoldBeforeRelease == TRUE
FlapHold == TRUE
HeldSetRechecked == TRUE
HoldRule == TRUE
HoldOnSetInUse == TRUE
SameRewriteReapplies == TRUE
RefusalsSeparate == TRUE
RefusalsCapped == FALSE
RefusalRetriesAtOnce == FALSE
SameServersUncapped == TRUE
SuspensionsExpire == TRUE
BoxBothSides == TRUE

ParseLoopback(box) == box
Parse(k, box) == IF k = LO THEN (IF box # NONE THEN ParseLoopback(box) ELSE NONE) ELSE k
Overridden(k, box) == k = LO /\ box # NONE

VARIABLES
    key,
    svc,
    ver,
    vgate,
    rec,
    h,
    watch,
    relay,
    fwd,
    app,
    budget,
    ghost

vars == <<key, svc, ver, vgate, rec, h, watch, relay, fwd, app, budget, ghost>>

NoRec == [has |-> FALSE, n |-> NONE, owner |-> 0]
HIdle(up) == [up |-> up, pc |-> "idle", basis |-> ABSENT, cmp |-> FALSE, then |-> "none",
              from |-> 0, expected |-> NONE, refused |-> 0, silent |-> 0]
FreshApp(id, dns) == [alive |-> TRUE, id |-> id, dns |-> dns, box |-> NONE, known |-> NONE,
                      unApply |-> NONE, unRel |-> FALSE, snapBox |-> NOBOX, snapKey |-> NEVER,
                      vstale |-> FALSE, lstale |-> FALSE, hstale |-> FALSE,
                      view |-> NONE, ovr |-> FALSE, live |-> NONE, held |-> NOHELD, taken |-> NONE,
                      applies |-> 0, refusals |-> 0, lastN |-> NONE, spaced |-> FALSE, susp |-> FALSE, rewritten |-> FALSE,
                      fresh |-> TRUE, tries |-> 0, req |-> "none", reqExp |-> NONE, pass |-> FALSE]

Init ==
    /\ key = 1 /\ svc = TRUE /\ ver = 1 /\ vgate = TRUE
    /\ rec = NoRec /\ h = HIdle(TRUE) /\ watch = FALSE
    /\ relay = TRUE /\ fwd = "answers"
    /\ app = FreshApp(1, "on")
    /\ budget = [disc |-> MaxDisconnects, flaps |-> MaxGateFlaps, repub |-> MaxRepublishes,
                 v4flaps |-> MaxIPv4Flaps, inflap |-> FALSE, same |-> MaxSameRewrites, exits |-> MaxOwnerExits,
                 crashes |-> MaxHelperCrashes, relay |-> MaxRelayDeaths, fwd |-> MaxForwarderFaults,
                 stops |-> MaxDNSStops]
    /\ ghost = [clobber |-> FALSE, served |-> FALSE, window |-> FALSE]

OwnerAlive == app.alive /\ app.id = rec.owner
ExitPending == watch /\ ~OwnerAlive
HelperFree == h.up /\ h.pc = "idle" /\ (~ExitsFirst \/ ~ExitPending)
Served == ghost.served \/ (rec.has /\ ~OwnerAlive)
Serving == h.up /\ relay /\ fwd = "answers"
AppAwake == app.alive /\ fwd # "silent"

Clobbers(v, sanctioned) ==
    IF v = h.basis THEN v # sanctioned ELSE ~h.cmp /\ v # ABSENT

-----------------------------------------------------------------------------

RelayServingOf(a) == a.dns = "on" /\ relay /\ fwd = "answers"
\* The live set intersected with a held set; two different lists share no server here.
UseSetOf(a) == IF a.held = NOHELD \/ a.held = a.live THEN a.live ELSE NONE
WantedOf(a, set) == RelayServingOf(a) /\ vgate /\ a.view \in Versions /\ (set = a.view \/ ~ServersInUse)
KeepsThroughFlap(a, set) ==
    HoldRule /\ RelayServingOf(a) /\ vgate /\ a.view \notin Versions /\ a.known # NONE
    /\ (IF HoldOnSetInUse THEN set ELSE a.live) = a.known
SameServers(a) == SameServersUncapped /\ a.view = a.lastN
CapReached(a) ==
    IF RefusalsSeparate
    THEN (~SameServers(a) /\ a.applies >= ApplyCap) \/ (RefusalsCapped /\ a.refusals >= 2)
    ELSE a.applies >= ApplyCap
DecisionOf(a, set) ==
    IF KeepsThroughFlap(a, set) THEN "none"
    ELSE IF ~WantedOf(a, set) THEN (IF a.known # NONE THEN "release" ELSE "none")
    ELSE IF a.known = a.view /\ ~(SameRewriteReapplies /\ a.rewritten) THEN "none"
    ELSE IF a.ovr THEN "none"
    ELSE IF a.susp \/ ~a.fresh THEN "none"
    ELSE IF CapReached(a) THEN "suspend"
    ELSE IF a.spaced THEN "none"
    ELSE "apply"
MayHoldOf(a) == a.known # NONE \/ a.unApply # NONE \/ a.unRel \/ a.req = "apply"

-----------------------------------------------------------------------------

Forget(a) == [a EXCEPT !.known = NONE, !.unApply = NONE, !.unRel = FALSE, !.box = NONE,
                       !.rewritten = FALSE]
AfterCall(a) ==
    LET b == [a EXCEPT !.req = "none", !.reqExp = NONE, !.pass = FALSE]
        keep == HeldSetRechecked /\ MayHoldOf(b) /\ DecisionOf(b, a.held) = "release"
    IN CASE a.pass /\ a.held # NOHELD /\ ~keep -> [b EXCEPT !.live = a.held, !.lstale = a.hstale, !.held = NOHELD]
         [] a.req = "release" /\ a.dns = "stop_wait_release" -> [b EXCEPT !.dns = "stop_clear"]
         [] a.req = "stopRelay" ->
              [b EXCEPT !.dns = "off", !.live = NONE, !.lstale = FALSE, !.held = NOHELD, !.taken = NONE]
         [] OTHER -> b
ApplyOK(a) == AfterCall([a EXCEPT !.known = a.reqExp, !.unApply = NONE, !.box = a.reqExp, !.spaced = TRUE,
                                   !.applies = IF RefusalsSeparate /\ ~(SameServersUncapped /\ a.reqExp = a.lastN)
                                               THEN @ + 1 ELSE @,
                                   !.lastN = a.reqExp, !.rewritten = FALSE])
NotLanded(a) == IF RefusalsCapped THEN [a EXCEPT !.refusals = @ + 1] ELSE a
ApplyRefused(a) == AfterCall([NotLanded(a) EXCEPT !.box = a.known, !.fresh = RefusalRetriesAtOnce,
                                                  !.tries = @ + 1])
ApplyFailed(a) == AfterCall([NotLanded(a) EXCEPT !.unApply = a.reqExp])
ReleaseOK(a) == AfterCall(Forget(a))
ReleaseFailed(a) == AfterCall([a EXCEPT !.unRel = TRUE])
Done(a) == AfterCall(a)
Failed(a) == CASE a.req = "apply" -> ApplyFailed(a)
               [] a.req = "release" -> ReleaseFailed(a)
               [] OTHER -> Done(a)

ReplyApp(f(_)) == IF app.alive /\ app.id = h.from /\ h.from # 0 THEN f(app) ELSE app
StopsForwarder == h.then = "stop" /\ app.alive /\ app.id = h.from

StartRelease(then, from) ==
    h' = [h EXCEPT !.pc = "rel_read", !.then = then, !.from = from]

FinishRelease(clobber) ==
    /\ rec' = NoRec /\ watch' = FALSE
    /\ h' = IF h.then = "exit" THEN HIdle(FALSE) ELSE HIdle(TRUE)
    /\ relay' = IF h.then \in {"stop", "exit"} THEN FALSE ELSE relay
    /\ app' = IF h.then \in {"reply", "stop"} THEN ReplyApp(ReleaseOK) ELSE app
    /\ fwd' = IF StopsForwarder THEN "refuses" ELSE fwd
    /\ ghost' = [ghost EXCEPT !.served = FALSE, !.window = FALSE, !.clobber = clobber]

-----------------------------------------------------------------------------

ClientRewrite ==
    /\ svc /\ key # ABSENT /\ ver < MaxVersions
    /\ ver' = ver + 1 /\ key' = ver + 1
    /\ UNCHANGED <<svc, vgate, rec, h, watch, relay, fwd, app, budget, ghost>>

ClientRewriteSame ==
    /\ svc /\ key = LO /\ budget.same > 0
    /\ key' = ver /\ budget' = IF Endless THEN budget ELSE [budget EXCEPT !.same = @ - 1]
    /\ UNCHANGED <<svc, ver, vgate, rec, h, watch, relay, fwd, app, ghost>>

ClientDelete ==
    /\ svc /\ budget.disc > 0
    /\ svc' = FALSE /\ key' = ABSENT /\ vgate' = FALSE
    /\ budget' = [budget EXCEPT !.disc = @ - 1]
    /\ UNCHANGED <<ver, rec, h, watch, relay, fwd, app, ghost>>

ClientPublishDNS ==
    /\ ~svc /\ ~budget.inflap /\ key = ABSENT /\ ver < MaxVersions
    /\ ver' = ver + 1 /\ key' = ver + 1
    /\ UNCHANGED <<svc, vgate, rec, h, watch, relay, fwd, app, budget, ghost>>

ClientPublishIPv4 ==
    /\ ~svc /\ ~budget.inflap /\ key \in Versions
    /\ svc' = TRUE /\ vgate' = TRUE
    /\ UNCHANGED <<key, ver, rec, h, watch, relay, fwd, app, budget, ghost>>

ClientRepublish ==
    /\ svc /\ key # ABSENT /\ ver < MaxVersions /\ budget.repub > 0
    /\ ver' = ver + 1 /\ key' = ver + 1 /\ svc' = FALSE
    /\ budget' = [budget EXCEPT !.repub = @ - 1]
    /\ UNCHANGED <<vgate, rec, h, watch, relay, fwd, app, ghost>>

ClientIPv4Flap ==
    /\ svc /\ key # ABSENT /\ budget.v4flaps > 0
    /\ svc' = FALSE /\ budget' = [budget EXCEPT !.v4flaps = IF Endless THEN @ ELSE @ - 1, !.inflap = TRUE]
    /\ UNCHANGED <<key, ver, vgate, rec, h, watch, relay, fwd, app, ghost>>

ClientIPv4Back ==
    /\ budget.inflap
    /\ svc' = TRUE /\ budget' = [budget EXCEPT !.inflap = FALSE]
    /\ UNCHANGED <<key, ver, vgate, rec, h, watch, relay, fwd, app, ghost>>

GateFlap ==
    /\ vgate /\ budget.flaps > 0
    /\ vgate' = FALSE /\ budget' = [budget EXCEPT !.flaps = @ - 1]
    /\ UNCHANGED <<key, svc, ver, rec, h, watch, relay, fwd, app, ghost>>

GateBack ==
    /\ ~vgate /\ svc
    /\ vgate' = TRUE
    /\ UNCHANGED <<key, svc, ver, rec, h, watch, relay, fwd, app, budget, ghost>>

-----------------------------------------------------------------------------

OwnerExit ==
    /\ app.alive /\ budget.exits > 0
    /\ app' = [FreshApp(app.id, "off") EXCEPT !.alive = FALSE]
    /\ fwd' = "refuses" /\ budget' = [budget EXCEPT !.exits = @ - 1]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, ghost>>

AppLaunch ==
    /\ ~app.alive
    /\ app' = FreshApp(app.id + 1, "off")
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

HelperCrash ==
    /\ h.up /\ budget.crashes > 0
    /\ h' = HIdle(FALSE) /\ relay' = FALSE /\ watch' = FALSE
    /\ budget' = [budget EXCEPT !.crashes = @ - 1]
    /\ app' = IF app.alive /\ app.req # "none" THEN Failed(app) ELSE app
    /\ fwd' = IF app.alive /\ app.req = "stopRelay" THEN "refuses" ELSE fwd
    /\ UNCHANGED <<key, svc, ver, vgate, rec, ghost>>

RelayDies ==
    /\ relay /\ budget.relay > 0
    /\ relay' = FALSE /\ budget' = [budget EXCEPT !.relay = @ - 1]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, fwd, app, ghost>>

ForwarderFault(f) ==
    /\ app.alive /\ app.dns # "off" /\ fwd = "answers" /\ budget.fwd > 0
    /\ fwd' = f /\ budget' = [budget EXCEPT !.fwd = @ - 1]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, app, ghost>>

ForwarderRecovers ==
    /\ app.alive /\ app.dns # "off" /\ fwd # "answers"
    /\ fwd' = "answers"
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, app, budget, ghost>>

-----------------------------------------------------------------------------

HAccept ==
    /\ HelperFree /\ app.alive /\ app.req # "none"
    /\ ghost' = [ghost EXCEPT !.served = Served]
    /\ CASE app.req = "apply" ->
              IF svc /\ key = app.reqExp /\ app.reqExp \in Versions /\ relay /\ fwd = "answers"
              THEN /\ rec' = [has |-> TRUE, n |-> app.reqExp, owner |-> app.id]
                   /\ h' = [h EXCEPT !.pc = "apply_write", !.basis = key, !.cmp = TRUE,
                                     !.from = app.id, !.expected = app.reqExp]
                   /\ UNCHANGED <<key, watch, relay, app, fwd>>
              ELSE /\ app' = ApplyRefused(app)
                   /\ UNCHANGED <<key, rec, h, watch, relay, fwd>>
         [] app.req = "release" ->
              IF rec.has THEN StartRelease("reply", app.id) /\ UNCHANGED <<key, rec, watch, relay, app, fwd>>
              ELSE app' = ReleaseOK(app) /\ UNCHANGED <<key, rec, h, watch, relay, fwd>>
         [] app.req = "startRelay" ->
              /\ relay' = TRUE /\ app' = Done(app)
              /\ h' = IF relay THEN h ELSE [h EXCEPT !.refused = 0, !.silent = 0]
              /\ UNCHANGED <<key, rec, watch, fwd>>
         [] app.req = "stopRelay" ->
              IF rec.has THEN StartRelease("stop", app.id) /\ UNCHANGED <<key, rec, watch, relay, app, fwd>>
              ELSE relay' = FALSE /\ app' = Done(app) /\ fwd' = "refuses" /\ UNCHANGED <<key, rec, h, watch>>
    /\ UNCHANGED <<svc, ver, vgate, budget>>

HApplyWrite ==
    /\ h.up /\ h.pc = "apply_write"
    /\ key' = LO
    /\ ghost' = [ghost EXCEPT !.clobber = @ \/ Clobbers(key, h.expected), !.window = key # h.basis]
    /\ h' = [h EXCEPT !.pc = "apply_ipv4", !.basis = LO, !.cmp = FALSE]
    /\ UNCHANGED <<svc, ver, vgate, rec, watch, relay, fwd, app, budget>>

HApplyIPv4 ==
    /\ h.up /\ h.pc = "apply_ipv4"
    /\ IF svc \/ ~ApplyChecksService
       THEN /\ app' = ReplyApp(ApplyOK)
            /\ IF ~WatchOwner \/ OwnerAlive
               THEN watch' = WatchOwner /\ h' = HIdle(TRUE)
               ELSE watch' = FALSE /\ StartRelease("none", 0)
       ELSE /\ h' = [h EXCEPT !.pc = "apply_gone_read"]
            /\ UNCHANGED <<watch, app>>
    /\ UNCHANGED <<key, svc, ver, vgate, rec, relay, fwd, budget, ghost>>

HApplyGoneRead ==
    /\ h.up /\ h.pc = "apply_gone_read"
    /\ IF key = LO \/ ~ApplyGoneCompares
       THEN /\ h' = [h EXCEPT !.pc = "apply_gone_write", !.basis = IF ApplyGoneCompares THEN key ELSE h.basis,
                                                         !.cmp = ApplyGoneCompares]
            /\ UNCHANGED <<rec, app, ghost>>
       ELSE
            /\ rec' = NoRec /\ h' = HIdle(TRUE) /\ app' = ReplyApp(ApplyRefused)
            /\ ghost' = [ghost EXCEPT !.served = FALSE, !.window = FALSE]
    /\ UNCHANGED <<key, svc, ver, vgate, watch, relay, fwd, budget>>

HApplyGoneWrite ==
    /\ h.up /\ h.pc = "apply_gone_write"
    /\ key' = IF RemovesGoneKey THEN ABSENT ELSE h.expected
    /\ ghost' = [ghost EXCEPT !.clobber = @ \/ Clobbers(key, LO), !.served = FALSE, !.window = FALSE]
    /\ rec' = NoRec /\ h' = HIdle(TRUE) /\ app' = ReplyApp(ApplyRefused)
    /\ UNCHANGED <<svc, ver, vgate, watch, relay, fwd, budget>>

HRelRead ==
    /\ h.up /\ h.pc = "rel_read"
    /\ h' = [h EXCEPT !.pc = "rel_write", !.basis = key, !.cmp = TRUE]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, watch, relay, fwd, app, budget, ghost>>

HRelWrite ==
    /\ h.up /\ h.pc = "rel_write"
    /\ IF (h.basis = LO \/ ~ReleaseCompares) /\ h.basis # ABSENT
       THEN /\ key' = rec.n
            /\ IF RemovesGoneKey
               THEN /\ h' = [h EXCEPT !.pc = "rel_ipv4", !.basis = rec.n, !.cmp = FALSE]
                    /\ ghost' = [ghost EXCEPT !.clobber = @ \/ Clobbers(key, LO)]
                    /\ UNCHANGED <<rec, watch, relay, app, fwd>>
               ELSE FinishRelease(ghost.clobber \/ Clobbers(key, LO))
       ELSE /\ FinishRelease(ghost.clobber) /\ UNCHANGED key
    /\ UNCHANGED <<svc, ver, vgate, budget>>

HRelIPv4 ==
    /\ h.up /\ h.pc = "rel_ipv4"
    /\ IF svc
       THEN FinishRelease(ghost.clobber) /\ UNCHANGED key
       ELSE /\ h' = [h EXCEPT !.pc = "rel_remove"]
            /\ UNCHANGED <<key, rec, watch, relay, app, fwd, ghost>>
    /\ UNCHANGED <<svc, ver, vgate, budget>>

HRelRemove ==
    /\ h.up /\ h.pc = "rel_remove"
    /\ key' = ABSENT
    /\ FinishRelease(ghost.clobber \/ Clobbers(key, h.basis))
    /\ UNCHANGED <<svc, ver, vgate, budget>>

HTick ==
    /\ h.up /\ h.pc = "idle" /\ rec.has
    /\ CASE ~relay -> StartRelease("none", 0)
         [] fwd = "refuses" ->
              IF h.refused + 1 >= 2 THEN StartRelease("none", 0)
              ELSE h' = [h EXCEPT !.refused = @ + 1, !.silent = 0]
         [] fwd = "silent" ->
              IF h.silent + 1 >= 3 THEN StartRelease("none", 0)
              ELSE h' = [h EXCEPT !.silent = @ + 1, !.refused = 0]
         [] OTHER -> h' = [h EXCEPT !.refused = 0, !.silent = 0]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, watch, relay, fwd, app, budget, ghost>>

HOwnerExit ==
    /\ h.up /\ h.pc = "idle" /\ ExitPending
    /\ StartRelease("none", 0) /\ watch' = FALSE
    /\ UNCHANGED <<key, svc, ver, vgate, rec, relay, fwd, app, budget, ghost>>

HSignal ==
    /\ h.up /\ h.pc = "idle" /\ budget.crashes > 0
    /\ budget' = [budget EXCEPT !.crashes = @ - 1]
    /\ IF rec.has
       THEN StartRelease("exit", 0) /\ UNCHANGED <<relay, watch>>
       ELSE h' = HIdle(FALSE) /\ relay' = FALSE /\ watch' = FALSE
    /\ UNCHANGED <<key, svc, ver, vgate, rec, fwd, app, ghost>>

HStart ==
    /\ ~h.up
    /\ IF rec.has /\ ReleaseAtStart
       THEN h' = [HIdle(TRUE) EXCEPT !.pc = "rel_read"]
       ELSE h' = HIdle(TRUE)
    /\ UNCHANGED <<key, svc, ver, vgate, rec, watch, relay, fwd, app, budget, ghost>>

-----------------------------------------------------------------------------

AppReadBox ==
    /\ AppAwake /\ app.dns # "off" /\ app.snapBox = NOBOX /\ <<key, svc>> # app.snapKey
    /\ app' = [app EXCEPT !.snapBox = app.box, !.snapKey = <<key, svc>>]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

AppReadStore ==
    /\ AppAwake /\ app.snapBox # NOBOX
    /\ LET b == IF BoxBothSides /\ app.box # NONE THEN app.box ELSE app.snapBox
           v == IF svc THEN Parse(key, b) ELSE NONE
           o == svc /\ Overridden(key, b)
       IN app' = [app EXCEPT !.snapBox = NOBOX, !.view = v, !.ovr = o, !.fresh = TRUE, !.tries = 0,
                                  !.vstale = o /\ b # app.box /\ <<key, svc>> # app.snapKey,
                                  !.rewritten = IF o THEN FALSE ELSE @]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

UseSet == UseSetOf(app)
Decision(set) == DecisionOf(app, set)
MayHold == MayHoldOf(app)
PassRunning == app.req # "none" /\ app.pass

NewSet == IF app.dns = "off" \/ ~vgate THEN NONE
          ELSE IF app.view \in Versions THEN app.view
          ELSE IF FlapHold THEN app.taken
          ELSE NONE

AppTake ==
    /\ AppAwake /\ NewSet # app.taken
    /\ LET hold == PassRunning \/ (HoldBeforeRelease /\ MayHold /\ Decision(NewSet) = "release")
       IN app' = [app EXCEPT !.taken = NewSet,
                             !.held = IF hold THEN NewSet ELSE @, !.hstale = IF hold THEN app.vstale ELSE @,
                             !.live = IF hold THEN @ ELSE NewSet, !.lstale = IF hold THEN @ ELSE app.vstale,
                             !.applies = IF vgate THEN @ ELSE 0, !.refusals = IF vgate THEN @ ELSE 0,
                             !.susp = vgate /\ @]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

\* A flap lasts well under a tick, so a tick re-arms only once the service is back.
Polled(a) ==
    IF rec.has /\ rec.n \in {a.known, a.unApply} \ {NONE}
    THEN [a EXCEPT !.known = rec.n, !.box = rec.n, !.unApply = NONE, !.unRel = FALSE, !.fresh = @ \/ svc, !.tries = 0,
                   !.rewritten = @ \/ (SameRewriteReapplies /\ svc /\ a.view = key /\ key \in Versions
                                       /\ ~a.ovr)]
    ELSE [Forget(a) EXCEPT !.fresh = @ \/ svc, !.tries = 0]

AppPoll ==
    /\ AppAwake /\ app.req = "none" /\ MayHold /\ HelperFree
    /\ ghost' = [ghost EXCEPT !.served = Served]
    /\ app' = Polled(app)
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget>>

AppPass ==
    /\ AppAwake /\ app.req = "none"
    /\ LET d == Decision(UseSet)
       IN CASE d = "release" ->
                 app' = [app EXCEPT !.req = "release", !.pass = TRUE]
            [] d = "apply" ->
                 app' = [app EXCEPT !.box = app.view, !.req = "apply", !.reqExp = app.view,
                                    !.pass = TRUE,
                                    !.applies = IF RefusalsSeparate THEN @ ELSE @ + 1]
            [] d = "suspend" ->
                 app' = [app EXCEPT !.susp = TRUE]
            [] OTHER ->
                 /\ app.held # NOHELD
                 /\ ~(HeldSetRechecked /\ MayHold /\ Decision(app.held) = "release")
                 /\ app' = [app EXCEPT !.live = app.held, !.lstale = app.hstale, !.held = NOHELD]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

AppCallFails ==
    /\ app.alive /\ app.req # "none" /\ ~h.up
    /\ app' = Failed(app)
    /\ fwd' = IF app.req = "stopRelay" THEN "refuses" ELSE fwd
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, budget, ghost>>

AppRestartRelay ==
    /\ AppAwake /\ app.dns = "on" /\ ~relay /\ app.req = "none"
    /\ app' = [app EXCEPT !.req = "startRelay"]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

AppStartDNS ==
    /\ AppAwake /\ app.dns = "off" /\ app.req = "none"
    /\ app' = [app EXCEPT !.dns = "on", !.req = "startRelay", !.snapKey = NEVER]
    /\ fwd' = "answers"
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, budget, ghost>>

AppStop ==
    /\ AppAwake /\ app.dns = "on" /\ budget.stops > 0
    /\ app' = [app EXCEPT !.dns = "stop_release"] /\ budget' = [budget EXCEPT !.stops = @ - 1]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, ghost>>

AppTdRelease ==
    /\ AppAwake /\ app.dns = "stop_release" /\ app.req = "none"
    /\ app' = IF MayHold
              THEN [app EXCEPT !.dns = "stop_wait_release", !.req = "release", !.pass = FALSE,
                               !.applies = 0, !.refusals = 0, !.susp = FALSE]
              ELSE [app EXCEPT !.dns = "stop_clear", !.applies = 0, !.refusals = 0, !.susp = FALSE]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

AppTdClear ==
    /\ AppAwake /\ app.dns = "stop_clear" /\ app.req = "none"
    /\ app' = [app EXCEPT !.dns = "stop_wait_clear", !.req = "stopRelay", !.pass = FALSE]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

SpacingElapses ==
    /\ app.alive /\ app.spaced
    /\ app' = [app EXCEPT !.spaced = FALSE, !.fresh = TRUE, !.tries = 0]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

SuspensionExpires ==
    /\ SuspensionsExpire /\ app.alive /\ app.susp
    /\ app' = [app EXCEPT !.susp = FALSE, !.applies = 0, !.refusals = 0, !.fresh = TRUE, !.tries = 0]
    /\ UNCHANGED <<key, svc, ver, vgate, rec, h, watch, relay, fwd, budget, ghost>>

-----------------------------------------------------------------------------

ClientNext == ClientRewrite \/ ClientDelete \/ ClientPublishDNS \/ ClientPublishIPv4 \/ ClientRepublish
              \/ ClientIPv4Flap \/ ClientIPv4Back \/ ClientRewriteSame
              \/ GateFlap \/ GateBack
EnvNext == OwnerExit \/ AppLaunch \/ HelperCrash \/ RelayDies \/ ForwarderRecovers
           \/ ForwarderFault("refuses") \/ ForwarderFault("silent")
HelperSteps == HApplyWrite \/ HApplyIPv4 \/ HApplyGoneRead \/ HApplyGoneWrite
               \/ HRelRead \/ HRelWrite \/ HRelIPv4 \/ HRelRemove
HelperNext == HAccept \/ HelperSteps \/ HTick \/ HOwnerExit \/ HSignal \/ HStart
AppNext == AppReadBox \/ AppReadStore \/ AppTake \/ AppPoll \/ AppPass \/ AppCallFails
           \/ AppRestartRelay \/ AppStartDNS \/ AppStop \/ AppTdRelease \/ AppTdClear
           \/ SpacingElapses \/ SuspensionExpires

Terminal == ~ENABLED (ClientNext \/ EnvNext \/ HelperNext \/ AppNext) /\ UNCHANGED vars

Next == ClientNext \/ EnvNext \/ HelperNext \/ AppNext \/ Terminal

\* Only the helper is fair: a crashed or stalled app may never act.
Fairness ==
    /\ WF_vars(HApplyWrite) /\ WF_vars(HApplyIPv4) /\ WF_vars(HApplyGoneRead) /\ WF_vars(HApplyGoneWrite)
    /\ WF_vars(HRelRead) /\ WF_vars(HRelWrite) /\ WF_vars(HRelIPv4) /\ WF_vars(HRelRemove)
    /\ WF_vars(HTick) /\ WF_vars(HOwnerExit) /\ WF_vars(HStart)
    /\ WF_vars(SuspensionExpires)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------

TypeOK ==
    /\ key \in Keys /\ svc \in BOOLEAN /\ ver \in Versions /\ vgate \in BOOLEAN
    /\ rec.has \in BOOLEAN /\ rec.n \in {NONE} \cup Versions
    /\ h.pc \in {"idle", "apply_write", "apply_ipv4", "apply_gone_read", "apply_gone_write",
                 "rel_read", "rel_write", "rel_ipv4", "rel_remove"}
    /\ h.refused \in 0..1 /\ h.silent \in 0..2
    /\ relay \in BOOLEAN /\ fwd \in {"answers", "refuses", "silent"}
    /\ app.dns \in {"on", "stop_release", "stop_wait_release", "stop_clear", "stop_wait_clear", "off"}
    /\ app.view \in Views /\ app.live \in Views /\ app.held \in Views \cup {NOHELD}
    /\ app.lastN \in {NONE} \cup Versions /\ app.spaced \in BOOLEAN /\ app.susp \in BOOLEAN
    /\ app.box \in {NONE} \cup Versions
    /\ app.req \in {"none", "apply", "release", "startRelay", "stopRelay"}

NoClobber == ~ghost.clobber

NoSelfReference == app.live # LO /\ app.view # LO /\ app.held # LO

NoServerlessDefault == key = LO => rec.has

ExitWindow == rec.has /\ ~OwnerAlive /\ ~ghost.served
ReleaseBeforeUnset ==
    (Serving /\ key = LO /\ ~ExitWindow)
        => (app.live = rec.n \/ ((ghost.window \/ app.lstale) /\ app.live \in Versions))

NoLoopbackWithoutService == (key = LO /\ ~svc /\ ~budget.inflap) => (rec.has /\ (~h.up \/ h.pc # "idle"))

ClientKeyKept == (svc \/ budget.inflap) => key # ABSENT

Suspends == AppAwake /\ app.req = "none" /\ Decision(UseSet) = "suspend"
NeverSuspended == ~Suspends /\ ~app.susp

\* tries counts refusals since the last reading, tick or wake.
OneRefusalPerTrigger == app.tries <= 1

SuspensionEnds == app.susp ~> ~app.susp

OverrideLost ==
    /\ rec.has /\ key = rec.n /\ app.known = rec.n /\ app.view = rec.n /\ ~app.ovr
    /\ Serving /\ vgate /\ svc /\ app.alive /\ app.dns = "on" /\ app.req = "none" /\ h.pc = "idle"
    /\ app.snapBox = NOBOX /\ <<key, svc>> = app.snapKey
    /\ ~app.spaced /\ ~app.susp
    /\ DecisionOf(Polled(app), UseSet) = "none"
NeverLost == ~OverrideLost

EventuallyReleased == (key = LO /\ ~Serving) ~> (key # LO \/ Serving)

=============================================================================
