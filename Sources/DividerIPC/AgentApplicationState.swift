import Foundation

/// Pure state machine for asynchronous activation. Only a successful reply
/// counts as applied; failed requests retry, and superseded replies are ignored.
public struct AgentApplicationState {
    public enum Action {
        case none
        case deactivate
        case apply(AgentCommand, token: UUID)
    }

    private struct Configuration: Equatable {
        var allowed: [String]
        var hidden: [Int]
        init(_ command: AgentCommand) {
            allowed = command.allowed
            hidden = command.hiddenSystemItems
        }
    }
    private var applied: Configuration?
    private var pending: (token: UUID, configuration: Configuration, startedAt: Date)?
    private var desired: AgentCommand?
    private var retryAt = Date.distantPast
    private var failures = 0
    public private(set) var error: String?
    public private(set) var acknowledgedRequestID = ""

    public init() {}
    public var isApplying: Bool { pending != nil }

    public func activationTimedOut(now: Date) -> Bool {
        pending.map { now.timeIntervalSince($0.startedAt) >= 5 } ?? false
    }

    public mutating func update(_ command: AgentCommand, now: Date) -> Action {
        let previous = desired
        desired = command
        guard command.mode == .apply else {
            let needsDeactivate = pending != nil || applied != nil
            pending = nil
            applied = nil
            error = nil
            failures = 0
            retryAt = .distantPast
            acknowledgedRequestID = command.requestID
            return needsDeactivate ? .deactivate : .none
        }
        let configuration = Configuration(command)
        if previous?.mode != .apply || previous.map(Configuration.init) != configuration {
            // New user intent should not sit behind a previous request's retry.
            // Even if it returns to the old applied value, issue a replacement
            // so the wrapper invalidates the superseded in-flight assertion.
            if pending != nil { applied = nil }
            pending = nil
            retryAt = .distantPast
            failures = 0
            error = nil
        }
        if applied == configuration, pending == nil {
            acknowledgedRequestID = command.requestID
            return .none
        }
        guard pending == nil, now >= retryAt else { return .none }
        let token = UUID()
        pending = (token, configuration, now)
        return .apply(command, token: token)
    }

    @discardableResult
    public mutating func complete(token: UUID, error message: String?, now: Date) -> Bool {
        guard let pending, pending.token == token else { return false }
        self.pending = nil
        if let message {
            error = message
            failures += 1
            retryAt = now.addingTimeInterval(min(8, pow(2, Double(min(failures - 1, 3)))))
        } else {
            applied = pending.configuration
            acknowledgedRequestID = desired?.requestID ?? ""
            error = nil
            failures = 0
            retryAt = .distantPast
        }
        return true
    }
}
