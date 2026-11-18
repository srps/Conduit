---------------------------- MODULE VPNDetection ----------------------------
(***************************************************************************)
(* The VPN detection chain, from the dynamic store to the split-DNS entry  *)
(* files in /etc/resolver. Each action names the Swift it stands for; the  *)
(* coverage record in .claude/skills/vpn-detection-model/SKILL.md maps     *)
(* every action to its file and function.                                  *)
(*                                                                         *)
(* Real time is abstracted. A wake-up fires at some later step; the flap   *)
(* windows advance in `AgeLoss`. Only the order of events is modelled.     *)
(* One tunnel stands for the store: the two-tunnel timer logic is covered  *)
(* by VPNFlapTimerModelCheckTests.                                         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxStarts,           \* host Starts (each followed by at most one Stop)
    MaxTunnelDrops,      \* the VPN drops or loses its address, notified
    MaxSilentChanges,    \* a store change whose notification is lost
    MaxStoreBreaks,      \* the store becomes unreadable
    MaxCancelFailures,   \* a subscription cancel the store refuses
    MaxHelperOutages,    \* the privileged helper stops answering
    MaxCallbackRestarts, \* a consumer restarts the monitor from onEvent
    MaxSystemWakes,      \* the Mac wakes and the orchestrator probes
    GatewayUnderManagedDomain, \* the VPN gateway's name falls under a split-DNS domain
    WithOrchestrator     \* model ProxyOrchestrator's reactions (checked on their own, smaller bounds)

Tunnels == {"none", "up", "lost"}   \* absent; IPv4 address; interface key, no address
Verdicts == {"connected", "reasserting", "disconnected", "unknown"}
Losses == {"none", "debounce", "grace", "past"}

\* SplitDNSVPNGate.entriesWanted
Wanted(v) == v \in {"connected", "reasserting"}

VARIABLES
    store,     \* the dynamic store: the tunnel, and whether it can be read
    budget,    \* what the environment may still do
    lc,        \* VPNStatusMonitor.lifecycleBox: started, generation, subscription
    wakeTask,  \* LifecycleState.wake: the one pending wake-up Task, while it sleeps
    monQ,      \* monitorQueue: start blocks, store callbacks, fired wake-ups
    pendingCb, \* subscriptions with a store callback queued (configd coalesces)
    liveSubs,  \* subscriptions whose store session can still call back
    sess,      \* VPNStatusMonitor.session (lives on monitorQueue)
    mon,       \* the monitor thread inside reconcile: decided, then publishing
    inbox,     \* ObserverDeliveries tasks carrying VPN reports to the host, in stamp order
    lastPub,   \* the verdict onChange published last
    host,      \* RuntimeHost: lifecycle phase, runtimeStarted, the gate
    platQ,     \* PlatformWork: the serial queue of entry-file operations
    files,     \* split-DNS entry files exist in /etc/resolver
    helperUp,  \* the helper answers
    repair,    \* SplitDNSEntryFileRepair: a failed operation pending, a retry in flight
    orchInbox, \* reports the gate took, on their way to ProxyOrchestrator.handleVPNStateChange
    orch,      \* ProxyOrchestrator: VPNReactionHistory and the stranded-socket sweeps
    ghost      \* observations for the properties; no code holds them

vars == <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, inbox, lastPub,
          host, platQ, files, helperUp, repair, orchInbox, orch, ghost>>
monVars == <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, inbox, lastPub>>
hostVars == <<host, platQ, files, helperUp, repair>>
orchVars == <<orchInbox, orch>>

-----------------------------------------------------------------------------
(* VPNFlapTimer, for one tunnel, with the windows fixed.                   *)
(* `loss` is where the clock stands against the dated loss: inside        *)
(* minVisible, inside grace, or past both. `AgeLoss` moves it on.          *)

NewTimer == [counted |-> FALSE, seenUp |-> FALSE, loss |-> "none",
             lastGood |-> FALSE, failedSince |-> FALSE]

LossVerdict(l) == CASE l = "debounce" -> "connected"
                    [] l = "grace"    -> "reasserting"
                    [] l = "past"     -> "disconnected"

\* VPNFlapTimer.settle: one good reading.
Settle(t, snap) ==
    CASE snap = "up" ->
            [t |-> [t EXCEPT !.counted = TRUE, !.seenUp = TRUE, !.loss = "none"], v |-> "connected"]
      [] snap = "lost" /\ t.loss # "none" ->
            [t |-> [t EXCEPT !.counted = FALSE], v |-> LossVerdict(t.loss)]
      [] snap = "lost" /\ t.counted ->
            [t |-> [t EXCEPT !.counted = FALSE, !.loss = "debounce"], v |-> "connected"]
      [] OTHER ->
            [t |-> [t EXCEPT !.counted = FALSE, !.loss = "none"], v |-> "disconnected"]

\* VPNFlapTimer.reconcile. After a blind gap a loss first seen at recovery is
\* dated at the last good reading (0047), so it may be anywhere in its windows.
Outcomes(t, reading) ==
    IF reading = "failed"
    THEN {[t |-> [t EXCEPT !.failedSince = t.lastGood], v |-> "unknown"]}
    ELSE IF t.failedSince /\ t.lastGood
    THEN LET atL == Settle(t, reading) IN
         IF t.loss = "none" /\ atL.t.loss = "debounce"
         THEN {[t |-> [atL.t EXCEPT !.loss = l, !.lastGood = TRUE, !.failedSince = FALSE],
                v |-> LossVerdict(l)] : l \in {"debounce", "grace", "past"}}
         ELSE LET atNow == Settle(atL.t, reading) IN
              {[t |-> [atNow.t EXCEPT !.lastGood = TRUE, !.failedSince = FALSE], v |-> atNow.v]}
    ELSE LET r == Settle(t, reading) IN {[t |-> [r.t EXCEPT !.lastGood = TRUE], v |-> r.v]}

\* VPNDetection.deadline: a debounce or a grace window is running.
HasDeadline(o, reading) == reading # "failed" /\ o.t.loss \in {"debounce", "grace"}

\* StoreReadSchedule: a failed attempt has its retry, a good reading its audit.
ReadDue(reading) == TRUE

-----------------------------------------------------------------------------
(* VPNStatusMonitor                                                        *)

NoSession == [gen |-> 0, timer |-> NewTimer, delivered |-> "none", failed |-> FALSE]
NewSession(g) == [NoSession EXCEPT !.gen = g]
IdleMon == [pc |-> "idle", gen |-> 0, verdict |-> "unknown", events |-> FALSE,
            deliver |-> FALSE, armsWake |-> FALSE, next |-> NoSession, fresh |-> FALSE]
BarrierPCs == {"emitted", "calling"}

\* VPNStatusMonitor.isCurrent
IsCurrent(g) == lc.started /\ lc.generation = g

Read == IF store.ok THEN store.tunnel ELSE "failed"

RECURSIVE SeqOf(_)
SeqOf(S) == IF S = {} THEN <<>>
            ELSE LET x == CHOOSE x \in S : \A y \in S : x <= y IN <<x>> \o SeqOf(S \ {x})

\* configd marks each live subscription once, however many changes it stands for.
Notify == LET new == SeqOf(liveSubs \ pendingCb) IN
          /\ monQ' = monQ \o [i \in 1..Len(new) |-> [kind |-> "store", gen |-> new[i], cur |-> FALSE]]
          /\ pendingCb' = pendingCb \cup liveSubs

\* A fired wake-up whose number is no longer the newest does nothing when it runs
\* (`wake` compares `wakeID`), so arming a new one drops it from the queue here.
StaleWakes(q) == SelectSeq(q, LAMBDA it : it.kind # "wake")

\* The decide half of VPNStatusMonitor.reconcile: outside the barrier.
Decide(g, s, reading) ==
    \E o \in Outcomes(s.timer, reading) :
        mon' = [pc |-> "decided", gen |-> g, verdict |-> o.v,
                events |-> reading = "failed" \/ s.failed,
                deliver |-> o.v # s.delivered,
                armsWake |-> ReadDue(reading) \/ HasDeadline(o, reading),
                next |-> [s EXCEPT !.timer = o.t, !.delivered = o.v, !.failed = (reading = "failed")],
                fresh |-> TRUE]

\* VPNStatusMonitor.attempt, then reconcile's guard and decide.
Attempt(g, s) ==
    IF ~IsCurrent(g) \/ s.gen # g
    THEN /\ mon' = mon /\ UNCHANGED <<lc, liveSubs>>
    ELSE IF lc.sub = 0
    THEN IF store.ok
         THEN /\ lc' = [lc EXCEPT !.sub = g]
              /\ liveSubs' = liveSubs \cup {g}
              /\ Decide(g, s, store.tunnel)
         ELSE /\ UNCHANGED <<lc, liveSubs>>
              /\ Decide(g, s, "failed")
    ELSE /\ UNCHANGED <<lc, liveSubs>>
         /\ Decide(g, s, Read)

\* VPNStatusMonitor.start: the block it queues.
StartItem(g) ==
    IF IsCurrent(g)
    THEN /\ sess' = NewSession(g)
         /\ Attempt(g, NewSession(g))
    ELSE /\ UNCHANGED <<sess, mon, lc, liveSubs>>

\* VPNStatusMonitor.storeChanged
StoreItem(g) ==
    IF IsCurrent(g) /\ sess.gen = g
    THEN /\ Decide(g, sess, Read) /\ UNCHANGED <<sess, lc, liveSubs>>
    ELSE UNCHANGED <<sess, mon, lc, liveSubs>>

\* VPNStatusMonitor.wake
WakeItem(it) ==
    IF it.cur
    THEN /\ Attempt(it.gen, sess) /\ UNCHANGED sess
    ELSE UNCHANGED <<sess, mon, lc, liveSubs>>

\* monitorQueue runs its next block.
MonStep ==
    /\ mon.pc = "idle"
    /\ monQ # <<>>
    /\ LET it == Head(monQ) IN
       /\ CASE it.kind = "start" -> StartItem(it.gen)
            [] it.kind = "store" -> StoreItem(it.gen)
            [] it.kind = "wake"  -> WakeItem(it)
       /\ monQ' = Tail(monQ)
       /\ pendingCb' = IF it.kind = "store" THEN pendingCb \ {it.gen} ELSE pendingCb
    /\ UNCHANGED <<wakeTask, inbox, lastPub, store, budget, hostVars, orchVars, ghost>>

\* VPNStatusMonitor.arm: replaces the pending wake-up, if still current.
Arm(g) ==
    IF IsCurrent(g)
    THEN /\ wakeTask' = [sleeping |-> TRUE, gen |-> g]
         /\ monQ' = StaleWakes(monQ)
    ELSE UNCHANGED <<wakeTask, monQ>>

\* The checks inside barrier.deliver.
EnterCheck == IsCurrent(mon.gen)
VerdictCheckOK == IsCurrent(mon.gen)

\* reconcile enters barrier.deliver: session, wake-up, events.
Enter ==
    /\ mon.pc = "decided"
    /\ IF EnterCheck
       THEN /\ sess' = mon.next
            /\ IF mon.armsWake THEN Arm(mon.gen) ELSE UNCHANGED <<wakeTask, monQ>>
            \* With no event there is no callback before the verdict check, so it runs here.
            /\ mon' = IF mon.events THEN [mon EXCEPT !.pc = "emitted"]
                      ELSE IF VerdictCheckOK /\ mon.deliver THEN [mon EXCEPT !.pc = "calling"]
                      ELSE IdleMon
            /\ ghost' = [ghost EXCEPT !.fresh = mon.fresh,
                                      !.late = ghost.late \/ (mon.events /\ ~IsCurrent(mon.gen))]
       ELSE /\ mon' = IdleMon
            /\ UNCHANGED <<sess, wakeTask, monQ, ghost>>
    /\ UNCHANGED <<lc, pendingCb, liveSubs, inbox, lastPub, store, budget, hostVars, orchVars>>

\* The generation check before names and onChange.
VerdictCheck ==
    /\ mon.pc = "emitted"
    /\ mon' = IF VerdictCheckOK /\ mon.deliver THEN [mon EXCEPT !.pc = "calling"] ELSE IdleMon
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, inbox, lastPub,
                   store, budget, hostVars, orchVars, ghost>>

\* onChange: RuntimeHost stamps the report and hands it to ObserverDeliveries.
Call ==
    /\ mon.pc = "calling"
    /\ inbox' = Append(inbox, mon.verdict)
    /\ lastPub' = mon.verdict
    /\ ghost' = [ghost EXCEPT !.late = ghost.late \/ ~IsCurrent(mon.gen)]
    /\ mon' = IdleMon
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, store, budget, hostVars, orchVars>>

\* The wake-up's Task finishes its sleep and queues VPNStatusMonitor.wake.
\* A wake-up that would re-read a store already read as it is changes nothing
\* (VPNFlapTimer.reconcile is idempotent), so one fires only once the store or the
\* clock moved since the last reading this session published.
WakeFire ==
    /\ wakeTask.sleeping /\ ~ghost.fresh
    /\ monQ' = Append(monQ, [kind |-> "wake", gen |-> wakeTask.gen, cur |-> TRUE])
    /\ wakeTask' = [sleeping |-> FALSE, gen |-> 0]
    /\ UNCHANGED <<lc, pendingCb, liveSubs, sess, mon, inbox, lastPub, store, budget,
                   hostVars, orchVars, ghost>>

\* VPNStatusMonitor.stop: the teardown inside barrier.stop, then the cancels.
StopMonitor(failCancel) ==
    IF lc.started
    THEN /\ lc' = [started |-> FALSE, generation |-> lc.generation + 1, sub |-> 0]
         /\ wakeTask' = [sleeping |-> FALSE, gen |-> 0]
         /\ liveSubs' = IF lc.sub # 0 /\ ~failCancel THEN liveSubs \ {lc.sub} ELSE liveSubs
    ELSE UNCHANGED <<lc, wakeTask, liveSubs>>

\* A consumer stops and starts the monitor from inside onEvent (ObserverStopBarrier is recursive).
CallbackRestart ==
    /\ mon.pc = "emitted"
    /\ budget.restarts > 0
    /\ budget' = [budget EXCEPT !.restarts = @ - 1]
    /\ lc' = [started |-> TRUE, generation |-> lc.generation + 2, sub |-> 0]
    /\ wakeTask' = [sleeping |-> FALSE, gen |-> 0]
    /\ liveSubs' = IF lc.sub # 0 THEN liveSubs \ {lc.sub} ELSE liveSubs
    /\ monQ' = Append(monQ, [kind |-> "start", gen |-> lc.generation + 2, cur |-> FALSE])
    /\ sess' = NoSession
    /\ UNCHANGED <<pendingCb, mon, inbox, lastPub, store, hostVars, orchVars, ghost>>

-----------------------------------------------------------------------------
(* The environment: the store, the VPN client, the helper, the Mac.        *)

\* The VPN client reaches its gateway only while no entry file captures the gateway's name.
CanConnect == ~(files /\ GatewayUnderManagedDomain)

StaleRead == /\ ghost' = [ghost EXCEPT !.fresh = FALSE]
             /\ mon' = IF mon.pc = "decided" THEN [mon EXCEPT !.fresh = FALSE] ELSE mon

\* The VPN client brings the tunnel up.
\* One connect for the start and one for each drop or silent change: as many as liveness needs.
VPNConnect ==
    /\ store.tunnel # "up" /\ CanConnect /\ budget.connects > 0
    /\ budget' = [budget EXCEPT !.connects = @ - 1]
    /\ store' = [store EXCEPT !.tunnel = "up"]
    /\ Notify /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, liveSubs, sess, inbox, lastPub, hostVars, orchVars>>

\* The tunnel goes away, or keeps its interface and loses its address.
TunnelDrop(t) ==
    /\ t \in {"none", "lost"} /\ store.tunnel # t /\ budget.drops > 0
    /\ budget' = [budget EXCEPT !.drops = @ - 1]
    /\ store' = [store EXCEPT !.tunnel = t]
    /\ Notify /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, liveSubs, sess, inbox, lastPub, hostVars, orchVars>>

\* A store change whose notification never arrives.
SilentChange(t) ==
    /\ store.tunnel # t /\ budget.silent > 0
    /\ t = "up" => CanConnect
    /\ budget' = [budget EXCEPT !.silent = @ - 1]
    /\ store' = [store EXCEPT !.tunnel = t]
    /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, inbox, lastPub, hostVars, orchVars>>

\* The store cannot be created, subscribed to or read; then it can again. No notification.
StoreBreak ==
    /\ store.ok /\ budget.breaks > 0
    /\ budget' = [budget EXCEPT !.breaks = @ - 1]
    /\ store' = [store EXCEPT !.ok = FALSE]
    /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, inbox, lastPub, hostVars, orchVars>>

StoreHeal ==
    /\ ~store.ok
    /\ store' = [store EXCEPT !.ok = TRUE]
    /\ StaleRead
    /\ UNCHANGED <<budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, inbox, lastPub, hostVars, orchVars>>

\* Time passes a debounce end or a grace end (ContinuousClock).
NextLoss(l) == IF l = "debounce" THEN "grace" ELSE IF l = "grace" THEN "past" ELSE l
AgeLoss ==
    /\ IsCurrent(sess.gen) /\ sess.timer.loss \in {"debounce", "grace"}
    /\ sess' = [sess EXCEPT !.timer.loss = NextLoss(@)]
    /\ mon' = IF mon.pc = "decided" /\ mon.next.gen = sess.gen
              THEN [mon EXCEPT !.next.timer.loss = NextLoss(@), !.fresh = FALSE] ELSE mon
    /\ ghost' = [ghost EXCEPT !.fresh = FALSE]
    /\ UNCHANGED <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, inbox, lastPub, hostVars, orchVars>>

HelperDown ==
    /\ helperUp /\ budget.outages > 0
    /\ budget' = [budget EXCEPT !.outages = @ - 1]
    /\ helperUp' = FALSE
    /\ UNCHANGED <<store, monVars, host, platQ, files, repair, orchVars, ghost>>

HelperUp ==
    /\ ~helperUp
    /\ helperUp' = TRUE
    /\ UNCHANGED <<store, budget, monVars, host, platQ, files, repair, orchVars, ghost>>

-----------------------------------------------------------------------------
(* RuntimeHost                                                             *)

\* SplitDNSVPNGate.action / entryFileOperation
EntryOp(v, started) == IF ~Wanted(v) THEN "remove" ELSE IF started THEN "apply" ELSE "nothing"

\* VPNObservationSequencer stamps each report in the order the monitor published it, and
\* VPNObservationOrder.admit drops a report older than one already taken. So taking
\* report i drops every report published before it: each would be dropped when it landed.
TakenAfter(i) == SubSeq(inbox, i + 1, Len(inbox))
GateDropsOlder == TRUE
InboxAfterTake(i) == IF GateDropsOlder THEN TakenAfter(i)
                     ELSE SubSeq(inbox, 1, i - 1) \o TakenAfter(i)

\* Whether handleVPNStateChange takes a report at all.
HostTakesReports == TRUE

NoOp(tag) == ~\E i \in 1..Len(platQ) : platQ[i].tag = tag

\* RuntimeHost.handleVPNStateChange: gate update, decision and queueing in one turn.
HostDeliver(i) ==
    /\ LET v == inbox[i] IN
       /\ inbox' = InboxAfterTake(i)
       /\ IF HostTakesReports
          THEN LET changed == Wanted(host.gate) # Wanted(v)
                   op == EntryOp(v, host.started)
               IN /\ host' = [host EXCEPT !.gate = v, !.tookReport = (host.phase = "applying")]
                  /\ platQ' = IF changed /\ op # "nothing"
                              THEN Append(platQ, [op |-> op, tag |-> "vpn"])
                              ELSE platQ
                  /\ orchInbox' = IF WithOrchestrator THEN Append(orchInbox, v) ELSE orchInbox
          ELSE UNCHANGED <<host, platQ, orchInbox>>
    /\ UNCHANGED <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, lastPub,
                   files, helperUp, repair, orch, ghost>>

\* RuntimeHostLifecycle.runStartEffect -> RuntimeHost.applyProxySurfaces: the apply.
HStartBegin ==
    /\ host.phase = "stopped" /\ host.starts < MaxStarts
    /\ host' = [host EXCEPT !.phase = "applying", !.starts = @ + 1,
                            !.capWanted = Wanted(host.gate), !.tookReport = FALSE]
    /\ platQ' = Append(platQ, [op |-> IF Wanted(host.gate) THEN "apply" ELSE "remove", tag |-> "start"])
    /\ ghost' = [ghost EXCEPT !.staleApply = ghost.staleApply \/ Wanted(host.gate)]
    /\ UNCHANGED <<store, budget, monVars, files, helperUp, repair, orchVars>>

\* applyProxySurfaces after its block: runtimeStarted, then the gate-moved correction;
\* then RuntimeHostLifecycle.startObservers -> VPNStatusMonitor.start. The DNS and
\* tunnel members start in between; a report can land on either side, as here.
HStartApplied ==
    /\ host.phase = "applying" /\ NoOp("start")
    /\ LET moved == Wanted(host.gate) # host.capWanted
                    \/ (Wanted(host.gate) /\ host.tookReport)
           op == EntryOp(host.gate, TRUE)
           corrects == moved /\ op # "nothing"
       \* What the apply captured is read only here, so it is cleared after.
       IN /\ host' = [host EXCEPT !.phase = "running", !.started = TRUE,
                                  !.capWanted = FALSE, !.tookReport = FALSE]
          /\ platQ' = IF corrects THEN Append(platQ, [op |-> op, tag |-> "vpn"]) ELSE platQ
          /\ ghost' = [ghost EXCEPT !.staleApply = ghost.staleApply \/ (corrects /\ op = "apply")]
    /\ IF ~lc.started
       THEN /\ lc' = [lc EXCEPT !.started = TRUE, !.generation = lc.generation + 1]
            /\ monQ' = Append(monQ, [kind |-> "start", gen |-> lc.generation + 1, cur |-> FALSE])
       ELSE UNCHANGED <<lc, monQ>>
    /\ UNCHANGED <<store, budget, wakeTask, pendingCb, liveSubs, sess, mon, inbox, lastPub,
                   files, helperUp, repair, orchVars>>

\* barrier.stop waits out a delivery in flight on the monitor thread.
StopWaitsForBarrier == mon.pc \notin BarrierPCs

\* RuntimeHostLifecycle.tearDown: vpnStatusMonitor.stop(), runtimeStarted = false, then
\* the proxy's clear (resolvers.clear) on platformWork. A report that lands between the
\* two can queue only a removal, so one step stands for both.
HStopBegin(failCancel) ==
    /\ host.phase = "running" /\ StopWaitsForBarrier
    /\ failCancel => (budget.cancelFails > 0 /\ lc.sub # 0)
    /\ budget' = IF failCancel THEN [budget EXCEPT !.cancelFails = @ - 1] ELSE budget
    /\ StopMonitor(failCancel)
    /\ host' = [host EXCEPT !.phase = "clearing", !.started = FALSE]
    /\ platQ' = Append(platQ, [op |-> "remove", tag |-> "stop"])
    \* What the stopped session saw is read only behind isCurrent from here on, so it is dropped.
    /\ sess' = NoSession
    /\ UNCHANGED <<store, monQ, pendingCb, mon, inbox, lastPub,
                   files, helperUp, repair, orchVars, ghost>>

HStopDone ==
    /\ host.phase = "clearing" /\ NoOp("stop")
    /\ host' = [host EXCEPT !.phase = "stopped"]
    /\ UNCHANGED <<store, budget, monVars, platQ, files, helperUp, repair, orchVars, ghost>>

\* PlatformWork runs the next operation: SplitDNSVPNGate.perform through the helper,
\* recorded by SplitDNSEntryFileRepair.record in queue order.
PlatformRun ==
    /\ platQ # <<>>
    /\ LET w == Head(platQ) IN
       /\ files' = IF helperUp THEN w.op = "apply" ELSE files
       /\ repair' = [pending |-> ~helperUp,
                     inFlight |-> IF w.tag = "retry" THEN FALSE ELSE repair.inFlight]
    /\ platQ' = Tail(platQ)
    /\ UNCHANGED <<store, budget, monVars, host, helperUp, orchVars, ghost>>

\* RuntimeHost.retrySplitDNSEntryFiles once the helper check sees it answering.
Retry ==
    /\ repair.pending /\ helperUp /\ ~repair.inFlight
    /\ host.phase \in {"stopped", "running"}
    /\ platQ' = Append(platQ, [op |-> IF host.started /\ Wanted(host.gate) THEN "apply" ELSE "remove",
                               tag |-> "retry"])
    /\ repair' = [repair EXCEPT !.inFlight = TRUE]
    /\ UNCHANGED <<store, budget, monVars, host, files, helperUp, orchVars, ghost>>

-----------------------------------------------------------------------------
(* ProxyOrchestrator                                                       *)

\* ProxyOrchestrator.handleVPNStateChange with VPNReactionHistory.record.
\* The orchestrator's own VPNObservationOrder drops a report older than one it applied.
OrchHandle(i) ==
    /\ orchInbox' = SubSeq(orchInbox, i + 1, Len(orchInbox))
    /\ LET o == orch
           v == orchInbox[i] IN
            orch' = CASE v = "unknown" ->
                           IF ~o.blind /\ o.definite # "none"
                           THEN [o EXCEPT !.blind = TRUE, !.sweeps = "held"]      \* .blinded
                           ELSE o
                      [] v # o.definite ->                                       \* .transition
                           [o EXCEPT !.blind = FALSE, !.definite = v,
                                     !.sweeps = IF v = "reasserting" THEN "held" ELSE "running"]
                      [] o.blind ->                                                \* .confirmed(afterBlind)
                           [o EXCEPT !.blind = FALSE,
                                     !.sweeps = IF v # "reasserting" THEN "running" ELSE o.sweeps]
                      [] OTHER -> o
    /\ UNCHANGED <<store, budget, monVars, hostVars, ghost>>

\* The sweep task finishes its passes.
SweepsDone ==
    /\ orch.sweeps = "running"
    /\ orch' = [orch EXCEPT !.sweeps = "idle"]
    /\ UNCHANGED <<store, budget, monVars, hostVars, orchInbox, ghost>>

\* handleSystemWake: a reachable upstream ends a stale flap, only while the monitor can read.
WakeSeesStore == ~orch.blind
SystemWake ==
    /\ budget.wakes > 0 /\ host.started /\ orch.definite = "reasserting" /\ WakeSeesStore
    /\ budget' = [budget EXCEPT !.wakes = @ - 1]
    /\ orch' = [orch EXCEPT !.definite = "connected", !.sweeps = "running"]
    /\ ghost' = [ghost EXCEPT !.blindRecover = ghost.blindRecover \/ orch.blind]
    /\ UNCHANGED <<store, monVars, hostVars, orchInbox>>

-----------------------------------------------------------------------------

Quiet == /\ monQ = <<>> /\ mon.pc = "idle" /\ inbox = <<>> /\ platQ = <<>> /\ orchInbox = <<>>
         /\ ~repair.inFlight /\ orch.sweeps # "running"

\* Every Start has run and stopped: nothing is left to happen.
Done ==
    /\ host.phase = "stopped" /\ host.starts = MaxStarts /\ Quiet
    /\ UNCHANGED vars

\* A launch on an unreadable store is a StoreBreak before the first Start. A launch with a
\* tunnel that has no address reads as one with no tunnel: a new session never counted it.
Init ==
    /\ store \in [tunnel : {"none", "up"}, ok : {TRUE}]
    /\ budget = [drops |-> MaxTunnelDrops, silent |-> MaxSilentChanges, breaks |-> MaxStoreBreaks,
                 cancelFails |-> MaxCancelFailures, outages |-> MaxHelperOutages,
                 restarts |-> MaxCallbackRestarts, wakes |-> MaxSystemWakes,
                 connects |-> MaxTunnelDrops + MaxSilentChanges + 1]
    /\ lc = [started |-> FALSE, generation |-> 0, sub |-> 0]
    /\ wakeTask = [sleeping |-> FALSE, gen |-> 0]
    /\ monQ = <<>> /\ pendingCb = {} /\ liveSubs = {}
    /\ sess = NoSession
    /\ mon = IdleMon
    /\ inbox = <<>> /\ lastPub = "unknown"
    /\ host = [phase |-> "stopped", started |-> FALSE, gate |-> "unknown",
               capWanted |-> FALSE, tookReport |-> FALSE, starts |-> 0]
    /\ platQ = <<>> /\ files = FALSE /\ helperUp = TRUE
    /\ repair = [pending |-> FALSE, inFlight |-> FALSE]
    /\ orchInbox = <<>>
    /\ orch = [definite |-> "none", blind |-> FALSE, sweeps |-> "idle"]
    /\ ghost = [late |-> FALSE, fresh |-> FALSE, blindRecover |-> FALSE, staleApply |-> FALSE]

HostTakesReport == \E i \in 1..Len(inbox) : HostDeliver(i)
OrchTakesReport == \E i \in 1..Len(orchInbox) : OrchHandle(i)

MonitorNext == MonStep \/ Enter \/ VerdictCheck \/ Call \/ WakeFire \/ CallbackRestart
HostNext == HostTakesReport \/ HStartBegin \/ HStartApplied
            \/ (\E f \in BOOLEAN : HStopBegin(f)) \/ HStopDone \/ PlatformRun \/ Retry
OrchNext == OrchTakesReport \/ SweepsDone \/ SystemWake
EnvNext == VPNConnect \/ (\E t \in Tunnels : TunnelDrop(t) \/ SilentChange(t))
           \/ StoreBreak \/ StoreHeal \/ AgeLoss \/ HelperDown \/ HelperUp

Next == MonitorNext \/ HostNext \/ OrchNext \/ EnvNext \/ Done

\* Each piece of code that has work runs; time passes; the helper and the VPN
\* client come back. Nothing forces the store to heal, a Start, or a Stop.
Fairness ==
    /\ WF_vars(MonStep) /\ WF_vars(Enter) /\ WF_vars(VerdictCheck) /\ WF_vars(Call) /\ WF_vars(WakeFire)
    /\ WF_vars(HostTakesReport)
    /\ WF_vars(HStartApplied) /\ WF_vars(HStopDone)
    /\ WF_vars(PlatformRun) /\ WF_vars(Retry)
    /\ WF_vars(OrchTakesReport) /\ WF_vars(SweepsDone)
    /\ WF_vars(AgeLoss) /\ WF_vars(HelperUp) /\ WF_vars(VPNConnect)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

TypeOK ==
    /\ store \in [tunnel : Tunnels, ok : BOOLEAN]
    /\ host.gate \in Verdicts /\ lastPub \in Verdicts
    /\ sess.timer.loss \in Losses
    /\ files \in BOOLEAN

\* The host has nothing in flight for the entry files.
HostQuiet == /\ inbox = <<>> /\ platQ = <<>> /\ ~repair.pending /\ ~repair.inFlight
             /\ host.phase \in {"running", "stopped"}

\* The monitor read the store as it is now, and no flap window is running.
MonitorSettled == /\ mon.pc = "idle" /\ ghost.fresh /\ IsCurrent(sess.gen)
                  /\ sess.timer.loss \notin {"debounce", "grace"}

\* S1. Once the system settles, an entry file exists only while the proxy runs,
\* the store reads, and a tunnel carries an IPv4 address. Harm: lookups under the
\* managed domains, the VPN gateway's own name among them, go to servers no route reaches.
NoEntryFilesOffVPN ==
    /\ (HostQuiet /\ host.phase = "stopped") => ~files
    /\ (HostQuiet /\ host.phase = "running" /\ MonitorSettled) =>
           (files => store.ok /\ store.tunnel = "up")

\* S2. Once the host has taken every report, the gate holds the verdict the monitor
\* published last. Harm: a failure or a drop the monitor reported is never acted on.
GateFollowsLastPublished == inbox = <<>> => host.gate = lastPub

\* S3. After stop returns, nothing of that session is published: no event, no verdict.
\* Harm: an obsolete verdict turns the retained gate and writes entry files.
NothingPublishedAfterStop == ~ghost.late

\* S4. A wake never ends a flap the monitor cannot see. Harm: VPNReactionHistory.recoverFlap's assert.
WakeRecoversOnlyWhenSeeing == ~ghost.blindRecover

\* S5. Once the orchestrator has taken every report, a definite connected or disconnected
\* verdict never leaves the stranded-socket sweeps held. Harm: clients stall on sockets
\* whose path is gone.
SweepsNotHeldWhenDefinite ==
    (orchInbox = <<>> /\ ~orch.blind /\ orch.definite \in {"connected", "disconnected"})
        => orch.sweeps # "held"

\* K1 (known gap, U4). No entry-file write is decided while the monitor is stopped, from
\* a verdict a stopped session left. Today a Start's apply, and its correction, read that
\* gate. Harm: if the VPN dropped while the proxy was stopped, the files go back against
\* servers no route reaches until the new session's first reading lands.
ApplyOnlyFromCurrentSession == ~ghost.staleApply

\* L1. A store that can be read is eventually read: the gate leaves .unknown while it runs.
NoStuckUnknown ==
    (host.phase = "running" /\ store.ok /\ host.gate = "unknown")
        ~> (host.gate # "unknown" \/ host.phase # "running" \/ ~store.ok)

\* L2. The entry files end up matching the VPN: present exactly while the proxy runs,
\* the store reads, and the tunnel is up.
FilesFollowVPN ==
    <>[](files = (host.phase = "running" /\ store.ok /\ store.tunnel = "up"))

\* L3. A VPN that is down comes back up: no entry file keeps the client from its gateway.
VPNReconnects == (store.tunnel # "up") ~> (store.tunnel = "up")

=============================================================================
