import Foundation
import os

public struct DiagnosticEvent: Codable {
    public let timestamp: Date
    public let source: String
    public let processID: Int32
    public let event: String
    public let details: [String: String]
}

/// Low-volume lifecycle events, never heartbeat or application-list payloads.
/// App and helper use separate files, so their writes and rotations cannot race.
public final class DiagnosticLog: @unchecked Sendable {
    public enum Source: String, CaseIterable {
        case app, agent
    }

    public static var directory: URL {
        AgentCommand.directory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private let source: Source
    private let folder: URL
    private let maximumBytes: Int
    private let queue: DispatchQueue
    private let logger: Logger
    private static let writerQueue = DispatchQueue(label: "BarLens.diagnostics")

    public init(source: Source, directory: URL = DiagnosticLog.directory,
                maximumBytes: Int = 64 * 1024) {
        self.source = source
        folder = directory
        self.maximumBytes = max(512, maximumBytes)
        queue = Self.writerQueue
        logger = Logger(subsystem: "com.barlens.app", category: source.rawValue)
    }

    /// `details` must contain diagnostic metadata only: reason codes, request
    /// IDs, process IDs, elapsed times and counts. Do not pass app names, bundle
    /// allow lists, AX text, paths, or NSError.localizedDescription here.
    public func record(event: String, details: [String: String] = [:], at date: Date = Date()) {
        let safeDetails = details.sorted { $0.key < $1.key }.prefix(12)
            .reduce(into: [String: String]()) { values, entry in
                values[String(entry.key.prefix(64))] = String(entry.value.prefix(160))
            }
        let entry = DiagnosticEvent(timestamp: date, source: source.rawValue,
                                    processID: ProcessInfo.processInfo.processIdentifier,
                                    event: String(event.prefix(80)), details: safeDetails)
        logger.info("\(entry.event, privacy: .public) \(String(describing: safeDetails), privacy: .public)")
        queue.async { [self] in
            do { try append(entry) }
            catch { logger.error("Diagnostic event could not be saved") }
        }
    }

    /// Intended for tests and controlled shutdown, not normal heartbeat paths.
    public func flush() { queue.sync {} }

    private func append(_ event: DiagnosticEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        // A tiny test limit or unusually verbose metadata must still remain
        // bounded. The event and timestamp survive even if details do not fit.
        if data.count + 1 > maximumBytes {
            data = try encoder.encode(DiagnosticEvent(timestamp: event.timestamp,
                                                      source: event.source,
                                                      processID: event.processID,
                                                      event: event.event,
                                                      details: ["metadata": "omitted: size limit"]))
        }
        if data.count + 1 > maximumBytes {
            data = try encoder.encode(DiagnosticEvent(timestamp: event.timestamp,
                                                      source: event.source,
                                                      processID: event.processID,
                                                      event: String(event.event.prefix(32)), details: [:]))
        }
        data.append(0x0a)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(folder.path, 0o700)
        let current = Self.fileURL(source, in: folder)
        let previous = Self.fileURL(source, in: folder, rotated: true)
        let size = ((try? FileManager.default.attributesOfItem(atPath: current.path)[.size]) as? NSNumber)?.intValue ?? 0
        if size + data.count > maximumBytes {
            if FileManager.default.fileExists(atPath: previous.path) {
                try FileManager.default.removeItem(at: previous)
            }
            if FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.moveItem(at: current, to: previous)
            }
        }
        if !FileManager.default.fileExists(atPath: current.path) {
            FileManager.default.createFile(atPath: current.path, contents: nil,
                                          attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func fileURL(_ source: Source, in directory: URL, rotated: Bool = false) -> URL {
        directory.appendingPathComponent("events-\(source.rawValue)\(rotated ? ".1" : "").jsonl")
    }

    public static func recentEvents(limit: Int = 80, directory: URL = DiagnosticLog.directory) -> [DiagnosticEvent] {
        guard limit > 0 else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var entries: [DiagnosticEvent] = []
        for source in Source.allCases {
            for rotated in [true, false] {
                guard let data = try? Data(contentsOf: fileURL(source, in: directory, rotated: rotated)) else { continue }
                // A concurrent final append may be incomplete; skip it and
                // keep the complete historical events available for copying.
                entries += data.split(separator: 0x0a).compactMap {
                    try? decoder.decode(DiagnosticEvent.self, from: Data($0))
                }
            }
        }
        return Array(entries.sorted { $0.timestamp < $1.timestamp }.suffix(limit))
    }

    public static func recentSummary(limit: Int = 80, directory: URL = DiagnosticLog.directory) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return recentEvents(limit: limit, directory: directory).map { entry in
            let details = entry.details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(formatter.string(from: entry.timestamp)) [\(entry.source):\(entry.processID)] \(entry.event) \(details)"
        }.joined(separator: "\n")
    }
}
