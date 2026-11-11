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
}

struct ItemScanApplication {
    let pid: pid_t
    let bundleID: String
}

struct ItemScanContext {
    let applications: [ItemScanApplication]
    let screens: [(DisplayID, CGRect)]
    let permissionGranted: Bool
}

struct ItemScanResult {
    var items: [MenuBarItem] = []
    var failedOwners: Set<String> = []
    var completedOwners: Set<String> = []
    var visibleSystemItems: Set<String> = []
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
        if !failedOwners.isEmpty { return "部分应用的菜单栏暂时无法读取。" }
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
        return ItemScanContext(applications: NSWorkspace.shared.runningApplications.compactMap {
            guard $0.processIdentifier > 0, let bundleID = $0.bundleIdentifier else { return nil }
            return ItemScanApplication(pid: $0.processIdentifier, bundleID: bundleID)
        }, screens: displayFrames(), permissionGranted: hasAccessibilityPermission)
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
                    if (title == nil || title?.isEmpty == true) && (desc == nil || desc?.isEmpty == true),
                       application.bundleID == "com.apple.MenuBarAgent" {
                        let nested = try nestedTelemetry(in: child, depth: 0, reader: reader)
                        if title == nil || title?.isEmpty == true { title = nested.title }
                        if desc == nil || desc?.isEmpty == true { desc = nested.description }
                        if val == nil || val?.isEmpty == true { val = nested.value }
                    }
                    let nonEmptyTitle = (title?.isEmpty == false) ? title : nil
                    let nonEmptyDesc = (desc?.isEmpty == false) ? desc : nil
                    let label = nonEmptyTitle ?? nonEmptyDesc
                    appItems.append(MenuBarItem(ownerBundleID: application.bundleID,
                        ownerPID: application.pid, frame: frame, display: display,
                        axIdentifier: identifier, label: label,
                        indexInApp: index,
                        axTitle: nonEmptyTitle,
                        axDescription: nonEmptyDesc,
                        axValue: (val?.isEmpty == false) ? val : nil,
                        axHelp: (help?.isEmpty == false) ? help : nil))
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

    /// Triggers a status item owned by `bundleID` via Accessibility (`AXPress` / `AXShowMenu`).
    @discardableResult
    static func pressStatusItem(bundleID: String) -> Bool {
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
            for child in children {
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
        for child in children.prefix(4) {
            let t = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXTitleAttribute as String)
            }
            let d = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXDescriptionAttribute as String)
            }
            let v = try AXReadBudget.optionalMetadata {
                try reader.string(child, kAXValueAttribute as String)
            }
            if (t?.isEmpty == false) || (d?.isEmpty == false) || (v?.isEmpty == false) {
                return RawAXItemTelemetry(title: t, description: d, value: v, help: nil)
            }
            let deeper = try nestedTelemetry(in: child, depth: depth + 1, reader: reader)
            if (deeper.title?.isEmpty == false) || (deeper.description?.isEmpty == false) || (deeper.value?.isEmpty == false) {
                return deeper
            }
        }
        return RawAXItemTelemetry()
    }

    private static func displayFrames() -> [(DisplayID, CGRect)] {
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
