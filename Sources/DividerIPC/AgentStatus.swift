import Foundation

/// A reply confirms that the helper is alive and that the private API answered.
/// The process ID and session prevent a previous helper's reply looking healthy.
public struct AgentStatus: Codable {
    public var sessionID: String
    public var processID: Int32
    public var requestID: String
    public var isApplying: Bool
    public var error: String?
    public var updatedAt: Date

    public init(sessionID: String, processID: Int32, requestID: String,
                isApplying: Bool, error: String? = nil, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.processID = processID
        self.requestID = requestID
        self.isApplying = isApplying
        self.error = error
        self.updatedAt = updatedAt
    }

    public func isCurrent(sessionID: String, processID: Int32, now: Date = Date()) -> Bool {
        self.sessionID == sessionID && self.processID == processID
            && abs(now.timeIntervalSince(updatedAt)) < AgentCommand.stalenessTimeout
    }

    public static var fileURL: URL {
        AgentCommand.directory.appendingPathComponent("agent-status.json")
    }

    public func write() throws {
        try AgentCommand.ensureSecureDirectory()
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
        _ = chmod(Self.fileURL.path, 0o600)
    }

    public static func read() -> AgentStatus? {
        guard AgentCommand.fileStamp(at: fileURL) != nil,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
