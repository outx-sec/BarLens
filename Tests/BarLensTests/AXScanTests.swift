import XCTest
import ApplicationServices
@testable import BarLens

final class AXScanTests: XCTestCase {
    func testSweepDeadlineShrinksEachIndividualReadAndRejectsFurtherReads() throws {
        var monotonicTime: TimeInterval = 100
        let cancellation = AXScanCancellation()
        let reader = AXReadBudget(seconds: 1, cancellation: cancellation, now: { monotonicTime })
        XCTAssertEqual(reader.nextCallTimeout, 0.15, accuracy: 0.001)
        monotonicTime += 0.95
        XCTAssertEqual(reader.nextCallTimeout, 0.05, accuracy: 0.001)
        try reader.check()
        monotonicTime += 0.1
        XCTAssertThrowsError(try reader.check()) { error in
            XCTAssertEqual(error as? AXScanFailure, .timedOut)
        }
    }

    func testCancellationStopsReadsBeforeTheirDeadline() throws {
        let cancellation = AXScanCancellation()
        let reader = AXReadBudget(seconds: 30, cancellation: cancellation)
        try reader.check()
        cancellation.cancel()
        XCTAssertThrowsError(try reader.check()) { error in
            XCTAssertEqual(error as? AXScanFailure, .cancelled)
        }
    }

    func testSlowReadDoesNotBlockMainQueueAndCancelledResultCannotPublish() {
        let worker = AXScanWorker(label: "BarLens.tests.ax")
        let first = AXScanCancellation()
        let second = AXScanCancellation()
        let started = expectation(description: "Background read started")
        let mainResponsive = expectation(description: "Main queue remained responsive")
        let replacementFinished = expectation(description: "Replacement result delivered")
        let staleDelivered = expectation(description: "Cancelled result must not be delivered")
        staleDelivered.isInverted = true
        let release = DispatchSemaphore(value: 0)
        worker.perform(cancellation: first, work: {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            // Schedule the main-queue check only after the slow read starts;
            // cancellation must happen while that work is in flight.
            DispatchQueue.main.async {
                mainResponsive.fulfill()
                first.cancel()
                worker.perform(cancellation: second, work: { "current" }) { value in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(value, "current")
                    replacementFinished.fulfill()
                }
                release.signal()
            }
            _ = release.wait(timeout: .now() + 1)
            return "stale"
        }) { _ in staleDelivered.fulfill() }
        wait(for: [started, mainResponsive, replacementFinished, staleDelivered], timeout: 0.5)
    }

    func testHeadlessProcessesAreAbsentButKnownOwnersAndCommunicationFailuresAreNot() {
        for error in [AXError.noValue, .attributeUnsupported, .notImplemented] {
            XCTAssertTrue(ItemEnumerator.missingExtrasAreReliable(errorCode: error.rawValue,
                                                                 previouslyObserved: false))
            XCTAssertFalse(ItemEnumerator.missingExtrasAreReliable(errorCode: error.rawValue,
                                                                  previouslyObserved: true))
        }
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement] {
            XCTAssertFalse(ItemEnumerator.missingExtrasAreReliable(errorCode: error.rawValue,
                                                                  previouslyObserved: false))
        }
    }

    func testUnreadableUnknownRootIsUnobservedRatherThanAbsentOrFailed() {
        var results = ItemScanOwnerResults()
        results.record(owner: "headless", .unreadableRoot)
        let snapshot = results.result(allOwners: ["headless"], knownOwners: [])
        XCTAssertEqual(snapshot.unobservedOwners, ["headless"])
        XCTAssertTrue(snapshot.completedOwners.isEmpty)
        XCTAssertTrue(snapshot.failedOwners.isEmpty)
    }

    func testUnreadableKnownRootStillPreservesItsFailure() {
        var results = ItemScanOwnerResults()
        results.record(owner: "previous", .unreadableRoot)
        let snapshot = results.result(allOwners: ["previous"], knownOwners: ["previous"])
        XCTAssertEqual(snapshot.failedOwners, ["previous"])
        XCTAssertTrue(snapshot.completedOwners.isEmpty)
    }

    func testReadableSiblingTreeResolvesUnresponsiveRootWithSameBundle() {
        var results = ItemScanOwnerResults()
        results.record(owner: "shared", .unreadableRoot)
        results.record(owner: "shared", .complete([testItem("shared")]))
        let snapshot = results.result(allOwners: ["shared"], knownOwners: ["shared"])
        XCTAssertTrue(snapshot.failedOwners.isEmpty)
        XCTAssertTrue(snapshot.unobservedOwners.isEmpty)
        XCTAssertEqual(snapshot.completedOwners, ["shared"])
        XCTAssertEqual(snapshot.items.count, 1)
    }

    func testReadableSiblingDoesNotMaskFailedTreeOrGeometry() {
        var results = ItemScanOwnerResults()
        results.record(owner: "shared", .incompleteTree)
        results.record(owner: "shared", .complete([testItem("shared")]))
        let snapshot = results.result(allOwners: ["shared"], knownOwners: [])
        XCTAssertEqual(snapshot.failedOwners, ["shared"])
        XCTAssertTrue(snapshot.completedOwners.isEmpty)
        XCTAssertTrue(snapshot.items.isEmpty, "A partial bundle is not a reliable positional snapshot")
    }

    func testEmptySiblingCannotConfirmAbsenceWhileTheOwnerRootIsUnreadable() {
        var results = ItemScanOwnerResults()
        results.record(owner: "shared", .unreadableRoot)
        results.record(owner: "shared", .complete([]))
        let known = results.result(allOwners: ["shared"], knownOwners: ["shared"])
        XCTAssertEqual(known.failedOwners, ["shared"])
        XCTAssertTrue(known.completedOwners.isEmpty)
        let unknown = results.result(allOwners: ["shared"], knownOwners: [])
        XCTAssertEqual(unknown.unobservedOwners, ["shared"])
        XCTAssertTrue(unknown.completedOwners.isEmpty)
    }

    func testAbsentSiblingDoesNotTurnUnreadableRootIntoConfirmedAbsence() {
        var results = ItemScanOwnerResults()
        results.record(owner: "shared", .absent)
        results.record(owner: "shared", .unreadableRoot)
        let snapshot = results.result(allOwners: ["shared", "not-reached"], knownOwners: [])
        XCTAssertEqual(snapshot.unobservedOwners, ["shared"])
        XCTAssertEqual(snapshot.failedOwners, ["not-reached"], "Budget exhaustion must remain a failure")
        XCTAssertTrue(snapshot.completedOwners.isEmpty)
    }

    func testOptionalMetadataFailureDoesNotHideItemButCancellationAndDeadlinePropagate() throws {
        XCTAssertNil(try AXReadBudget.optionalMetadata { throw AXScanFailure.readFailed(-25200) })
        for failure in [AXScanFailure.cancelled, .timedOut] {
            XCTAssertThrowsError(try AXReadBudget.optionalMetadata { throw failure }) { error in
                XCTAssertEqual(error as? AXScanFailure, failure)
            }
        }
    }

    private func testItem(_ owner: String) -> MenuBarItem {
        MenuBarItem(ownerBundleID: owner, ownerPID: 1,
                    frame: CGRect(x: 100, y: 0, width: 20, height: 20),
                    display: DisplayID(rawValue: 1, localizedName: "Test"),
                    axIdentifier: nil, label: nil, indexInApp: 0)
    }

    func testEmptyFailureIsDifferentFromCompletedEmptySnapshot() {
        let complete = ItemScanResult(completedOwners: ["example.app"])
        XCTAssertTrue(complete.isComplete)
        let unreadable = ItemScanResult(failedOwners: ["example.app"])
        XCTAssertFalse(unreadable.isComplete)
        XCTAssertNotNil(unreadable.failureDescription)
        let unavailable = ItemScanResult(permissionGranted: false)
        XCTAssertFalse(unavailable.isComplete)
    }

    func testDisplayMatchingRejectsOffScreenParkedItemsAndMatchesMenuBarBand() {
        let main = DisplayID(rawValue: 1, localizedName: "Main")
        let external = DisplayID(rawValue: 2, localizedName: "Right")
        let screens: [(DisplayID, CGRect)] = [
            (main, CGRect(x: 0, y: 0, width: 1512, height: 982)),
            (external, CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
        ]
        let parkedOffScreen = CGRect(x: -300, y: 4, width: 22, height: 22)
        XCTAssertNil(ItemEnumerator.display(containing: parkedOffScreen, in: screens))

        let onMain = CGRect(x: 1200, y: 4, width: 22, height: 22)
        XCTAssertEqual(ItemEnumerator.display(containing: onMain, in: screens), main)

        let onExternal = CGRect(x: 1800, y: 4, width: 22, height: 22)
        XCTAssertEqual(ItemEnumerator.display(containing: onExternal, in: screens), external)
    }

    func testMenuBarEndOffsetHandlesVerticallyStackedAndNegativeOriginDisplays() {
        let main = DisplayID(rawValue: 1, localizedName: "Built-in")
        let upperExternal = DisplayID(rawValue: 2, localizedName: "Upper 4K")
        let screens: [(DisplayID, CGRect)] = [
            (main, CGRect(x: 0, y: 0, width: 1512, height: 982)),
            (upperExternal, CGRect(x: -200, y: -1440, width: 2560, height: 1440)),
        ]

        // Frontmost app's menu bar is rendered at the top of the upper external display (y = -1436, minX = -200..maxX = 320).
        // Horizontal X overlaps `main` (0..1512), so matching must check both X and menu-bar-top Y band.
        let upperMenuItems = [
            CGRect(x: -188, y: -1436, width: 28, height: 24),
            CGRect(x: -150, y: -1436, width: 92, height: 24),
            CGRect(x: 240, y: -1436, width: 80, height: 24), // maxX = 320 -> offset from -200 is 520pt!
        ]
        let measured = ItemEnumerator.measureMenuBarEndOffset(itemFrames: upperMenuItems, in: screens)
        XCTAssertEqual(measured ?? 0, 520, accuracy: 0.5)
    }
}
