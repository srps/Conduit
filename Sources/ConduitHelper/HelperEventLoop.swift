// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ConduitShared
import HelperSupport

/// One thread. The caller sets `SIGTERM` and `SIGINT` to `SIG_IGN`; kqueue still records them.
final class HelperEventLoop {
    enum Event: Equatable {
        case connection
        case ownerExited(pid_t)
        case storeChanged
        case tick
        case signal(Int32)
        case failed(String)
    }

    private let queue: Int32
    private var watched: pid_t?
    private var nextTick: UInt64?
    private var pending: [Event] = []
    private static let batch = 8

    init(listenFD: Int32) {
        queue = kqueue()
        guard queue >= 0 else {
            HelperLog.error("kqueue failed: \(Self.errnoText)")
            exit(EXIT_FAILURE)
        }
        var changes = [
            kevent(ident: UInt(listenFD), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGINT), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: Self.storeIdent, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil),
        ]
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0 else {
            HelperLog.error("kevent registration failed: \(Self.errnoText)")
            exit(EXIT_FAILURE)
        }
    }

    func next(tickDue: Bool) -> Event {
        if !tickDue {
            nextTick = nil
        } else if nextTick == nil {
            nextTick = HelperLineIO.now() + Self.tickNanoseconds
        }
        while true {
            while !pending.isEmpty {
                let event = pending.removeFirst()
                if case .ownerExited(let pid) = event {
                    guard pid == watched else { continue }
                    watched = nil
                }
                return event
            }
            let now = HelperLineIO.now()
            if let due = nextTick, now >= due {
                nextTick = now + Self.tickNanoseconds
                return .tick
            }
            var events = [Darwin.kevent](repeating: Darwin.kevent(), count: Self.batch)
            let count: Int32
            if let due = nextTick {
                let remaining = due - now
                var limit = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
                count = kevent(queue, nil, 0, &events, Int32(Self.batch), &limit)
            } else {
                count = kevent(queue, nil, 0, &events, Int32(Self.batch), nil)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .failed("kevent: \(Self.errnoText)")
            }
            pending = Self.ordered(events.prefix(Int(count)))
        }
    }

    /// Signals first, so stopping never waits behind a backlog; then owner exits; then the store; then one connection.
    private static func ordered(_ events: ArraySlice<Darwin.kevent>) -> [Event] {
        var signals: [Event] = []
        var exits: [Event] = []
        var store = false
        var connection = false
        for event in events {
            switch Int32(event.filter) {
            case EVFILT_SIGNAL: signals.append(.signal(Int32(event.ident)))
            case EVFILT_PROC: exits.append(.ownerExited(pid_t(event.ident)))
            case EVFILT_USER: store = true
            case EVFILT_READ: connection = true
            default: break
            }
        }
        return signals + exits + (store ? [.storeChanged] : []) + (connection ? [.connection] : [])
    }

    private static let storeIdent: UInt = 1

    /// Safe from any thread: a store notification wakes the loop, and repeats before it runs are one event.
    var storeTrigger: @Sendable () -> Void {
        let queue = self.queue
        return {
            var change = kevent(
                ident: HelperEventLoop.storeIdent, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER),
                data: 0, udata: nil
            )
            _ = kevent(queue, &change, 1, nil, 0, nil)
        }
    }

    enum Watch: Equatable {
        case watching
        case gone
        case failed(String)
    }

    /// Moves the one `NOTE_EXIT` watch to `pid`. A pid reused after `ESRCH` cannot matter: the watch is registered only
    /// while the owner is alive. Nothing is watched after `gone` or `failed`.
    @discardableResult
    func watchOwner(_ pid: pid_t?) -> Watch {
        guard pid != watched else { return .watching }
        if let previous = watched {
            var change = kevent(ident: UInt(previous), filter: Int16(EVFILT_PROC), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
            if kevent(queue, &change, 1, nil, 0, nil) != 0, errno != ESRCH, errno != ENOENT {
                HelperLog.warning("vpn-dns-override: could not stop watching pid=\(previous): \(Self.errnoText)")
            }
            watched = nil
        }
        guard let pid else { return .watching }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            return errno == ESRCH ? .gone : .failed(Self.errnoText)
        }
        watched = pid
        return .watching
    }

    private static let tickNanoseconds = UInt64(VPNDNSOverridePublisher.tickSeconds) * 1_000_000_000

    private static var errnoText: String { String(cString: strerror(errno)) }
}
