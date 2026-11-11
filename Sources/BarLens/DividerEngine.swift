import AppKit
import CMenuBarPrivate   // only to report whether the private API exists
import DividerIPC
import SwiftUI

/// Owns the section model and tells the helper what allow list to assert.
///
/// This process deliberately never holds the restriction itself. The helper
/// does, so a mistake here cannot leave icons hidden after a crash, and so the
/// assertion outlives any UI teardown. All this side does is decide the list
/// and write it to the command file.
///
/// The invariant that matters: the restriction is bound to the helper's XPC
/// connection, so if either process dies, every hidden item comes back.
final class DividerEngine: ObservableObject {

    @Published private(set) var model = SectionModel.load()
    @Published private(set) var reveal: SectionModel.Reveal = .none
    @Published private(set) var lastError: String?
    @Published private(set) var isRecovering = false
    @Published private(set) var connectionError: String?
    @Published private(set) var lastRecoveryAt: Date?
    @Published private(set) var lastRecoveryDuration: TimeInterval?
    @Published private(set) var lastRecoveryReason: String?
    @Published private(set) var nextRetryAt: Date?
    @Published private(set) var lastExitReason: String?
    @Published private(set) var hasAccessibility = ItemEnumerator.hasAccessibilityPermission
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    /// Whether the always-hidden section is in use at all. Off by default is
    /// tempting, but it is on by default because the section only matters once
    /// the user has decided what belongs in it.
    @Published private(set) var alwaysHiddenEnabled = Defaults.alwaysHiddenEnabled
    /// How long revealed hidden sections stay open before automatically collapsing.
    @Published private(set) var autoRehideInterval = Defaults.autoRehideInterval
    /// Optional hover dwell time over the menu bar trigger icon to automatically reveal hidden items.
    @Published private(set) var hoverRevealDelay = Defaults.hoverRevealDelay
    /// User-customized item ordering inside the second-row floating bar.
    @Published private(set) var floatingBarOrder = Defaults.floatingBarOrder
    /// Whether revealing shows items inline in the menu bar or in a floating bar below the dot.
    @Published private(set) var revealPresentationStyle = Defaults.revealPresentationStyle
    @Published private(set) var floatingBarIconStyle = Defaults.floatingBarIconStyle
    @Published private(set) var statusBarIconStyle = Defaults.statusBarIconStyle
    @Published private(set) var appearanceMode = Defaults.appearanceMode
    @Published private(set) var systemIsDark: Bool = DividerEngine.readSystemIsDark()
    @Published private(set) var appLanguage = Defaults.appLanguage
    @Published private(set) var glassOpacity = Defaults.glassOpacity
    @Published private(set) var rimIntensity = Defaults.rimIntensity
    @Published private(set) var lensTelemetryEnabled = Defaults.lensTelemetryEnabled
    @Published private(set) var systemTelemetryRevision = 0
    @Published private(set) var spatialBudgetPolicy = Defaults.spatialBudgetPolicy
    @Published private(set) var spatialExemptBundleIDs = Defaults.spatialExemptBundleIDs
    @Published private(set) var overflowDemotedBundleIDs: Set<String> = []
    @Published private(set) var overflowDemotionReasons: [String: SpatialDemotionReason] = [:]
    @Published private(set) var pinnedBundleID: String?
    @Published private(set) var pinnedSystemItemRawValue: Int?
    /// Where an application goes before the user has classified it.
    @Published private(set) var unclassifiedSection = Defaults.unclassifiedSection
    /// Where a built-in item goes the moment a scan records it.
    @Published private(set) var newSystemItemSection = Defaults.newSystemItemSection
    @Published private(set) var bindings: [HotkeyAction: Hotkey] = Defaults.hotkeys
    /// Which section each built-in item — Wi-Fi, battery, clock, Control Center, Focus Mode —
    /// belongs to.
    @Published private(set) var systemItems = SystemItemModel.load()
    @Published private(set) var systemItemModes: [String: ControlCenterShowMode] = MenuBarBuiltIns.controlCenterModes()
    private var liveVisibleSystemItemIDs: Set<String> = []
    private var systemAXTelemetryByID: [String: LensTelemetry] = [:]
    private var lastMeasuredWidthByBundleID: [String: CGFloat] = [:]
    private var lastMeasuredMinXByBundleID: [String: CGFloat] = [:]
    private var latestDisplayGeometries: [DisplayMenuBarGeometry] = []
    private var latestFrontmostMenuWidth: CGFloat?
    private var activeDotDisplayID: DisplayID?
    private var fixedSystemBarWidth: CGFloat = 140
    private var itemLastInteractedAt: [String: TimeInterval] = Defaults.itemLastInteractedAt
    private var frontmostMenuCheckWork: DispatchWorkItem?
    private var distributedObserver: NSObjectProtocol?
    private var themeDistributedObserver: NSObjectProtocol?
    private var appearanceKVO: NSKeyValueObservation?

    static func readSystemIsDark() -> Bool {
        if let app = NSApp {
            return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    var effectiveColorScheme: ColorScheme {
        appearanceMode.resolvedColorScheme(systemIsDark: systemIsDark)
    }

    var effectiveNSAppearance: NSAppearance {
        appearanceMode.resolvedNSAppearance(systemIsDark: systemIsDark)
    }

    func refreshSystemAppearance() {
        let isDark = Self.readSystemIsDark()
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        if appearanceMode == .system {
            onChange?()
        }
    }

    func isSystemItemActive(_ item: SystemItem) -> Bool {
        let mode = systemItemModes[item.identifier] ?? .disabled
        switch mode {
        case .alwaysShow:
            return true
        case .showWhenActive:
            if item.identifier == "com.apple.menuextra.display", NSScreen.screens.count > 1 {
                return true
            }
            if item.identifier == "com.apple.menuextra.screen-mirroring",
               CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0 {
                return true
            }
            return liveVisibleSystemItemIDs.contains(item.identifier)
        case .disabled:
            return liveVisibleSystemItemIDs.contains(item.identifier)
        }
    }

    var unavailableSystemItemIDs: Set<String> {
        Set(systemItems.items.filter { !isSystemItemActive($0) }.map(\.identifier))
    }

    var activeSystemItems: [SystemItem] {
        systemItems.items.filter { isSystemItemActive($0) }
    }

    /// Items shown in Settings → 系统图标: includes both `始终显示` items and
    /// `启用时显示` items checked in System Settings → Menu Bar.
    var settingsSystemItems: [SystemItem] {
        systemItems.items.filter { item in
            let mode = systemItemModes[item.identifier] ?? .disabled
            return mode != .disabled || liveVisibleSystemItemIDs.contains(item.identifier)
        }
    }

    /// Non-addressable Control Center items (such as `专注模式`) that should be
    /// rendered on the top menu bar by `DividerController` while `MBAssessmentModeAssertion`
    /// is active (which suppresses `ControlCenter.app`'s own status item for them).
    var topBarProxySystemItems: [SystemItem] {
        guard currentCommand?.mode == .apply else { return [] }
        let barReveal: SectionModel.Reveal = (revealPresentationStyle == .floatingBar) ? .none : reveal
        return activeSystemItems.filter { item in
            guard !item.isAddressableByAssessment else { return false }
            // Items backed by their own system process (such as Time Machine in
            // SystemUIServer or TextInputMenuAgent) display their native icon directly
            // when their host bundle is admitted in `allowed`.
            if item.pressableHostBundleID != nil { return false }
            if !item.hostBundleIDs.isEmpty,
               item.hostBundleIDs.contains(where: { itemScanState.owners.contains($0) }) {
                return false
            }
            return !systemItems.isItemSuppressedOnBar(item,
                                                      reveal: barReveal,
                                                      alwaysHiddenEnabled: alwaysHiddenEnabled)
        }
    }

    func refreshControlCenterModes() {
        let updated = MenuBarBuiltIns.controlCenterModes()
        if updated != systemItemModes {
            for (id, mode) in updated where systemItemModes[id] != mode && mode != .alwaysShow {
                liveVisibleSystemItemIDs.remove(id)
            }
            systemItemModes = updated
            catalogRevision += 1
            apply()
            onChange?()
        }
    }

    private let hotkeyRegistry = HotkeyRegistry()
    /// Bumped whenever the set of apps on the bar may have changed, so the
    /// settings list knows to rebuild.
    @Published private(set) var catalogRevision = 0

    /// Cached because `NSWorkspace.runningApplications` is a LaunchServices
    /// query, and `apply()` can run while a menu is closing — the query was
    /// long enough to visibly stutter that animation. Refreshed from the
    /// workspace notifications instead of on every apply.
    private var runningBundleIDs: Set<String> = []
    /// Several workspace notifications can arrive while an Accessibility scan
    /// is running. Only the newest scan may replace the catalog.
    private var itemScanGeneration = 0

    private var currentCommand: AgentCommand?
    private var heartbeat: Timer?
    private var permissionTimer: Timer?
    private var isMeasuring = false
    private let agent = AgentLauncher()
    private let sessionID = UUID().uuidString
    private var isStarted = false
    private var isSleeping = false
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var recoveryWork: DispatchWorkItem?
    private var autoRehideWork: DispatchWorkItem?
    private var pinnedExpireWork: DispatchWorkItem?
    private var popupWatchWork: DispatchWorkItem?
    private var pressGeneration = 0
    @Published private(set) var lastActivatedTargetID: String?
    private var lastActivatedFromFloatingBar = false

    func isFloatingBarTargetActive(itemID: String, systemItem: SystemItem? = nil) -> Bool {
        guard let active = lastActivatedTargetID else { return false }
        if active == itemID { return true }
        if let host = systemItem?.pressableHostBundleID, active == "app:\(host)" {
            return true
        }
        return false
    }
    private var lastPopupObservedOpenAt: Date = .distantPast
    private var wasControlCenterOpenAtMouseDown = false
    private var openPopupPIDsAtMouseDown: Set<pid_t> = []
    private var lastLocalMouseDownAt: Date = .distantPast
    private var localMouseDownMonitor: Any?
    private(set) var lastMonitorDismissedRevealAt: Date = .distantPast
    var isQuickPanelOpen = false {
        didSet {
            if isQuickPanelOpen != oldValue { scheduleAutoRehideIfNeeded() }
        }
    }
    var isFloatingBarHovered = false {
        didSet {
            if isFloatingBarHovered != oldValue { scheduleAutoRehideIfNeeded() }
        }
    }
    var isLensLoupeHovered = false {
        didSet {
            if isLensLoupeHovered != oldValue { scheduleAutoRehideIfNeeded() }
        }
    }
    var isContextMenuOpen = false {
        didSet {
            if isContextMenuOpen != oldValue { scheduleAutoRehideIfNeeded() }
        }
    }
    /// Optional programmatic navigation target for `SettingsView`.
    @Published var requestedSettingsPane: SettingsPane?
    /// Optional hook set by `DividerController` to present the interactive onboarding tour.
    var onReplayOnboarding: (() -> Void)?
    private var lastAgentStart = Date.distantPast
    private var lastMenuBarAgentPID: pid_t?
    private var operationGeneration = 0
    private var scanInterrupted: (() -> Void)?
    private let diagnosticLog = DiagnosticLog(source: .app)
    private var recoveryStartedAt: Date?
    private var recoveryStartedUptime: TimeInterval?
    private var recoveryReason = tr("启动", "Startup")
    private var lastAcknowledgedRequest: String?
    private var reportedAgentError: String?
    private var reportedWriteError: String?

    /// Fired on the main queue whenever something the menu displays changes.
    var onChange: (() -> Void)?

    /// Long enough for the helper's 0.15s poll plus MenuBarAgent settling the
    /// layout. This gap is the flicker the re-measure is allowed to cause.
    private let settleDelay: TimeInterval = 1.1

    var visibleCount: Int { assignedCount(in: .visible) }
    var alwaysHiddenCount: Int { assignedCount(in: .alwaysHidden) }
    var revealableCount: Int { assignedCount(in: .hidden) }
    var tuckedOverflowCount: Int { overflowDemotedBundleIDs.count }
    var currentHiddenCount: Int { reveal == .none ? (revealableCount + tuckedOverflowCount) : 0 }

    /// Counts follow effective sections for items actually present on the menu bar.
    private func assignedCount(in section: SectionModel.Section) -> Int {
        func effective(_ value: SectionModel.Section) -> SectionModel.Section {
            !alwaysHiddenEnabled && value == .alwaysHidden ? .hidden : value
        }
        let owners = bundlesWithItems
            .subtracting(SectionModel.ownIdentifiers)
            .subtracting(SectionModel.notClassifiable)
        return owners.filter { effective(model.section(of: $0)) == section }.count
            + activeSystemItems.filter { effective(systemItems.section(of: $0)) == section }.count
    }

    /// Whether there is anything for the current rules to hide.
    ///
    /// Load-bearing beyond its name: this is also what keeps
    /// `unclassifiedSection` from firing on a fresh install. The default is not
    /// an assignment, so a user who has never classified anything lands here,
    /// the agent stays suspended, and no restriction is asserted — which is the
    /// whole reason a default of "永久隐藏" is safe to offer.
    var isConfigured: Bool {
        let hasConfiguredSystemItems = activeSystemItems.contains { systemItems.section(of: $0) != .visible }
        if !model.hidden.isEmpty || !model.alwaysHidden.isEmpty || !model.visible.isEmpty
            || hasConfiguredSystemItems {
            return true
        }

        // Defaults are preferences rather than assignments. A fresh install
        // with no discovered items remains suspended, but once a scan finds a
        // target a non-visible default is a real rule and must be applied.
        let defaultableApps = bundlesWithItems
            .subtracting(SectionModel.ownIdentifiers)
            .subtracting(SectionModel.notClassifiable)
        let hasDefaultedApps = model.unclassified != .visible && !defaultableApps.isEmpty
        let hasDefaultedSystemItems = systemItems.unassigned != .visible
            && !activeSystemItems.isEmpty
        return hasDefaultedApps || hasDefaultedSystemItems
    }

    /// Whether the app is somewhere LaunchServices recognises as installed.
    ///
    /// Not cosmetic: MenuBarAgent files status items under the owning app's
    /// bundle identifier only for installed apps, and looks them up that way
    /// while a restriction is active. Run from anywhere else and this app's own
    /// dot is silently left out of the bar, with no error anywhere to explain it.
    var isInstalledCorrectly: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        AgentCommand.cleanupStaleTempFiles()
        beginRecovery(reason: tr("启动", "Startup"))
        diagnosticLog.record(event: "app_started", details: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "pid": String(ProcessInfo.processInfo.processIdentifier)])
        agent.onFailure = { [weak self] message in
            guard let self else { return }
            self.connectionError = message
            self.isRecovering = false
            self.nextRetryAt = self.agent.nextRetryAt
            self.onChange?()
        }
        agent.onStarted = { [weak self] _ in
            guard let self else { return }
            self.lastAgentStart = Date()
            self.nextRetryAt = nil
            self.isRecovering = true
            self.onChange?()
        }
        agent.onExit = { [weak self] exit in
            guard let self else { return }
            self.lastExitReason = (exit.expected ? tr("计划内退出 · ", "Expected exit · ") : "") + exit.description
            guard self.isStarted, !self.isSleeping, !exit.expected else { return }
            self.beginRecovery(reason: tr("助手意外退出", "Helper exited unexpectedly"))
            self.connectionError = exit.description
            self.isRecovering = false
            self.nextRetryAt = exit.retryAt
            self.onChange?()
        }
        observeLifecycle()
        refreshSystemAppearance()
        // Write before launching: an old command can be stale after sleep or
        // a previous app exit, and must never kill the brand new helper.
        send(AgentCommand(mode: .suspend, allowed: []))
        ensureAgentIsHealthy()
        refreshRunningApplications()
        startHeartbeat()
        startPermissionPolling()
        startHotkeys()
    }

    /// Bundles that currently own an item the Accessibility tree can see.
    ///
    /// The unclassified default must not reach beyond this set. A status item
    /// that AX does not publish cannot be listed, so it cannot be given an
    /// explicit section either — hide it and the user is left with a missing
    /// icon and nothing to click to get it back. Little Snitch's agent is
    /// exactly that: its `AXExtrasMenuBar` answers `kAXErrorNoValue` every
    /// time, and it was being hidden by the default with no row to undo it.
    ///
    /// Refreshed off the main thread; `refreshRunningApplications` is called on
    /// every app launch, and this sweep is the same one `Catalog` exists to keep
    /// off the main thread.
    private(set) var bundlesWithItems: Set<String> = []

    /// Owners only the system's bookkeeping knows about, minus the ones
    /// Accessibility already reports.
    ///
    /// Non-empty only with Full Disk Access. These are the Little Snitch case:
    /// an app whose item exists, whose icon System Settings will happily list,
    /// and which no AX query can see. Kept separately from `bundlesWithItems`
    /// so the list can say *why* a row is there.
    private(set) var ledgerOnlyOwners: Set<String> = []

    /// Whether the system ledger could be read at all.
    @Published private(set) var hasSystemLedger = false

    private let itemScanQueue = DispatchQueue(label: "BarLens.items", qos: .utility)
    private let bulkScanQueue = DispatchQueue(label: "BarLens.bulk", qos: .userInitiated)
    private var itemScanCancellation: AXScanCancellation?
    private var itemScanRetry: DispatchWorkItem?
    private var bulkScanCancellation: AXScanCancellation?
    private var itemScanState = MenuBarScanState()
    private var retainedScanItems: [MenuBarItem] = []
    private(set) var latestScanItems: [MenuBarItem]?
    private var trustedLedgerOwners: Set<String> = []
    @Published private(set) var scanWarning: String?

    func refreshRunningApplications() {
        guard isStarted, !isSleeping else { return }
        itemScanCancellation?.cancel()
        itemScanRetry?.cancel()
        itemScanRetry = nil
        itemScanGeneration += 1
        let applications = NSWorkspace.shared.runningApplications
        runningBundleIDs = Set(applications.compactMap(\.bundleIdentifier))
        let menuBarPID = applications.first { $0.bundleIdentifier == "com.apple.MenuBarAgent" }?.processIdentifier
        if let previous = lastMenuBarAgentPID, menuBarPID != previous, isStarted {
            scheduleRecovery()
        }
        lastMenuBarAgentPID = menuBarPID
        startItemScan(generation: itemScanGeneration, attempt: 0)
    }

    /// Stop and sleep invalidate queued work as well as its completion. A
    /// stale scan can consume at most one AX call before noticing cancellation.
    private func cancelItemScanWork() {
        itemScanGeneration += 1
        itemScanState.resetAbsenceConfirmation()
        itemScanCancellation?.cancel()
        itemScanCancellation = nil
        itemScanRetry?.cancel()
        itemScanRetry = nil
        cancelBulkScanWork()
    }

    private func cancelBulkScanWork() {
        bulkScanCancellation?.cancel()
        bulkScanCancellation = nil
    }

    private func startItemScan(generation: Int, attempt: Int) {
        guard isStarted, !isSleeping, generation == itemScanGeneration else { return }
        let context = ItemEnumerator.captureContext()
        let cancellation = AXScanCancellation()
        itemScanCancellation = cancellation
        let knownOwners = itemScanState.owners
        itemScanQueue.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            let result = ItemEnumerator.scan(context: context, knownOwners: knownOwners,
                                             cancellation: cancellation)
            guard !cancellation.isCancelled else { return }
            let ledger = MenuBarLedger.ownerBundleIDs()
            DispatchQueue.main.async {
                guard let self, !cancellation.isCancelled, self.isStarted, !self.isSleeping,
                      generation == self.itemScanGeneration else { return }
                let needsRetry = self.itemScanState.accept(result, running: self.runningBundleIDs)
                if result.permissionGranted, !result.cancelled {
                    let freshItems = result.items.filter { self.itemScanState.owners.contains($0.ownerBundleID) }
                    let freshOwners = Set(freshItems.map(\.ownerBundleID))
                    let keptItems = self.retainedScanItems.filter {
                        self.itemScanState.owners.contains($0.ownerBundleID)
                            && !freshOwners.contains($0.ownerBundleID)
                    }
                    self.retainedScanItems = keptItems + freshItems
                    self.latestScanItems = self.retainedScanItems
                    self.updateSystemAXTelemetry(from: result.items)
                    self.updateSpatialMeasurements(context: context, result: result)
                }
                let disabledInSystem = MenuBarLedger.disabledBundleIDs()
                self.hasSystemLedger = ledger != nil
                if let ledger { self.trustedLedgerOwners = ledger.intersection(self.runningBundleIDs) }
                else { self.trustedLedgerOwners.formIntersection(self.runningBundleIDs) }
                // Only treat apps with a real, live Accessibility status item on the
                // menu bar as active menu bar items. Historical entries in the system
                // plist ledger include apps whose menu bar icon was turned off in the
                // app's own settings or background helper processes with no icon.
                self.ledgerOnlyOwners = []
                self.bundlesWithItems = self.itemScanState.owners.subtracting(disabledInSystem)
                self.systemItemModes = MenuBarBuiltIns.controlCenterModes()
                if result.completedOwners.contains("com.apple.MenuBarAgent") {
                    let isRestrictionActive = (self.currentCommand?.mode == .apply)
                    let hiddenByUs: Set<Int> = isRestrictionActive
                        ? Set(self.currentCommand?.hiddenSystemItems ?? [])
                        : []
                    var visible = result.visibleSystemItems
                    for item in self.systemItems.items where self.liveVisibleSystemItemIDs.contains(item.identifier) {
                        let mode = self.systemItemModes[item.identifier] ?? .disabled
                        guard mode != .disabled else { continue }
                        if item.isAddressableByAssessment && hiddenByUs.contains(item.rawValue) {
                            visible.insert(item.identifier)
                        } else if !item.isAddressableByAssessment && isRestrictionActive {
                            visible.insert(item.identifier)
                        }
                    }
                    self.liveVisibleSystemItemIDs = visible
                }
                self.apply()
                self.catalogRevision += 1
                self.onChange?()

                if !result.permissionGranted {
                    self.scanWarning = tr(
                        "辅助功能权限不可用，已保留上次识别的分区。",
                        "Accessibility permission unavailable; keeping previous section state."
                    )
                    return
                }
                guard needsRetry else {
                    self.scanWarning = nil
                    self.diagnosticLog.record(event: attempt > 0 ? "catalog_scan_recovered" : "catalog_scan_completed", details: [
                        "attempt": String(attempt + 1), "ownerCount": String(self.bundlesWithItems.count),
                        "unobservedCount": String(result.unobservedOwners.count)])
                    return
                }
                let maximumRetries = 3
                self.scanWarning = attempt < maximumRetries
                    ? tr("菜单栏尚未读取完整，保留上次结果并自动重试。", "Menu bar scan incomplete; keeping previous state and retrying.")
                    : tr("部分菜单栏暂时读不到，已保留上次结果；可稍后刷新。", "Some menu bar items could not be read; keeping previous state.")
                self.diagnosticLog.record(event: "catalog_scan_incomplete", details: [
                    "attempt": String(attempt + 1), "failedCount": String(result.failedOwners.count),
                    "failureSummary": result.failureSummary,
                    "timedOut": String(result.timedOut), "retainedCount": String(self.bundlesWithItems.count)])
                guard attempt < maximumRetries else { return }
                let retry = DispatchWorkItem { [weak self] in
                    self?.startItemScan(generation: generation, attempt: attempt + 1)
                }
                self.itemScanRetry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(attempt)), execute: retry)
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        diagnosticLog.record(event: "app_stopping")
        isStarted = false
        recoveryWork?.cancel()
        recoveryWork = nil
        autoRehideWork?.cancel()
        autoRehideWork = nil
        pinnedExpireWork?.cancel()
        pinnedExpireWork = nil
        popupWatchWork?.cancel()
        popupWatchWork = nil
        frontmostMenuCheckWork?.cancel()
        frontmostMenuCheckWork = nil
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        for (center, observer) in lifecycleObservers { center.removeObserver(observer) }
        lifecycleObservers.removeAll()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
        if let themeDistributedObserver {
            DistributedNotificationCenter.default().removeObserver(themeDistributedObserver)
            self.themeDistributedObserver = nil
        }
        appearanceKVO?.invalidate()
        appearanceKVO = nil
        interruptMeasurements()
        cancelItemScanWork()
        stopHeartbeat()
        send(AgentCommand(mode: .stop, allowed: []))
        agent.stop()
    }

    /// Rebuild the helper's system connection without losing any assignments.
    func recoverConnection() {
        recoverConnection(reason: tr("手动重连", "Manual reconnect"), resetBackoff: true)
    }

    private func recoverConnection(reason: String, resetBackoff: Bool = false) {
        guard isStarted, !isSleeping else { return }
        recoveryWork?.cancel()
        recoveryWork = nil
        interruptMeasurements()
        if resetBackoff { recoveryStartedAt = nil; recoveryStartedUptime = nil }
        beginRecovery(reason: reason)
        isRecovering = true
        connectionError = nil
        nextRetryAt = nil
        refreshRunningApplications()
        apply()
        guard writeCurrentCommand() else { return }
        lastAgentStart = Date()
        diagnosticLog.record(event: "recovery_requested", details: [
            "reason": reason, "previousPID": agent.processID.map(String.init) ?? "none"])
        agent.restart(resetBackoff: resetBackoff)
        nextRetryAt = agent.nextRetryAt
        if nextRetryAt != nil, !agent.isRunning { isRecovering = false }
        onChange?()
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name,
                     action: @escaping () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
            lifecycleObservers.append((center, token))
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            self.isSleeping = true
            self.diagnosticLog.record(event: "system_will_sleep")
            self.recoveryStartedAt = nil
            self.recoveryStartedUptime = nil
            self.recoveryWork?.cancel()
            self.recoveryWork = nil
            self.autoRehideWork?.cancel()
            self.autoRehideWork = nil
            self.interruptMeasurements()
            self.cancelItemScanWork()
            self.agent.stop()
        }
        let wakeNotifications: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, tr("系统唤醒", "System wake")),
            (NSWorkspace.screensDidWakeNotification, tr("屏幕唤醒", "Display wake")),
            (NSWorkspace.sessionDidBecomeActiveNotification, tr("会话恢复", "Session active"))]
        for (name, reason) in wakeNotifications {
            observe(workspace, name) { [weak self] in
                self?.isSleeping = false
                self?.diagnosticLog.record(event: "wake_notification", details: ["reason": reason])
                self?.scheduleAutoRehideIfNeeded()
                self?.scheduleRecovery(reason: reason)
            }
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.latestDisplayGeometries = ItemEnumerator.displayMenuBarGeometries()
            self?.scheduleRecovery(reason: tr("显示器变化", "Display change"))
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            self?.scheduleFrontmostMenuCheck()
        }
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.usermenuextra.styledidchange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshControlCenterModes()
            self?.refreshRunningApplications()
        }
        if let themeDistributedObserver {
            DistributedNotificationCenter.default().removeObserver(themeDistributedObserver)
        }
        themeDistributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSystemAppearance()
        }
        appearanceKVO?.invalidate()
        appearanceKVO = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshSystemAppearance()
            }
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.lastLocalMouseDownAt = Date()
            self.openPopupPIDsAtMouseDown = ItemEnumerator.openPopupOwnerPIDs()
            self.wasControlCenterOpenAtMouseDown = ItemEnumerator.isControlCenterPopupOpen()
            return event
        }
    }

    private func scheduleRecovery(reason: String = tr("系统菜单栏重启", "Menu bar restart")) {
        guard isStarted, !isSleeping else { return }
        recoveryWork?.cancel()
        interruptMeasurements()
        beginRecovery(reason: reason)
        isRecovering = true
        diagnosticLog.record(event: "recovery_scheduled", details: ["reason": reason])
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recoverConnection(reason: self.recoveryReason)
        }
        recoveryWork = work
        // Wake, unlock and display changes often arrive together. Give the
        // system menu bar one settling interval and restart only once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func beginRecovery(reason: String) {
        guard recoveryStartedAt == nil else { return }
        recoveryStartedAt = Date()
        recoveryStartedUptime = ProcessInfo.processInfo.systemUptime
        recoveryReason = reason
    }

    private func completeRecovery() {
        guard recoveryStartedAt != nil else { return }
        lastRecoveryAt = Date()
        lastRecoveryReason = recoveryReason
        lastRecoveryDuration = max(0, ProcessInfo.processInfo.systemUptime
            - (recoveryStartedUptime ?? ProcessInfo.processInfo.systemUptime))
        diagnosticLog.record(event: "recovery_succeeded", details: [
            "reason": recoveryReason,
            "durationSeconds": String(format: "%.2f", lastRecoveryDuration ?? 0),
            "pid": agent.processID.map(String.init) ?? "none"])
        recoveryStartedAt = nil
        recoveryStartedUptime = nil
    }

    private func interruptMeasurements() {
        operationGeneration += 1
        cancelBulkScanWork()
        isMeasuring = false
        isScanningSystemItems = false
        let interrupted = scanInterrupted
        scanInterrupted = nil
        interrupted?()
    }

    private func ensureAgentIsHealthy() {
        guard isStarted, !isSleeping, recoveryWork == nil else { return }
        guard MBPrivateAPIAvailable() else {
            connectionError = tr("这台系统不支持菜单栏隐藏接口。", "MenuBarAgent private API is not available on this macOS version.")
            isRecovering = false
            return
        }
        let elapsed = Date().timeIntervalSince(lastAgentStart)
        if !agent.isRunning {
            nextRetryAt = agent.nextRetryAt
            guard agent.canStartNow else {
                isRecovering = false
                connectionError = agent.lastExitDescription ?? connectionError ?? tr("助手暂时无法启动，稍后将自动重试。", "Helper is temporarily unavailable; retrying shortly.")
                onChange?()
                return
            }
            guard elapsed >= AgentCommand.heartbeatInterval else { return }
            interruptMeasurements()
            apply()
            guard writeCurrentCommand() else { return }
            beginRecovery(reason: tr("助手恢复", "Helper recovery"))
            isRecovering = true
            lastAgentStart = Date()
            agent.start()
            onChange?()
            return
        }
        if let pid = agent.processID, let status = AgentStatus.read(),
           status.isCurrent(sessionID: sessionID, processID: pid) {
            connectionError = status.error
            isRecovering = status.error == nil && (status.isApplying || status.requestID != currentCommand?.requestID)
            nextRetryAt = nil
            if let error = status.error, error != reportedAgentError {
                diagnosticLog.record(event: "agent_reported_error", details: ["requestID": status.requestID])
            }
            reportedAgentError = status.error
            if status.error == nil, !isRecovering {
                agent.noteHealthy()
                completeRecovery()
                if lastAcknowledgedRequest != status.requestID {
                    lastAcknowledgedRequest = status.requestID
                    diagnosticLog.record(event: "command_acknowledged", details: [
                        "requestID": status.requestID, "pid": String(pid),
                        "mode": currentCommand?.mode.rawValue ?? "none"])
                }
            }
            if status.error != nil, isScanningSystemItems {
                interruptMeasurements()
                apply()
            }
            onChange?()
        } else if elapsed >= AgentCommand.stalenessTimeout {
            connectionError = tr("菜单栏助手未响应，正在重新连接。", "Menu bar helper is unresponsive; reconnecting.")
            diagnosticLog.record(event: "agent_unresponsive", details: ["pid": agent.processID.map(String.init) ?? "none"])
            recoverConnection(reason: tr("助手无响应", "Helper unresponsive"))
        }
    }

    // MARK: - Hotkeys

    private func startHotkeys() {
        hotkeyRegistry.onFire = { [weak self] action in
            self?.perform(action)
        }
        for (action, hotkey) in bindings {
            _ = hotkeyRegistry.register(hotkey, for: action)
        }
    }

    /// Returns nil on success, or why the combination could not be used.
    @discardableResult
    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) -> String? {
        guard let hotkey else {
            hotkeyRegistry.unregister(action)
            bindings[action] = nil
            Defaults.hotkeys = bindings
            onChange?()
            return nil
        }
        if let error = hotkeyRegistry.register(hotkey, for: action) {
            lastError = error
            onChange?()
            return error
        }
        bindings[action] = hotkey
        Defaults.hotkeys = bindings
        lastError = nil
        onChange?()
        return nil
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleHidden:       toggleHidden()
        case .toggleAlwaysHidden: toggleAlwaysHidden()
        }
    }

    // MARK: - Command channel

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: AgentCommand.heartbeatInterval,
                                         repeats: true) { [weak self] _ in
            guard let self, !self.isSleeping else { return }
            self.refreshControlCenterModes()
            if self.writeCurrentCommand() { self.ensureAgentIsHealthy() }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func send(_ command: AgentCommand) {
        var command = command
        command.sessionID = sessionID
        // A catalog refresh with identical settings is just a heartbeat, not
        // a new operation that should interrupt an in-flight activation.
        if let current = currentCommand, current.mode == command.mode,
           current.allowed == command.allowed,
           current.hiddenSystemItems == command.hiddenSystemItems {
            command.requestID = current.requestID
        }
        if currentCommand?.requestID != command.requestID {
            diagnosticLog.record(event: "command_requested", details: [
                "mode": command.mode.rawValue, "requestID": command.requestID,
                "allowedCount": String(command.allowed.count),
                "hiddenSystemCount": String(command.hiddenSystemItems.count)])
        }
        currentCommand = command
        writeCurrentCommand()
    }

    /// Rewrites the file with a fresh timestamp. The payload only changes when
    /// the sections or the set of running apps do; the rewrite is what tells
    /// the helper this process is still here.
    @discardableResult
    private func writeCurrentCommand() -> Bool {
        guard var command = currentCommand else { return false }
        command.updatedAt = Date()
        do {
            try command.write()
            reportedWriteError = nil
            return true
        } catch {
            connectionError = tr("无法与助手通信：\(error.localizedDescription)", "Failed to communicate with helper: \(error.localizedDescription)")
            if reportedWriteError != connectionError {
                let failure = error as NSError
                diagnosticLog.record(event: "command_write_failed", details: [
                    "domain": failure.domain, "code": String(failure.code)])
                reportedWriteError = connectionError
            }
            isRecovering = false
            onChange?()
            return false
        }
    }

    // MARK: - Permissions

    /// Permission can be granted or revoked while the app runs.
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = ItemEnumerator.hasAccessibilityPermission
            if granted != self.hasAccessibility {
                self.hasAccessibility = granted
                self.catalogRevision += 1
                if granted { self.refreshRunningApplications() }
                else { self.interruptMeasurements(); self.apply() }
            }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    }

    func requestAccessibility() {
        ItemEnumerator.requestAccessibilityPermission()
    }

    /// Copyable diagnostics deliberately exclude application lists and stored
    /// preferences. Recording is local and limited to service state changes.
    func diagnosticSummary() -> String {
        let formatter = ISO8601DateFormatter()
        func timestamp(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "none" }
        let status = AgentStatus.read()
        let current = agent.processID.map {
            status?.isCurrent(sessionID: sessionID, processID: $0) == true
        } ?? false
        let lines = [
            "BarLens \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Captured: \(formatter.string(from: Date()))",
            "App PID: \(ProcessInfo.processInfo.processIdentifier)",
            "Helper PID: \(agent.processID.map(String.init) ?? "none")",
            "Current reply: \(current)",
            "Request acknowledged: \(current && status?.requestID == currentCommand?.requestID && status?.isApplying == false && status?.error == nil)",
            "State: \(isSleeping ? "sleeping" : isRecovering ? "recovering" : connectionError == nil ? "ready" : "error")",
            "Error: \(connectionError ?? "none")",
            "Last recovery: \(timestamp(lastRecoveryAt))",
            "Recovery reason: \(lastRecoveryReason ?? "none")",
            "Recovery duration: \(lastRecoveryDuration.map { String(format: "%.2fs", $0) } ?? "none")",
            "Last helper exit: \(lastExitReason ?? "none")",
            "Next retry: \(timestamp(nextRetryAt))",
            "Consecutive failures: \(agent.consecutiveFailures)",
            "Accessibility granted: \(hasAccessibility)",
            "Catalog scan: \(scanWarning ?? "complete")",
            "", "Recent events:", DiagnosticLog.recentSummary(limit: 60)]
        return lines.joined(separator: "\n")
    }

    // MARK: - Applying

    func apply() {
        guard isStarted, !isSleeping else { return }
        guard !isMeasuring, !isScanningSystemItems else { return }
        guard MBPrivateAPIAvailable() else {
            lastError = tr("这台系统上没有 MenuBarAgent 的私有 API。", "MenuBarAgent private API is not available on this system.")
            onChange?()
            return
        }

        if runningBundleIDs.isEmpty { refreshRunningApplications() }
        recomputeSpatialBudget()

        // With nothing assigned and no spatial overflow to protect, stay suspended
        // until there is actually something to hide.
        guard isConfigured || !overflowDemotedBundleIDs.isEmpty else {
            send(AgentCommand(mode: .suspend, allowed: []))
            return
        }

        // Every running application, not just the ones with a status item: the
        // API is a white list, so anything missing here gets hidden. Since a
        // status item can only be owned by a running process, this is a
        // complete superset — and it needs no access to any private plist.
        // A newly launched app has to be admitted, or its icon would stay
        // hidden until something else triggered an apply.
        let barReveal: SectionModel.Reveal = (revealPresentationStyle == .floatingBar) ? .none : reveal
        var allowed = model.allowedBundles(running: runningBundleIDs,
                                           reveal: barReveal,
                                           alwaysHiddenEnabled: alwaysHiddenEnabled,
                                           listable: bundlesWithItems)
        if barReveal == .none, !overflowDemotedBundleIDs.isEmpty {
            allowed.removeAll { overflowDemotedBundleIDs.contains($0) }
        }
        for item in systemItems.items where !item.hostBundleIDs.isEmpty {
            let suppressed = systemItems.isItemSuppressedOnBar(
                item,
                reveal: barReveal,
                alwaysHiddenEnabled: alwaysHiddenEnabled
            )
            if suppressed {
                allowed.removeAll { item.hostBundleIDs.contains($0) }
            }
        }
        if let pinnedBundleID, runningBundleIDs.contains(pinnedBundleID), !allowed.contains(pinnedBundleID) {
            allowed.append(pinnedBundleID)
            allowed.sort()
        }

        var hiddenSys = normalHiddenSystemItems
        if let pinnedRaw = pinnedSystemItemRawValue {
            hiddenSys.removeAll { $0 == pinnedRaw }
        }

        let hasPinnedTarget = pinnedBundleID != nil || pinnedSystemItemRawValue != nil
        let hasHiddenControlCenter = systemItems.hasHiddenControlCenterItems(
            reveal: barReveal,
            alwaysHiddenEnabled: alwaysHiddenEnabled,
            excluding: unavailableSystemItemIDs
        )
        // Even an unrestricted allow list hides some unsupported built-ins.
        // Release the assertion entirely when the current rules hide nothing.
        guard hasPinnedTarget || !runningBundleIDs.subtracting(allowed).isEmpty || !hiddenSys.isEmpty || hasHiddenControlCenter else {
            send(AgentCommand(mode: .suspend, allowed: []))
            return
        }

        send(AgentCommand(mode: .apply,
                          allowed: allowed,
                          hiddenSystemItems: hiddenSys))
    }

    /// What `apply` would hide, ignoring any sweep in progress.
    private var normalHiddenSystemItems: [Int] {
        let barReveal: SectionModel.Reveal = (revealPresentationStyle == .floatingBar) ? .none : reveal
        return systemItems.hiddenRawValues(reveal: barReveal,
                                           alwaysHiddenEnabled: alwaysHiddenEnabled)
    }

    // MARK: - System item discovery

    /// Suppresses the ordinary apply while a sweep is driving the restriction.
    /// Without this the heartbeat would overwrite each probe with the user's
    /// real settings and the search would never observe anything.
    private var isScanningSystemItems = false

    func beginSystemItemScan(onInterrupted: @escaping () -> Void) {
        interruptMeasurements()
        isScanningSystemItems = true
        scanInterrupted = onInterrupted
        if runningBundleIDs.isEmpty { refreshRunningApplications() }
    }

    func suspendForSystemItemScan() {
        guard isScanningSystemItems, !isSleeping, isStarted else { return }
        send(AgentCommand(mode: .suspend, allowed: []))
    }

    /// A probe is measurable only after the helper confirmed this exact
    /// request. Merely waiting a second cannot prove that activation succeeded.
    var isSystemProbeApplied: Bool {
        isScanningSystemItems && isCurrentCommandAcknowledged
    }

    private var isCurrentCommandAcknowledged: Bool {
        guard let pid = agent.processID,
              let status = AgentStatus.read(),
              status.isCurrent(sessionID: sessionID, processID: pid) else { return false }
        return status.requestID == currentCommand?.requestID
            && !status.isApplying && status.error == nil
    }

    func endSystemItemScan() {
        isScanningSystemItems = false
        scanInterrupted = nil
        apply()
    }

    /// Hold a restriction that hides the user's own hidden items *plus* these,
    /// keeping the bundle allow list unchanged so nothing else on the bar moves.
    ///
    /// Union rather than replace: a probe that dropped the user's hidden set
    /// would pop their hidden icons back onto the bar for the length of the
    /// sweep, which looks like the app coming apart.
    func probeSystemItems(_ extra: [Int]) {
        guard isScanningSystemItems, !isSleeping, isStarted else { return }
        send(AgentCommand(mode: .apply,
                          allowed: model.allowedBundles(running: runningBundleIDs,
                                                        reveal: reveal,
                                                        alwaysHiddenEnabled: alwaysHiddenEnabled,
                                                        listable: bundlesWithItems),
                          hiddenSystemItems: normalHiddenSystemItems + extra))
    }

    /// Fold a measured raw value into the registry. False when it was already
    /// known.
    @discardableResult
    func recordSystemItem(_ identifier: String, rawValue: Int) -> Bool {
        guard isScanningSystemItems, !isSleeping, connectionError == nil else { return false }
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        liveVisibleSystemItemIDs.insert(canonical)
        let isNew = systemItems.record(canonical, rawValue: rawValue)
        if isNew {
            catalogRevision += 1
            onChange?()
        }
        return isNew
    }

    func pruneSystemItems(keeping presentIdentifiers: Set<String>) {
        let canonicalPresent = Set(presentIdentifiers.map(SystemItemName.canonicalIdentifier(for:)))
        liveVisibleSystemItemIDs = canonicalPresent
        let changed = systemItems.prune(keeping: canonicalPresent)
        if changed {
            catalogRevision += 1
            onChange?()
        }
    }

    // MARK: - User actions

    func noteMonitorDismissedReveal() {
        lastMonitorDismissedRevealAt = Date()
    }

    func setReveal(_ value: SectionModel.Reveal) {
        refreshControlCenterModes()
        let effectiveValue = (!alwaysHiddenEnabled && value == .all) ? .hidden : value
        let wasRevealed = (reveal != .none)
        pinnedExpireWork?.cancel()
        pinnedExpireWork = nil
        pinnedBundleID = nil
        pinnedSystemItemRawValue = nil
        if effectiveValue == .none, wasRevealed {
            pressGeneration += 1
            popupWatchWork?.cancel()
            popupWatchWork = nil
            if lastActivatedFromFloatingBar {
                lastActivatedTargetID = nil
                lastActivatedFromFloatingBar = false
                lastPopupObservedOpenAt = .distantPast
                itemScanQueue.async {
                    _ = ItemEnumerator.dismissControlCenterPopup()
                }
            }
        }
        reveal = effectiveValue
        scheduleAutoRehideIfNeeded()
        apply()
        onChange?()
    }

    func setRevealPresentationStyle(_ style: RevealPresentationStyle) {
        guard revealPresentationStyle != style else { return }
        revealPresentationStyle = style
        Defaults.revealPresentationStyle = style
        pinnedExpireWork?.cancel()
        pinnedExpireWork = nil
        popupWatchWork?.cancel()
        popupWatchWork = nil
        frontmostMenuCheckWork?.cancel()
        frontmostMenuCheckWork = nil
        pinnedBundleID = nil
        pinnedSystemItemRawValue = nil
        apply()
        onChange?()
    }

    func setStatusBarIconStyle(_ style: StatusBarIconStyle) {
        guard statusBarIconStyle != style else { return }
        statusBarIconStyle = style
        Defaults.statusBarIconStyle = style
        onChange?()
    }

    func setFloatingBarIconStyle(_ style: FloatingBarIconDisplayStyle) {
        guard floatingBarIconStyle != style else { return }
        floatingBarIconStyle = style
        Defaults.floatingBarIconStyle = style
        onChange?()
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        let latestDark = Self.readSystemIsDark()
        if systemIsDark != latestDark {
            systemIsDark = latestDark
        }
        guard appearanceMode != mode else {
            onChange?()
            return
        }
        appearanceMode = mode
        Defaults.appearanceMode = mode
        onChange?()
    }

    func setAppLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        Defaults.appLanguage = language
        appLanguage = language
        catalogRevision += 1
        onChange?()
    }

    func setGlassOpacity(_ value: Double) {
        let clamped = min(max(value, 0.0), 0.90)
        guard abs(glassOpacity - clamped) > 0.001 else { return }
        glassOpacity = clamped
        Defaults.glassOpacity = clamped
        onChange?()
    }

    func setRimIntensity(_ value: Double) {
        let clamped = min(max(value, 0.2), 1.6)
        guard abs(rimIntensity - clamped) > 0.001 else { return }
        rimIntensity = clamped
        Defaults.rimIntensity = clamped
        onChange?()
    }

    func applyOptimalAppearancePreset() {
        setAppearanceMode(.system)
        setGlassOpacity(0.36)
        setRimIntensity(1.15)
    }

    /// Temporarily admits a single hidden app onto the top menu bar and triggers
    /// its native status bar item via AX, or collapses it if already open.
    func activateFromFloatingBar(bundleID: String, preferredIndex: Int? = nil) {
        pinnedExpireWork?.cancel()
        popupWatchWork?.cancel()
        pressGeneration += 1
        let generation = pressGeneration
        let targetID = "app:\(bundleID)"

        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
        let clickedRecently = Date().timeIntervalSince(lastLocalMouseDownAt) < 0.6
        let appPopupOpenAtClick = ItemEnumerator.hasOpenPopupWindow(bundleID: bundleID)
            || (clickedRecently && pids.contains { openPopupPIDsAtMouseDown.contains($0) })
            || (lastActivatedTargetID == targetID && Date().timeIntervalSince(lastPopupObservedOpenAt) < 0.45)

        if preferredIndex == nil && (pinnedBundleID == bundleID || appPopupOpenAtClick) {
            lastActivatedTargetID = nil
            lastActivatedFromFloatingBar = false
            lastPopupObservedOpenAt = .distantPast
            pinnedBundleID = nil
            pinnedSystemItemRawValue = nil
            itemScanQueue.async {
                _ = ItemEnumerator.cancelStatusItem(bundleID: bundleID)
            }
            apply()
            onChange?()
            scheduleAutoRehideIfNeeded()
            return
        }

        if ItemEnumerator.isControlCenterPopupOpen() {
            itemScanQueue.async {
                _ = ItemEnumerator.dismissControlCenterPopup()
            }
        }

        recordItemInteraction(bundleID: bundleID)
        pinnedBundleID = bundleID
        pinnedSystemItemRawValue = nil
        lastActivatedTargetID = targetID
        lastActivatedFromFloatingBar = true
        lastPopupObservedOpenAt = Date()
        apply()
        onChange?()
        scheduleAutoRehideIfNeeded()

        retryPressMenuBarItem(generation: generation, initialDelay: 0.15, attemptsLeft: 6) {
            ItemEnumerator.pressStatusItem(bundleID: bundleID, preferredIndex: preferredIndex)
        }
        startPopupWatch(for: targetID)
        schedulePinnedExpiration(after: max(8, autoRehideInterval.seconds ?? 8))
    }

    /// Triggers a hidden system item's native menu or Control Center detail sheet
    /// from the Floating Bar without unhiding Control Center modules onto the top bar.
    func activateFromFloatingBar(systemItem: SystemItem) {
        activateSystemItem(systemItem, fromFloatingBar: true)
    }

    /// Triggers a system item's native menu or Control Center detail sheet
    /// without suspending `MBAssessmentModeAssertion` or expanding all icons.
    /// Clicking again while the item's panel is open collapses it instead of reopening.
    func activateSystemItem(_ systemItem: SystemItem, fromFloatingBar: Bool = false) {
        if let hostBundleID = systemItem.pressableHostBundleID {
            activateFromFloatingBar(bundleID: hostBundleID)
            return
        }
        pinnedExpireWork?.cancel()
        popupWatchWork?.cancel()
        pressGeneration += 1
        let generation = pressGeneration
        let targetID = "sys:\(systemItem.identifier)"

        let clickedRecently = Date().timeIntervalSince(lastLocalMouseDownAt) < 0.6
        let ccOpenNow = ItemEnumerator.isControlCenterPopupOpen()
        let ccOpenAtClick = ccOpenNow
            || (clickedRecently && wasControlCenterOpenAtMouseDown)
            || (lastActivatedTargetID == targetID && Date().timeIntervalSince(lastPopupObservedOpenAt) < 0.45)

        if (ccOpenAtClick && (lastActivatedTargetID == targetID || lastActivatedTargetID == nil))
            || (pinnedSystemItemRawValue != nil && pinnedSystemItemRawValue == systemItem.rawValue) {
            lastActivatedTargetID = nil
            lastActivatedFromFloatingBar = false
            lastPopupObservedOpenAt = .distantPast
            wasControlCenterOpenAtMouseDown = false
            if pinnedBundleID != nil || pinnedSystemItemRawValue != nil {
                pinnedBundleID = nil
                pinnedSystemItemRawValue = nil
                apply()
                onChange?()
            }
            itemScanQueue.async {
                _ = ItemEnumerator.dismissControlCenterPopup()
            }
            if fromFloatingBar {
                scheduleAutoRehideIfNeeded()
            }
            return
        }

        pinnedBundleID = nil
        lastActivatedTargetID = targetID
        lastActivatedFromFloatingBar = fromFloatingBar
        lastPopupObservedOpenAt = Date()

        if ItemEnumerator.canTriggerViaControlCenter(identifier: systemItem.identifier) {
            let controlCenterRaw = 8
            if normalHiddenSystemItems.contains(controlCenterRaw) {
                pinnedSystemItemRawValue = controlCenterRaw
            } else {
                pinnedSystemItemRawValue = nil
            }
            apply()
            onChange?()
            if fromFloatingBar {
                scheduleAutoRehideIfNeeded()
            }

            let allowDirect = !fromFloatingBar && systemItem.isAddressableByAssessment
            retryPressMenuBarItem(generation: generation, initialDelay: 0.02, attemptsLeft: 4) {
                ItemEnumerator.triggerControlCenterModule(
                    for: systemItem.identifier,
                    allowDirectStatusItemPress: allowDirect
                )
            }
            startPopupWatch(for: targetID)
            if pinnedSystemItemRawValue != nil {
                schedulePinnedExpiration(after: max(8, autoRehideInterval.seconds ?? 8))
            }
        } else if systemItem.isAddressableByAssessment {
            pinnedSystemItemRawValue = systemItem.rawValue
            apply()
            onChange?()
            if fromFloatingBar {
                scheduleAutoRehideIfNeeded()
            }

            retryPressMenuBarItem(generation: generation, initialDelay: 0.15, attemptsLeft: 6) {
                if ItemEnumerator.pressSystemItem(identifier: systemItem.identifier) {
                    return true
                }
                return ItemEnumerator.triggerControlCenterModule(
                    for: systemItem.identifier,
                    allowDirectStatusItemPress: true
                )
            }
            startPopupWatch(for: targetID)
            schedulePinnedExpiration(after: max(8, autoRehideInterval.seconds ?? 8))
        }
    }

    private func retryPressMenuBarItem(generation: Int,
                                       initialDelay: TimeInterval = 0.15,
                                       attemptsLeft: Int = 6,
                                       action: @escaping () -> Bool) {
        guard attemptsLeft > 0 else { return }
        itemScanQueue.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self, self.isStarted, !self.isSleeping else { return }
            let isCurrentGen = DispatchQueue.main.sync { self.pressGeneration == generation }
            guard isCurrentGen else { return }
            if !action() {
                self.retryPressMenuBarItem(
                    generation: generation,
                    initialDelay: 0.14,
                    attemptsLeft: attemptsLeft - 1,
                    action: action
                )
            }
        }
    }

    private func startPopupWatch(for targetID: String) {
        popupWatchWork?.cancel()
        let graceDeadline = Date().addingTimeInterval(1.0)
        func scheduleNext(delay: TimeInterval) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isStarted, !self.isSleeping,
                      self.lastActivatedTargetID == targetID else { return }
                let isOpen: Bool
                if targetID.hasPrefix("sys:") {
                    isOpen = ItemEnumerator.isControlCenterPopupOpen()
                } else if targetID.hasPrefix("app:") {
                    let bundleID = String(targetID.dropFirst(4))
                    isOpen = ItemEnumerator.hasOpenPopupWindow(bundleID: bundleID)
                } else {
                    isOpen = false
                }
                if isOpen {
                    self.lastPopupObservedOpenAt = Date()
                    scheduleNext(delay: 0.25)
                } else if Date() < graceDeadline {
                    scheduleNext(delay: 0.2)
                } else {
                    // Popup has closed. If an app/system item was temporarily pinned
                    // to the top bar and the pointer has left the menu bar, unpin now.
                    if (self.pinnedBundleID != nil || self.pinnedSystemItemRawValue != nil),
                       !Self.isPointerInMenuBarBand() {
                        self.pinnedBundleID = nil
                        self.pinnedSystemItemRawValue = nil
                        self.apply()
                        self.onChange?()
                    }
                    let clearDelay: TimeInterval = 0.35
                    DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) { [weak self] in
                        guard let self, self.lastActivatedTargetID == targetID,
                              Date().timeIntervalSince(self.lastPopupObservedOpenAt) >= clearDelay else {
                            return
                        }
                        self.lastActivatedTargetID = nil
                        self.lastActivatedFromFloatingBar = false
                    }
                }
            }
            popupWatchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        scheduleNext(delay: 0.25)
    }

    private func schedulePinnedExpiration(after delay: TimeInterval) {
        pinnedExpireWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted, !self.isSleeping else { return }
            guard self.pinnedBundleID != nil || self.pinnedSystemItemRawValue != nil else { return }
            let stillOpen: Bool
            if let bid = self.pinnedBundleID {
                stillOpen = ItemEnumerator.hasOpenPopupWindow(bundleID: bid)
            } else {
                stillOpen = ItemEnumerator.isControlCenterPopupOpen()
            }
            if Self.isPointerInMenuBarBand() || stillOpen {
                self.schedulePinnedExpiration(after: 2.0)
                return
            }
            self.pinnedBundleID = nil
            self.pinnedSystemItemRawValue = nil
            self.apply()
            self.onChange?()
        }
        pinnedExpireWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Plain click on the dot: show or hide the revealable section.
    func toggleHidden() {
        setReveal(reveal == .none ? .hidden : .none)
    }

    /// Double-click or hotkey: peek at the always-hidden section as well. Does
    /// nothing when that section is switched off in settings.
    func toggleAlwaysHidden() {
        guard alwaysHiddenEnabled else { return }
        setReveal(reveal == .all ? .none : .all)
    }

    func setAlwaysHiddenEnabled(_ enabled: Bool) {
        alwaysHiddenEnabled = enabled
        Defaults.alwaysHiddenEnabled = enabled
        if !enabled, reveal == .all { reveal = .none }
        scheduleAutoRehideIfNeeded()
        catalogRevision += 1
        apply()
        onChange?()
    }

    func setAutoRehideInterval(_ interval: AutoRehideInterval) {
        autoRehideInterval = interval
        Defaults.autoRehideInterval = interval
        scheduleAutoRehideIfNeeded()
        onChange?()
    }

    func setHoverRevealDelay(_ delay: HoverRevealDelay) {
        guard hoverRevealDelay != delay else { return }
        hoverRevealDelay = delay
        Defaults.hoverRevealDelay = delay
        onChange?()
    }

    func setLensTelemetryEnabled(_ enabled: Bool) {
        guard lensTelemetryEnabled != enabled else { return }
        lensTelemetryEnabled = enabled
        Defaults.lensTelemetryEnabled = enabled
        catalogRevision += 1
        onChange?()
    }

    func setSpatialBudgetPolicy(_ policy: SpatialBudgetPolicy) {
        guard spatialBudgetPolicy != policy else { return }
        spatialBudgetPolicy = policy
        Defaults.spatialBudgetPolicy = policy
        if latestDisplayGeometries.isEmpty {
            latestDisplayGeometries = ItemEnumerator.displayMenuBarGeometries()
        }
        apply()
        catalogRevision += 1
        onChange?()
    }

    func isSpatiallyExempt(_ bundleID: String) -> Bool {
        spatialExemptBundleIDs.contains(bundleID)
    }

    func toggleSpatialExemption(for bundleID: String) {
        if spatialExemptBundleIDs.contains(bundleID) {
            spatialExemptBundleIDs.remove(bundleID)
        } else {
            spatialExemptBundleIDs.insert(bundleID)
        }
        Defaults.spatialExemptBundleIDs = spatialExemptBundleIDs
        apply()
        catalogRevision += 1
        onChange?()
    }

    func recordItemInteraction(bundleID: String) {
        let now = Date().timeIntervalSince1970
        itemLastInteractedAt[bundleID] = now
        if itemLastInteractedAt.count > 120 {
            let sorted = itemLastInteractedAt.sorted { $0.value > $1.value }.prefix(96)
            itemLastInteractedAt = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }
        Defaults.itemLastInteractedAt = itemLastInteractedAt
    }

    private func updateSpatialMeasurements(context: ItemScanContext, result: ItemScanResult) {
        if !context.menuBarGeometries.isEmpty {
            latestDisplayGeometries = context.menuBarGeometries
        }
        if let menuWidth = result.frontmostMenuBarWidth {
            latestFrontmostMenuWidth = menuWidth
        }
        if let dotItem = result.items.first(where: { $0.axIdentifier == "BarLens.dot" }) {
            activeDotDisplayID = dotItem.display
        } else if activeDotDisplayID == nil {
            activeDotDisplayID = latestDisplayGeometries.first?.displayID
        }

        let targetDisplay = activeDotDisplayID ?? result.items.first?.display
        let displayItems = targetDisplay.map { d in result.items.filter { $0.display == d } } ?? result.items
        var widthsByOwner: [String: CGFloat] = [:]
        var minXByOwner: [String: CGFloat] = [:]
        var fixedOverhead: CGFloat = 0

        for item in displayItems {
            let w = max(18, item.frame.width) + 4
            if SectionModel.ownIdentifiers.contains(item.ownerBundleID)
                || SectionModel.notClassifiable.contains(item.ownerBundleID) {
                fixedOverhead += w
            } else {
                widthsByOwner[item.ownerBundleID, default: 0] += w
                if let currentMin = minXByOwner[item.ownerBundleID] {
                    minXByOwner[item.ownerBundleID] = min(currentMin, item.frame.minX)
                } else {
                    minXByOwner[item.ownerBundleID] = item.frame.minX
                }
            }
        }

        for (owner, w) in widthsByOwner where w > 0 {
            lastMeasuredWidthByBundleID[owner] = w
        }
        for (owner, x) in minXByOwner {
            lastMeasuredMinXByBundleID[owner] = x
        }
        if result.completedOwners.contains("com.apple.MenuBarAgent"), fixedOverhead > 0 {
            fixedSystemBarWidth = max(72, fixedOverhead)
        }
    }

    private func recomputeSpatialBudget() {
        if spatialBudgetPolicy == .off {
            if !overflowDemotedBundleIDs.isEmpty || !overflowDemotionReasons.isEmpty {
                overflowDemotedBundleIDs = []
                overflowDemotionReasons = [:]
            }
            return
        }

        if latestDisplayGeometries.isEmpty {
            latestDisplayGeometries = ItemEnumerator.displayMenuBarGeometries()
        }

        let eligibleOwners = bundlesWithItems
            .subtracting(SectionModel.ownIdentifiers)
            .subtracting(SectionModel.notClassifiable)
            .intersection(runningBundleIDs)
            .filter { model.section(of: $0) == .visible }

        let candidates = eligibleOwners.map { bundleID in
            SpatialCandidate(
                bundleID: bundleID,
                estimatedWidth: lastMeasuredWidthByBundleID[bundleID] ?? SpatialBudgetPlanner.defaultItemWidth,
                isExempt: spatialExemptBundleIDs.contains(bundleID),
                isExplicitlyVisible: model.visible.contains(bundleID),
                lastInteractedAt: itemLastInteractedAt[bundleID] ?? 0,
                menuBarMinX: lastMeasuredMinXByBundleID[bundleID]
            )
        }

        let targetGeo = latestDisplayGeometries.first(where: { $0.displayID == activeDotDisplayID })
            ?? latestDisplayGeometries.first
        let availableWidth = targetGeo?.availableRightWidth(frontmostMenuWidth: latestFrontmostMenuWidth)

        let evaluation = SpatialBudgetPlanner.evaluate(
            policy: spatialBudgetPolicy,
            candidates: candidates,
            fixedOverheadWidth: fixedSystemBarWidth,
            availableRightWidth: availableWidth,
            previouslyDemoted: overflowDemotedBundleIDs
        )

        if evaluation.demotedBundleIDs != overflowDemotedBundleIDs
            || evaluation.reasonsByBundleID != overflowDemotionReasons {
            overflowDemotedBundleIDs = evaluation.demotedBundleIDs
            overflowDemotionReasons = evaluation.reasonsByBundleID
        }
    }

    private func scheduleFrontmostMenuCheck() {
        guard isStarted, !isSleeping, spatialBudgetPolicy != .off else { return }
        frontmostMenuCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted, !self.isSleeping else { return }
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 0 else { return }
            self.itemScanQueue.async { [weak self] in
                let measured = ItemEnumerator.measureFrontmostMenuBarWidth(pid: pid)
                DispatchQueue.main.async {
                    guard let self, self.isStarted, !self.isSleeping else { return }
                    let oldDemoted = self.overflowDemotedBundleIDs
                    if let measured {
                        self.latestFrontmostMenuWidth = measured
                    }
                    self.recomputeSpatialBudget()
                    if self.overflowDemotedBundleIDs != oldDemoted {
                        self.apply()
                        self.catalogRevision += 1
                        self.onChange?()
                    }
                }
            }
        }
        frontmostMenuCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func telemetry(for systemItem: SystemItem) -> LensTelemetry {
        _ = systemTelemetryRevision
        guard lensTelemetryEnabled else { return .empty }
        let canonical = SystemItemName.canonicalIdentifier(for: systemItem.identifier)
        let fallback = systemAXTelemetryByID[canonical] ?? .empty
        return SystemTelemetryReader.shared.telemetry(for: systemItem, fallbackAX: fallback)
    }

    func bumpSystemTelemetry() {
        systemTelemetryRevision &+= 1
    }

    /// Executes a root or nested `AXMenu` sub-item directly without touching or flashing the top menu bar,
    /// granting cooperative window activation when opening app/settings windows, and falling back to
    /// opening the status item menu if the target app dynamically rebuilt its menu.
    func performTunnelAction(_ action: LensTunnelAction, bundleID: String, collapseBarAfter: Bool = true) {
        guard action.isEnabled, !action.hasSubmenu else { return }
        recordItemInteraction(bundleID: bundleID)
        let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let targetApp {
            NSApp?.yieldActivation(to: targetApp)
        }
        let shouldActivateTargetWindow = Self.actionLikelyOpensWindow(action.title)
        itemScanQueue.async { [weak self] in
            let ok = ItemEnumerator.performTunneledMenuAction(
                bundleID: bundleID,
                statusItemIndex: action.statusItemIndex,
                menuPath: action.menuPath,
                titlePath: action.titlePath
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    if shouldActivateTargetWindow, let targetApp {
                        targetApp.activate()
                    }
                    if collapseBarAfter {
                        self.setReveal(.none)
                    } else {
                        self.refreshRunningApplications()
                    }
                } else {
                    self.activateFromFloatingBar(bundleID: bundleID, preferredIndex: action.statusItemIndex)
                }
            }
        }
    }

    private static func actionLikelyOpensWindow(_ title: String) -> Bool {
        let lower = title.lowercased()
        let markers = [
            "open", "打开", "show", "显示", "settings", "preferences",
            "设置", "首选项", "偏好", "window", "窗口", "dashboard", "面板", "控制台", "new ", "新建"
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Raises a specific window of `bundleID` via Accessibility and brings the app to the front.
    func focusApplicationWindow(bundleID: String, windowTitle: String) {
        recordItemInteraction(bundleID: bundleID)
        let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let targetApp {
            NSApp?.yieldActivation(to: targetApp)
        }
        itemScanQueue.async {
            _ = ItemEnumerator.raiseApplicationWindow(bundleID: bundleID, matchingTitle: windowTitle)
            DispatchQueue.main.async {
                targetApp?.activate()
            }
        }
        setReveal(.none)
    }

    /// Brings the target application's windows to the front (or reopens its main window).
    func activateApplicationWindow(bundleID: String) {
        recordItemInteraction(bundleID: bundleID)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            NSApp?.yieldActivation(to: app)
            itemScanQueue.async {
                _ = ItemEnumerator.raiseApplicationWindow(bundleID: bundleID, matchingTitle: nil)
            }
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            } else {
                app.activate()
            }
        }
        setReveal(.none)
    }

    func quitApplication(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    private func updateSystemAXTelemetry(from scannedItems: [MenuBarItem]) {
        var rawByCanonical: [String: [RawAXItemTelemetry]] = [:]
        for item in scannedItems {
            let canonical: String?
            if item.ownerBundleID == "com.apple.MenuBarAgent", let id = item.axIdentifier, !id.isEmpty {
                canonical = SystemItemName.canonicalIdentifier(for: id)
            } else if item.ownerBundleID == "com.apple.systemuiserver" {
                canonical = "com.apple.menuextra.timemachine"
            } else if item.ownerBundleID == "com.apple.TextInputMenuAgent" {
                canonical = "com.apple.menuextra.textinput"
            } else {
                canonical = nil
            }
            guard let canonical else { continue }
            rawByCanonical[canonical, default: []].append(
                RawAXItemTelemetry(
                    title: item.axTitle ?? item.label,
                    description: item.axDescription,
                    value: item.axValue,
                    help: item.axHelp
                )
            )
        }
        for (canonical, raws) in rawByCanonical {
            let displayTitle = SystemItemName.title(for: canonical)
            let distilled = SemanticLensExtractor.extract(
                appName: displayTitle,
                bundleID: canonical,
                items: raws
            )
            if distilled.hasLiveSignal {
                systemAXTelemetryByID[canonical] = distilled
            }
        }
    }

    func moveFloatingBarItemToIndex(_ itemID: String, toIndex: Int, within currentIDs: [String]) {
        var updated = floatingBarOrder
        updated.moveToIndex(itemID: itemID, toIndex: toIndex, within: currentIDs)
        guard updated != floatingBarOrder else { return }
        floatingBarOrder = updated
        Defaults.floatingBarOrder = updated
    }

    func moveFloatingBarItem(_ movingID: String, to targetID: String, within currentIDs: [String]) {
        var updated = floatingBarOrder
        updated.move(itemID: movingID, to: targetID, within: currentIDs)
        guard updated != floatingBarOrder else { return }
        floatingBarOrder = updated
        Defaults.floatingBarOrder = updated
    }

    func moveFloatingBarItemByStep(_ itemID: String, delta: Int, within currentIDs: [String]) {
        var updated = floatingBarOrder
        updated.moveByStep(itemID: itemID, delta: delta, within: currentIDs)
        guard updated != floatingBarOrder else { return }
        floatingBarOrder = updated
        Defaults.floatingBarOrder = updated
    }

    func moveFloatingBarItemToEdge(_ itemID: String, toFront: Bool, within currentIDs: [String]) {
        var updated = floatingBarOrder
        updated.moveToEdge(itemID: itemID, toFront: toFront, within: currentIDs)
        guard updated != floatingBarOrder else { return }
        floatingBarOrder = updated
        Defaults.floatingBarOrder = updated
    }

    func resetFloatingBarOrder() {
        guard !floatingBarOrder.isEmpty else { return }
        var updated = floatingBarOrder
        updated.reset()
        floatingBarOrder = updated
        Defaults.floatingBarOrder = updated
    }

    func exportProfile() -> BarLensProfile {
        let hotkeysRaw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        let sysRaw = systemItems.assignments.mapValues(\.rawValue)
        return BarLensProfile(
            visibleBundles: Array(model.visible).sorted(),
            hiddenBundles: Array(model.hidden).sorted(),
            alwaysHiddenBundles: Array(model.alwaysHidden).sorted(),
            systemItemAssignments: sysRaw,
            floatingBarOrder: floatingBarOrder.orderedIDs,
            alwaysHiddenEnabled: alwaysHiddenEnabled,
            unclassifiedSection: unclassifiedSection.rawValue,
            newSystemItemSection: newSystemItemSection.rawValue,
            appearanceMode: appearanceMode.rawValue,
            revealPresentationStyle: revealPresentationStyle.rawValue,
            floatingBarIconStyle: floatingBarIconStyle.rawValue,
            statusBarIconStyle: statusBarIconStyle.rawValue,
            glassOpacity: glassOpacity,
            rimIntensity: rimIntensity,
            autoRehideInterval: autoRehideInterval.rawValue,
            hoverRevealDelay: hoverRevealDelay.rawValue,
            appLanguage: appLanguage.rawValue,
            hotkeys: hotkeysRaw,
            lensTelemetryEnabled: lensTelemetryEnabled,
            spatialBudgetPolicy: spatialBudgetPolicy.rawValue,
            spatialExemptBundles: Array(spatialExemptBundleIDs).sorted()
        )
    }

    func applyProfile(_ profile: BarLensProfile) {
        let newUnclassified = SectionModel.Section(rawValue: profile.unclassifiedSection) ?? .visible
        let newSysDefault = SectionModel.Section(rawValue: profile.newSystemItemSection) ?? .visible

        unclassifiedSection = newUnclassified
        Defaults.unclassifiedSection = newUnclassified
        newSystemItemSection = newSysDefault
        Defaults.newSystemItemSection = newSysDefault

        model.replaceAll(
            visible: Set(profile.visibleBundles),
            hidden: Set(profile.hiddenBundles),
            alwaysHidden: Set(profile.alwaysHiddenBundles),
            unclassified: newUnclassified
        )

        var sysMap: [String: SectionModel.Section] = [:]
        for (id, raw) in profile.systemItemAssignments {
            if let sec = SectionModel.Section(rawValue: raw) {
                sysMap[id] = sec
            }
        }
        systemItems.replaceAssignments(sysMap, unassigned: newSysDefault)

        let newOrder = FloatingBarOrder(orderedIDs: profile.floatingBarOrder)
        floatingBarOrder = newOrder
        Defaults.floatingBarOrder = newOrder

        if let mode = AppearanceMode(rawValue: profile.appearanceMode) {
            setAppearanceMode(mode)
        }
        if let style = RevealPresentationStyle(rawValue: profile.revealPresentationStyle) {
            setRevealPresentationStyle(style)
        }
        if let iconStyle = FloatingBarIconDisplayStyle(rawValue: profile.floatingBarIconStyle) {
            setFloatingBarIconStyle(iconStyle)
        }
        if let triggerStyle = StatusBarIconStyle(rawValue: profile.statusBarIconStyle) {
            setStatusBarIconStyle(triggerStyle)
        }
        setGlassOpacity(profile.glassOpacity)
        setRimIntensity(profile.rimIntensity)
        if let rehide = AutoRehideInterval(rawValue: profile.autoRehideInterval) {
            setAutoRehideInterval(rehide)
        }
        if let hover = HoverRevealDelay(rawValue: profile.hoverRevealDelay) {
            setHoverRevealDelay(hover)
        }
        if let lang = AppLanguage(rawValue: profile.appLanguage) {
            setAppLanguage(lang)
        }
        if let lensEnabled = profile.lensTelemetryEnabled {
            setLensTelemetryEnabled(lensEnabled)
        }
        if let rawSpatial = profile.spatialBudgetPolicy,
           let policy = SpatialBudgetPolicy(rawValue: rawSpatial) {
            spatialBudgetPolicy = policy
            Defaults.spatialBudgetPolicy = policy
        }
        if let exempt = profile.spatialExemptBundles {
            spatialExemptBundleIDs = Set(exempt)
            Defaults.spatialExemptBundleIDs = spatialExemptBundleIDs
        }

        var newBindings: [HotkeyAction: Hotkey] = [:]
        for (rawAction, hotkey) in profile.hotkeys {
            if let action = HotkeyAction(rawValue: rawAction) {
                newBindings[action] = hotkey
            }
        }
        bindings = newBindings
        Defaults.hotkeys = newBindings
        if isStarted {
            hotkeyRegistry.unregisterAll()
            startHotkeys()
        }

        setAlwaysHiddenEnabled(profile.alwaysHiddenEnabled)
        catalogRevision += 1
        apply()
        onChange?()
    }

    private func scheduleAutoRehideIfNeeded() {
        autoRehideWork?.cancel()
        autoRehideWork = nil
        if pinnedBundleID == nil && pinnedSystemItemRawValue == nil {
            pinnedExpireWork?.cancel()
            pinnedExpireWork = nil
        }
        guard isStarted, !isSleeping, reveal != .none,
              let seconds = autoRehideInterval.seconds else { return }
        scheduleAutoRehideCheck(after: seconds)
    }

    private func scheduleAutoRehideCheck(after delay: TimeInterval) {
        autoRehideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted, !self.isSleeping,
                  self.reveal != .none, self.autoRehideInterval.seconds != nil else { return }
            let hasActivePopup = self.pinnedBundleID != nil
                || (self.lastActivatedFromFloatingBar && ItemEnumerator.isControlCenterPopupOpen())
            if self.isQuickPanelOpen || self.isFloatingBarHovered || self.isLensLoupeHovered || self.isContextMenuOpen || Self.isPointerInMenuBarBand() || hasActivePopup {
                self.scheduleAutoRehideCheck(after: 1.5)
                return
            }
            self.setReveal(.none)
        }
        autoRehideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func isPointerInMenuBarBand() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else {
            return false
        }
        let menuBarHeight = max(28, screen.frame.maxY - screen.visibleFrame.maxY)
        return mouse.y >= screen.frame.maxY - menuBarHeight - 4
    }

    func setSection(_ section: SectionModel.Section, for bundleID: String) {
        model.set(section, for: bundleID)
        catalogRevision += 1
        apply()
        onChange?()
    }

    func removeAssignment(for bundleID: String) {
        model.removeAssignment(for: bundleID)
        catalogRevision += 1
        apply()
        onChange?()
    }

    func setSection(_ section: SectionModel.Section, for item: SystemItem) {
        systemItems.set(section, for: item)
        catalogRevision += 1
        apply()
        onChange?()
    }

    func removeAssignment(for item: SystemItem) {
        systemItems.removeAssignment(for: item)
        catalogRevision += 1
        apply()
        onChange?()
    }

    func setControlCenterShowMode(_ mode: ControlCenterShowMode, for item: SystemItem) {
        MenuBarBuiltIns.setControlCenterMode(mode, for: item.identifier)
        systemItemModes[item.identifier] = mode
        if mode != .alwaysShow {
            systemItems.removeAssignment(for: item)
        }
        catalogRevision += 1
        apply()
        onChange?()
    }

    func setUnclassifiedSection(_ section: SectionModel.Section) {
        guard unclassifiedSection != section else { return }
        for bundleID in bundlesWithItems where !model.isClassified(bundleID) {
            model.set(unclassifiedSection, for: bundleID)
        }
        unclassifiedSection = section
        Defaults.unclassifiedSection = section
        model.unclassified = section
        catalogRevision += 1
        apply()
        onChange?()
    }

    func setNewSystemItemSection(_ section: SectionModel.Section) {
        guard newSystemItemSection != section else { return }
        for item in activeSystemItems where !systemItems.isClassified(item) {
            systemItems.set(newSystemItemSection, for: item)
        }
        newSystemItemSection = section
        Defaults.newSystemItemSection = section
        systemItems.unassigned = section
        catalogRevision += 1
        apply()
        onChange?()
    }

    /// How many already-recorded system items have no explicit assignment and
    /// would therefore move if the default changed — the number the setting is
    /// about to act on, so it is worth showing before it is flipped.
    var unassignedSystemItemCount: Int {
        activeSystemItems.filter { systemItems.assignments[$0.identifier] == nil }.count
    }


    var isSuspendedForReal: Bool { currentCommand?.mode == .suspend }

    func suspend() {
        send(AgentCommand(mode: .suspend, allowed: []))
        onChange?()
    }

    func resume() {
        apply()
    }

    func setLastError(_ message: String) {
        lastError = message
        onChange?()
    }

    func clearLastError() {
        guard lastError != nil else { return }
        lastError = nil
        onChange?()
    }

    /// Apps appearing or disappearing changes the list, not the assignments.
    func noteCatalogChanged() {
        catalogRevision += 1
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        if let error = LaunchAtLogin.setEnabled(enabled) {
            lastError = tr("开机自启设置失败：\(error)", "Failed to update Launch at Login: \(error)")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        onChange?()
    }

    // MARK: - Bulk assignment

    /// Reveals the bar, then measures the dot and its neighbours together.
    /// Capturing the dot before revealing could sweep icons from its right into
    /// the selected section, because revealing also moves the dot itself.
    func assignEverythingLeftOfDot(on display: DisplayID,
                                   to section: SectionModel.Section,
                                   completion: ((Error?) -> Void)? = nil) {
        guard isStarted, !isSleeping else { return }
        guard hasAccessibility else {
            let error = NSError(domain: "BarLens", code: 2, userInfo: [
                NSLocalizedDescriptionKey: tr("需要辅助功能权限才能读取菜单栏布局。", "Accessibility permission is required to read the menu bar layout.")])
            lastError = error.localizedDescription
            requestAccessibility()
            onChange?()
            completion?(error)
            return
        }

        interruptMeasurements()
        let generation = operationGeneration
        isMeasuring = true
        let cancellation = AXScanCancellation()
        bulkScanCancellation = cancellation
        send(AgentCommand(mode: .suspend, allowed: []))
        let requestID = currentCommand?.requestID
        let deadline = ProcessInfo.processInfo.systemUptime + 5

        func failure(_ message: String) -> NSError {
            NSError(domain: "BarLens", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func isCurrent(_ engine: DividerEngine) -> Bool {
            !cancellation.isCancelled && generation == engine.operationGeneration
                && engine.isStarted && !engine.isSleeping && engine.isMeasuring
                && engine.currentCommand?.requestID == requestID
        }
        let finish: (Error?) -> Void = { [weak self] error in
            guard let self, isCurrent(self) else { return }
            self.isMeasuring = false
            self.bulkScanCancellation = nil
            self.lastError = error.map {
                if let failure = $0 as? BulkAssignmentBoundary.Failure { return failure.description }
                if let failure = $0 as? SectionModel.BulkError { return failure.description }
                return $0.localizedDescription
            }
            self.catalogRevision += 1
            self.apply()
            self.onChange?()
            completion?(error)
        }

        func measure() {
            guard isCurrent(self) else { return }
            let context = ItemEnumerator.captureContext()
            let knownOwners = itemScanState.owners.union(SectionModel.ownIdentifiers)
            bulkScanQueue.async { [weak self] in
                guard !cancellation.isCancelled else { return }
                let result = ItemEnumerator.scan(context: context, knownOwners: knownOwners,
                                                 cancellation: cancellation, budget: 6)
                DispatchQueue.main.async {
                    guard let self, isCurrent(self) else { return }
                    guard self.isCurrentCommandAcknowledged else {
                        finish(failure(tr("菜单栏连接在测量期间发生变化，已保留原有划分。", "Menu bar connection changed during measurement; keeping previous sections.")))
                        return
                    }
                    do {
                        let dot = try BulkAssignmentBoundary.resolve(in: result, on: display)
                        try self.model.assignEverything(leftOf: dot.frame.minX, on: dot.display,
                                                        from: result.items, to: section)
                        self.diagnosticLog.record(event: "bulk_assignment_completed", details: [
                            "display": String(display.rawValue), "itemCount": String(result.items.count)])
                        finish(nil)
                    } catch {
                        self.diagnosticLog.record(event: "bulk_assignment_aborted")
                        finish(error)
                    }
                }
            }
        }

        func awaitSuspension() {
            guard isCurrent(self) else { return }
            if isCurrentCommandAcknowledged {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                    guard isCurrent(self) else { return }
                    guard self.isCurrentCommandAcknowledged else {
                        finish(failure(tr("菜单栏连接在测量期间发生变化，已保留原有划分。", "Menu bar connection changed during measurement; keeping previous sections.")))
                        return
                    }
                    measure()
                }
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                finish(failure(tr("菜单栏尚未恢复为全部显示，已保留原有划分，请稍后重试。", "Menu bar did not finish revealing all items in time; please try again.")))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { awaitSuspension() }
            }
        }
        awaitSuspension()
    }

    /// Forget every assignment, showing everything.
    ///
    /// Defaults must also become visible, otherwise clearing explicit
    /// assignments would immediately hide the same apps through their default.
    func clearSections() {
        interruptMeasurements()
        unclassifiedSection = .visible
        newSystemItemSection = .visible
        Defaults.unclassifiedSection = .visible
        Defaults.newSystemItemSection = .visible
        model.unclassified = .visible
        systemItems.unassigned = .visible
        model.clear()
        systemItems.clearAssignments()
        floatingBarOrder.reset()
        Defaults.floatingBarOrder = floatingBarOrder
        catalogRevision += 1
        apply()
        onChange?()
    }
}
