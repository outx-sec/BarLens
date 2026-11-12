import AppKit
import SwiftUI
import XCTest
@testable import BarLens

@MainActor
final class FloatingBarPresentationTests: XCTestCase {
    func testCatalogRebuildCompletionRunsWithPopulatedEntriesAndDropsStaleGenerations() {
        let catalog = Catalog()
        let currentBundleID = "com.apple.finder"
        let display = DisplayID(rawValue: 1, localizedName: "Built-in Retina Display")
        let snapshot = [
            MenuBarItem(
                ownerBundleID: currentBundleID,
                ownerPID: ProcessInfo.processInfo.processIdentifier,
                frame: CGRect(x: 500, y: 0, width: 24, height: 24),
                display: display,
                axIdentifier: nil,
                label: "Finder",
                indexInApp: 0
            )
        ]
        var model = SectionModel()
        model.set(.hidden, for: currentBundleID)

        var staleCalled = false
        let freshExpectation = expectation(description: "Fresh catalog rebuild completed")
        var observedCountInCompletion = 0

        catalog.rebuild(model: model, query: "", snapshot: []) {
            staleCalled = true
        }
        catalog.rebuild(model: model, query: "", snapshot: snapshot) {
            observedCountInCompletion = catalog.entries.count
            freshExpectation.fulfill()
        }

        wait(for: [freshExpectation], timeout: 3.0)
        XCTAssertFalse(staleCalled, "Superseded rebuild generation must not fire completion")
        XCTAssertGreaterThanOrEqual(observedCountInCompletion, 1)
        XCTAssertTrue(catalog.entries.contains(where: { $0.bundleID == currentBundleID }))
    }

    func testFloatingBarMeasuresFullWidthBeforeInitialOrderFront() {
        let engine = DividerEngine()
        let catalog = Catalog()
        let coordinator = LensLoupeCoordinator()
        let display = DisplayID(rawValue: 1, localizedName: "Built-in Retina Display")

        let runningApps = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter { !SectionModel.ownIdentifiers.contains($0) && !SectionModel.notClassifiable.contains($0) }
        let sampleBundles = Array(Set(runningApps).prefix(6))
        guard sampleBundles.count >= 2 else { return }

        var snapshot: [MenuBarItem] = []
        for (idx, bid) in sampleBundles.enumerated() {
            snapshot.append(
                MenuBarItem(
                    ownerBundleID: bid,
                    ownerPID: 100 + Int32(idx),
                    frame: CGRect(x: CGFloat(400 + idx * 28), y: 0, width: 24, height: 24),
                    display: display,
                    axIdentifier: nil,
                    label: nil,
                    indexInApp: 0
                )
            )
            engine.setSection(.hidden, for: bid)
        }
        engine.setRevealPresentationStyle(.floatingBar)
        engine.setReveal(.hidden)

        let ready = expectation(description: "Catalog populated")
        catalog.rebuild(model: engine.model, query: "", snapshot: snapshot) {
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3.0)

        let maxBarWidth: CGFloat = 1200
        let rootView = FloatingBarView(
            engine: engine,
            catalog: catalog,
            loupeCoordinator: coordinator,
            maxBarWidth: maxBarWidth,
            onOpenSettings: {},
            onExpandInline: {}
        )
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]

        let sizeViaHosting = hosting.sizeThatFits(in: NSSize(width: maxBarWidth, height: 200))
        let sizeViaFitting = hosting.view.fittingSize

        let expectedMinWidth = CGFloat(sampleBundles.count) * 38.0 + 70.0
        XCTAssertGreaterThanOrEqual(sizeViaHosting.width, expectedMinWidth)
        XCTAssertLessThan(sizeViaHosting.height, 110, "Height must stay tightly hugging capsule, not expand to 200pt")
        XCTAssertEqual(ceil(sizeViaHosting.width), ceil(sizeViaFitting.width), accuracy: 2.0)
        XCTAssertEqual(ceil(sizeViaHosting.height), ceil(sizeViaFitting.height), accuracy: 2.0)
    }
}
