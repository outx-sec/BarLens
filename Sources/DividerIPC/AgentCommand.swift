import Foundation

/// The channel between the UI app and the agent that holds the MenuBarAgent
/// assertion.
///
/// They are separate processes for one measured reason: an app that holds the
/// visibility restriction stops having its *own* status items drawn, even when
/// its bundle identifier is in the allow list. The dividers are status items,
/// so the process drawing them must not be the process asserting.
///
/// A file rather than XPC: the payload is a list of strings, the two processes
/// are the same user with the same file permissions, and the failure mode we
/// care about — the UI app going away — is exactly what a stale timestamp
/// detects. No connection to set up, and `cat` is the debugger.
public struct AgentCommand: Codable {

    public enum Mode: String, Codable {
        /// Hold the restriction with `allowed`.
        case apply
        /// Drop the restriction, stay alive. Used while the UI app measures.
        case suspend
        /// Drop the restriction and exit.
        case stop
    }

    public var mode: Mode
    public var allowed: [String]

    /// `MBSystemItemIdentifier` raw values to suppress — Wi-Fi, battery, clock,
    /// Control Center and friends all live behind one of these.
    ///
    /// A black list, unlike `allowed`. The caller cannot enumerate the enum, so
    /// a value it has never heard of has to default to visible; a white list
    /// would hide every built-in item the moment the user hid one. Empty means
    /// "hide none", which is what an untouched install wants.
    ///
    /// Decoded leniently: a command file written before this replaced
    /// `allowedSystemItems` has no such key, and the synthesized decoder would
    /// throw on a non-optional. See `init(from:)`.
    public var hiddenSystemItems: [Int]

    public var updatedAt: Date
    /// A new UI launch must not accept a reply left by an earlier process.
    public var sessionID: String
    /// Preserved by heartbeat writes; identifies the requested configuration.
    public var requestID: String

    public init(mode: Mode,
                allowed: [String],
                hiddenSystemItems: [Int] = [],
                updatedAt: Date = Date(),
                sessionID: String = "",
                requestID: String = UUID().uuidString) {
        self.mode = mode
        self.allowed = allowed
        self.hiddenSystemItems = hiddenSystemItems
        self.updatedAt = updatedAt
        self.sessionID = sessionID
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case mode, allowed, hiddenSystemItems, updatedAt, sessionID, requestID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        allowed = try container.decode([String].self, forKey: .allowed)
        hiddenSystemItems = try container.decodeIfPresent([Int].self,
                                                          forKey: .hiddenSystemItems) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? "legacy"
    }

    // MARK: - Transport

    /// How often the UI app rewrites the file just to refresh `updatedAt`.
    public static let heartbeatInterval: TimeInterval = 2.0

    /// How long the agent waits before deciding the UI app is gone. Generous
    /// enough to survive a slow frame, short enough that a crash does not leave
    /// icons hidden for long.
    public static let stalenessTimeout: TimeInterval = 10.0

    public var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > Self.stalenessTimeout
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BarLens", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("agent-command.json")
    }

    public struct FileStamp: Equatable {
        public let inode: UInt64
        public let seconds: Int
        public let nanoseconds: Int
        public let size: Int64
    }

    public static func fileStamp(at url: URL = fileURL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(inode: UInt64(info.st_ino),
                         seconds: info.st_mtimespec.tv_sec,
                         nanoseconds: info.st_mtimespec.tv_nsec,
                         size: Int64(info.st_size))
    }

    public static func ensureSecureDirectory(_ dir: URL = directory) throws {
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(dir.path, 0o700)
    }

    /// Removes orphaned `.sb-*` temporary files left behind if a process was
    /// killed mid-atomic write.
    public static func cleanupStaleTempFiles(in dir: URL = directory) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.lastPathComponent.contains(".sb-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func write() throws {
        try Self.ensureSecureDirectory()
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL, options: .atomic)
        _ = chmod(Self.fileURL.path, 0o600)
    }

    public static func read() -> AgentCommand? {
        guard fileStamp(at: fileURL) != nil,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AgentCommand.self, from: data)
    }
}
