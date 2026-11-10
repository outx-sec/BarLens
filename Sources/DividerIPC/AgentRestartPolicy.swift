import Foundation

/// A successful launch is not proof of recovery: the helper may crash seconds
/// later. Only sustained successful acknowledgements reset the failure streak.
public struct AgentRestartPolicy {
    public private(set) var consecutiveFailures = 0
    public private(set) var nextRetryAt: Date?
    private var healthySince: Date?
    private var lastHealthyAt: Date?

    public static let stableInterval: TimeInterval = 30

    public init() {}

    public func canAttempt(at now: Date) -> Bool {
        nextRetryAt.map { now >= $0 } ?? true
    }

    /// A new process must establish its own uninterrupted healthy interval.
    public mutating func didLaunch() {
        nextRetryAt = nil
        healthySince = nil
        lastHealthyAt = nil
    }

    @discardableResult
    public mutating func recordFailure(at now: Date) -> TimeInterval {
        consecutiveFailures = min(consecutiveFailures + 1, 32)
        let delay = min(60, 2 * pow(2, Double(min(consecutiveFailures - 1, 5))))
        nextRetryAt = now.addingTimeInterval(delay)
        healthySince = nil
        lastHealthyAt = nil
        return delay
    }

    public mutating func noteHealthy(at now: Date) {
        // A missing acknowledgement or clock discontinuity breaks the streak.
        if let lastHealthyAt,
           now < lastHealthyAt || now.timeIntervalSince(lastHealthyAt) > AgentCommand.stalenessTimeout {
            healthySince = nil
        }
        if healthySince == nil { healthySince = now }
        lastHealthyAt = now
        if let healthySince, now.timeIntervalSince(healthySince) >= Self.stableInterval {
            consecutiveFailures = 0
            nextRetryAt = nil
        }
    }

    /// A user explicitly requesting a retry may bypass the remaining delay.
    public mutating func reset() {
        self = AgentRestartPolicy()
    }
}
