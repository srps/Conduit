// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// The process quit's one total deadline and its reserved draft flush (decision 0015). The quit latches first, so nothing else is admitted;
/// this window then admits each declared all-save-only private update once, the runtime and platform save and the preferences save, through
/// the same custody, store and exact baselines. It applies nothing and writes no disable. The window closes when every declared flush has
/// ended, or at the deadline, whichever comes first. Closing it revokes the flush's write claim in the workflow's intent, so a flush admitted
/// but not yet at its replacement writes nothing afterwards; a write already past its claim completes, and the quit's join of store work
/// covers it. Nothing retries.
///
/// The same deadline bounds the whole quit: `settled` answers whether the quit's work ended before it. A quit past its deadline is reported
/// as such while its work still runs and still owns the root, until it ends.
@MainActor
final class RuntimeQuitFlush {
    enum Part {
        case configuration
        case preferences
    }

    private let workflow: RuntimeConfigurationWorkflow
    /// The declared parts not yet ended. The window is open while this is not empty and the deadline has not passed.
    private var awaiting: Set<Part>
    private var admitted: Set<Part> = []
    private var open: Bool
    private var deadlinePassed = false
    /// Set once the quit's work ended: whether that was before the deadline.
    private var endedInTime: Bool?
    private var flushWaiter: CheckedContinuation<Void, Never>?
    private var settleWaiter: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    /// Opens the window for `flush` until `deadline`, in the latch's own turn. A deadline already past opens nothing and has passed.
    init(until deadline: ContinuousClock.Instant, admitting flush: ControlQuitFlush, workflow: RuntimeConfigurationWorkflow) {
        self.workflow = workflow
        var parts: Set<Part> = []
        if flush.configuration { parts.insert(.configuration) }
        if flush.preferences { parts.insert(.preferences) }
        awaiting = parts
        guard deadline > ContinuousClock.now else {
            open = false
            deadlinePassed = true
            return
        }
        open = !parts.isEmpty
        workflow.setQuitFlush(open: open)
        timer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self?.expire()
        }
    }

    /// Whether the window is open: declared flushes remain and the deadline has not passed.
    var isOpen: Bool { open }

    /// Admits the declared `part` once, while the window is open.
    func admit(_ part: Part) -> Bool {
        guard open, awaiting.contains(part), !admitted.contains(part) else { return false }
        admitted.insert(part)
        return true
    }

    /// An admitted flush ended, whatever it wrote. The window closes once every declared part has.
    func finish(_ part: Part) {
        awaiting.remove(part)
        if awaiting.isEmpty { close() }
    }

    /// Returns once the window has closed: every declared flush ended, or the deadline passed.
    func closed() async {
        guard flushWaiter == nil else { preconditionFailure("the host runs a single quit") }
        guard open else { return }
        await withCheckedContinuation { flushWaiter = $0 }
    }

    /// Whether the quit's work ended before the deadline. Returns at the first of the two.
    func settled() async -> Bool {
        guard settleWaiter == nil else { preconditionFailure("one operation reports the quit") }
        if let endedInTime { return endedInTime }
        if deadlinePassed { return false }
        return await withCheckedContinuation { settleWaiter = $0 }
    }

    /// The quit's work has ended: its teardown, the flush, the store join and the diagnostic flush.
    func quitDidEnd() {
        endedInTime = !deadlinePassed
        timer?.cancel()
        timer = nil
        settleWaiter?.resume(returning: !deadlinePassed)
        settleWaiter = nil
    }

    /// The deadline: an open window closes, so nothing more is admitted and an admitted flush's unstarted write is revoked. The quit stops
    /// waiting for the flush here, and its join of store work covers a write already started.
    private func expire() {
        deadlinePassed = true
        timer = nil
        close()
        guard endedInTime == nil else { return }
        settleWaiter?.resume(returning: false)
        settleWaiter = nil
    }

    private func close() {
        guard open else { return }
        open = false
        workflow.setQuitFlush(open: false)
        flushWaiter?.resume()
        flushWaiter = nil
    }
}
