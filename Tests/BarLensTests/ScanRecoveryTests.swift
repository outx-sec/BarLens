import XCTest
@testable import BarLens

final class ScanRecoveryTests: XCTestCase {
    private let display = DisplayID(rawValue: 1, localizedName: "Main")
    private func item(_ owner: String, x: CGFloat = 10, dot: Bool = false,
                      on screen: DisplayID? = nil) -> MenuBarItem {
        MenuBarItem(ownerBundleID: owner, ownerPID: 1,
                    frame: CGRect(x: x, y: 0, width: 20, height: 20),
                    display: screen ?? display,
                    axIdentifier: dot ? "BarLens.dot" : nil,
                    label: nil, indexInApp: 0)
    }

    func testWakeFailurePreservesDefaultHiddenOwnerUntilACompleteRead() {
        var state = MenuBarScanState(owners: ["hidden"])
        let failure = ItemScanResult(failedOwners: ["hidden"], timedOut: true)
        XCTAssertTrue(state.accept(failure, running: ["hidden", "new"]))
        XCTAssertEqual(state.owners, ["hidden"])
        let model = SectionModel(unclassified: .hidden)
        let allowed = model.allowedBundles(running: ["hidden", "new"], reveal: .none,
                                           alwaysHiddenEnabled: true, listable: state.owners)
        XCTAssertFalse(allowed.contains("hidden"), "Wake failure must not undo default hiding")
        XCTAssertTrue(allowed.contains("new"), "An unobserved app must not be hidden by guesswork")
    }

    func testPartialReadUpdatesSuccessfulOwnersAndPreservesOnlyUnresolvedOnes() {
        var state = MenuBarScanState(owners: ["slow", "removed", "quit"])
        let partial = ItemScanResult(items: [item("new")], failedOwners: ["slow"],
                                     completedOwners: ["new", "removed"])
        XCTAssertTrue(state.accept(partial, running: ["slow", "removed", "new"]))
        XCTAssertEqual(state.owners, ["slow", "removed", "new"])
        let complete = ItemScanResult(items: [item("new")],
                                      completedOwners: ["slow", "new", "removed"])
        XCTAssertTrue(state.accept(complete, running: ["slow", "removed", "new"]))
        XCTAssertEqual(state.owners, ["slow", "new"], "The previously failed owner needs two successful empty reads")
        XCTAssertFalse(state.accept(complete, running: ["slow", "removed", "new"]))
        XCTAssertEqual(state.owners, ["new"])
    }

    func testEmptyBarRequiresTwoConsecutiveCompleteScans() {
        var state = MenuBarScanState(owners: ["previous"])
        let empty = ItemScanResult(completedOwners: ["previous"])
        XCTAssertTrue(state.accept(empty, running: ["previous"]))
        XCTAssertEqual(state.owners, ["previous"])
        XCTAssertTrue(state.accept(ItemScanResult(failedOwners: ["previous"]), running: ["previous"]))
        XCTAssertTrue(state.accept(empty, running: ["previous"]))
        XCTAssertEqual(state.owners, ["previous"], "A failed scan breaks empty-result confirmation")
        XCTAssertFalse(state.accept(empty, running: ["previous"]))
        XCTAssertTrue(state.owners.isEmpty)
    }

    func testPermissionLossPreservesRunningOwnersButDropsExitedProcesses() {
        var state = MenuBarScanState(owners: ["running", "quit"])
        XCTAssertFalse(state.accept(ItemScanResult(permissionGranted: false), running: ["running"]))
        XCTAssertEqual(state.owners, ["running"])
    }

    func testSleepResetDoesNotCombineEmptyObservationsAcrossGenerations() {
        for otherAppIsReady in [false, true] {
            let running: Set<String> = otherAppIsReady ? ["previous", "ready"] : ["previous"]
            var state = MenuBarScanState(owners: running)
            let emptyOwner = ItemScanResult(items: otherAppIsReady ? [item("ready")] : [],
                                            completedOwners: running)
            XCTAssertTrue(state.accept(emptyOwner, running: running))
            state.resetAbsenceConfirmation()
            XCTAssertEqual(state.owners, running, "Reset preserves trusted owners")
            XCTAssertTrue(state.accept(emptyOwner, running: running))
            XCTAssertEqual(state.owners, running, "The first post-wake empty read must not remove an owner")
            XCTAssertFalse(state.accept(emptyOwner, running: running))
            XCTAssertEqual(state.owners, otherAppIsReady ? ["ready"] : [])
        }
    }

    func testInitialEmptyReadRequestsConfirmation() {
        var state = MenuBarScanState()
        XCTAssertTrue(state.accept(ItemScanResult(), running: []))
        XCTAssertFalse(state.accept(ItemScanResult(), running: []))
    }

    func testOneOwnersTransientEmptyTreeCannotUndoDefaultWhileOtherAppsAreReady() {
        var state = MenuBarScanState(owners: ["sleeping", "ready"])
        let transient = ItemScanResult(items: [item("ready")], completedOwners: ["sleeping", "ready"])
        XCTAssertTrue(state.accept(transient, running: ["sleeping", "ready"]))
        XCTAssertEqual(state.owners, ["sleeping", "ready"])
        let recovered = ItemScanResult(items: [item("ready"), item("sleeping")],
                                       completedOwners: ["sleeping", "ready"])
        XCTAssertFalse(state.accept(recovered, running: ["sleeping", "ready"]))
        XCTAssertEqual(state.owners, ["sleeping", "ready"])
    }

    func testBulkBoundaryUsesRevealedDotRatherThanItsPreviouslyShiftedPosition() throws {
        // Hiding the item at x=120 had moved the dot to x=130. The fully
        // revealed snapshot restores x=100 and must keep that item on the right.
        let snapshot = ItemScanResult(items: [item("left", x: 70), item("dot", x: 100, dot: true),
                                              item("right", x: 120)])
        let dot = try BulkAssignmentBoundary.resolve(in: snapshot, on: display)
        XCTAssertEqual(dot.frame.minX, 100)
        let affected = snapshot.items.filter { $0.frame.minX < dot.frame.minX }.map(\.ownerBundleID)
        XCTAssertEqual(affected, ["left"])
    }

    func testBulkBoundaryUsesTheInvokingDisplayWithNegativeCoordinates() throws {
        let secondary = DisplayID(rawValue: 2, localizedName: "Left")
        let snapshot = ItemScanResult(items: [item("dot", x: 100, dot: true),
                                              item("dot", x: -350, dot: true, on: secondary)])
        let dot = try BulkAssignmentBoundary.resolve(in: snapshot, on: secondary)
        XCTAssertEqual(dot.frame.minX, -350)
        XCTAssertEqual(dot.display, secondary)
    }

    func testBulkBoundaryDoesNotFallbackToAnotherDisplayOrMissingDot() {
        let secondary = DisplayID(rawValue: 2, localizedName: "Left")
        let snapshot = ItemScanResult(items: [item("dot", x: 100, dot: true)])
        XCTAssertThrowsError(try BulkAssignmentBoundary.resolve(in: snapshot, on: secondary))
        XCTAssertThrowsError(try BulkAssignmentBoundary.resolve(in: ItemScanResult(), on: display))
    }

    func testBulkBoundaryRejectsPartialTimeoutAndCancelledSnapshots() {
        let dot = item("dot", x: 100, dot: true)
        for snapshot in [ItemScanResult(items: [dot], failedOwners: ["unread-app"]),
                         ItemScanResult(items: [dot], timedOut: true),
                         ItemScanResult(items: [dot], cancelled: true),
                         ItemScanResult(items: [dot], permissionGranted: false)] {
            XCTAssertThrowsError(try BulkAssignmentBoundary.resolve(in: snapshot, on: display))
        }
    }

    func testRemovedStatusItemOnDisplaySwitchRetiresCleanlyAfterTwoResponsiveNoValueScans() {
        // Reproduces switching from an external display (where `com.apple.AirPlayUIAgent` or a display
        // utility owned an extra) back to the MacBook screen: the running process removes its status item
        // and responsively answers `AXError.noValue` (`.absent`) without entering `failedOwners`.
        let running: Set<String> = ["com.apple.AirPlayUIAgent", "com.tencent.xinWeChat"]
        var state = MenuBarScanState(owners: running)

        var ownerResults1 = ItemScanOwnerResults()
        ownerResults1.record(owner: "com.apple.AirPlayUIAgent", .absent)
        ownerResults1.record(owner: "com.tencent.xinWeChat", .complete([item("com.tencent.xinWeChat")]))
        let scan1 = ownerResults1.result(allOwners: running, knownOwners: state.owners)

        XCTAssertTrue(scan1.failedOwners.isEmpty, "Responsive AXNoValue must not stick in failedOwners")
        XCTAssertTrue(state.accept(scan1, running: running), "First absence requests one quiet confirmation pass")
        XCTAssertEqual(state.owners, running, "Owner stays protected during first confirmation pass")

        let scan2 = ownerResults1.result(allOwners: running, knownOwners: state.owners)
        XCTAssertFalse(state.accept(scan2, running: running), "Second consecutive responsive absence retires owner cleanly")
        XCTAssertEqual(state.owners, ["com.tencent.xinWeChat"])
    }
}
