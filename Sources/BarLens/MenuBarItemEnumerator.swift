import AppKit
import ApplicationServices

/// Which display a menu bar item lives on.
///
/// With more than one display each screen keeps its own menu bar, and the items
/// are split between them. Accessibility reports every item's frame in the
/// coordinate space of *its own* display, and those spaces do not share an
/// origin — a secondary display placed to the left of the main one reports
/// negative x. Comparing raw x across displays would silently sort one
/// display's items into the wrong section, so items are grouped by display
/// before anything is ordered.
struct DisplayID: Hashable {
    let rawValue: UInt32
    let localizedName: String
}

/// One status item currently known to MenuBarAgent.
struct MenuBarItem {
    /// Bundle identifier of the process that owns the item. Note this is the
    /// *owning process*, which for several popular apps is a helper agent and
    /// not the app the user would name — e.g. `com.example.App.agent` rather
    /// than `com.example.App`. The allow list is keyed on this value, so it
    /// has to be this one.
    let ownerBundleID: String
    let ownerPID: pid_t
    /// Frame in the owning display's coordinate space, not a global one.
    let frame: CGRect
    let display: DisplayID
    /// Only set for items we create ourselves; third-party items report nil.
    let axIdentifier: String?
    /// What the item calls itself: `AXTitle`, falling back to `AXDescription`.
    ///
    /// Title first, deliberately. Description is often *state* rather than name
    /// — the weather item's title is "天气" while its description is the current
    /// condition ("大部多云") — so leading with it would put a changing string in
    /// a list of stable names.
    ///
    /// Worth having at all because the owning bundle can be uninformative: the
    /// Siri item belongs to `com.apple.systemuiserver`, and a row named after
    /// its owner gives no clue that hiding it hides Siri. Nil when the item
    /// publishes neither attribute.
    let label: String?
    let indexInApp: Int
    /// Optional raw Accessibility strings retained for BarLens's zero-capture Semantic Lens.
    var axTitle: String? = nil
    var axDescription: String? = nil
    var axValue: String? = nil
    var axHelp: String? = nil
    var axMenuEntries: [AXMenuSnapshotEntry] = []
    var dockBadge: String? = nil
    var openWindowTitles: [String] = []
}

struct ItemScanApplication {
    let pid: pid_t
    let bundleID: String
}

struct ItemScanContext {
    let applications: [ItemScanApplication]
    let screens: [(DisplayID, CGRect)]
    let permissionGranted: Bool
    var frontmostPID: pid_t? = nil
    var menuBarGeometries: [DisplayMenuBarGeometry] = []
}

struct ItemScanResult {
    var items: [MenuBarItem] = []
    var failedOwners: Set<String> = []
    var completedOwners: Set<String> = []
    var visibleSystemItems: Set<String> = []
    var frontmostMenuBarWidth: CGFloat? = nil
    var timedOut = false
    var cancelled = false
    var permissionGranted = true
    /// Aggregate stages and error codes only; never log application identities.
    var failureCounts: [String: Int] = [:]
    /// Processes whose AX root is unreadable and which have never supplied a
    /// trusted menu item. They are neither confirmed absent nor classified.
    var unobservedOwners: Set<String> = []

    var failureSummary: String {
        failureCounts.keys.sorted().map { "\($0)=\(failureCounts[$0]!)" }.joined(separator: ",")
    }

    var isComplete: Bool {
        permissionGranted && !timedOut && !cancelled && failedOwners.isEmpty
    }

    var failureDescription: String? {
        if !permissionGranted { return AXScanFailure.permissionDenied.description }
        if cancelled { return AXScanFailure.cancelled.description }
        if timedOut { return AXScanFailure.timedOut.description }
        if !failedOwners.isEmpty {
            return tr("部分应用的菜单栏暂时无法读取。", "Some applications' menu bar items could not be read temporarily.")
        }
        return nil
    }
}

/// Several running processes may share a bundle identifier. A readable extras
/// tree resolves an unreadable sibling root, but cannot resolve a failed item
/// tree or geometry read from a sibling that really does own status items.
struct ItemScanOwnerResults {
    enum Observation {
        case absent
        case unreadableRoot
        case complete([MenuBarItem])
        case incompleteTree
    }

    private var processed: Set<String> = []
    private var absent: Set<String> = []
    private var unreadableRoots: Set<String> = []
    private var completeTrees: Set<String> = []
    private var nonemptyTrees: Set<String> = []
    private var incompleteTrees: Set<String> = []
    private var items: [MenuBarItem] = []

    mutating func record(owner: String, _ observation: Observation) {
        processed.insert(owner)
        switch observation {
        case .absent: absent.insert(owner)
        case .unreadableRoot: unreadableRoots.insert(owner)
        case .complete(let observed):
            completeTrees.insert(owner)
            if !observed.isEmpty { nonemptyTrees.insert(owner) }
            items += observed
        case .incompleteTree: incompleteTrees.insert(owner)
        }
    }

    func result(allOwners: Set<String>, knownOwners: Set<String>) -> ItemScanResult {
        // An empty sibling does not prove that the process owning the old
        // icon has recovered. Only a positively observed item resolves it.
        let unresolvedRoots = unreadableRoots.subtracting(nonemptyTrees)
        let failed = incompleteTrees.union(allOwners.subtracting(processed))
            .union(unresolvedRoots.intersection(knownOwners))
        let completed = completeTrees.union(absent.subtracting(unreadableRoots))
            .subtracting(failed).subtracting(unresolvedRoots)
        return ItemScanResult(items: items.filter { !failed.contains($0.ownerBundleID) },
                             failedOwners: failed, completedOwners: completed,
                             unobservedOwners: unresolvedRoots.subtracting(failed))
    }
}

enum ItemEnumerator {
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// AppKit screen and running-process metadata are captured on the main
    /// queue. Only the potentially blocking AX messages run on workers.
    static func captureContext() -> ItemScanContext {
        if !Thread.isMainThread { return DispatchQueue.main.sync { captureContext() } }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return ItemScanContext(
            applications: NSWorkspace.shared.runningApplications.compactMap {
                guard $0.processIdentifier > 0, let bundleID = $0.bundleIdentifier else { return nil }
                return ItemScanApplication(pid: $0.processIdentifier, bundleID: bundleID)
            },
            screens: displayFrames(),
            permissionGranted: hasAccessibilityPermission,
            frontmostPID: (frontPID ?? 0) > 0 ? frontPID : nil,
            menuBarGeometries: displayMenuBarGeometries()
        )
    }

    /// Used by the catalog's background queue. Operation owners should prefer
    /// `scan` and retain their last trusted items for failed owners.
    static func enumerate() -> [MenuBarItem] {
        precondition(!Thread.isMainThread, "AX enumeration must run off the main thread")
        return scan(context: captureContext()).items
    }

    /// A hidden item reports its old frame. Positional classification must use
    /// a successful snapshot after every item (including the dot) is revealed.
    static func scan(context: ItemScanContext, knownOwners: Set<String> = [],
                     cancellation: AXScanCancellation = AXScanCancellation(),
                     budget: TimeInterval = 4) -> ItemScanResult {
        precondition(!Thread.isMainThread, "AX scanning must run off the main thread")
        var result = ItemScanResult(permissionGranted: context.permissionGranted)
        let owners = Set(context.applications.map(\.bundleID))
        guard context.permissionGranted, !context.screens.isEmpty else {
            result.failedOwners = owners
            return result
        }
        let reader = AXReadBudget(seconds: budget, cancellation: cancellation)
        var ownerResults = ItemScanOwnerResults()
        var scannedSystemItems: Set<String> = []
        // Read previously observed owners first so an unrelated unresponsive
        // application cannot spend the entire budget before relevant items.
        let applications = context.applications.sorted {
            knownOwners.contains($0.bundleID) && !knownOwners.contains($1.bundleID)
        }
        for application in applications {
            if let failure = reader.failure {
                result.timedOut = failure == .timedOut
                result.cancelled = failure == .cancelled
                break
            }
            var stage = "extras"
            do {
                let element = AXUIElementCreateApplication(application.pid)
                let extras: AXUIElement
                do {
                    extras = try reader.element(element, "AXExtrasMenuBar")
                } catch AXScanFailure.readFailed(let code)
                    where missingExtrasAreReliable(errorCode: code,
                        previouslyObserved: knownOwners.contains(application.bundleID)) {
                    // Most running applications do not own a status item.
                    ownerResults.record(owner: application.bundleID, .absent)
                    continue
                }
                stage = "children"
                let children = try reader.children(extras)
                // A successfully read empty array is distinct from AXNoValue.
                // MenuBarScanState confirms this absence across two snapshots
                // before removing a previously observed owner.
                var appItems: [MenuBarItem] = []
                for (index, child) in children.enumerated() {
                    stage = "frame"
                    let frame = try frame(of: child, reader: reader)
                    // Some third-party apps keep a zero-width placeholder item
                    // in their AXExtrasMenuBar; ignore invisible placeholders
                    // rather than failing the entire application's tree.
                    guard frame.width > 0, frame.height > 0 else { continue }
                    stage = "display"
                    // Status items disabled in System Settings or hidden by the
                    // owning app itself are parked off-screen (e.g. x = -300).
                    // Skip off-screen items rather than failing the app's tree.
                    guard let display = display(containing: frame, in: context.screens) else {
                        continue
                    }
                    stage = "labels"
                    var identifier = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXIdentifierAttribute as String)
                    }
                    if identifier == nil, application.bundleID == "com.apple.MenuBarAgent" {
                        identifier = try nestedIdentifier(in: child, depth: 0, reader: reader)
                    }
                    if application.bundleID == "com.apple.MenuBarAgent",
                       let id = identifier, !id.isEmpty {
                        let canonical = SystemItemName.canonicalIdentifier(for: id)
                        identifier = canonical
                        scannedSystemItems.insert(canonical)
                    } else if application.bundleID == "com.apple.systemuiserver" {
                        scannedSystemItems.insert("com.apple.menuextra.timemachine")
                    } else if application.bundleID == "com.apple.TextInputMenuAgent" {
                        scannedSystemItems.insert("com.apple.menuextra.textinput")
                    } else if application.bundleID == "com.apple.campo" || application.bundleID == "com.apple.Spotlight" {
                        scannedSystemItems.insert("com.apple.menuextra.spotlight")
                    } else if application.bundleID == "com.apple.Siri" {
                        scannedSystemItems.insert("com.apple.menuextra.siri")
                    }
                    var title = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXTitleAttribute as String)
                    }
                    var desc = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXDescriptionAttribute as String)
                    }
                    var val = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXValueAttribute as String)
                    }
                    let help = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXHelpAttribute as String)
                    }
                    if (title == nil || title?.isEmpty == true)
                        && (desc == nil || desc?.isEmpty == true)
                        && (val == nil || val?.isEmpty == true),
                       !SectionModel.ownIdentifiers.contains(application.bundleID) {
                        let nested = try nestedTelemetry(in: child, depth: 0, reader: reader)
                        if title == nil || title?.isEmpty == true { title = nested.title }
                        if desc == nil || desc?.isEmpty == true { desc = nested.description }
                        if val == nil || val?.isEmpty == true { val = nested.value }
                    }
                    let nonEmptyTitle = (title?.isEmpty == false) ? title : nil
                    let nonEmptyDesc = (desc?.isEmpty == false) ? desc : nil
                    let label = nonEmptyTitle ?? nonEmptyDesc
                    let menuEntries: [AXMenuSnapshotEntry]
                    if application.bundleID != "com.apple.MenuBarAgent"
                        && !SectionModel.ownIdentifiers.contains(application.bundleID) {
                        menuEntries = try readMenuSnapshot(from: child, statusItemIndex: index, reader: reader)
                    } else {
                        menuEntries = []
                    }
                    appItems.append(MenuBarItem(ownerBundleID: application.bundleID,
                        ownerPID: application.pid, frame: frame, display: display,
                        axIdentifier: identifier, label: label,
                        indexInApp: index,
                        axTitle: nonEmptyTitle,
                        axDescription: nonEmptyDesc,
                        axValue: (val?.isEmpty == false) ? val : nil,
                        axHelp: (help?.isEmpty == false) ? help : nil,
                        axMenuEntries: menuEntries))
                }
                if !appItems.isEmpty,
                   application.bundleID != "com.apple.MenuBarAgent",
                   !SectionModel.ownIdentifiers.contains(application.bundleID),
                   reader.failure == nil {
                    let windowTitles = readOpenWindowTitles(from: element, reader: reader)
                    if !windowTitles.isEmpty {
                        for idx in appItems.indices {
                            appItems[idx].openWindowTitles = windowTitles
                        }
                    }
                }
                ownerResults.record(owner: application.bundleID, .complete(appItems))
            } catch {
                ownerResults.record(owner: application.bundleID,
                                    stage == "extras" ? .unreadableRoot : .incompleteTree)
                let reason: String
                switch error as? AXScanFailure {
                case .readFailed(let code): reason = String(code)
                case .cancelled: reason = "cancelled"
                case .timedOut: reason = "timedOut"
                case .permissionDenied: reason = "permissionDenied"
                case .unavailable: reason = "unavailable"
                case nil: reason = "unexpected"
                }
                result.failureCounts["\(stage):\(reason)", default: 0] += 1
            }
        }
        let merged = ownerResults.result(allOwners: owners, knownOwners: knownOwners)
        result.items = merged.items
        result.failedOwners = merged.failedOwners
        result.completedOwners = merged.completedOwners
        result.unobservedOwners = merged.unobservedOwners
        if merged.completedOwners.contains("com.apple.MenuBarAgent") {
            result.visibleSystemItems = scannedSystemItems
        }
        if reader.failure == nil, let frontPID = context.frontmostPID {
            result.frontmostMenuBarWidth = measureMenuBarWidth(
                pid: frontPID,
                screens: context.screens,
                reader: reader
            )
        }
        if reader.failure == nil,
           let dockPID = context.applications.first(where: { $0.bundleID == "com.apple.dock" })?.pid {
            let dockBadges = readDockBadges(dockPID: dockPID, reader: reader)
            if !dockBadges.isEmpty {
                for idx in result.items.indices {
                    let bid = result.items[idx].ownerBundleID
                    if let badge = dockBadges[bid] {
                        result.items[idx].dockBadge = badge
                    }
                }
            }
        }
        if let failure = reader.failure {
            result.timedOut = failure == .timedOut
            result.cancelled = failure == .cancelled
        }
        result.items.sort {
            if $0.display != $1.display { return $0.display.rawValue < $1.display.rawValue }
            return $0.frame.minX < $1.frame.minX
        }
        return result
    }

    struct SemanticPollSnapshot {
        var rawByOwner: [String: [RawAXItemTelemetry]] = [:]
        var dockBadges: [String: String] = [:]
        var completedOwners: Set<String> = []
    }

    /// Lightweight off-main-thread poll of status-item semantic telemetry and Dock
    /// unread badges for a targeted set of hidden/tucked bundle identifiers.
    /// Does not require an on-screen display match so status items parked off-screen
    /// while hidden by `MBAssessmentModeAssertion` still report live text and menu changes.
    static func pollSemanticSnapshot(applications: [ItemScanApplication],
                                     dockPID: pid_t?,
                                     budget: TimeInterval = 1.4) -> SemanticPollSnapshot {
        precondition(!Thread.isMainThread, "AX semantic polling must run off the main thread")
        guard hasAccessibilityPermission else { return SemanticPollSnapshot() }
        let reader = AXReadBudget(seconds: budget, cancellation: AXScanCancellation())
        var snapshot = SemanticPollSnapshot()

        for application in applications {
            guard reader.failure == nil else { break }
            do {
                let appElement = AXUIElementCreateApplication(application.pid)
                let extras = try reader.element(appElement, "AXExtrasMenuBar")
                let children = try reader.children(extras)
                var ownerItems: [RawAXItemTelemetry] = []
                for (index, child) in children.enumerated() {
                    guard reader.failure == nil else { break }
                    if let rect = try? frame(of: child, reader: reader),
                       (rect.width <= 0 || rect.height <= 0) {
                        continue
                    }
                    let identifier = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXIdentifierAttribute as String)
                    }
                    var title = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXTitleAttribute as String)
                    }
                    var desc = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXDescriptionAttribute as String)
                    }
                    var val = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXValueAttribute as String)
                    }
                    let help = try AXReadBudget.optionalMetadata {
                        try reader.string(child, kAXHelpAttribute as String)
                    }
                    if (title == nil || title?.isEmpty == true)
                        && (desc == nil || desc?.isEmpty == true)
                        && (val == nil || val?.isEmpty == true) {
                        let nested = try nestedTelemetry(in: child, depth: 0, reader: reader)
                        if title == nil || title?.isEmpty == true { title = nested.title }
                        if desc == nil || desc?.isEmpty == true { desc = nested.description }
                        if val == nil || val?.isEmpty == true { val = nested.value }
                    }
                    let menuEntries = try readShallowStatusMenuEntries(
                        from: child,
                        statusItemIndex: index,
                        reader: reader
                    )
                    ownerItems.append(RawAXItemTelemetry(
                        indexInApp: index,
                        identifier: (identifier?.isEmpty == false) ? identifier : nil,
                        title: (title?.isEmpty == false) ? title : nil,
                        description: (desc?.isEmpty == false) ? desc : nil,
                        value: (val?.isEmpty == false) ? val : nil,
                        help: (help?.isEmpty == false) ? help : nil,
                        menuEntries: menuEntries
                    ))
                }
                if reader.failure == nil {
                    snapshot.rawByOwner[application.bundleID, default: []] += ownerItems
                    snapshot.completedOwners.insert(application.bundleID)
                }
            } catch {
                continue
            }
        }

        if reader.failure == nil, let dockPID, dockPID > 0 {
            snapshot.dockBadges = readDockBadges(dockPID: dockPID, reader: reader)
        }
        return snapshot
    }

    /// Reads the current live on-screen status-item geometries for newly surfaced top-bar
    /// status bubbles so `TopBarClickTracker` can match user clicks on surfaced icons accurately.
    static func readLiveStatusItemFrames(applications: [ItemScanApplication],
                                         screens: [(DisplayID, CGRect)],
                                         budget: TimeInterval = 0.8) -> [MenuBarItem] {
        precondition(!Thread.isMainThread, "AX frame read must run off the main thread")
        guard hasAccessibilityPermission, !screens.isEmpty else { return [] }
        let reader = AXReadBudget(seconds: budget, cancellation: AXScanCancellation())
        var items: [MenuBarItem] = []
        for application in applications {
            guard reader.failure == nil else { break }
            let appEl = AXUIElementCreateApplication(application.pid)
            guard let extras = try? reader.element(appEl, "AXExtrasMenuBar"),
                  let children = try? reader.children(extras) else {
                continue
            }
            for (index, child) in children.enumerated() {
                guard let rect = try? frame(of: child, reader: reader),
                      rect.width > 0, rect.height > 0,
                      let display = display(containing: rect, in: screens) else {
                    continue
                }
                items.append(MenuBarItem(
                    ownerBundleID: application.bundleID,
                    ownerPID: application.pid,
                    frame: rect,
                    display: display,
                    axIdentifier: nil,
                    label: nil,
                    indexInApp: index
                ))
            }
        }
        return items
    }

    private static let nonSharingSystemExtraIdentifiers: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.wifi",
        "com.apple.menuextra.battery",
        "com.apple.menuextra.bluetooth",
        "com.apple.menuextra.sound",
        "com.apple.menuextra.spotlight",
        "com.apple.menuextra.siri",
        "com.apple.menuextra.focusmode",
        "com.apple.menuextra.textinput",
        "com.apple.menuextra.weather",
        "com.apple.menuextra.timer",
        "com.apple.menuextra.passwords",
        "com.apple.menuextra.user",
        "com.apple.menuextra.controlcenter",
        "com.apple.menuextra.airdrop",
        "com.apple.menuextra.display",
        "com.apple.menuextra.stagemanager",
        "com.apple.menuextra.nowplaying",
        "com.apple.menuextra.timemachine",
    ]

    /// Lightweight off-main-thread probe of `MenuBarAgent` / `ControlCenter` to check whether
    /// macOS is currently displaying the active screen-sharing pill (`"当前正在共享"` / `"Currently Sharing"`).
    /// Invoked only during active capture verification or static-window hold (`0%` idle overhead).
    static func pollControlCenterScreenShareIndicator(applications: [ItemScanApplication],
                                                      screens: [(DisplayID, CGRect)],
                                                      budget: TimeInterval = 0.18) -> Bool {
        precondition(!Thread.isMainThread, "AX share indicator probe must run off the main thread")
        guard hasAccessibilityPermission, !screens.isEmpty, !applications.isEmpty else { return false }
        let reader = AXReadBudget(seconds: budget, cancellation: AXScanCancellation())
        for application in applications {
            guard reader.failure == nil else { break }
            let appEl = AXUIElementCreateApplication(application.pid)
            guard let extras = try? reader.element(appEl, "AXExtrasMenuBar"),
                  let children = try? reader.children(extras) else {
                continue
            }
            for (index, child) in children.enumerated() {
                guard reader.failure == nil else { break }
                guard let rect = try? frame(of: child, reader: reader),
                      rect.width > 0, rect.height > 0,
                      let display = display(containing: rect, in: screens) else {
                    continue
                }
                var identifier = try? AXReadBudget.optionalMetadata {
                    try reader.string(child, kAXIdentifierAttribute as String)
                }
                if identifier == nil, application.bundleID == "com.apple.MenuBarAgent" {
                    identifier = try? nestedIdentifier(in: child, depth: 0, reader: reader)
                }
                if let id = identifier, !id.isEmpty {
                    let canonical = SystemItemName.canonicalIdentifier(for: id)
                    identifier = canonical
                    let lower = canonical.lowercased()
                    if nonSharingSystemExtraIdentifiers.contains(lower)
                        || lower.contains("controlcenter")
                        || lower.contains("bentobox") {
                        continue
                    }
                    if lower.contains("screenrecording")
                        || lower.contains("screen-recording")
                        || lower.contains("contentsharing") {
                        return true
                    }
                }
                var title = try? AXReadBudget.optionalMetadata {
                    try reader.string(child, kAXTitleAttribute as String)
                }
                var desc = try? AXReadBudget.optionalMetadata {
                    try reader.string(child, kAXDescriptionAttribute as String)
                }
                var val = try? AXReadBudget.optionalMetadata {
                    try reader.string(child, kAXValueAttribute as String)
                }
                if (title == nil || title?.isEmpty == true)
                    && (desc == nil || desc?.isEmpty == true)
                    && (val == nil || val?.isEmpty == true) {
                    if let nested = try? nestedTelemetry(in: child, depth: 0, reader: reader) {
                        if title == nil || title?.isEmpty == true { title = nested.title }
                        if desc == nil || desc?.isEmpty == true { desc = nested.description }
                        if val == nil || val?.isEmpty == true { val = nested.value }
                    }
                }
                let nonEmptyTitle = (title?.isEmpty == false) ? title : nil
                let nonEmptyDesc = (desc?.isEmpty == false) ? desc : nil
                let item = MenuBarItem(
                    ownerBundleID: application.bundleID,
                    ownerPID: application.pid,
                    frame: rect,
                    display: display,
                    axIdentifier: identifier,
                    label: nonEmptyTitle ?? nonEmptyDesc,
                    indexInApp: index,
                    axTitle: nonEmptyTitle,
                    axDescription: nonEmptyDesc,
                    axValue: (val?.isEmpty == false) ? val : nil
                )
                if DisplayMirrorDetector.hasControlCenterScreenShareIndicator(in: [item]) {
                    return true
                }
            }
        }
        return false
    }

    /// Reads only top-level status/checked menu rows (skipping cascading submenus and
    /// shortcut modifier queries) so background status-bubble polling stays ultra-lightweight.
    private static func readShallowStatusMenuEntries(from statusItem: AXUIElement,
                                                     statusItemIndex: Int,
                                                     reader: AXReadBudget) throws -> [AXMenuSnapshotEntry] {
        guard let subChildren = try AXReadBudget.optionalValue({ try reader.children(statusItem) }),
              !subChildren.isEmpty else {
            return []
        }
        var rootMenu: AXUIElement?
        for child in subChildren.prefix(4) {
            let role = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXRoleAttribute as String)
            }
            if role == (kAXMenuRole as String) {
                rootMenu = child
                break
            }
        }
        guard let rootMenu,
              let menuItems = try AXReadBudget.optionalValue({ try reader.children(rootMenu) }),
              !menuItems.isEmpty else {
            return []
        }
        var entries: [AXMenuSnapshotEntry] = []
        for (menuIndex, itemElement) in menuItems.prefix(10).enumerated() {
            guard reader.failure == nil else { break }
            let rawTitle = try AXReadBudget.optionalMetadata {
                try reader.string(itemElement, kAXTitleAttribute as String)
            }
            guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                continue
            }
            let enabled = (try AXReadBudget.optionalValue {
                try reader.bool(itemElement, kAXEnabledAttribute as String)
            }) ?? true
            let mark = try AXReadBudget.optionalMetadata {
                try reader.string(itemElement, "AXMenuItemMarkChar")
            }
            let hasMark = (mark?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            guard !enabled || hasMark else { continue }
            entries.append(AXMenuSnapshotEntry(
                statusItemIndex: statusItemIndex,
                menuPath: [menuIndex],
                titlePath: [title],
                title: title,
                isEnabled: enabled,
                markChar: hasMark ? mark : nil,
                shortcutHint: nil,
                children: []
            ))
        }
        return entries
    }

    /// An app that never exposed Accessibility is not a failed menu-bar read.
    /// A previously observed owner disappearing is ambiguous and must be kept
    /// until a later reliable snapshot (or process exit) resolves it.
    static func missingExtrasAreReliable(errorCode: Int32, previouslyObserved: Bool) -> Bool {
        guard !previouslyObserved else { return false }
        return [AXError.noValue, .attributeUnsupported, .notImplemented]
            .contains { $0.rawValue == errorCode }
    }

    static func displayID(for screen: NSScreen) -> DisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return DisplayID(rawValue: number.uint32Value, localizedName: screen.localizedName)
    }

    /// Triggers a status item owned by `bundleID` via Accessibility (`AXPress` / `AXShowMenu`),
    /// optionally targeting a specific `preferredIndex` for multi-icon applications.
    @discardableResult
    static func pressStatusItem(bundleID: String, preferredIndex: Int? = nil) -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        guard hasAccessibilityPermission else { return false }
        let (pids, screens) = DispatchQueue.main.sync {
            (
                NSWorkspace.shared.runningApplications
                    .filter { $0.bundleIdentifier == bundleID && $0.processIdentifier > 0 }
                    .map(\.processIdentifier),
                displayFrames()
            )
        }
        let reader = AXReadBudget(seconds: 1.5, cancellation: AXScanCancellation())
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let extras = try? reader.element(app, "AXExtrasMenuBar"),
                  let children = try? reader.children(extras) else { continue }
            let orderedChildren: [AXUIElement]
            if let preferredIndex, children.indices.contains(preferredIndex) {
                orderedChildren = [children[preferredIndex]] + children.enumerated()
                    .filter { $0.offset != preferredIndex }
                    .map(\.element)
            } else {
                orderedChildren = children
            }
            for child in orderedChildren {
                if let rect = try? frame(of: child, reader: reader),
                   rect.width > 0, rect.height > 0,
                   display(containing: rect, in: screens) != nil {
                    if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                        return true
                    }
                    if AXUIElementPerformAction(child, "AXShowMenu" as CFString) == .success {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Cancels/closes an open menu on a status item owned by `bundleID` via `kAXCancelAction`.
    @discardableResult
    static func cancelStatusItem(bundleID: String) -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        guard hasAccessibilityPermission else { return false }
        let pids = DispatchQueue.main.sync {
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleID && $0.processIdentifier > 0 }
                .map(\.processIdentifier)
        }
        let reader = AXReadBudget(seconds: 1.0, cancellation: AXScanCancellation())
        var cancelled = false
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let extras = try? reader.element(app, "AXExtrasMenuBar"),
                  let children = try? reader.children(extras) else { continue }
            for child in children {
                if AXUIElementPerformAction(child, kAXCancelAction as CFString) == .success {
                    cancelled = true
                }
            }
        }
        return cancelled
    }

    /// Triggers a built-in system status item matching `identifier`.
    @discardableResult
    static func pressSystemItem(identifier: String) -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        guard hasAccessibilityPermission else { return false }
        let targetCanonical = SystemItemName.canonicalIdentifier(for: identifier)
        let systemBundles: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.MenuBarAgent",
        ]
        let (pids, screens) = DispatchQueue.main.sync {
            (
                NSWorkspace.shared.runningApplications
                    .filter {
                        guard let bid = $0.bundleIdentifier, $0.processIdentifier > 0 else { return false }
                        return systemBundles.contains(bid) || bid == identifier
                    }
                    .map(\.processIdentifier),
                displayFrames()
            )
        }
        let reader = AXReadBudget(seconds: 1.5, cancellation: AXScanCancellation())
        func findAndPress(_ element: AXUIElement, depth: Int) -> Bool {
            let axID = try? AXReadBudget.optionalMetadata {
                try reader.string(element, kAXIdentifierAttribute as String)
            }
            if let axID, !axID.isEmpty,
               (axID == identifier || SystemItemName.canonicalIdentifier(for: axID) == targetCanonical) {
                if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    return true
                }
                if AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success {
                    return true
                }
            }
            guard depth < 3, let children = try? reader.children(element) else { return false }
            for child in children {
                if findAndPress(child, depth: depth + 1) {
                    return true
                }
            }
            return false
        }
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let extras = try? reader.element(app, "AXExtrasMenuBar"),
                  let children = try? reader.children(extras) else { continue }
            for child in children {
                if let rect = try? frame(of: child, reader: reader),
                   rect.width > 0, rect.height > 0,
                   display(containing: rect, in: screens) != nil,
                   findAndPress(child, depth: 0) {
                    return true
                }
            }
        }
        return false
    }

    static let syntheticEventTag: Int64 = 0x4D424456
    private static let syntheticClickLock = NSLock()
    private static var _lastSyntheticClickAt: Date = .distantPast
    static var lastSyntheticClickAt: Date {
        get {
            syntheticClickLock.lock()
            defer { syntheticClickLock.unlock() }
            return _lastSyntheticClickAt
        }
        set {
            syntheticClickLock.lock()
            _lastSyntheticClickAt = newValue
            syntheticClickLock.unlock()
        }
    }

    private static let controlCenterModuleSubstrings: [String: String] = [
        "com.apple.menuextra.focusmode":        "controlcenter-focus-modes",
        "com.apple.menuextra.airdrop":          "controlcenter-airdrop",
        "com.apple.menuextra.screen-mirroring": "controlcenter-screen-mirroring",
        "com.apple.menuextra.display":          "controlcenter-display",
        "com.apple.menuextra.sound":            "controlcenter-volume",
        "com.apple.menuextra.bluetooth":        "controlcenter-bluetooth",
        "com.apple.menuextra.wifi":             "controlcenter-wifi",
        "com.apple.menuextra.stagemanager":     "windowmanager.stagemanager",
    ]

    private static let standaloneSystemApps: [String: String] = [
        "com.apple.menuextra.spotlight": "/System/Library/CoreServices/Spotlight.app",
        "com.apple.menuextra.siri":      "/System/Library/CoreServices/Siri.app",
        "com.apple.menuextra.timer":     "/System/Applications/Clock.app",
        "com.apple.menuextra.weather":   "/System/Applications/Weather.app",
        "com.apple.menuextra.passwords": "/System/Applications/Passwords.app",
    ]

    /// Whether `identifier` can be triggered via Control Center or a standalone
    /// system app without unhiding its status item on the top menu bar.
    static func canTriggerViaControlCenter(identifier: String) -> Bool {
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        if controlCenterModuleSubstrings[canonical] != nil { return true }
        if standaloneSystemApps[canonical] != nil { return true }
        switch canonical {
        case "com.apple.menuextra.nowplaying",
             "com.apple.menuextra.user",
             "com.apple.menuextra.controlcenter":
            return true
        default:
            return false
        }
    }

    /// Returns PIDs of processes (excluding BarLens itself) that currently
    /// have an open popup/menu/panel window above the normal window layer.
    static func openPopupOwnerPIDs() -> Set<pid_t> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids: Set<pid_t> = []
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer >= 20,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.height > 45, rect.width > 45 else {
                continue
            }
            pids.insert(pid)
        }
        return pids
    }

    /// Whether `com.apple.controlcenter` currently has an open popup window on screen.
    static func isControlCenterPopupOpen() -> Bool {
        let ccPIDs: [pid_t]
        if Thread.isMainThread {
            ccPIDs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter")
                .map(\.processIdentifier)
        } else {
            ccPIDs = DispatchQueue.main.sync {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter")
                    .map(\.processIdentifier)
            }
        }
        guard let ccPID = ccPIDs.first else { return false }
        if openPopupOwnerPIDs().contains(ccPID) {
            return true
        }
        if !Thread.isMainThread && hasAccessibilityPermission {
            let ccApp = AXUIElementCreateApplication(ccPID)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(ccApp, kAXWindowsAttribute as CFString, &winRef) == .success,
               let wins = winRef as? [AXUIElement], !wins.isEmpty {
                return true
            }
        }
        return false
    }

    /// Whether the app identified by `bundleID` currently has an open menu/popover window.
    static func hasOpenPopupWindow(bundleID: String) -> Bool {
        let pids: [pid_t]
        if Thread.isMainThread {
            pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier)
        } else {
            pids = DispatchQueue.main.sync {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .map(\.processIdentifier)
            }
        }
        guard !pids.isEmpty else { return false }
        let openPIDs = openPopupOwnerPIDs()
        return pids.contains { openPIDs.contains($0) }
    }

    /// Whether the current mouse cursor location lies inside any open popup/menu window
    /// owned by another process (such as Control Center or a third-party menu bar app).
    static func isCurrentMouseInOpenPopupWindow() -> Bool {
        guard let mouse = CGEvent(source: nil)?.location else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer >= 20,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.height > 45, rect.width > 45 else {
                continue
            }
            if rect.contains(mouse) {
                return true
            }
        }
        return false
    }

    /// Closes an open Control Center popup window by clicking its status bar item
    /// and restoring the cursor position. (`AXPress` on `MenuBarAgent` only opens
    /// Control Center and does not toggle it closed.)
    @discardableResult
    static func dismissControlCenterPopup() -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        guard hasAccessibilityPermission, isControlCenterPopupOpen() else { return false }
        guard let ccFrame = findSystemItemFrame(identifier: "com.apple.menuextra.controlcenter"),
              ccFrame.width > 0, ccFrame.height > 0 else {
            return false
        }
        let savedMouse = CGEvent(source: nil)?.location
        let clickPoint = CGPoint(x: ccFrame.midX, y: ccFrame.midY)
        lastSyntheticClickAt = Date()
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: clickPoint, mouseButton: .left),
           let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: clickPoint, mouseButton: .left) {
            down.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        if let savedMouse {
            CGWarpMouseCursorPosition(savedMouse)
        }
        return true
    }

    private static func findSystemItemFrame(identifier: String) -> CGRect? {
        let targetCanonical = SystemItemName.canonicalIdentifier(for: identifier)
        let systemBundles: Set<String> = [
            "com.apple.MenuBarAgent",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
        ]
        let (pids, screens) = DispatchQueue.main.sync {
            (
                NSWorkspace.shared.runningApplications
                    .filter {
                        guard let bid = $0.bundleIdentifier, $0.processIdentifier > 0 else { return false }
                        return systemBundles.contains(bid)
                    }
                    .map(\.processIdentifier),
                displayFrames()
            )
        }
        let reader = AXReadBudget(seconds: 1.5, cancellation: AXScanCancellation())
        func matchesIdentifier(_ element: AXUIElement, depth: Int) -> Bool {
            let axID = try? AXReadBudget.optionalMetadata {
                try reader.string(element, kAXIdentifierAttribute as String)
            }
            if let axID, !axID.isEmpty,
               (axID == identifier || SystemItemName.canonicalIdentifier(for: axID) == targetCanonical) {
                return true
            }
            guard depth < 3, let children = try? reader.children(element) else { return false }
            return children.contains { matchesIdentifier($0, depth: depth + 1) }
        }
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let extras = try? reader.element(app, "AXExtrasMenuBar"),
                  let children = try? reader.children(extras) else { continue }
            for child in children {
                if let rect = try? frame(of: child, reader: reader),
                   rect.width > 0, rect.height > 0,
                   display(containing: rect, in: screens) != nil,
                   matchesIdentifier(child, depth: 0) {
                    return rect
                }
            }
        }
        return nil
    }

    /// Opens the native macOS UI for a Control Center or system item without
    /// suspending `MBAssessmentModeAssertion`.
    @discardableResult
    static func triggerControlCenterModule(for identifier: String,
                                           allowDirectStatusItemPress: Bool = false) -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)

        if let appPath = standaloneSystemApps[canonical] {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
            }
            return true
        }

        if canonical == "com.apple.menuextra.controlcenter" {
            return pressSystemItem(identifier: canonical)
        }

        if allowDirectStatusItemPress, pressSystemItem(identifier: canonical) {
            return true
        }

        guard hasAccessibilityPermission else { return false }
        let ccPID: pid_t? = DispatchQueue.main.sync {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter")
                .first?.processIdentifier
        }
        guard let ccPID else { return false }

        let ccApp = AXUIElementCreateApplication(ccPID)
        let targetSubstring = controlCenterModuleSubstrings[canonical]

        var winRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ccApp, kAXWindowsAttribute as CFString, &winRef)
        let existingWins = winRef as? [AXUIElement] ?? []
        if !existingWins.isEmpty {
            if let targetSubstring {
                for win in existingWins {
                    if findAndTriggerControlCenterElement(in: win, matching: targetSubstring) {
                        return true
                    }
                }
                // Control Center is already open on a different detail sub-sheet;
                // close it first so reopening brings up the main Control Center grid.
                _ = dismissControlCenterPopup()
                Thread.sleep(forTimeInterval: 0.14)
            } else {
                return true
            }
        }

        guard pressSystemItem(identifier: "com.apple.menuextra.controlcenter") else {
            return false
        }

        guard let targetSubstring else {
            // For items like NowPlaying or UserSwitcher that reside directly inside
            // Control Center's main sheet, opening Control Center is sufficient.
            return true
        }

        for _ in 0..<16 {
            var currentWinRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(ccApp, kAXWindowsAttribute as CFString, &currentWinRef) == .success,
               let wins = currentWinRef as? [AXUIElement], !wins.isEmpty {
                for win in wins {
                    if findAndTriggerControlCenterElement(in: win, matching: targetSubstring) {
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        return false
    }

    private static func findAndTriggerControlCenterElement(in element: AXUIElement,
                                                           matching substring: String,
                                                           depth: Int = 0) -> Bool {
        var idRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idRef) == .success,
           let idStr = idRef as? String,
           !idStr.hasSuffix("-slider"),
           idStr.contains(substring) {
            var actionsRef: CFArray?
            if AXUIElementCopyActionNames(element, &actionsRef) == .success,
               let actions = actionsRef as? [String],
               let detailAction = actions.first(where: { $0.hasPrefix("Name:") }) {
                if AXUIElementPerformAction(element, detailAction as CFString) == .success {
                    return true
                }
            }
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }
            if AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success {
                return true
            }
        }
        guard depth < 6 else { return false }
        var chRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &chRef) == .success,
              let children = chRef as? [AXUIElement] else {
            return false
        }
        for child in children {
            if findAndTriggerControlCenterElement(in: child, matching: substring, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func nestedIdentifier(in element: AXUIElement, depth: Int,
                                         reader: AXReadBudget) throws -> String? {
        if let id = try AXReadBudget.optionalMetadata({
            try reader.string(element, kAXIdentifierAttribute as String)
        }), !id.isEmpty {
            return id
        }
        guard depth < 3 else { return nil }
        let children: [AXUIElement]
        do {
            children = try reader.children(element)
        } catch AXScanFailure.readFailed(let code)
            where code == AXError.noValue.rawValue || code == AXError.attributeUnsupported.rawValue {
            return nil
        }
        for child in children {
            if let id = try nestedIdentifier(in: child, depth: depth + 1, reader: reader) {
                return id
            }
        }
        return nil
    }

    private static func nestedTelemetry(in element: AXUIElement, depth: Int,
                                        reader: AXReadBudget) throws -> RawAXItemTelemetry {
        guard depth < 2 else { return RawAXItemTelemetry() }
        let children: [AXUIElement]
        do {
            children = try reader.children(element)
        } catch AXScanFailure.readFailed(let code)
            where code == AXError.noValue.rawValue || code == AXError.attributeUnsupported.rawValue {
            return RawAXItemTelemetry()
        }
        var collectedValues: [String] = []
        var firstTitle: String?
        var firstDesc: String?
        for child in children.prefix(6) {
            let role = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXRoleAttribute as String)
            }
            if role == (kAXMenuRole as String) {
                continue
            }
            let t = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXTitleAttribute as String)
            }
            let d = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXDescriptionAttribute as String)
            }
            let v = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXValueAttribute as String)
            }
            if firstTitle == nil, let t, !t.isEmpty { firstTitle = t }
            if firstDesc == nil, let d, !d.isEmpty { firstDesc = d }
            if let v, !v.isEmpty, !collectedValues.contains(v) {
                collectedValues.append(v)
            }
            if firstTitle == nil && firstDesc == nil && collectedValues.isEmpty {
                let deeper = try nestedTelemetry(in: child, depth: depth + 1, reader: reader)
                if firstTitle == nil, let dt = deeper.title, !dt.isEmpty { firstTitle = dt }
                if firstDesc == nil, let dd = deeper.description, !dd.isEmpty { firstDesc = dd }
                if let dv = deeper.value, !dv.isEmpty, !collectedValues.contains(dv) {
                    collectedValues.append(dv)
                }
            }
        }
        let joinedValue = collectedValues.isEmpty ? nil : collectedValues.joined(separator: " · ")
        return RawAXItemTelemetry(title: firstTitle, description: firstDesc, value: joinedValue, help: nil)
    }

    private static func readOpenWindowTitles(from appElement: AXUIElement, reader: AXReadBudget) -> [String] {
        guard reader.failure == nil,
              let rawWins = try? reader.attribute(appElement, kAXWindowsAttribute as String, optional: true),
              let wins = rawWins as? [AXUIElement], !wins.isEmpty else {
            return []
        }
        var titles: [String] = []
        for win in wins.prefix(4) {
            guard reader.failure == nil else { break }
            if let subrole = try? reader.string(win, kAXSubroleAttribute as String),
               subrole == "AXSystemDialog" || subrole == "AXUnknown" {
                continue
            }
            if let t = (try? reader.string(win, kAXTitleAttribute as String))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                titles.append(t)
                if titles.count >= 3 { break }
            }
        }
        return titles
    }

    static func displayMenuBarGeometries() -> [DisplayMenuBarGeometry] {
        if !Thread.isMainThread { return DispatchQueue.main.sync { displayMenuBarGeometries() } }
        return NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            let cocoa = screen.frame
            let auxRight = screen.auxiliaryTopRightArea
            return DisplayMenuBarGeometry(
                displayID: id,
                screenMinX: cocoa.minX,
                screenMaxX: cocoa.maxX,
                auxiliaryTopRightMinX: auxRight?.minX,
                auxiliaryTopRightMaxX: auxRight?.maxX
            )
        }
    }

    static func measureFrontmostMenuBarWidth(pid: pid_t) -> CGFloat? {
        precondition(!Thread.isMainThread, "AX menu bar measurement must run off the main thread")
        guard hasAccessibilityPermission, pid > 0 else { return nil }
        let screens = DispatchQueue.main.sync { displayFrames() }
        let reader = AXReadBudget(seconds: 0.35, cancellation: AXScanCancellation())
        return measureMenuBarWidth(pid: pid, screens: screens, reader: reader)
    }

    private static func measureMenuBarWidth(pid: pid_t,
                                            screens: [(DisplayID, CGRect)],
                                            reader: AXReadBudget) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = try? reader.element(app, kAXMenuBarAttribute as String),
              let children = try? reader.children(menuBar),
              !children.isEmpty else {
            return nil
        }
        let rects: [CGRect] = children.prefix(24).compactMap { child in
            guard let rect = try? frame(of: child, reader: reader),
                  rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        return measureMenuBarEndOffset(itemFrames: rects, in: screens)
    }

    static func measureMenuBarEndOffset(itemFrames: [CGRect],
                                        in screens: [(DisplayID, CGRect)]) -> CGFloat? {
        guard !itemFrames.isEmpty, !screens.isEmpty else { return nil }
        var maxOffsetFromLeft: CGFloat = 0
        for rect in itemFrames {
            guard rect.minX.isFinite, rect.minY.isFinite,
                  rect.width > 0, rect.height > 0 else { continue }
            let midpoint = CGPoint(x: rect.midX, y: rect.midY)
            // Match both X and top-of-display Y band so vertically stacked multi-monitor
            // setups never confuse an upper/lower external display with the main display.
            guard let hostingScreen = screens.first(where: {
                $0.1.insetBy(dx: -4, dy: -8).contains(midpoint) && midpoint.y <= $0.1.minY + 64
            }) else {
                continue
            }
            let offset = rect.maxX - hostingScreen.1.minX
            if offset > maxOffsetFromLeft && offset < hostingScreen.1.width * 0.75 {
                maxOffsetFromLeft = offset
            }
        }
        return maxOffsetFromLeft > 40 ? maxOffsetFromLeft : nil
    }

    static func displayFrames() -> [(DisplayID, CGRect)] {
        guard let main = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            let cocoa = screen.frame
            return (id, CGRect(x: cocoa.minX, y: main.frame.maxY - cocoa.maxY,
                               width: cocoa.width, height: cocoa.height))
        }
    }

    static func display(containing frame: CGRect,
                        in screens: [(DisplayID, CGRect)]) -> DisplayID? {
        guard !screens.isEmpty,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return nil }
        let midpoint = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first {
            $0.1.contains(midpoint) && midpoint.y <= $0.1.minY + 60
        }?.0
    }

    private static func readMenuSnapshot(from statusItem: AXUIElement,
                                         statusItemIndex: Int,
                                         reader: AXReadBudget) throws -> [AXMenuSnapshotEntry] {
        guard let subChildren = try AXReadBudget.optionalValue({ try reader.children(statusItem) }),
              !subChildren.isEmpty else {
            return []
        }
        var rootMenu: AXUIElement?
        for child in subChildren.prefix(4) {
            let role = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXRoleAttribute as String)
            }
            if role == (kAXMenuRole as String) {
                rootMenu = child
                break
            }
        }
        guard let rootMenu else { return [] }
        return try readMenuEntries(
            from: rootMenu,
            statusItemIndex: statusItemIndex,
            parentIndexPath: [],
            parentTitlePath: [],
            depth: 0,
            reader: reader
        )
    }

    private static func readMenuEntries(from menuElement: AXUIElement,
                                        statusItemIndex: Int,
                                        parentIndexPath: [Int],
                                        parentTitlePath: [String],
                                        depth: Int,
                                        reader: AXReadBudget) throws -> [AXMenuSnapshotEntry] {
        guard reader.failure == nil else { return [] }
        guard let menuItems = try AXReadBudget.optionalValue({ try reader.children(menuElement) }),
              !menuItems.isEmpty else {
            return []
        }

        let scanLimit = (depth == 0) ? 20 : 16
        let keepLimit = (depth == 0) ? 14 : 12
        var entries: [AXMenuSnapshotEntry] = []

        for (menuIndex, itemElement) in menuItems.prefix(scanLimit).enumerated() {
            guard reader.failure == nil else { break }
            let rawTitle = try AXReadBudget.optionalMetadata {
                try reader.string(itemElement, kAXTitleAttribute as String)
            }
            guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                continue
            }
            let enabled = (try AXReadBudget.optionalValue {
                try reader.bool(itemElement, kAXEnabledAttribute as String)
            }) ?? true
            let mark = try AXReadBudget.optionalMetadata {
                try reader.string(itemElement, "AXMenuItemMarkChar")
            }
            let cmdChar = try AXReadBudget.optionalMetadata {
                try reader.string(itemElement, "AXMenuItemCmdChar")
            }
            let cmdMods = try AXReadBudget.optionalValue {
                try reader.int(itemElement, "AXMenuItemCmdModifiers")
            }
            let shortcut = formatMenuShortcut(cmdChar: cmdChar, modifiers: cmdMods)
            let currentIndexPath = parentIndexPath + [menuIndex]
            let currentTitlePath = parentTitlePath + [title]

            var childEntries: [AXMenuSnapshotEntry] = []
            if depth < 2,
               let itemChildren = try AXReadBudget.optionalValue({ try reader.children(itemElement) }),
               !itemChildren.isEmpty {
                for sub in itemChildren.prefix(3) {
                    let subRole = try AXReadBudget.optionalMetadata {
                        try reader.string(sub, kAXRoleAttribute as String)
                    }
                    if subRole == (kAXMenuRole as String) {
                        childEntries = try readMenuEntries(
                            from: sub,
                            statusItemIndex: statusItemIndex,
                            parentIndexPath: currentIndexPath,
                            parentTitlePath: currentTitlePath,
                            depth: depth + 1,
                            reader: reader
                        )
                        break
                    }
                }
            }

            entries.append(AXMenuSnapshotEntry(
                statusItemIndex: statusItemIndex,
                menuPath: currentIndexPath,
                titlePath: currentTitlePath,
                title: title,
                isEnabled: enabled,
                markChar: (mark?.isEmpty == false) ? mark : nil,
                shortcutHint: shortcut,
                children: childEntries
            ))
            if entries.count >= keepLimit {
                break
            }
        }
        return entries
    }

    private static func formatMenuShortcut(cmdChar: String?, modifiers: Int?) -> String? {
        guard let rawChar = cmdChar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawChar.isEmpty else {
            return nil
        }
        let mods = modifiers ?? 0
        var out = ""
        if (mods & (1 << 2)) != 0 { out += "⌃" }
        if (mods & (1 << 1)) != 0 { out += "⌥" }
        if (mods & (1 << 0)) != 0 { out += "⇧" }
        if (mods & (1 << 3)) == 0 { out += "⌘" }
        out += rawChar.uppercased()
        return out
    }

    private static func readDockBadges(dockPID: pid_t, reader: AXReadBudget) -> [String: String] {
        guard dockPID > 0 else { return [:] }
        let dockApp = AXUIElementCreateApplication(dockPID)
        guard let lists = try? reader.children(dockApp) else { return [:] }
        var badges: [String: String] = [:]
        for list in lists.prefix(3) {
            guard let dockItems = try? reader.children(list) else { continue }
            for dockItem in dockItems.prefix(48) {
                guard reader.failure == nil else { return badges }
                guard let status = (try? reader.string(dockItem, "AXStatusLabel"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !status.isEmpty else {
                    continue
                }
                if let rawURL = try? reader.attribute(dockItem, kAXURLAttribute as String, optional: true) {
                    let resolvedURL: URL?
                    if let url = rawURL as? URL {
                        resolvedURL = url
                    } else if let str = rawURL as? String {
                        resolvedURL = URL(string: str)
                    } else {
                        resolvedURL = nil
                    }
                    if let url = resolvedURL,
                       let bundleID = Bundle(url: url)?.bundleIdentifier,
                       !bundleID.isEmpty {
                        badges[bundleID] = status
                    }
                }
            }
        }
        return badges
    }

    /// Invokes a root or nested `NSMenuItem` inside an application's status item `AXMenu`
    /// directly via `kAXPressAction` / `AXPick` without opening or flashing the top menu bar.
    @discardableResult
    static func performTunneledMenuAction(bundleID: String,
                                          statusItemIndex: Int,
                                          menuPath: [Int],
                                          titlePath: [String]) -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        guard hasAccessibilityPermission, (!menuPath.isEmpty || !titlePath.isEmpty) else { return false }
        let pids: [pid_t] = DispatchQueue.main.sync {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier)
                .filter { $0 > 0 }
        }
        guard !pids.isEmpty else { return false }
        let reader = AXReadBudget(seconds: 1.2, cancellation: AXScanCancellation())
        let depthCount = max(menuPath.count, titlePath.count)

        func findChildMenu(in parent: AXUIElement) -> AXUIElement? {
            guard let children = try? reader.children(parent) else { return nil }
            for child in children.prefix(4) {
                let role = try? reader.string(child, kAXRoleAttribute as String)
                if role == (kAXMenuRole as String) {
                    return child
                }
            }
            return nil
        }

        func resolveMenuItem(in menu: AXUIElement, expectedTitle: String?, fallbackIndex: Int?) -> AXUIElement? {
            guard let menuItems = try? reader.children(menu), !menuItems.isEmpty else { return nil }
            if let expectedTitle, !expectedTitle.isEmpty {
                if let exact = menuItems.first(where: { el in
                    let t = (try? reader.string(el, kAXTitleAttribute as String))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return t == expectedTitle
                }) {
                    return exact
                }
            }
            if let fallbackIndex, menuItems.indices.contains(fallbackIndex) {
                let candidate = menuItems[fallbackIndex]
                if let expectedTitle, !expectedTitle.isEmpty {
                    if let t = (try? reader.string(candidate, kAXTitleAttribute as String))?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty,
                       t.localizedCaseInsensitiveContains(String(expectedTitle.prefix(min(4, expectedTitle.count)))) {
                        return candidate
                    }
                } else {
                    return candidate
                }
            }
            return nil
        }

        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let extras = try? reader.element(app, "AXExtrasMenuBar"),
                  let statusItems = try? reader.children(extras),
                  !statusItems.isEmpty else {
                continue
            }
            let orderedIndices: [Int]
            if statusItems.indices.contains(statusItemIndex) {
                orderedIndices = [statusItemIndex] + statusItems.indices.filter { $0 != statusItemIndex }
            } else {
                orderedIndices = Array(statusItems.indices)
            }

            for idx in orderedIndices {
                guard var currentMenu = findChildMenu(in: statusItems[idx]) else { continue }
                var targetItem: AXUIElement?

                for level in 0..<depthCount {
                    let expected = (level < titlePath.count) ? titlePath[level] : nil
                    let idxHint = (level < menuPath.count) ? menuPath[level] : nil
                    guard let matched = resolveMenuItem(in: currentMenu, expectedTitle: expected, fallbackIndex: idxHint) else {
                        targetItem = nil
                        break
                    }
                    if level == depthCount - 1 {
                        targetItem = matched
                    } else {
                        guard let nextMenu = findChildMenu(in: matched) else {
                            targetItem = nil
                            break
                        }
                        currentMenu = nextMenu
                    }
                }

                if let targetItem {
                    AXUIElementSetMessagingTimeout(targetItem, 0.5)
                    if AXUIElementPerformAction(targetItem, kAXPressAction as CFString) == .success {
                        return true
                    }
                    if AXUIElementPerformAction(targetItem, "AXPick" as CFString) == .success {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Raises and focuses a specific window (or the main window) of `bundleID` via Accessibility.
    @discardableResult
    static func raiseApplicationWindow(bundleID: String, matchingTitle: String? = nil) -> Bool {
        precondition(!Thread.isMainThread, "AX action must run off the main thread")
        guard hasAccessibilityPermission else { return false }
        let pids: [pid_t] = DispatchQueue.main.sync {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier)
                .filter { $0 > 0 }
        }
        guard !pids.isEmpty else { return false }
        let reader = AXReadBudget(seconds: 0.9, cancellation: AXScanCancellation())
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let rawWins = try? reader.attribute(app, kAXWindowsAttribute as String, optional: true),
                  let wins = rawWins as? [AXUIElement], !wins.isEmpty else {
                continue
            }
            let targetWin: AXUIElement?
            if let matchingTitle, !matchingTitle.isEmpty {
                targetWin = wins.first(where: { win in
                    let t = (try? reader.string(win, kAXTitleAttribute as String))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return t == matchingTitle || (t?.localizedCaseInsensitiveContains(matchingTitle) == true)
                }) ?? wins.first
            } else {
                targetWin = wins.first
            }
            if let win = targetWin {
                AXUIElementSetMessagingTimeout(win, 0.4)
                _ = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                _ = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                if AXUIElementPerformAction(win, kAXRaiseAction as CFString) == .success {
                    return true
                }
            }
        }
        return false
    }

    private static func frame(of element: AXUIElement, reader: AXReadBudget) throws -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = try reader.attribute(element, kAXPositionAttribute as String),
              CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              let dimensions = try reader.attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(dimensions) == AXValueGetTypeID(),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size) else {
            throw AXScanFailure.unavailable
        }
        return CGRect(origin: origin, size: size)
    }
}
