// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// The Test DNS control: idle, one probe out, or the reading of the last one. A reading is one probe of one DNS run, not DNS health, so
/// a change in what the app shows of that run (its state, its error or its bound port) clears it, and a probe still out is dropped
/// with it: the host's own verdict is newer.
enum DNSTest: Equatable {
    case idle
    /// One probe out. Its answer is shown only while this is still the probe out.
    case testing(UUID)
    case finished(DNSTestResult, at: Date)

    var isTesting: Bool {
        if case .testing = self { true } else { false }
    }

    /// Whether a probe can say anything in this DNS run state. A warning or a failure is when the check matters most: system DNS may
    /// still point at port 53.
    static func probes(in state: ModuleRunState) -> Bool {
        switch state {
        case .running, .warning, .failed: true
        case .stopped, .starting: false
        }
    }
}

enum DNSTestResult: Equatable {
    /// The port replied to a DNS query. Any reply counts, so this says the listener serves, not that names resolve.
    case answered(ControlPort)
    /// Refused, a reply too short to be DNS, or no reply before the probe's timeout.
    case noAnswer(ControlPort)
    /// The host had no port to probe: the forwarder is configured on port 0 and none is bound.
    case noPort
    /// No settlement was read: the test was not sent, was refused, or its answer was lost.
    case noResult

    init(_ outcome: ControlOperationOutcome?) {
        switch outcome {
        case .completed(let completion)?:
            guard case .dnsLiveness(let probe) = completion.result else { self = .noResult; return }
            self = probe.answered ? .answered(probe.port) : .noAnswer(probe.port)
        case .failed(.effectFailed)?:
            self = .noPort
        default:
            self = .noResult
        }
    }

    var message: String {
        switch self {
        case .answered(let port): "127.0.0.1:\(port.rawValue) answered a DNS query"
        case .noAnswer(let port): "No DNS answer from 127.0.0.1:\(port.rawValue)"
        case .noPort: "Not tested: the DNS forwarder has no bound port"
        case .noResult: "Not tested: the test did not run, or its answer was lost"
        }
    }
}
