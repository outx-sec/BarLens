import XCTest
import DividerIPC

final class AgentRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    private func command(_ allowed: [String] = ["one"], mode: AgentCommand.Mode = .apply,
                         hidden: [Int] = []) -> AgentCommand {
        AgentCommand(mode: mode, allowed: allowed, hiddenSystemItems: hidden,
                     updatedAt: now, sessionID: "test")
    }

    private func token(_ action: AgentApplicationState.Action,
                       file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        guard case .apply(_, let token) = action else {
            XCTFail("Expected a fresh activation", file: file, line: line)
            throw NSError(domain: "test", code: 1)
        }
        return token
    }

    func testFailedActivationRetriesIdenticalCommandAndOnlySuccessAcknowledgesIt() throws {
        var state = AgentApplicationState()
        let request = command()
        let first = try token(state.update(request, now: now))
        XCTAssertTrue(state.isApplying)
        XCTAssertEqual(state.acknowledgedRequestID, "")
        XCTAssertTrue(state.complete(token: first, error: "connection lost", now: now))
        XCTAssertEqual(state.acknowledgedRequestID, "")
        guard case .none = state.update(request, now: now.addingTimeInterval(0.5)) else {
            return XCTFail("Retry should be delayed")
        }
        let retry = try token(state.update(request, now: now.addingTimeInterval(1)))
        XCTAssertNotEqual(first, retry)
        XCTAssertTrue(state.complete(token: retry, error: nil, now: now.addingTimeInterval(1)))
        XCTAssertNil(state.error)
        XCTAssertEqual(state.acknowledgedRequestID, request.requestID)
    }

    func testSuspendCancelsPendingAndIgnoresLateSuccess() throws {
        var state = AgentApplicationState()
        let pending = try token(state.update(command(), now: now))
        let suspend = command(mode: .suspend)
        guard case .deactivate = state.update(suspend, now: now) else {
            return XCTFail("Suspend must invalidate in-flight activation")
        }
        XCTAssertFalse(state.complete(token: pending, error: nil, now: now))
        XCTAssertFalse(state.isApplying)
        XCTAssertEqual(state.acknowledgedRequestID, suspend.requestID)
        _ = try token(state.update(command(), now: now))
    }

    func testReturningToAppliedConfigurationStillCancelsSupersededActivation() throws {
        var state = AgentApplicationState()
        let original = command(["A"])
        let first = try token(state.update(original, now: now))
        state.complete(token: first, error: nil, now: now)
        let superseded = try token(state.update(command(["B"]), now: now))
        let replacement = try token(state.update(original, now: now))
        XCTAssertFalse(state.complete(token: superseded, error: nil, now: now))
        XCTAssertTrue(state.complete(token: replacement, error: nil, now: now))
        XCTAssertEqual(state.acknowledgedRequestID, original.requestID)
    }

    func testSystemOnlyChangeActivatesButHeartbeatDoesNot() throws {
        var state = AgentApplicationState()
        var request = command(hidden: [1])
        let first = try token(state.update(request, now: now))
        state.complete(token: first, error: nil, now: now)
        request.updatedAt = now.addingTimeInterval(2)
        guard case .none = state.update(request, now: request.updatedAt) else {
            return XCTFail("Heartbeat must not churn assertions")
        }
        _ = try token(state.update(command(hidden: [2]), now: now))
    }

    func testHungActivationHasDeadlineAndFreshHelperReappliesSameRequest() throws {
        let request = command()
        var old = AgentApplicationState()
        _ = try token(old.update(request, now: now))
        XCTAssertFalse(old.activationTimedOut(now: now.addingTimeInterval(4.9)))
        XCTAssertTrue(old.activationTimedOut(now: now.addingTimeInterval(5)))
        var restarted = AgentApplicationState()
        _ = try token(restarted.update(request, now: now.addingTimeInterval(6)))
    }

    func testReplyMustMatchLiveProcessSessionAndFreshTimestamp() {
        let status = AgentStatus(sessionID: "current", processID: 123,
                                 requestID: "request", isApplying: false, updatedAt: now)
        XCTAssertTrue(status.isCurrent(sessionID: "current", processID: 123, now: now))
        XCTAssertFalse(status.isCurrent(sessionID: "old", processID: 123, now: now))
        XCTAssertFalse(status.isCurrent(sessionID: "current", processID: 124, now: now))
        XCTAssertFalse(status.isCurrent(sessionID: "current", processID: 123,
                                        now: now.addingTimeInterval(11)))
    }

    func testLegacyCommandDecodesWithoutReplyIdentifiers() throws {
        let data = Data(#"{"mode":"suspend","allowed":[],"updatedAt":1000}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentCommand.self, from: data)
        XCTAssertEqual(decoded.hiddenSystemItems, [])
        XCTAssertEqual(decoded.sessionID, "")
        XCTAssertEqual(decoded.requestID, "legacy")
    }
}
