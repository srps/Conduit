// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The process quit's one reserved draft flush (decision 0015). The quit latches first, so nothing else is admitted; this window admits
/// exactly one all-save-only private update, through the same custody, store and exact baselines, until the quit's total deadline. It
/// applies nothing and writes no disable. The quit waits for the flush it admitted, or for the deadline, whichever comes first; a write
/// already started still completes, and the quit's join of store work covers it. Nothing retries.
@MainActor
final class RuntimeQuitFlush {
    private enum State {
        case open
        case admitted
        case closed
    }

    private var state = State.open
    private var waiter: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Opens the window until `deadline`. A deadline already past closes it at once.
    init(until deadline: ContinuousClock.Instant) {
        guard deadline > ContinuousClock.now else {
            state = .closed
            return
        }
        timer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self?.expire()
        }
    }

    /// Admits the one flush, if the window is still open.
    func admit() -> Bool {
        guard case .open = state else { return false }
        state = .admitted
        return true
    }

    /// The admitted flush ended, whatever it wrote.
    func finish() {
        close()
    }

    /// Returns once the window has closed: the admitted flush ended, or the deadline passed.
    func closed() async {
        guard waiter == nil else { preconditionFailure("the host runs a single quit") }
        if case .closed = state { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// The deadline: an open window closes, so nothing more is admitted. An admitted flush may still be writing; the quit stops waiting
    /// for it here, and its join of store work covers a write already started.
    private func expire() {
        close()
    }

    private func close() {
        state = .closed
        timer?.cancel()
        timer = nil
        waiter?.resume()
        waiter = nil
    }
}
