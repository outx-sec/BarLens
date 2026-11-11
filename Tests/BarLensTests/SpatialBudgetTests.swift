import XCTest
@testable import BarLens

final class SpatialBudgetTests: XCTestCase {

    func testNotchedDisplayGeometryUsesAuxiliaryRightAreaAndAppMenuOverflow() {
        let notched = DisplayMenuBarGeometry(
            displayID: DisplayID(rawValue: 1, localizedName: "Built-in Retina Display"),
            screenMinX: 0,
            screenMaxX: 1512,
            auxiliaryTopRightMinX: 880,
            auxiliaryTopRightMaxX: 1512
        )
        XCTAssertTrue(notched.hasPhysicalNotch)
        // Normal app menu (320pt) stays left of the notch (880pt), so full right area (632pt) is available.
        XCTAssertEqual(notched.availableRightWidth(frontmostMenuWidth: 320), 632)
        // Ultra-wide app menu overflowing past the notch (960pt) shrinks available right width to 552pt.
        XCTAssertEqual(notched.availableRightWidth(frontmostMenuWidth: 960), 552)

        let external = DisplayMenuBarGeometry(
            displayID: DisplayID(rawValue: 2, localizedName: "KU27F144M"),
            screenMinX: 0,
            screenMaxX: 2560,
            auxiliaryTopRightMinX: nil,
            auxiliaryTopRightMaxX: nil
        )
        XCTAssertFalse(external.hasPhysicalNotch)
        XCTAssertEqual(external.availableRightWidth(frontmostMenuWidth: 260), 2300)
    }

    func testDemotesLeftmostLowPriorityItemsBeforeNotchCollisionAndStabilizesWithHysteresis() {
        let candidates = [
            SpatialCandidate(bundleID: "com.app.leftEdge", estimatedWidth: 32, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 910),
            SpatialCandidate(bundleID: "com.app.middle", estimatedWidth: 32, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 950),
            SpatialCandidate(bundleID: "com.app.rightNearClock", estimatedWidth: 32, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 1020),
        ]

        // Fixed overhead = 140pt. Three items = 96pt -> total 236pt + 18pt safety = 254pt.
        // With budget = 230pt, two items fit (140 + 64 + 18 = 222 <= 230), leftmost item must tuck!
        let firstPass = SpatialBudgetPlanner.evaluate(
            policy: .notchGuard,
            candidates: candidates,
            fixedOverheadWidth: 140,
            availableRightWidth: 230,
            previouslyDemoted: []
        )
        XCTAssertEqual(firstPass.demotedBundleIDs, ["com.app.leftEdge"])
        XCTAssertEqual(firstPass.reasonsByBundleID["com.app.leftEdge"], .physicalSpace)

        // Hysteresis check: if available width grows slightly from 230pt to 260pt
        // (needs 140 + 96 + 18 + 20 = 274pt to restore), leftEdge stays tucked without flickering!
        let jitterPass = SpatialBudgetPlanner.evaluate(
            policy: .notchGuard,
            candidates: candidates,
            fixedOverheadWidth: 140,
            availableRightWidth: 260,
            previouslyDemoted: firstPass.demotedBundleIDs
        )
        XCTAssertEqual(jitterPass.demotedBundleIDs, ["com.app.leftEdge"])

        // Once ample space opens up (e.g. switching to Finder or external monitor, budget = 400pt), it restores!
        let restoredPass = SpatialBudgetPlanner.evaluate(
            policy: .notchGuard,
            candidates: candidates,
            fixedOverheadWidth: 140,
            availableRightWidth: 400,
            previouslyDemoted: jitterPass.demotedBundleIDs
        )
        XCTAssertTrue(restoredPass.demotedBundleIDs.isEmpty)
    }

    func testExemptAndRecentlyInteractedAppsOutrankUntouchedAppsUnderCompactSlotCap() {
        let candidates = [
            SpatialCandidate(bundleID: "com.untouched.1", estimatedWidth: 28, isExempt: false, isExplicitlyVisible: true, lastInteractedAt: 0, menuBarMinX: 1900),
            SpatialCandidate(bundleID: "com.untouched.2", estimatedWidth: 28, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 1850),
            SpatialCandidate(bundleID: "com.untouched.3", estimatedWidth: 28, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 1800),
            SpatialCandidate(bundleID: "com.untouched.4", estimatedWidth: 28, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 1750),
            SpatialCandidate(bundleID: "com.recent.a", estimatedWidth: 28, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 1_700_000_100, menuBarMinX: 1600),
            SpatialCandidate(bundleID: "com.recent.b", estimatedWidth: 28, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 1_700_000_200, menuBarMinX: 1550),
            SpatialCandidate(bundleID: "com.exempt.locked", estimatedWidth: 28, isExempt: true, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 1500),
        ]

        // Policy .compact5 allows at most 5 visible third-party slots on a wide 2560pt monitor.
        let eval = SpatialBudgetPlanner.evaluate(
            policy: .compact5,
            candidates: candidates,
            fixedOverheadWidth: 160,
            availableRightWidth: 2200,
            previouslyDemoted: []
        )

        // Kept 5: exempt.locked, recent.b, recent.a, untouched.1 (explicitly visible), untouched.2 (rightmost remaining).
        // Demoted 2: untouched.3, untouched.4.
        XCTAssertEqual(eval.demotedBundleIDs, ["com.untouched.3", "com.untouched.4"])
        XCTAssertFalse(eval.demotedBundleIDs.contains("com.exempt.locked"))
        XCTAssertFalse(eval.demotedBundleIDs.contains("com.recent.a"))
        XCTAssertFalse(eval.demotedBundleIDs.contains("com.recent.b"))
        XCTAssertEqual(eval.reasonsByBundleID["com.untouched.3"], .slotCap)
    }

    func testOffPolicyNeverDemotesAnything() {
        let candidates = [
            SpatialCandidate(bundleID: "com.heavy.1", estimatedWidth: 120, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 500),
            SpatialCandidate(bundleID: "com.heavy.2", estimatedWidth: 120, isExempt: false, isExplicitlyVisible: false, lastInteractedAt: 0, menuBarMinX: 620),
        ]
        let eval = SpatialBudgetPlanner.evaluate(
            policy: .off,
            candidates: candidates,
            fixedOverheadWidth: 200,
            availableRightWidth: 180,
            previouslyDemoted: ["com.heavy.1"]
        )
        XCTAssertTrue(eval.demotedBundleIDs.isEmpty)
    }
}
