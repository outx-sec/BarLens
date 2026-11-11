import XCTest
@testable import BarLens

final class SectionModelTests: XCTestCase {
    private let normal = "example.normal"
    private let hidden = "example.hidden"
    private let permanent = "example.permanent"

    func testDisablingPermanentSectionFoldsBothAssignmentsIntoRevealableSection() {
        let model = SectionModel(alwaysHidden: [permanent], hidden: [hidden], visible: [normal])
        let running: Set<String> = [normal, hidden, permanent]

        let collapsed = allowed(model, running: running, reveal: .none, enabled: false)
        XCTAssertTrue(collapsed.contains(normal))
        XCTAssertFalse(collapsed.contains(hidden))
        XCTAssertFalse(collapsed.contains(permanent))

        for reveal in [SectionModel.Reveal.hidden, .all] {
            XCTAssertTrue(running.isSubset(of: allowed(model, running: running,
                                                       reveal: reveal, enabled: false)))
        }

        // Toggling the feature back on restores the original permanent rule.
        let restored = allowed(model, running: running, reveal: .hidden, enabled: true)
        XCTAssertTrue(restored.contains(hidden))
        XCTAssertFalse(restored.contains(permanent))
        XCTAssertEqual(model.section(of: permanent), .alwaysHidden)
    }

    func testEnabledSectionsFollowTheThreeRevealStates() {
        let model = SectionModel(alwaysHidden: [permanent], hidden: [hidden], visible: [normal])
        let running: Set<String> = [normal, hidden, permanent]
        let expected: [(SectionModel.Reveal, Set<String>)] = [
            (.none, [normal]), (.hidden, [normal, hidden]), (.all, running),
        ]
        for (reveal, visible) in expected {
            XCTAssertEqual(allowed(model, running: running, reveal: reveal, enabled: true)
                .intersection(running), visible)
        }
    }

    func testDefaultPermanentRuleOnlyHidesListableUnclassifiedApplications() {
        let invisibleToAccessibility = "example.no-ax"
        let systemOwner = "com.apple.MenuBarAgent"
        let model = SectionModel(visible: [normal], unclassified: .alwaysHidden)
        let running: Set<String> = [normal, permanent, invisibleToAccessibility, systemOwner]
        let listable: Set<String> = [normal, permanent, systemOwner]

        let result = Set(model.allowedBundles(running: running, reveal: .none,
                                             alwaysHiddenEnabled: true, listable: listable))
        XCTAssertTrue(result.contains(normal), "An explicit visible assignment overrides the default")
        XCTAssertTrue(result.contains(invisibleToAccessibility), "An uneditable app must stay visible")
        XCTAssertTrue(result.contains(systemOwner), "System items are controlled separately")
        XCTAssertFalse(result.contains(permanent))
        XCTAssertTrue(SectionModel.ownIdentifiers.isSubset(of: result))

        let revealed = Set(model.allowedBundles(running: running, reveal: .hidden,
                                               alwaysHiddenEnabled: false, listable: listable))
        XCTAssertTrue(running.isSubset(of: revealed))
    }

    func testRemovingExplicitAssignmentRestoresDefaultSection() {
        var model = SectionModel(alwaysHidden: [permanent], hidden: [hidden],
                                 visible: [normal], unclassified: .hidden)
        XCTAssertTrue(model.isClassified(normal))
        XCTAssertEqual(model.section(of: normal), .visible)

        model.removeAssignment(for: normal, persist: false)
        XCTAssertFalse(model.isClassified(normal))
        XCTAssertEqual(model.section(of: normal), .hidden)
    }

    private func allowed(_ model: SectionModel, running: Set<String>,
                         reveal: SectionModel.Reveal, enabled: Bool) -> Set<String> {
        Set(model.allowedBundles(running: running, reveal: reveal,
                                 alwaysHiddenEnabled: enabled, listable: running))
    }
}

final class AppCatalogSearchTests: XCTestCase {
    func testSearchFindsTheDisplayedMenuBarItemName() {
        let entry = AppEntry(bundleID: "com.apple.campo", name: "Siri", icon: nil,
                             section: .visible, isRunning: true,
                             itemLabels: ["Spotlight"], isLedgerOnly: false, itemCount: 1)
        XCTAssertEqual(entry.displayName, "Spotlight")
        XCTAssertTrue(AppCatalog.matches(entry, query: "  spotlight\n"))
        XCTAssertTrue(AppCatalog.matches(entry, query: "Siri"))
        XCTAssertFalse(AppCatalog.matches(entry, query: "Calendar"))
    }
}

final class SystemItemModelTests: XCTestCase {
    func testPermanentSystemItemsFollowOrdinaryRevealWhenSectionIsDisabled() {
        let registry = SystemItemRegistry(values: ["wifi": 6, "clock": 2, "battery": 0],
                                          build: "test")
        let model = SystemItemModel(registry: registry,
                                    assignments: ["wifi": .alwaysHidden, "clock": .hidden],
                                    unassigned: .visible)
        XCTAssertEqual(Set(model.hiddenRawValues(reveal: .none, alwaysHiddenEnabled: false)), [2, 6])
        XCTAssertTrue(model.hiddenRawValues(reveal: .hidden, alwaysHiddenEnabled: false).isEmpty)
        XCTAssertTrue(model.hiddenRawValues(reveal: .all, alwaysHiddenEnabled: false).isEmpty)
        XCTAssertEqual(model.hiddenRawValues(reveal: .hidden, alwaysHiddenEnabled: true), [6])
        XCTAssertTrue(model.hiddenRawValues(reveal: .all, alwaysHiddenEnabled: true).isEmpty)
    }

    func testSystemItemSymbolsSearchAndAssignmentRemoval() {
        let wifi = SystemItem(identifier: "com.apple.menuextra.wifi", rawValue: 6)
        let battery = SystemItem(identifier: "battery", rawValue: 0)
        XCTAssertEqual(wifi.title, "Wi-Fi")
        XCTAssertEqual(wifi.symbol, "wifi")
        XCTAssertEqual(battery.symbol, "battery.100")
        XCTAssertTrue(wifi.matches(query: "wi-fi"))
        XCTAssertTrue(wifi.matches(query: "menuextra"))
        XCTAssertFalse(wifi.matches(query: "bluetooth"))

        let registry = SystemItemRegistry(values: ["wifi": 6], build: "test")
        var model = SystemItemModel(registry: registry,
                                    assignments: ["wifi": .alwaysHidden],
                                    unassigned: .hidden)
        let item = SystemItem(identifier: "wifi", rawValue: 6)
        XCTAssertTrue(model.isClassified(item))
        model.removeAssignment(for: item, persist: false)
        XCTAssertFalse(model.isClassified(item))
        XCTAssertEqual(model.section(of: item), .hidden)
    }

    func testParallelBitmaskSolverResolvesMultipleItemsInSixProbes() {
        let truth: [String: Int] = [
            "battery": 0,
            "clock": 2,
            "wifi": 6,
            "controlcenter": 8,
            "bluetooth": 13,
            "siri": 45,
        ]
        let allIdentifiers = Array(truth.keys).sorted() + ["airdrop", "focusmode"]
        let baselineVisible = Set(truth.keys)

        let partition = SystemItemBitmaskSolver.partitionBaseline(
            identifiers: allIdentifiers,
            baselineVisible: baselineVisible)
        XCTAssertEqual(partition.unsupported, ["airdrop", "focusmode"])
        XCTAssertEqual(Set(partition.addressable), baselineVisible)

        let count = 64
        let bitCount = SystemItemBitmaskSolver.bitCount(for: count)
        XCTAssertEqual(bitCount, 6)

        var candidates: [String: Int] = [:]
        for bit in 0..<bitCount {
            let hiddenValues = Set(SystemItemBitmaskSolver.probeValues(forBit: bit, count: count))
            let visible = Set(truth.compactMap { id, raw in
                hiddenValues.contains(raw) ? nil : id
            })
            candidates = SystemItemBitmaskSolver.foldBitObservation(
                addressable: partition.addressable,
                visible: visible,
                bit: bit,
                into: candidates)
        }
        XCTAssertEqual(candidates, truth)
    }

    func testSystemItemsPruneAndExcludeUnavailableFromRawValueMask() {
        var registry = SystemItemRegistry(values: [
            "com.apple.menuextra.wifi": 6,
            "com.apple.menuextra.sound": 5,
            "com.apple.menuextra.vpn": 12,
            "com.apple.menuextra.clock": 2,
        ], build: "test")
        var model = SystemItemModel(
            registry: registry,
            assignments: [
                "com.apple.menuextra.wifi": .hidden,
                "com.apple.menuextra.sound": .hidden,
            ],
            unassigned: .visible
        )
        XCTAssertEqual(
            model.hiddenRawValues(
                reveal: .none,
                alwaysHiddenEnabled: true,
                excluding: ["com.apple.menuextra.sound"]
            ),
            [6]
        )
        XCTAssertTrue(registry.prune(keeping: ["com.apple.menuextra.wifi", "com.apple.menuextra.clock"]))
        XCTAssertNil(registry.rawValue(of: "com.apple.menuextra.vpn"))
        XCTAssertEqual(registry.rawValue(of: "com.apple.menuextra.sound"), 5)
        XCTAssertEqual(registry.rawValue(of: "com.apple.menuextra.wifi"), 6)
        _ = model.prune(keeping: ["com.apple.menuextra.wifi", "com.apple.menuextra.clock"])
        XCTAssertEqual(
            model.items.map(\.identifier),
            ["com.apple.menuextra.clock", "com.apple.menuextra.sound", "com.apple.menuextra.wifi"]
        )
    }

    func testCanonicalIdentifiersAndControlCenterManagedItems() {
        XCTAssertEqual(
            SystemItemName.canonicalIdentifier(for: "com.apple.menuextra.displays"),
            "com.apple.menuextra.display"
        )
        XCTAssertEqual(
            SystemItemName.canonicalIdentifier(for: "com.apple.menuextra.screenmirroring"),
            "com.apple.menuextra.screen-mirroring"
        )
        XCTAssertEqual(
            SystemItemName.canonicalIdentifier(for: "com.apple.menuextra.keyboardbrightness"),
            "com.apple.menuextra.keyboard-brightness"
        )
        XCTAssertEqual(
            SystemItemName.canonicalIdentifier(for: "com.apple.menuextra.volume"),
            "com.apple.menuextra.sound"
        )
        XCTAssertEqual(
            SystemItemName.canonicalIdentifier(for: "com.apple.menuextra.primarybentobox"),
            "com.apple.menuextra.controlcenter"
        )

        let registry = SystemItemRegistry(values: [
            "com.apple.menuextra.wifi": 6,
            "com.apple.menuextra.focusmode": SystemItem.controlCenterManagedRawValue,
        ], build: "test")
        let model = SystemItemModel(
            registry: registry,
            assignments: [
                "com.apple.menuextra.wifi": .visible,
                "com.apple.menuextra.focusmode": .hidden,
            ],
            unassigned: .visible
        )
        XCTAssertTrue(model.hiddenRawValues(reveal: .none, alwaysHiddenEnabled: true).isEmpty)
        XCTAssertTrue(model.hasHiddenControlCenterItems(reveal: .none, alwaysHiddenEnabled: true))
        XCTAssertFalse(model.hasHiddenControlCenterItems(reveal: .hidden, alwaysHiddenEnabled: true))
        XCTAssertFalse(
            model.hasHiddenControlCenterItems(
                reveal: .none,
                alwaysHiddenEnabled: true,
                excluding: ["com.apple.menuextra.focusmode"]
            )
        )
        XCTAssertTrue(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.display"))
        XCTAssertTrue(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.focusmode"))
        XCTAssertTrue(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.sound"))
        XCTAssertTrue(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.screen-mirroring"))
        XCTAssertTrue(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.wifi"))
        XCTAssertTrue(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.bluetooth"))
        XCTAssertFalse(ItemEnumerator.canTriggerViaControlCenter(identifier: "com.apple.menuextra.clock"))
    }
}

final class FloatingBarOrderAndProfileTests: XCTestCase {
    func testFloatingBarOrderSortsMovesAndPreservesUnseenItems() {
        var order = FloatingBarOrder(orderedIDs: ["app:b", "app:a", "app:b"])
        XCTAssertEqual(order.orderedIDs, ["app:b", "app:a"], "Duplicate IDs must be deduplicated")

        let current = ["app:a", "app:b", "sys:wifi", "sys:clock"]
        XCTAssertEqual(
            order.sorted(current, id: { $0 }),
            ["app:b", "app:a", "sys:wifi", "sys:clock"]
        )

        order.move(itemID: "sys:clock", to: "app:b", within: ["app:b", "app:a", "sys:wifi", "sys:clock"])
        XCTAssertEqual(
            order.sorted(current, id: { $0 }),
            ["sys:clock", "app:b", "app:a", "sys:wifi"]
        )

        order.moveToEdge(itemID: "sys:clock", toFront: false, within: ["sys:clock", "app:b", "app:a", "sys:wifi"])
        XCTAssertEqual(
            order.sorted(current, id: { $0 }),
            ["app:b", "app:a", "sys:wifi", "sys:clock"]
        )

        order.moveToEdge(itemID: "sys:wifi", toFront: true, within: ["app:b", "app:a", "sys:wifi", "sys:clock"])
        XCTAssertEqual(
            order.sorted(current, id: { $0 }),
            ["sys:wifi", "app:b", "app:a", "sys:clock"]
        )

        order.reset()
        XCTAssertTrue(order.isEmpty)
        XCTAssertEqual(order.sorted(current, id: { $0 }), current)
    }

    func testBarLensProfileRoundTripSanitizesAndClamps() throws {
        let rawProfile = BarLensProfile(
            visibleBundles: ["com.example.visible", "com.apple.MenuBarAgent"],
            hiddenBundles: ["com.example.hidden", "com.apple.controlcenter"],
            alwaysHiddenBundles: ["com.example.always"],
            systemItemAssignments: [
                "com.apple.menuextra.volume": "hidden",
                "com.apple.menuextra.displays": "alwaysHidden",
                "com.apple.menuextra.wifi": "invalidSection",
            ],
            floatingBarOrder: ["app:com.example.hidden", "sys:com.apple.menuextra.sound"],
            alwaysHiddenEnabled: true,
            unclassifiedSection: "visible",
            newSystemItemSection: "hidden",
            appearanceMode: "dark",
            revealPresentationStyle: "floatingBar",
            floatingBarIconStyle: "monochrome",
            statusBarIconStyle: "eclipse",
            glassOpacity: 9.99,
            rimIntensity: 0.01,
            autoRehideInterval: 10,
            hoverRevealDelay: 350,
            appLanguage: "zh-Hans",
            hotkeys: ["toggleHidden": Hotkey(keyCode: 42, carbonModifiers: 256, display: "⌘\\")]
        )

        let data = try rawProfile.encodedJSON()
        let decoded = try BarLensProfile.decode(from: data)

        XCTAssertEqual(decoded.visibleBundles, ["com.example.visible"])
        XCTAssertEqual(decoded.hiddenBundles, ["com.example.hidden"])
        XCTAssertEqual(decoded.alwaysHiddenBundles, ["com.example.always"])
        XCTAssertEqual(
            decoded.systemItemAssignments,
            [
                "com.apple.menuextra.sound": "hidden",
                "com.apple.menuextra.display": "alwaysHidden",
            ]
        )
        XCTAssertEqual(decoded.glassOpacity, 0.75, accuracy: 0.0001)
        XCTAssertEqual(decoded.rimIntensity, 0.40, accuracy: 0.0001)
        XCTAssertEqual(decoded.hoverRevealDelay, 350)
        XCTAssertEqual(decoded.hotkeys["toggleHidden"], Hotkey(keyCode: 42, carbonModifiers: 256, display: "⌘\\"))

        var sectionModel = SectionModel()
        sectionModel.replaceAll(
            visible: Set(decoded.visibleBundles),
            hidden: Set(decoded.hiddenBundles),
            alwaysHidden: Set(decoded.alwaysHiddenBundles),
            unclassified: .hidden,
            persist: false
        )
        XCTAssertEqual(sectionModel.section(of: "com.example.visible"), .visible)
        XCTAssertEqual(sectionModel.section(of: "com.example.hidden"), .hidden)
        XCTAssertEqual(sectionModel.section(of: "com.example.always"), .alwaysHidden)
    }
}
