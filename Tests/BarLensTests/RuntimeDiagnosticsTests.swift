import XCTest
import DividerIPC
@testable import BarLens

final class AgentRestartPolicyTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000)

    func testBriefSuccessDoesNotResetCrashLoopBackoff() {
        var policy = AgentRestartPolicy()
        var now = origin
        for expectedDelay in [2.0, 4, 8, 16, 32, 60, 60] {
            let delay = policy.recordFailure(at: now)
            XCTAssertEqual(delay, expectedDelay)
            XCTAssertFalse(policy.canAttempt(at: now.addingTimeInterval(delay - 0.01)))
            now = now.addingTimeInterval(delay)
            XCTAssertTrue(policy.canAttempt(at: now))
            policy.didLaunch()
            policy.noteHealthy(at: now)
            policy.noteHealthy(at: now.addingTimeInterval(2))
            now = now.addingTimeInterval(3)
        }
        XCTAssertEqual(policy.consecutiveFailures, 7)
    }

    func testOnlySustainedAcknowledgementsResetFailureStreak() {
        var policy = AgentRestartPolicy()
        policy.recordFailure(at: origin)
        policy.didLaunch()
        for elapsed in stride(from: 0, through: 28, by: 2) {
            policy.noteHealthy(at: origin.addingTimeInterval(Double(elapsed)))
        }
        XCTAssertEqual(policy.consecutiveFailures, 1)
        policy.noteHealthy(at: origin.addingTimeInterval(30))
        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertEqual(policy.recordFailure(at: origin.addingTimeInterval(31)), 2)
    }

    func testMissingAcknowledgementBreaksHealthyIntervalAndManualRetryBypassesDelay() {
        var policy = AgentRestartPolicy()
        policy.recordFailure(at: origin)
        policy.didLaunch()
        policy.noteHealthy(at: origin)
        policy.noteHealthy(at: origin.addingTimeInterval(31))
        XCTAssertEqual(policy.consecutiveFailures, 1)
        policy.recordFailure(at: origin.addingTimeInterval(32))
        XCTAssertFalse(policy.canAttempt(at: origin.addingTimeInterval(32)))
        policy.reset()
        XCTAssertTrue(policy.canAttempt(at: origin.addingTimeInterval(32)))
        XCTAssertEqual(policy.consecutiveFailures, 0)
    }
}

final class DiagnosticLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testRotationIsBoundedAndRetainsNewestEvents() throws {
        let log = DiagnosticLog(source: .app, directory: directory, maximumBytes: 512)
        for index in 0..<20 {
            log.record(event: "recovery.\(index)", details: ["cause": "wake"],
                       at: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 512) }
        let events = DiagnosticLog.recentEvents(directory: directory)
        XCTAssertEqual(events.last?.event, "recovery.19")
        XCTAssertFalse(events.contains { $0.event == "recovery.0" })
        XCTAssertTrue(DiagnosticLog.recentSummary(directory: directory).contains("cause=wake"))
    }

    func testReadsBothProcessesAndToleratesPartialFinalLine() throws {
        let app = DiagnosticLog(source: .app, directory: directory)
        let agent = DiagnosticLog(source: .agent, directory: directory)
        app.record(event: "wake", at: Date(timeIntervalSinceReferenceDate: 1))
        agent.record(event: "activation.succeeded", at: Date(timeIntervalSinceReferenceDate: 2))
        app.flush()
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("events-agent.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{unfinished".utf8))
        try handle.close()
        let events = DiagnosticLog.recentEvents(limit: 2, directory: directory)
        XCTAssertEqual(events.map(\.source), ["app", "agent"])
        XCTAssertEqual(events.map(\.event), ["wake", "activation.succeeded"])
    }

    func testOversizedMetadataAndCollidingTruncatedKeysCannotBreakLogging() throws {
        let log = DiagnosticLog(source: .app, directory: directory, maximumBytes: 512)
        let prefix = String(repeating: "x", count: 64)
        log.record(event: "test", details: [prefix + "a": String(repeating: "a", count: 400),
                                          prefix + "b": String(repeating: "b", count: 400),
                                          "another": String(repeating: "c", count: 400)])
        log.flush()
        XCTAssertEqual(DiagnosticLog.recentEvents(directory: directory).count, 1)
        let file = directory.appendingPathComponent("events-app.jsonl")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 512)
    }
}

final class AgentLauncherTests: XCTestCase {
    @MainActor
    func testPlannedReplacementReapsOldChildAndStopDoesNotLaunchAnother() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(source: .app, directory: directory)
        let launcher = AgentLauncher(executableURL: { URL(fileURLWithPath: "/bin/sleep") },
                                     arguments: ["30"], diagnostics: log)
        let replacement = expectation(description: "replacement launched")
        let stopped = expectation(description: "replacement stopped")
        var launchedPIDs: [Int32] = []
        var exits = 0
        launcher.onStarted = { pid in
            launchedPIDs.append(pid)
            if launchedPIDs.count == 2 { replacement.fulfill() }
        }
        launcher.onExit = { event in
            XCTAssertTrue(event.expected)
            XCTAssertNil(event.retryAt)
            exits += 1
            if exits == 2 { stopped.fulfill() }
        }
        launcher.start()
        launcher.restart()
        XCTAssertNil(launcher.processID, "The predecessor must not acknowledge the replacement recovery")
        launcher.restart()
        await fulfillment(of: [replacement], timeout: 3)
        XCTAssertEqual(launchedPIDs.count, 2)
        XCTAssertEqual(Set(launchedPIDs).count, 2)
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(launcher.consecutiveFailures, 0)
        launcher.stop()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertFalse(launcher.isRunning)
        XCTAssertEqual(launchedPIDs.count, 2)
        log.flush()
    }

    @MainActor
    func testRealChildExitReportsStatusAndCannotBypassBackoffWithRepeatedStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(source: .app, directory: directory)
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let launcher = AgentLauncher(executableURL: { URL(fileURLWithPath: "/usr/bin/false") },
                                     now: { now }, diagnostics: log)
        var launches = 0
        var exits = 0
        let first = expectation(description: "first child exited")
        let second = expectation(description: "second child exited")
        launcher.onStarted = { _ in launches += 1 }
        launcher.onExit = { event in
            XCTAssertEqual(event.status, 1)
            XCTAssertFalse(event.expected)
            XCTAssertFalse(event.wasSignalled)
            XCTAssertNotNil(event.retryAt)
            exits += 1
            if exits == 1 { first.fulfill() } else { second.fulfill() }
        }
        launcher.start()
        launcher.start()
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(launcher.consecutiveFailures, 1)
        XCTAssertFalse(launcher.canStartNow)
        launcher.start()
        XCTAssertEqual(launches, 1)
        now = now.addingTimeInterval(2)
        launcher.start()
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(launcher.consecutiveFailures, 2)
        XCTAssertEqual(launcher.nextRetryAt, now.addingTimeInterval(4))
        launcher.stop()
        log.flush()
        let events = DiagnosticLog.recentEvents(directory: directory)
        XCTAssertEqual(events.filter { $0.event == "helper.exited" }.count, 2)
    }

    @MainActor
    func testMissingExecutableReportsFailureOncePerAttemptAndManualRetryResetsDelay() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(source: .app, directory: directory)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let launcher = AgentLauncher(executableURL: { nil }, now: { now }, diagnostics: log)
        var failures = 0
        launcher.onFailure = { _ in failures += 1 }
        launcher.start()
        launcher.start()
        XCTAssertEqual(failures, 1)
        XCTAssertNotNil(launcher.lastExitDescription)
        XCTAssertEqual(launcher.nextRetryAt, now.addingTimeInterval(2))
        launcher.restart(resetBackoff: true)
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(launcher.consecutiveFailures, 1)
        launcher.stop()
        log.flush()
    }
}
