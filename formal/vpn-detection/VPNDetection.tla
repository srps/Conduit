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
    stamp,     \* VPNObservationSequencer: the last stamp it handed out
    inbox,     \* ObserverDeliveries tasks carrying stamped VPN reports to the host, not yet run
    lastPub,   \* the verdict onChange published last
    host,      \* RuntimeHost: lifecycle phase, runtimeStarted, the gate and splitDNSGateOrder
    platQ,     \* PlatformWork: the serial queue of entry-file operations, each with its queue place
    done,      \* operations PlatformWork ran whose task has not yet resumed on RuntimeActor to record them
    files,     \* split-DNS entry files exist in /etc/resolver
    helperUp,  \* the helper answers
    repair,    \* SplitDNSEntryFileRepair: pending, generation, the last place queued; a retry in flight
    orch,      \* ProxyOrchestrator: vpnObservations, VPNReactionHistory and the stranded-socket sweeps
    ghost      \* observations for the properties; no code holds them

vars == <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, stamp, inbox, lastPub,
          host, platQ, done, files, helperUp, repair, orch, ghost>>
monVars == <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, stamp, inbox, lastPub>>
hostVars == <<host, platQ, done, files, helperUp, repair>>
orchVars == <<orch>>

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
    /\ UNCHANGED <<wakeTask, stamp, inbox, lastPub, store, budget, hostVars, orchVars, ghost>>

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
    /\ UNCHANGED <<lc, pendingCb, liveSubs, stamp, inbox, lastPub, store, budget, hostVars, orchVars>>

\* The generation check before names and onChange.
VerdictCheck ==
    /\ mon.pc = "emitted"
    /\ mon' = IF VerdictCheckOK /\ mon.deliver THEN [mon EXCEPT !.pc = "calling"] ELSE IdleMon
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, stamp, inbox, lastPub,
                   store, budget, hostVars, orchVars, ghost>>

\* onChange: RuntimeHost stamps the report (VPNObservationSequencer.next) and hands it to
\* ObserverDeliveries, one task per report, which run in no fixed order.
Call ==
    /\ mon.pc = "calling"
    /\ stamp' = stamp + 1
    /\ inbox' = inbox \cup {[seq |-> stamp + 1, v |-> mon.verdict]}
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
    /\ UNCHANGED <<lc, pendingCb, liveSubs, sess, mon, stamp, inbox, lastPub, store, budget,
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
    /\ UNCHANGED <<pendingCb, mon, stamp, inbox, lastPub, store, hostVars, orchVars, ghost>>

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
    /\ UNCHANGED <<lc, wakeTask, liveSubs, sess, stamp, inbox, lastPub, hostVars, orchVars>>

\* The tunnel goes away, or keeps its interface and loses its address.
TunnelDrop(t) ==
    /\ t \in {"none", "lost"} /\ store.tunnel # t /\ budget.drops > 0
    /\ budget' = [budget EXCEPT !.drops = @ - 1]
    /\ store' = [store EXCEPT !.tunnel = t]
    /\ Notify /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, liveSubs, sess, stamp, inbox, lastPub, hostVars, orchVars>>

\* A store change whose notification never arrives.
SilentChange(t) ==
    /\ store.tunnel # t /\ budget.silent > 0
    /\ t = "up" => CanConnect
    /\ budget' = [budget EXCEPT !.silent = @ - 1]
    /\ store' = [store EXCEPT !.tunnel = t]
    /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, stamp, inbox, lastPub, hostVars, orchVars>>

\* The store cannot be created, subscribed to or read; then it can again. No notification.
StoreBreak ==
    /\ store.ok /\ budget.breaks > 0
    /\ budget' = [budget EXCEPT !.breaks = @ - 1]
    /\ store' = [store EXCEPT !.ok = FALSE]
    /\ StaleRead
    /\ UNCHANGED <<lc, wakeTask, monQ, pendingCb, liveSubs, sess, stamp, inbox, lastPub, hostVars, orchVars>>

StoreHeal ==
    /\ ~store.ok
    /\ store' = [store EXCEPT !.ok = TRUE]
    /\ StaleRead
    /\ UNCHANGED <<budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, stamp, inbox, lastPub, hostVars, orchVars>>

\* Time passes a debounce end or a grace end (ContinuousClock).
NextLoss(l) == IF l = "debounce" THEN "grace" ELSE IF l = "grace" THEN "past" ELSE l
AgeLoss ==
    /\ IsCurrent(sess.gen) /\ sess.timer.loss \in {"debounce", "grace"}
    /\ sess' = [sess EXCEPT !.timer.loss = NextLoss(@)]
    /\ mon' = IF mon.pc = "decided" /\ mon.next.gen = sess.gen
              THEN [mon EXCEPT !.next.timer.loss = NextLoss(@), !.fresh = FALSE] ELSE mon
    /\ ghost' = [ghost EXCEPT !.fresh = FALSE]
    /\ UNCHANGED <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, stamp, inbox, lastPub, hostVars, orchVars>>

HelperDown ==
    /\ helperUp /\ budget.outages > 0
    /\ budget' = [budget EXCEPT !.outages = @ - 1]
    /\ helperUp' = FALSE
    /\ UNCHANGED <<store, monVars, host, platQ, done, files, repair, orchVars, ghost>>

HelperUp ==
    /\ ~helperUp
    /\ helperUp' = TRUE
    /\ UNCHANGED <<store, budget, monVars, host, platQ, done, files, repair, orchVars, ghost>>

-----------------------------------------------------------------------------
(* RuntimeHost                                                             *)
(*                                                                         *)
(* Every entry-file operation is decided and queued on platformWork in one *)
(* RuntimeActor turn, with its place from SplitDNSEntryFileRepair.queue.   *)
(* It runs on the queue (`PlatformRun`). Later the task that queued it     *)
(* resumes on RuntimeActor and records it (`RecordOutcome`). Those tasks   *)
(* resume in no fixed order, so outcomes are recorded in any order.        *)

\* SplitDNSVPNGate.action / entryFileOperation
EntryOp(v, started) == IF ~Wanted(v) THEN "remove" ELSE IF started THEN "apply" ELSE "nothing"

\* With no helper outage every operation succeeds and nothing is ever pending, so a queue
\* place never changes what `record` does. Those checks keep every place at 0, and fold a VPN
\* operation's record, then a no-op unless it takes a report on to the orchestrator, into
\* `PlatformRun`.
PlacesMatter == MaxHelperOutages > 0

\* SplitDNSEntryFileRepair.queue
NextPlace == IF ~PlacesMatter THEN 0
             ELSE (IF repair.queued > repair.generation THEN repair.queued ELSE repair.generation) + 1

\* The report a delivery task takes on to the orchestrator once its entry-file work is recorded.
NoFwd == [seq |-> 0, v |-> "unknown"]
Fwd(r) == IF WithOrchestrator THEN [seq |-> r.seq, v |-> r.v] ELSE NoFwd

\* Places are only compared with one another, and queue() takes the largest plus one. After a
\* record, the places still held (the generation, the queue, the tasks waiting) are renumbered
\* 1..n in order, which keeps every comparison and merges states that differ only in how many
\* operations came before.
RankOf(p, L) == IF p = 0 THEN 0 ELSE Cardinality({q \in L : q <= p})

Op(op, owner, fwd) == [op |-> op, place |-> NextPlace, owner |-> owner, fwd |-> fwd]

\* splitDNSGateOrder.admit (VPNObservationOrder): a report older than one the gate took is
\* not the tunnel's state. The gate skips it; the orchestrator still hears of it.
GateAdmitsAt(r, applied) == r.seq > applied
GateAdmits(r) == GateAdmitsAt(r, host.gateSeq)

\* Report stamps and queue places are only compared with one another. Once nothing in flight
\* holds one they restart from 0, which keeps every comparison TLC will make and merges
\* states that differ only in how many reports or operations came before.
StampsRest(in, pq, d, h) ==
    /\ in = {}
    /\ \A i \in 1..Len(pq) : pq[i].fwd = NoFwd
    /\ \A o \in d : o.fwd = NoFwd
    /\ h.phase # "applying" \/ h.gateSeq = h.capSeq
RestStamps(h) == [h EXCEPT !.gateSeq = 0, !.capSeq = 0]

-----------------------------------------------------------------------------
(* ProxyOrchestrator: handleVPNStateChange runs on RuntimeActor, and its   *)
(* order check, VPNReactionHistory.record and the sweep decision all come  *)
(* before its first suspension, so they are part of the caller's turn.    *)

\* vpnObservations.admit: a report older than one it applied is dropped (vpn.observation_stale).
OrchAdmits(r) == r.seq > orch.seq

\* VPNReactionHistory.record: what a report changed (`Change`), and the history after it.
ConfirmsAfterBlind(o) == o.blind   \* `guard wasBlind || replaced || ... else { return nil }`
Change(o, v) ==
    CASE v = "unknown"         -> IF ~o.blind /\ o.definite # "none" THEN "blinded" ELSE "none"
      [] v # o.definite        -> "transition"
      [] ConfirmsAfterBlind(o) -> "confirmed"
      [] OTHER                 -> "none"
Recorded(o, v) ==
    IF v = "unknown" THEN [o EXCEPT !.blind = o.blind \/ o.definite # "none"]
    ELSE [o EXCEPT !.blind = FALSE, !.definite = v]

\* handleVPNStateChange's switch over the change: hold, start or resume the sweeps.
React(o, c, v) ==
    CASE c = "blinded"    -> [o EXCEPT !.sweeps = "held"]
      [] c = "transition" -> [o EXCEPT !.sweeps = IF v = "reasserting" THEN "held" ELSE "running"]
      [] c = "confirmed"  -> [o EXCEPT !.sweeps = IF v # "reasserting" THEN "running" ELSE o.sweeps]
      [] OTHER            -> o

\* ProxyOrchestrator.handleVPNStateChange(state, sequence:), up to its first suspension.
OrchHandle(r) ==
    IF OrchAdmits(r)
    THEN [React(Recorded(orch, r.v), Change(orch, r.v), r.v) EXCEPT !.seq = r.seq, !.last = r.v]
    ELSE orch

-----------------------------------------------------------------------------

\* Whether handleVPNStateChange takes a report at all.
Observing == host.phase = "running"   \* networkPathObserving: set by startObservers, cleared by tearDown
HostTakesReports == TRUE

\* handleVPNStateChange awaits reconcileEntryFiles before it calls the orchestrator.
OrchestratorAfterFiles == TRUE

\* RuntimeHost.handleVPNStateChange, its first turn: the gate's admit and update, the decision
\* and the queueing. With nothing queued, reconcileEntryFiles returns without suspending and
\* the orchestrator is called in this turn. Otherwise the task resumes once its operation is
\* recorded (`RecordOutcome`). Without the orchestrator, a report the gate will skip does
\* nothing when it runs, so it is dropped here.
HostDeliver(r) ==
    LET take     == HostTakesReports
        admitted == take /\ GateAdmits(r)
        changed  == admitted /\ Wanted(host.gate) # Wanted(r.v)
        op       == EntryOp(r.v, host.started)
        queues   == changed /\ op # "nothing"
        now      == take /\ WithOrchestrator /\ (~queues \/ ~OrchestratorAfterFiles)
        h        == IF admitted THEN [host EXCEPT !.gate = r.v, !.gateSeq = r.seq] ELSE host
        pq       == IF queues THEN Append(platQ, Op(op, "vpn", IF now THEN NoFwd ELSE Fwd(r))) ELSE platQ
        in       == {x \in inbox \ {r} : WithOrchestrator \/ GateAdmitsAt(x, h.gateSeq)}
        o        == IF now THEN OrchHandle(r) ELSE orch
        rest     == StampsRest(in, pq, done, h)
    IN /\ inbox' = in
       /\ platQ' = pq
       /\ repair' = IF queues THEN [repair EXCEPT !.queued = NextPlace] ELSE repair
       /\ host' = IF rest THEN RestStamps(h) ELSE h
       /\ orch' = IF rest THEN [o EXCEPT !.seq = 0] ELSE o
       /\ stamp' = IF rest THEN 0 ELSE stamp
       \* The orchestrator heard of this report while the work its turn queued has not run.
       /\ ghost' = [ghost EXCEPT !.orchEarly = @ \/ (now /\ queues)]
       /\ UNCHANGED <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, lastPub,
                      done, files, helperUp>>

\* RuntimeHostLifecycle.runStartEffect -> RuntimeHost.applyProxySurfaces: the gate and
\* splitDNSGateOrder.applied captured, the apply queued with its place.
HStartBegin ==
    /\ host.phase = "stopped" /\ host.starts < MaxStarts
    /\ host' = [host EXCEPT !.phase = "applying", !.starts = @ + 1,
                            !.capWanted = Wanted(host.gate), !.capSeq = host.gateSeq]
    /\ platQ' = Append(platQ, Op(IF Wanted(host.gate) THEN "apply" ELSE "remove", "start", NoFwd))
    /\ repair' = [repair EXCEPT !.queued = NextPlace]
    /\ ghost' = [ghost EXCEPT !.staleApply = ghost.staleApply \/ Wanted(host.gate)]
    /\ UNCHANGED <<store, budget, monVars, done, files, helperUp, orchVars>>

\* Whether applyProxySurfaces sets runtimeStarted in the turn that decides its correction.
StartedAtSurfaces == TRUE

\* runAdmittedStart after applyProxySurfaces returns: the DNS and tunnel members start
\* (startDNSModule, orchestrator.startTunnels), each awaited, then startObservers ->
\* VPNStatusMonitor.start. Until this step the new session has not started: reports from the
\* last one may still land, and nothing reads the store.
HStartObservers ==
    /\ host.phase = "members"
    /\ host' = [host EXCEPT !.phase = "running", !.started = TRUE]
    /\ IF ~lc.started
       THEN /\ lc' = [lc EXCEPT !.started = TRUE, !.generation = lc.generation + 1]
            /\ monQ' = Append(monQ, [kind |-> "start", gen |-> lc.generation + 1, cur |-> FALSE])
       ELSE UNCHANGED <<lc, monQ>>
    /\ UNCHANGED <<store, budget, wakeTask, pendingCb, liveSubs, sess, mon, stamp, inbox, lastPub,
                   platQ, done, files, helperUp, repair, orchVars, ghost>>

\* barrier.stop waits out a delivery in flight on the monitor thread.
StopWaitsForBarrier == mon.pc \notin BarrierPCs

\* RuntimeHostLifecycle.tearDown: vpnStatusMonitor.stop(), runtimeStarted = false, then
\* tearDownProxy's clear (resolvers.clear) queued with its place. A report that lands between
\* the two can queue only a removal, so one step stands for both.
HStopBegin(failCancel) ==
    /\ host.phase = "running" /\ StopWaitsForBarrier
    /\ failCancel => (budget.cancelFails > 0 /\ lc.sub # 0)
    /\ budget' = IF failCancel THEN [budget EXCEPT !.cancelFails = @ - 1] ELSE budget
    /\ StopMonitor(failCancel)
    /\ host' = [host EXCEPT !.phase = "clearing", !.started = FALSE]
    /\ platQ' = Append(platQ, Op("remove", "stop", NoFwd))
    /\ repair' = [repair EXCEPT !.queued = NextPlace]
    \* What the stopped session saw is read only behind isCurrent from here on, so it is dropped.
    /\ sess' = NoSession
    /\ UNCHANGED <<store, monQ, pendingCb, mon, stamp, inbox, lastPub,
                   done, files, helperUp, orchVars, ghost>>

\* PlatformWork runs the next operation: SplitDNSVPNGate.perform through the helper, the
\* start's apply, or the stop's clear. The stop's clear reports a failure only while entry
\* files are still on disk (tearDownProxy).
PlatformRun ==
    /\ platQ # <<>>
    /\ LET w == Head(platQ) IN
       /\ files' = IF helperUp THEN w.op = "apply" ELSE files
       /\ done' = IF ~PlacesMatter /\ w.owner = "vpn" /\ w.fwd = NoFwd THEN done
                  ELSE done \cup {[place |-> w.place, owner |-> w.owner, fwd |-> w.fwd,
                                   ok |-> helperUp \/ (w.owner = "stop" /\ ~files)]}
    /\ platQ' = Tail(platQ)
    /\ UNCHANGED <<store, budget, monVars, host, helperUp, repair, orchVars, ghost>>

\* SplitDNSEntryFileRepair.record's guard: an outcome queued before one already recorded is
\* older than the disk and is dropped (platform.split_dns_outcome_superseded).
RecordKeeps(o) == ~(o.place < repair.generation)

\* The task that queued an operation resumes on RuntimeActor: RuntimeHost.recordSplitDNS ->
\* SplitDNSEntryFileRepair.record, then the rest of that task's turn. recordSplitDNS suspends
\* only to retry a failed intercept refresh, which the model leaves out.
\*  - start: applyProxySurfaces sets runtimeStarted and decides the gate-moved correction.
\*  - correction: applyProxySurfaces returns; the members start (`HStartObservers`).
\*  - vpn: handleVPNStateChange calls the orchestrator.
\*  - stop: tearDown returns.
\*  - retry: retrySplitDNSEntryFiles' defer ends the retry in flight.
RecordOutcome(o) ==
    LET keep    == RecordKeeps(o)
        d       == done \ {o}
        moved   == Wanted(host.gate) # host.capWanted
                   \/ (Wanted(host.gate) /\ host.gateSeq # host.capSeq)
        corrOp  == EntryOp(host.gate, TRUE)
        corrects == o.owner = "start" /\ moved
        pq      == IF corrects THEN Append(platQ, Op(corrOp, "correction", NoFwd)) ELSE platQ
        rp      == [repair EXCEPT !.generation = IF keep THEN o.place ELSE @,
                                  !.pending = IF keep THEN ~o.ok ELSE @,
                                  !.inFlight = IF o.owner = "retry" THEN FALSE ELSE @,
                                  !.queued = IF corrects THEN NextPlace ELSE @]
        \* What the apply captured is read only here, so it is cleared after.
        h       == CASE o.owner = "start" ->
                          [host EXCEPT !.phase = IF corrects THEN "correcting" ELSE "members",
                                       !.started = StartedAtSurfaces, !.capWanted = FALSE, !.capSeq = 0]
                     [] o.owner = "correction" -> [host EXCEPT !.phase = "members"]
                     [] o.owner = "stop"       -> [host EXCEPT !.phase = "stopped"]
                     [] OTHER                  -> host
        oc      == IF o.fwd # NoFwd THEN OrchHandle(o.fwd) ELSE orch
        rest    == StampsRest(inbox, pq, d, h)
        L       == ({pq[i].place : i \in 1..Len(pq)} \cup {x.place : x \in d} \cup {rp.generation}) \ {0}
    IN /\ platQ' = [i \in 1..Len(pq) |-> [pq[i] EXCEPT !.place = RankOf(@, L)]]
       /\ done' = {[x EXCEPT !.place = RankOf(@, L)] : x \in d}
       /\ repair' = [rp EXCEPT !.generation = RankOf(@, L), !.queued = Cardinality(L)]
       /\ host' = IF rest THEN RestStamps(h) ELSE h
       /\ orch' = IF rest THEN [oc EXCEPT !.seq = 0] ELSE oc
       /\ stamp' = IF rest THEN 0 ELSE stamp
       /\ ghost' = [ghost EXCEPT !.staleApply = @ \/ (corrects /\ corrOp = "apply")]
       /\ UNCHANGED <<store, budget, lc, wakeTask, monQ, pendingCb, liveSubs, sess, mon, inbox, lastPub,
                      files, helperUp>>

\* RuntimeHost.retrySplitDNSEntryFiles once the helper check sees it answering.
Retry ==
    /\ repair.pending /\ helperUp /\ ~repair.inFlight
    /\ host.phase \in {"stopped", "running"}
    /\ platQ' = Append(platQ, Op(IF host.started /\ Wanted(host.gate) THEN "apply" ELSE "remove", "retry", NoFwd))
    /\ repair' = [repair EXCEPT !.inFlight = TRUE, !.queued = NextPlace]
    /\ UNCHANGED <<store, budget, monVars, host, done, files, helperUp, orchVars, ghost>>

\* The sweep task finishes its passes.
SweepsDone ==
    /\ orch.sweeps = "running"
    /\ orch' = [orch EXCEPT !.sweeps = "idle"]
    /\ UNCHANGED <<store, budget, monVars, hostVars, ghost>>

\* handleSystemWake: a reachable upstream ends a stale flap, only while the monitor can read.
WakeSeesStore == ~orch.blind
SystemWake ==
    /\ budget.wakes > 0 /\ host.started /\ orch.definite = "reasserting" /\ WakeSeesStore
    /\ budget' = [budget EXCEPT !.wakes = @ - 1]
    /\ orch' = [orch EXCEPT !.definite = "connected", !.sweeps = "running"]
    /\ ghost' = [ghost EXCEPT !.blindRecover = ghost.blindRecover \/ orch.blind]
    /\ UNCHANGED <<store, monVars, hostVars>>

-----------------------------------------------------------------------------

\* A report is still on its way to the orchestrator: its delivery task has not run, or waits
\* for the entry-file work it queued.
ReportsInFlight ==
    \/ inbox # {}
    \/ \E i \in 1..Len(platQ) : platQ[i].fwd # NoFwd
    \/ \E o \in done : o.fwd # NoFwd

Quiet == /\ monQ = <<>> /\ mon.pc = "idle" /\ inbox = {} /\ platQ = <<>> /\ done = {}
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
    /\ stamp = 0 /\ inbox = {} /\ lastPub = "unknown"
    /\ host = [phase |-> "stopped", started |-> FALSE, gate |-> "unknown", gateSeq |-> 0,
               capWanted |-> FALSE, capSeq |-> 0, starts |-> 0]
    /\ platQ = <<>> /\ done = {} /\ files = FALSE /\ helperUp = TRUE
    /\ repair = [pending |-> FALSE, inFlight |-> FALSE, generation |-> 0, queued |-> 0]
    /\ orch = [definite |-> "none", blind |-> FALSE, sweeps |-> "idle", seq |-> 0, last |-> "unknown"]
    /\ ghost = [late |-> FALSE, fresh |-> FALSE, blindRecover |-> FALSE, staleApply |-> FALSE,
                orchEarly |-> FALSE]

HostTakesReport == \E r \in inbox : HostDeliver(r)
HostRecords == \E o \in done : RecordOutcome(o)

MonitorNext == MonStep \/ Enter \/ VerdictCheck \/ Call \/ WakeFire \/ CallbackRestart
HostNext == HostTakesReport \/ HostRecords \/ HStartBegin \/ HStartObservers
            \/ (\E f \in BOOLEAN : HStopBegin(f)) \/ PlatformRun \/ Retry
OrchNext == SweepsDone \/ SystemWake
EnvNext == VPNConnect \/ (\E t \in Tunnels : TunnelDrop(t) \/ SilentChange(t))
           \/ StoreBreak \/ StoreHeal \/ AgeLoss \/ HelperDown \/ HelperUp

Next == MonitorNext \/ HostNext \/ OrchNext \/ EnvNext \/ Done

\* Each piece of code that has work runs: the monitor queue, every delivery task, every task
\* waiting on platformWork, and the queue itself. Time passes; the helper and the VPN client
\* come back. Startup progresses: a Start whose surfaces are applied goes on to start its
\* observers (`HStartObservers`), which assumes the DNS and tunnel member starts return.
\* Nothing forces the store to heal, a Start, or a Stop.
Fairness ==
    /\ WF_vars(MonStep) /\ WF_vars(Enter) /\ WF_vars(VerdictCheck) /\ WF_vars(Call) /\ WF_vars(WakeFire)
    /\ WF_vars(HostTakesReport) /\ WF_vars(HostRecords) /\ WF_vars(HStartObservers)
    /\ WF_vars(PlatformRun) /\ WF_vars(Retry) /\ WF_vars(SweepsDone)
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
HostQuiet == /\ inbox = {} /\ platQ = <<>> /\ done = {} /\ ~repair.pending /\ ~repair.inFlight
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
GateFollowsLastPublished == inbox = {} => host.gate = lastPub

\* S3. After stop returns, nothing of that session is published: no event, no verdict.
\* Harm: an obsolete verdict turns the retained gate and writes entry files.
NothingPublishedAfterStop == ~ghost.late

\* S4. A wake never ends a flap the monitor cannot see. Harm: VPNReactionHistory.recoverFlap's assert.
WakeRecoversOnlyWhenSeeing == ~ghost.blindRecover

\* S5. A definite connected or disconnected verdict the orchestrator can see never leaves the
\* stranded-socket sweeps held. Harm: clients stall on sockets whose path is gone.
SweepsNotHeldWhenDefinite ==
    (~orch.blind /\ orch.definite \in {"connected", "disconnected"}) => orch.sweeps # "held"

\* S6. The orchestrator hears of a report only after the entry-file work that report's gate
\* turn queued has run (r2 acceptance: entry files land before the orchestrator hears of the
\* VPN change). Harm: its reprobe and sweeps act on a network whose resolvers are not yet there.
OrchestratorAfterEntryFiles == ~ghost.orchEarly

\* S7. Once no report is on its way, the verdict the orchestrator applied last is the one the
\* monitor published last (#155). Harm: routing and the sweeps follow an older tunnel state.
OrchestratorFollowsLastPublished ==
    (WithOrchestrator /\ ~ReportsInFlight) => orch.last = lastPub

\* K1 (known gap, U4). No entry-file write is decided while the monitor is stopped, from
\* a verdict a stopped session left. Today a Start's apply, and its correction, read that
\* gate. Harm: if the VPN dropped while the proxy was stopped, the files go back against
\* servers no route reaches. The removal waits for the Start to reach startObservers, then
\* for the new session's reading, its delivery and the platform queue.
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
