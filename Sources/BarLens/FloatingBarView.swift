import AppKit
import Combine
import SwiftUI

/// Borderless panel that does not let AppKit clamp `frame.maxY` to `visibleFrame.maxY`,
/// allowing the capsule's top shadow padding to overlap the menu bar bottom edge
/// so the capsule itself sits snugly 4pt below the menu bar.
private final class FloatingBarPanel: NSPanel {
    var allowsKeyFocus = false

    override var canBecomeKey: Bool {
        allowsKeyFocus
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Coordinates hover dwell, icon-anchored geometry, cascading secondary submenus,
/// and mouse-bridge continuity between the Floating Bar, Optical Loupe, and Submenu Flyout.
final class LensLoupeCoordinator: ObservableObject {
    struct ActiveTarget: Equatable {
        let itemID: String
        let anchorScreenRect: NSRect
    }

    struct ActiveSubmenu: Equatable {
        let parentItemID: String
        let bundleID: String
        let action: LensTunnelAction
        let anchorRowScreenRect: NSRect
    }

    @Published private(set) var activeTarget: ActiveTarget?
    @Published private(set) var activeSubmenu: ActiveSubmenu?
    private var pendingShowWork: DispatchWorkItem?
    private var pendingHideWork: DispatchWorkItem?
    private var pendingSubmenuHideWork: DispatchWorkItem?
    private var hoveredIconID: String?
    private var hoveredSubmenuActionID: String?
    private var isPointerInsideLoupe = false
    private var isPointerInsideSubmenu = false

    var isAnyOverlayHovered: Bool {
        isPointerInsideLoupe || isPointerInsideSubmenu
    }

    func iconHoverChanged(itemID: String, isHovering: Bool, screenRect: NSRect?, lensEnabled: Bool) {
        guard lensEnabled else {
            dismissImmediately()
            return
        }
        if isHovering, let screenRect {
            hoveredIconID = itemID
            pendingHideWork?.cancel()
            pendingHideWork = nil
            pendingShowWork?.cancel()
            pendingShowWork = nil

            if let current = activeTarget {
                if current.itemID != itemID {
                    clearSubmenuImmediately()
                }
                activeTarget = ActiveTarget(itemID: itemID, anchorScreenRect: screenRect)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hoveredIconID == itemID else { return }
                    self.activeTarget = ActiveTarget(itemID: itemID, anchorScreenRect: screenRect)
                }
                pendingShowWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
            }
        } else {
            if hoveredIconID == itemID {
                hoveredIconID = nil
            }
            pendingShowWork?.cancel()
            pendingShowWork = nil
            scheduleDismissIfIdle()
        }
    }

    func loupeHoverChanged(_ hovering: Bool, onEngineUpdate: (Bool) -> Void) {
        isPointerInsideLoupe = hovering
        onEngineUpdate(isAnyOverlayHovered)
        if hovering {
            pendingHideWork?.cancel()
            pendingHideWork = nil
        } else {
            scheduleSubmenuDismissIfIdle()
            scheduleDismissIfIdle()
        }
    }

    func submenuParentRowHoverChanged(parentItemID: String,
                                      bundleID: String,
                                      action: LensTunnelAction,
                                      isHovering: Bool,
                                      rowScreenRect: NSRect?) {
        if isHovering, action.hasSubmenu, let rowScreenRect {
            hoveredSubmenuActionID = action.id
            pendingSubmenuHideWork?.cancel()
            pendingSubmenuHideWork = nil
            activeSubmenu = ActiveSubmenu(
                parentItemID: parentItemID,
                bundleID: bundleID,
                action: action,
                anchorRowScreenRect: rowScreenRect
            )
        } else {
            if hoveredSubmenuActionID == action.id {
                hoveredSubmenuActionID = nil
            }
            scheduleSubmenuDismissIfIdle()
        }
    }

    func nonSubmenuRowHovered() {
        hoveredSubmenuActionID = nil
        scheduleSubmenuDismissIfIdle()
    }

    func submenuFlyoutHoverChanged(_ hovering: Bool, onEngineUpdate: (Bool) -> Void) {
        isPointerInsideSubmenu = hovering
        onEngineUpdate(isAnyOverlayHovered)
        if hovering {
            pendingHideWork?.cancel()
            pendingHideWork = nil
            pendingSubmenuHideWork?.cancel()
            pendingSubmenuHideWork = nil
        } else {
            scheduleSubmenuDismissIfIdle()
            scheduleDismissIfIdle()
        }
    }

    func clearSubmenuImmediately() {
        pendingSubmenuHideWork?.cancel()
        pendingSubmenuHideWork = nil
        hoveredSubmenuActionID = nil
        isPointerInsideSubmenu = false
        if activeSubmenu != nil {
            activeSubmenu = nil
        }
    }

    func dismissImmediately() {
        pendingShowWork?.cancel()
        pendingShowWork = nil
        pendingHideWork?.cancel()
        pendingHideWork = nil
        clearSubmenuImmediately()
        hoveredIconID = nil
        isPointerInsideLoupe = false
        if activeTarget != nil {
            activeTarget = nil
        }
    }

    private func scheduleSubmenuDismissIfIdle() {
        pendingSubmenuHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.hoveredSubmenuActionID == nil && !self.isPointerInsideSubmenu else { return }
            self.activeSubmenu = nil
        }
        pendingSubmenuHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    }

    private func scheduleDismissIfIdle() {
        pendingHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.hoveredIconID == nil
                && !self.isPointerInsideLoupe
                && !self.isPointerInsideSubmenu else { return }
            self.clearSubmenuImmediately()
            self.activeTarget = nil
        }
        pendingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
    }
}

/// Manages the horizontal Liquid Glass floating menu bar, its companion Optical Loupe panel,
/// and its cascading secondary Submenu Flyout panel.
final class FloatingBarController {
    private let engine: DividerEngine
    private let catalog: Catalog
    private let onOpenSettings: () -> Void
    private let loupeCoordinator = LensLoupeCoordinator()
    private var panel: NSPanel?
    private var loupePanel: NSPanel?
    private var submenuPanel: NSPanel?
    private weak var anchorButton: NSStatusBarButton?
    private var cancellables: Set<AnyCancellable> = []
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?

    init(engine: DividerEngine, catalog: Catalog, onOpenSettings: @escaping () -> Void) {
        self.engine = engine
        self.catalog = catalog
        self.onOpenSettings = onOpenSettings

        catalog.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown else { return }
                DispatchQueue.main.async {
                    self.layoutAndPositionPanel()
                    self.syncLoupePanel(animated: false)
                    self.syncSubmenuPanel(animated: false)
                }
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            engine.$lensTelemetryEnabled.map { _ in () }.eraseToAnyPublisher(),
            engine.$overflowDemotedBundleIDs.map { _ in () }.eraseToAnyPublisher(),
            engine.$shieldedBundleIDs.map { _ in () }.eraseToAnyPublisher(),
            engine.$recentStatusBubbleHistory.map { _ in () }.eraseToAnyPublisher(),
            engine.$systemTelemetryRevision.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, self.isShown else { return }
            if !self.engine.lensTelemetryEnabled {
                self.loupeCoordinator.dismissImmediately()
            }
            DispatchQueue.main.async {
                self.layoutAndPositionPanel()
                self.syncLoupePanel(animated: false)
                self.syncSubmenuPanel(animated: false)
            }
        }
        .store(in: &cancellables)

        loupeCoordinator.$activeTarget
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                guard let self else { return }
                if target == nil || !self.isShown || !self.engine.lensTelemetryEnabled {
                    self.hideLoupePanel()
                } else {
                    self.syncLoupePanel(animated: self.loupePanel?.isVisible == true)
                }
            }
            .store(in: &cancellables)

        loupeCoordinator.$activeSubmenu
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sub in
                guard let self else { return }
                if sub == nil || !self.isShown || self.loupePanel?.isVisible != true {
                    self.hideSubmenuPanel()
                } else {
                    self.syncSubmenuPanel(animated: self.submenuPanel?.isVisible == true)
                }
            }
            .store(in: &cancellables)
    }

    var isShown: Bool {
        panel?.isVisible == true
    }

    var barCapsuleScreenFrame: NSRect? {
        guard isShown, let panel else { return nil }
        return panel.frame
    }

    var panelScreenFrame: NSRect? {
        guard isShown, let panel else { return nil }
        var combined = panel.frame
        if let loupePanel, loupePanel.isVisible {
            combined = combined.union(loupePanel.frame)
        }
        if let submenuPanel, submenuPanel.isVisible {
            combined = combined.union(submenuPanel.frame)
        }
        return combined
    }

    func update(relativeTo button: NSStatusBarButton?) {
        anchorButton = button
        let shouldShow = engine.revealPresentationStyle == .floatingBar && engine.reveal != .none
        guard shouldShow, let button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else {
            hide()
            return
        }

        catalog.rebuild(model: engine.model, query: "",
                        extraOwners: engine.ledgerOnlyOwners,
                        snapshot: engine.latestScanItems)

        let panel = ensurePanel()
        let targetAppearance = engine.effectiveNSAppearance
        panel.appearance = targetAppearance
        loupePanel?.appearance = targetAppearance
        submenuPanel?.appearance = targetAppearance
        let maxBarWidth = max(260, screen.visibleFrame.width - 32)
        let rootView = FloatingBarView(
            engine: engine,
            catalog: catalog,
            loupeCoordinator: loupeCoordinator,
            maxBarWidth: maxBarWidth,
            onOpenSettings: { [weak self] in
                self?.loupeCoordinator.dismissImmediately()
                self?.onOpenSettings()
            },
            onExpandInline: { [weak self] in
                guard let self else { return }
                self.loupeCoordinator.dismissImmediately()
                let targetReveal = self.engine.reveal == .none ? SectionModel.Reveal.hidden : self.engine.reveal
                self.engine.setRevealPresentationStyle(.inline)
                self.engine.setReveal(targetReveal)
            }
        )

        if let hosting = panel.contentViewController as? NSHostingController<FloatingBarView> {
            hosting.rootView = rootView
            hosting.view.appearance = targetAppearance
        } else {
            let hosting = NSHostingController(rootView: rootView)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.view.appearance = targetAppearance
            panel.contentViewController = hosting
        }

        layoutAndPositionPanel()
        if !panel.isVisible {
            engine.refreshRunningApplications()
            panel.orderFrontRegardless()
            installMonitors(statusButtonWindow: buttonWindow)
        } else {
            syncLoupePanel(animated: false)
            syncSubmenuPanel(animated: false)
        }
    }

    private func layoutAndPositionPanel() {
        guard let panel, let button = anchorButton, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let maxBarWidth = max(260, screen.visibleFrame.width - 32)
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingSize = panel.contentViewController?.view.fittingSize ?? NSSize(width: 240, height: 74)
        let width = min(maxBarWidth, max(160, fittingSize.width))
        let height = max(70, fittingSize.height)

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)

        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - width - 8
        let desiredX = buttonRectOnScreen.midX - width / 2
        let x = min(max(desiredX, minX), max(minX, maxX))
        // FloatingBarView has 5pt top padding; placing maxY at menuBarBottom + 1
        // puts the capsule's top edge a tight 4pt below the menu bar.
        let menuBarBottom = min(buttonRectOnScreen.minY, screen.visibleFrame.maxY)
        let y = menuBarBottom - height + 1

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func resolveLoupeItem(for itemID: String) -> FloatingBarItem? {
        let allItems = FloatingBarItemBuilder.allItems(engine: engine, catalog: catalog)
        return allItems.first { $0.id == itemID }
    }

    private func syncLoupePanel(animated: Bool) {
        guard isShown,
              engine.lensTelemetryEnabled,
              let mainPanel = panel,
              let target = loupeCoordinator.activeTarget,
              let resolvedItem = resolveLoupeItem(for: target.itemID) else {
            hideLoupePanel()
            return
        }

        let screen = mainPanel.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(mainPanel.frame) })
            ?? NSScreen.main
        guard let screen else {
            hideLoupePanel()
            return
        }

        let loupe = ensureLoupePanel()
        let targetAppearance = engine.effectiveNSAppearance
        loupe.appearance = targetAppearance

        // Exact symmetric panel width: 304pt card + 14pt left + 14pt right shadow padding = 332pt.
        let nominalPanelWidth: CGFloat = 332
        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - nominalPanelWidth - 8
        let desiredX = target.anchorScreenRect.midX - nominalPanelWidth / 2
        let clampedX = min(max(desiredX, minX), max(minX, maxX))
        let pointerOffsetX = min(max(target.anchorScreenRect.midX - (clampedX + nominalPanelWidth / 2), -130), 130)

        // Main capsule has 18pt bottom shadow padding; overlapping by 14pt places the Loupe card
        // a clean 4pt beneath the main capsule while creating a continuous hover bridge!
        let mainCapsuleBottomY = mainPanel.frame.minY + 18
        let topY = mainCapsuleBottomY + 4 // includes Loupe's 8pt top hover-bridge padding -> visual gap = 4pt
        let availablePanelHeight = max(220, topY - (screen.visibleFrame.minY + 8))
        let maxBodyHeight = max(140, availablePanelHeight - 122)

        let loupeView = FloatingLensLoupeView(
            item: resolvedItem,
            pointerOffsetX: pointerOffsetX,
            maxBodyHeight: maxBodyHeight,
            engine: engine,
            coordinator: loupeCoordinator
        )

        if let hosting = loupe.contentViewController as? NSHostingController<FloatingLensLoupeView> {
            hosting.rootView = loupeView
            hosting.view.appearance = targetAppearance
        } else {
            let hosting = NSHostingController(rootView: loupeView)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.view.appearance = targetAppearance
            loupe.contentViewController = hosting
        }

        loupe.contentView?.layoutSubtreeIfNeeded()
        let fitting = loupe.contentViewController?.view.fittingSize ?? NSSize(width: nominalPanelWidth, height: 140)
        let width = nominalPanelWidth
        let height = min(availablePanelHeight, max(84, fitting.height))
        let y = max(screen.visibleFrame.minY + 6, topY - height)
        let targetFrame = NSRect(x: clampedX, y: y, width: width, height: height)

        if animated && loupe.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                loupe.animator().setFrame(targetFrame, display: true)
            }
        } else {
            loupe.setFrame(targetFrame, display: true)
            if !loupe.isVisible {
                loupe.alphaValue = 0
                loupe.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    loupe.animator().alphaValue = 1
                }
            }
        }
    }

    private func syncSubmenuPanel(animated: Bool) {
        guard isShown,
              engine.lensTelemetryEnabled,
              let loupe = loupePanel,
              loupe.isVisible,
              let activeSub = loupeCoordinator.activeSubmenu,
              activeSub.action.hasSubmenu else {
            hideSubmenuPanel()
            return
        }

        let screen = loupe.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(loupe.frame) })
            ?? NSScreen.main
        guard let screen else {
            hideSubmenuPanel()
            return
        }

        let subPanel = ensureSubmenuPanel()
        let targetAppearance = engine.effectiveNSAppearance
        subPanel.appearance = targetAppearance

        let maxSubmenuListHeight = max(140, min(320, screen.visibleFrame.height - 110))
        let flyoutView = FloatingLensSubmenuFlyoutView(
            submenu: activeSub,
            maxListHeight: maxSubmenuListHeight,
            engine: engine,
            coordinator: loupeCoordinator
        )

        if let hosting = subPanel.contentViewController as? NSHostingController<FloatingLensSubmenuFlyoutView> {
            hosting.rootView = flyoutView
            hosting.view.appearance = targetAppearance
        } else {
            let hosting = NSHostingController(rootView: flyoutView)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.view.appearance = targetAppearance
            subPanel.contentViewController = hosting
        }

        // Exact symmetric panel width: 236pt card + 12pt left + 12pt right padding = 260pt.
        let panelWidth: CGFloat = 260
        subPanel.contentView?.layoutSubtreeIfNeeded()
        let fitting = subPanel.contentViewController?.view.fittingSize ?? NSSize(width: panelWidth, height: 110)
        let height = max(68, fitting.height)

        // Loupe has 14pt horizontal shadow padding; Submenu has 12pt horizontal shadow padding.
        // Overlapping transparent paddings by 22pt places the cards 4pt apart visually while
        // maintaining a continuous 100% gapless mouse-hover bridge between the two panels!
        let rightSideX = loupe.frame.maxX - 22
        let leftSideX = loupe.frame.minX + 22 - panelWidth
        let resolvedX: CGFloat
        if rightSideX + panelWidth <= screen.visibleFrame.maxX - 4 {
            resolvedX = rightSideX
        } else {
            resolvedX = max(screen.visibleFrame.minX + 4, leftSideX)
        }

        // Align top of submenu card with the hovered parent row's top edge (+8pt top padding + 4pt card inset).
        let desiredTopY = activeSub.anchorRowScreenRect.maxY + 12
        let minY = screen.visibleFrame.minY + 8
        let resolvedY = max(minY, desiredTopY - height)
        let targetFrame = NSRect(x: resolvedX, y: resolvedY, width: panelWidth, height: height)

        if animated && subPanel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                subPanel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            subPanel.setFrame(targetFrame, display: true)
            if !subPanel.isVisible {
                subPanel.alphaValue = 0
                subPanel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.11
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    subPanel.animator().alphaValue = 1
                }
            }
        }
    }

    private func hideSubmenuPanel() {
        guard let submenuPanel else { return }
        if submenuPanel.isVisible {
            submenuPanel.orderOut(nil)
        }
        if submenuPanel.contentViewController != nil {
            submenuPanel.contentViewController = nil
        }
    }

    private func hideLoupePanel() {
        hideSubmenuPanel()
        engine.isLensLoupeHovered = false
        guard let loupePanel else { return }
        if loupePanel.isVisible {
            loupePanel.orderOut(nil)
        }
        if loupePanel.contentViewController != nil {
            loupePanel.contentViewController = nil
        }
    }

    func hide() {
        removeMonitors()
        loupeCoordinator.dismissImmediately()
        engine.isFloatingBarHovered = false
        engine.isLensLoupeHovered = false
        if let submenuPanel {
            if submenuPanel.isVisible { submenuPanel.orderOut(nil) }
            if submenuPanel.contentViewController != nil { submenuPanel.contentViewController = nil }
        }
        if let loupePanel {
            if loupePanel.isVisible { loupePanel.orderOut(nil) }
            if loupePanel.contentViewController != nil { loupePanel.contentViewController = nil }
        }
        if let panel {
            if panel.isVisible { panel.orderOut(nil) }
            if panel.contentViewController != nil { panel.contentViewController = nil }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = FloatingBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    private func ensureLoupePanel() -> NSPanel {
        if let loupePanel { return loupePanel }
        let panel = FloatingBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.allowsKeyFocus = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.loupePanel = panel
        return panel
    }

    private func ensureSubmenuPanel() -> NSPanel {
        if let submenuPanel { return submenuPanel }
        let panel = FloatingBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.allowsKeyFocus = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.submenuPanel = panel
        return panel
    }

    private func installMonitors(statusButtonWindow: NSWindow) {
        removeMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown, !self.engine.isContextMenuOpen else { return }
            if Date().timeIntervalSince(ItemEnumerator.lastSyntheticClickAt) < 0.25 {
                return
            }
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ItemEnumerator.syntheticEventTag {
                return
            }
            if ItemEnumerator.isCurrentMouseInOpenPopupWindow() {
                return
            }
            self.loupeCoordinator.dismissImmediately()
            self.engine.noteMonitorDismissedReveal()
            self.engine.setReveal(.none)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown, !self.engine.isContextMenuOpen, let panel = self.panel else { return event }
            if event.window === panel
                || event.window === self.loupePanel
                || event.window === self.submenuPanel
                || event.window === statusButtonWindow
                || event.window?.title == "BarLens"
                || event.window?.className.contains("StatusBar") == true {
                return event
            }
            self.loupeCoordinator.dismissImmediately()
            self.engine.noteMonitorDismissedReveal()
            self.engine.setReveal(.none)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isShown, event.keyCode == 53 else { return event }
            self.loupeCoordinator.dismissImmediately()
            self.engine.setReveal(.none)
            return nil
        }
    }

    private func removeMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Shared Item Builder

fileprivate struct FloatingBarItem: Identifiable {
    enum Target {
        case app(bundleID: String, isClassified: Bool)
        case system(SystemItem, isClassified: Bool)
    }

    let id: String
    let title: String
    let icon: NSImage?
    let isTemplateIcon: Bool
    let symbol: String
    let badgeCount: Int?
    let section: SectionModel.Section
    let telemetry: LensTelemetry
    let vitals: ProcessVitals?
    let isSpatialOverflow: Bool
    let isShielded: Bool
    let isSpatiallyExempt: Bool
    let pulseEvent: StatusBubbleEvent?
    let target: Target
}

private enum FloatingBarItemBuilder {
    static func effective(_ section: SectionModel.Section, alwaysHiddenEnabled: Bool) -> SectionModel.Section {
        !alwaysHiddenEnabled && section == .alwaysHidden ? .hidden : section
    }

    static func tuckedOverflowItems(engine: DividerEngine, catalog: Catalog) -> [FloatingBarItem] {
        let tuckedSet = engine.temporarilyTuckedBundleIDs
        guard !tuckedSet.isEmpty else { return [] }
        let useMono = engine.floatingBarIconStyle == .monochrome
        let overflowApps = catalog.entries
            .filter {
                $0.isRunning && $0.itemCount > 0
                    && tuckedSet.contains($0.bundleID)
                    && engine.model.section(of: $0.bundleID) == .visible
            }
            .map { entry in
                let icon = useMono ? (entry.monochromeIcon ?? entry.icon) : entry.icon
                let isTemplate = useMono && entry.monochromeIcon != nil
                return FloatingBarItem(
                    id: "app:\(entry.bundleID)",
                    title: entry.displayName,
                    icon: icon,
                    isTemplateIcon: isTemplate,
                    symbol: "app",
                    badgeCount: entry.itemCount > 1 ? entry.itemCount : nil,
                    section: .visible,
                    telemetry: engine.lensTelemetryEnabled ? entry.telemetry : .empty,
                    vitals: engine.lensTelemetryEnabled ? entry.vitals : nil,
                    isSpatialOverflow: engine.overflowDemotedBundleIDs.contains(entry.bundleID),
                    isShielded: engine.shieldedBundleIDs.contains(entry.bundleID),
                    isSpatiallyExempt: engine.isSpatiallyExempt(entry.bundleID),
                    pulseEvent: engine.recentPulse(for: entry.bundleID),
                    target: .app(bundleID: entry.bundleID, isClassified: entry.isClassified)
                )
            }
        return engine.floatingBarOrder.sorted(overflowApps, id: \.id)
    }

    static func items(in section: SectionModel.Section, engine: DividerEngine, catalog: Catalog) -> [FloatingBarItem] {
        let useMono = engine.floatingBarIconStyle == .monochrome
        let appItems = catalog.entries
            .filter {
                $0.isRunning && $0.itemCount > 0
                    && effective(engine.model.section(of: $0.bundleID), alwaysHiddenEnabled: engine.alwaysHiddenEnabled) == section
            }
            .map { entry in
                let icon = useMono ? (entry.monochromeIcon ?? entry.icon) : entry.icon
                let isTemplate = useMono && entry.monochromeIcon != nil
                return FloatingBarItem(
                    id: "app:\(entry.bundleID)",
                    title: entry.displayName,
                    icon: icon,
                    isTemplateIcon: isTemplate,
                    symbol: "app",
                    badgeCount: entry.itemCount > 1 ? entry.itemCount : nil,
                    section: section,
                    telemetry: engine.lensTelemetryEnabled ? entry.telemetry : .empty,
                    vitals: engine.lensTelemetryEnabled ? entry.vitals : nil,
                    isSpatialOverflow: false,
                    isShielded: false,
                    isSpatiallyExempt: engine.isSpatiallyExempt(entry.bundleID),
                    pulseEvent: section == .hidden ? engine.recentPulse(for: entry.bundleID) : nil,
                    target: .app(bundleID: entry.bundleID, isClassified: entry.isClassified)
                )
            }
        let sysItems = engine.activeSystemItems
            .filter {
                effective(engine.systemItems.section(of: $0), alwaysHiddenEnabled: engine.alwaysHiddenEnabled) == section
            }
            .map { sys in
                FloatingBarItem(
                    id: "sys:\(sys.identifier)",
                    title: sys.title,
                    icon: nil,
                    isTemplateIcon: false,
                    symbol: sys.symbol,
                    badgeCount: nil,
                    section: section,
                    telemetry: engine.telemetry(for: sys),
                    vitals: nil,
                    isSpatialOverflow: false,
                    isShielded: false,
                    isSpatiallyExempt: false,
                    pulseEvent: nil,
                    target: .system(sys, isClassified: engine.systemItems.isClassified(sys))
                )
            }
        return engine.floatingBarOrder.sorted(appItems + sysItems, id: \.id)
    }

    static func allItems(engine: DividerEngine, catalog: Catalog) -> [FloatingBarItem] {
        var out = tuckedOverflowItems(engine: engine, catalog: catalog)
            + items(in: .hidden, engine: engine, catalog: catalog)
        if engine.alwaysHiddenEnabled && engine.reveal == .all {
            out += items(in: .alwaysHidden, engine: engine, catalog: catalog)
        }
        return out
    }
}

// MARK: - Drag Reordering State

private struct ActiveFloatingBarDrag: Equatable {
    let itemID: String
    let section: SectionModel.Section
    let siblingIDs: [String]
    let startIndex: Int
    var targetIndex: Int

    static let slotStride: CGFloat = 45.0 // 38pt icon button + 7pt HStack spacing

    func effectiveTranslationX(raw rawDX: CGFloat) -> CGFloat {
        let minOffset = -CGFloat(startIndex) * Self.slotStride
        let maxOffset = CGFloat(max(0, siblingIDs.count - 1 - startIndex)) * Self.slotStride
        if rawDX < minOffset {
            return minOffset + (rawDX - minOffset) * 0.26
        } else if rawDX > maxOffset {
            return maxOffset + (rawDX - maxOffset) * 0.26
        }
        return rawDX
    }

    func computedTargetIndex(for rawDX: CGFloat) -> Int {
        guard !siblingIDs.isEmpty else { return 0 }
        let slotDelta = Int((rawDX / Self.slotStride).rounded())
        return min(max(0, startIndex + slotDelta), siblingIDs.count - 1)
    }

    func neighborShiftX(at index: Int) -> CGFloat {
        if startIndex < targetIndex, ((startIndex + 1)...targetIndex).contains(index) {
            return -Self.slotStride
        } else if targetIndex < startIndex, (targetIndex...(startIndex - 1)).contains(index) {
            return Self.slotStride
        }
        return 0
    }
}

// MARK: - Main Single-Capsule Floating Bar View

struct FloatingBarView: View {
    @ObservedObject var engine: DividerEngine
    @ObservedObject var catalog: Catalog
    @ObservedObject var loupeCoordinator: LensLoupeCoordinator
    let maxBarWidth: CGFloat
    let onOpenSettings: () -> Void
    let onExpandInline: () -> Void

    @State private var activeDrag: ActiveFloatingBarDrag?
    @State private var activeDragTranslationX: CGFloat = 0
    @State private var settleItemID: String?
    @State private var settleOffsetX: CGFloat = 0

    private var tuckedOverflowItems: [FloatingBarItem] {
        guard engine.reveal != .none else { return [] }
        return FloatingBarItemBuilder.tuckedOverflowItems(engine: engine, catalog: catalog)
    }

    private var hiddenItems: [FloatingBarItem] {
        guard engine.reveal != .none else { return [] }
        return FloatingBarItemBuilder.items(in: .hidden, engine: engine, catalog: catalog)
    }

    private var alwaysHiddenItems: [FloatingBarItem] {
        guard engine.reveal != .none, engine.alwaysHiddenEnabled else { return [] }
        return FloatingBarItemBuilder.items(in: .alwaysHidden, engine: engine, catalog: catalog)
    }

    private var hasDisplayedItems: Bool {
        !tuckedOverflowItems.isEmpty
            || !hiddenItems.isEmpty
            || (engine.reveal == .all && !alwaysHiddenItems.isEmpty)
    }

    private var colorScheme: ColorScheme { engine.effectiveColorScheme }

    var body: some View {
        barContent
            .padding(.top, 5)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .environment(\.colorScheme, engine.effectiveColorScheme)
            .preferredColorScheme(engine.effectiveColorScheme)
            .onHover { hovering in
                engine.isFloatingBarHovered = hovering
            }
    }

    private var showsAlwaysHiddenToggle: Bool {
        engine.alwaysHiddenEnabled && !alwaysHiddenItems.isEmpty
    }

    private var maxIconsViewportWidth: CGFloat {
        let chromeReserve: CGFloat = showsAlwaysHiddenToggle ? 186 : 116
        return max(96, maxBarWidth - chromeReserve)
    }

    private var itemsTrack: some View {
        HStack(spacing: 7) {
            if !tuckedOverflowItems.isEmpty {
                let tuckedIDs = tuckedOverflowItems.map(\.id)
                let tuckedIndexByID = Dictionary(uniqueKeysWithValues: tuckedIDs.enumerated().map { ($1, $0) })
                ForEach(tuckedOverflowItems) { item in
                    FloatingBarItemButton(
                        item: item,
                        itemIndex: tuckedIndexByID[item.id] ?? 0,
                        siblingIDs: tuckedIDs,
                        engine: engine,
                        loupeCoordinator: loupeCoordinator,
                        activeDrag: $activeDrag,
                        activeDragTranslationX: $activeDragTranslationX,
                        settleItemID: $settleItemID,
                        settleOffsetX: $settleOffsetX
                    )
                }
                if !hiddenItems.isEmpty || (engine.reveal == .all && !alwaysHiddenItems.isEmpty) {
                    FloatingBarSeparator()
                }
            }

            let hiddenIDs = hiddenItems.map(\.id)
            let hiddenIndexByID = Dictionary(uniqueKeysWithValues: hiddenIDs.enumerated().map { ($1, $0) })
            ForEach(hiddenItems) { item in
                FloatingBarItemButton(
                    item: item,
                    itemIndex: hiddenIndexByID[item.id] ?? 0,
                    siblingIDs: hiddenIDs,
                    engine: engine,
                    loupeCoordinator: loupeCoordinator,
                    activeDrag: $activeDrag,
                    activeDragTranslationX: $activeDragTranslationX,
                    settleItemID: $settleItemID,
                    settleOffsetX: $settleOffsetX
                )
            }

            if engine.reveal == .all, !alwaysHiddenItems.isEmpty {
                if !hiddenItems.isEmpty {
                    FloatingBarSeparator()
                }
                let alwaysIDs = alwaysHiddenItems.map(\.id)
                let alwaysIndexByID = Dictionary(uniqueKeysWithValues: alwaysIDs.enumerated().map { ($1, $0) })
                ForEach(alwaysHiddenItems) { item in
                    FloatingBarItemButton(
                        item: item,
                        itemIndex: alwaysIndexByID[item.id] ?? 0,
                        siblingIDs: alwaysIDs,
                        engine: engine,
                        loupeCoordinator: loupeCoordinator,
                        activeDrag: $activeDrag,
                        activeDragTranslationX: $activeDragTranslationX,
                        settleItemID: $settleItemID,
                        settleOffsetX: $settleOffsetX
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    private var barContent: some View {
        HStack(spacing: 7) {
            if !hasDisplayedItems {
                Button(action: onOpenSettings) {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.84))
                        Text(tr("暂无隐藏图标 · 打开设置", "No Hidden Items · Open Settings"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.86))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            } else {
                CappedProposalLayout(maxWidth: maxIconsViewportWidth) {
                    ViewThatFits(in: .horizontal) {
                        itemsTrack
                        ScrollView(.horizontal, showsIndicators: false) {
                            itemsTrack
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if showsAlwaysHiddenToggle {
                FloatingBarSeparator()

                Button {
                    loupeCoordinator.dismissImmediately()
                    engine.setReveal(engine.reveal == .all ? .hidden : .all)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: engine.reveal == .all ? "eye.slash" : "eye.slash.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                        if engine.reveal != .all {
                            Text("\(alwaysHiddenItems.count)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(
                        colorScheme == .dark
                            ? Color(red: 0.94, green: 0.82, blue: 1.0)
                            : Color(red: 0.48, green: 0.12, blue: 0.64)
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .contentShape(Capsule())
                }
                .buttonStyle(FloatingBarCapsuleStyle(tint: SectionModel.Section.alwaysHidden.tint, isActive: engine.reveal == .all))
                .help(engine.reveal == .all ? tr("收起永久隐藏项目", "Collapse Always-Hidden Items") : tr("显示永久隐藏项目", "Reveal Always-Hidden Items"))
            }

            FloatingBarSeparator()

            FloatingBarGearButton(
                engine: engine,
                loupeCoordinator: loupeCoordinator,
                onOpenSettings: onOpenSettings,
                onExpandInline: onExpandInline
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .settingsGlass(cornerRadius: 26)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.13), radius: 7, y: 3)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 2, y: 1)
        }
    }
}

private struct FloatingBarSeparator: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.02),
                        Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.16),
                        Color.primary.opacity(0.02),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}

// MARK: - Unified Liquid Glass Optical Loupe Card & Cascading Submenu Flyout

private struct FloatingLensLoupeView: View {
    let item: FloatingBarItem
    let pointerOffsetX: CGFloat
    var maxBodyHeight: CGFloat = 560
    @ObservedObject var engine: DividerEngine
    @ObservedObject var coordinator: LensLoupeCoordinator
    @State private var copiedIPFeedback = false

    private var colorScheme: ColorScheme { engine.effectiveColorScheme }

    private var displayRows: [LensFactRow] {
        if !item.telemetry.rows.isEmpty {
            return item.telemetry.rows
        }
        // Universal fallback rows for apps that publish neither AXHelp nor AXMenu status lines,
        // ensuring every hovered app in the Floating Bar displays rich live process telemetry.
        if let vitals = item.vitals {
            var rows: [LensFactRow] = [
                LensFactRow(
                    label: tr("内存占用", "Memory"),
                    value: vitals.formattedMemory,
                    tone: vitals.isHighMemory ? .warning : .accent
                ),
                LensFactRow(
                    label: tr("CPU 活跃", "CPU"),
                    value: vitals.formattedCPU,
                    tone: vitals.isHighCPU ? .warning : .neutral
                ),
            ]
            if let multi = item.badgeCount, multi > 1 {
                rows.append(LensFactRow(
                    label: tr("顶栏图标", "Status Items"),
                    value: tr("\(multi) 个关联项", "\(multi) items"),
                    tone: .neutral
                ))
            } else {
                rows.append(LensFactRow(
                    label: tr("运行状态", "State"),
                    value: tr("后台常驻就绪", "Running in menu bar"),
                    tone: .active
                ))
            }
            return rows
        }
        return []
    }

    private func inkColor(for tone: LensFactRow.ValueTone) -> Color {
        switch tone {
        case .neutral:
            return .primary.opacity(0.84)
        case .active:
            return BarLensPalette.ink(.green, in: colorScheme)
        case .accent:
            return BarLensPalette.ink(.cyan, in: colorScheme)
        case .warning:
            return BarLensPalette.ink(.orange, in: colorScheme)
        }
    }

    private func triggerNativeMenu(preferredIndex: Int? = nil) {
        coordinator.dismissImmediately()
        switch item.target {
        case .app(let bundleID, _):
            engine.activateFromFloatingBar(bundleID: bundleID, preferredIndex: preferredIndex)
        case .system(let sysItem, _):
            engine.activateFromFloatingBar(systemItem: sysItem)
        }
    }

    private var symmetricConnectorGradient: LinearGradient {
        let glow = colorScheme == .dark
            ? Color(red: 0.36, green: 0.84, blue: 1.0)
            : Color(red: 0.14, green: 0.60, blue: 0.94)
        let center = colorScheme == .dark
            ? Color.white.opacity(0.96)
            : Color(red: 0.06, green: 0.50, blue: 0.90).opacity(0.88)
        return LinearGradient(
            stops: [
                .init(color: glow.opacity(0.0), location: 0.00),
                .init(color: glow.opacity(colorScheme == .dark ? 0.50 : 0.38), location: 0.28),
                .init(color: center, location: 0.50),
                .init(color: glow.opacity(colorScheme == .dark ? 0.50 : 0.38), location: 0.72),
                .init(color: glow.opacity(0.0), location: 1.00),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var hasMiddleBodyContent: Bool {
        if item.telemetry.interactiveControl != nil { return true }
        if !displayRows.isEmpty { return true }
        if case .app = item.target {
            return item.telemetry.statusSubItems.count > 1
                || !item.telemetry.openWindowTitles.isEmpty
                || !item.telemetry.tunnelActions.isEmpty
        }
        return false
    }

    @ViewBuilder
    private var middleBodySections: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let control = item.telemetry.interactiveControl {
                interactiveControlSection(control)
            }

            if case .app(let bundleID, _) = item.target, item.telemetry.statusSubItems.count > 1 {
                statusSubItemsSection(bundleID: bundleID, subItems: item.telemetry.statusSubItems)
            }

            if !displayRows.isEmpty {
                factRowsSection(displayRows)
            }

            if case .app(let bundleID, _) = item.target, !item.telemetry.openWindowTitles.isEmpty {
                openWindowsSection(bundleID: bundleID, titles: item.telemetry.openWindowTitles)
            }

            if case .app(let bundleID, _) = item.target, !item.telemetry.tunnelActions.isEmpty {
                tunnelActionsSection(bundleID: bundleID, actions: item.telemetry.tunnelActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerSection

            if hasMiddleBodyContent {
                CappedProposalLayout(maxWidth: 278, maxHeight: maxBodyHeight) {
                    ViewThatFits(in: .vertical) {
                        middleBodySections
                        ScrollView(.vertical, showsIndicators: true) {
                            middleBodySections
                        }
                    }
                }
            }

            Divider()
                .opacity(colorScheme == .dark ? 0.45 : 0.35)

            footerQuickBar
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 304)
        .settingsGlass(cornerRadius: 18)
        .overlay(alignment: .top) {
            // Palindromic 5-stop optical connector beam centered to the sub-pixel beneath the hovered icon.
            Capsule()
                .fill(symmetricConnectorGradient)
                .frame(width: 32, height: 2.2)
                .offset(x: pointerOffsetX, y: 0.5)
                .allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.36 : 0.14), radius: 9, y: 4)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 2.5, y: 1)
        }
        // Top 8pt padding acts as a seamless hover bridge right below the Floating Bar capsule;
        // symmetric 14pt left & right padding keeps the 304pt card dead-center inside the 332pt panel.
        .padding(.top, 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: 332)
        .contentShape(Rectangle())
        .environment(\.colorScheme, colorScheme)
        .preferredColorScheme(colorScheme)
        .onHover { hovering in
            coordinator.loupeHoverChanged(hovering) { isInside in
                engine.isLensLoupeHovered = isInside
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.055))
                    .frame(width: 24, height: 24)
                if let icon = item.icon {
                    if item.isTemplateIcon {
                        Image(nsImage: icon)
                            .renderingMode(.template)
                            .resizable()
                            .interpolation(.high)
                            .foregroundStyle(.primary.opacity(0.92))
                            .frame(width: 15, height: 15)
                    } else {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 17, height: 17)
                    }
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(BarLensPalette.ink(.cyan, in: colorScheme))
                }
            }

            Text(item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let unread = item.telemetry.unreadBadge {
                Text(tr("未读 \(unread)", "\(unread) Unread"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color(red: 0.90, green: 0.25, blue: 0.24), in: Capsule())
            } else if let pulse = item.pulseEvent {
                Text(tr("刚更新", "Updated"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .foregroundStyle(BarLensPalette.ink(pulse.reason.tone, in: colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(BarLensPalette.badgeFill(pulse.reason.tone, in: colorScheme), in: Capsule())
            } else if item.isShielded {
                Text(tr("净空暂收", "Shielded"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .foregroundStyle(BarLensPalette.ink(.indigo, in: colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(BarLensPalette.badgeFill(.indigo, in: colorScheme), in: Capsule())
            } else if item.isSpatialOverflow {
                Text(tr("容量暂收", "Tucked"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .foregroundStyle(BarLensPalette.ink(.teal, in: colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(BarLensPalette.badgeFill(.teal, in: colorScheme), in: Capsule())
            }

            Spacer(minLength: 4)

            if let vitals = item.vitals {
                let warn = vitals.isHighMemory || vitals.isHighCPU
                Text(vitals.compactSummary)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .foregroundStyle(
                        warn
                            ? BarLensPalette.ink(.orange, in: colorScheme)
                            : .primary.opacity(0.68)
                    )
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(
                        warn
                            ? BarLensPalette.badgeFill(.orange, in: colorScheme)
                            : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)),
                        in: Capsule()
                    )
            } else if let chip = item.telemetry.shortChip {
                Text(chip)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BarLensPalette.ink(.cyan, in: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 132, alignment: .trailing)
            }
        }
    }

    // MARK: Multi-Icon Status Modules (e.g. iStat Menus, Stats)

    private func statusSubItemsSection(bundleID: String, subItems: [StatusSubItemOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("顶栏模块", "Status Bar Modules"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.56))
                .padding(.leading, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(subItems) { sub in
                        LoupeChipButton(
                            title: sub.title,
                            icon: "menubar.arrow.down.rectangle",
                            isSelected: false
                        ) {
                            triggerNativeMenu(preferredIndex: sub.indexInApp)
                        }
                    }
                }
            }
        }
    }

    // MARK: Structured Fact Rows (Geometry-Driven Universal Layout)

    private func isPathOrURL(_ text: String) -> Bool {
        text.contains("://") || text.hasPrefix("/") || text.hasPrefix("~/")
    }

    private func splitInlineFacets(_ text: String) -> [String] {
        for sep in [" · ", " • ", " | "] {
            if text.contains(sep) {
                let parts = text.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    return parts
                }
            }
        }
        return [text]
    }

    @ViewBuilder
    private func clauseOrProseView(_ text: String,
                                   font: Font,
                                   color: Color,
                                   dotColor: Color,
                                   maxLines: Int = 2) -> some View {
        let facets = splitInlineFacets(text)
        if facets.count >= 2 {
            FlowClauseLayout(horizontalGap: 5.5, verticalSpacing: 2.5, maxLines: maxLines) {
                ForEach(Array(facets.enumerated()), id: \.offset) { idx, facet in
                    if idx > 0 {
                        Circle()
                            .fill(dotColor)
                    }
                    Text(facet)
                        .font(font)
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(isPathOrURL(facet) ? .middle : .tail)
                }
            }
        } else {
            Text(text)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .lineLimit(maxLines)
                .truncationMode(isPathOrURL(text) ? .middle : .tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factRowsSection(_ rows: [LensFactRow]) -> some View {
        let hasLabelledRows = rows.contains { ($0.label?.isEmpty == false) }
        let showDividers = rows.count > 1

        return VStack(alignment: .leading, spacing: 5.5) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                if idx > 0 && showDividers {
                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.05))
                        .frame(height: 0.6)
                }
                factRowView(row, hasLabelledSiblings: hasLabelledRows)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.038))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                    lineWidth: 0.65
                )
        }
    }

    @ViewBuilder
    private func factRowView(_ row: LensFactRow, hasLabelledSiblings: Bool) -> some View {
        let primaryColor = inkColor(for: row.tone)
        let unlabelledColor: Color = row.tone == .neutral ? .primary.opacity(0.84) : primaryColor

        if let label = row.label, !label.isEmpty {
            VStack(alignment: .leading, spacing: 2.5) {
                AdaptiveKeyValueLayout(horizontalSpacing: 10, verticalSpacing: 2) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.66))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    clauseOrProseView(
                        row.value,
                        font: .system(size: 11, weight: .semibold, design: .rounded),
                        color: primaryColor,
                        dotColor: primaryColor.opacity(0.45),
                        maxLines: 2
                    )
                }

                if let detail = row.detail, !detail.isEmpty {
                    clauseOrProseView(
                        detail,
                        font: .system(size: 10, weight: .medium, design: .rounded),
                        color: .primary.opacity(0.58),
                        dotColor: .primary.opacity(0.32),
                        maxLines: 2
                    )
                }
            }
        } else if hasLabelledSiblings {
            VStack(alignment: .leading, spacing: 2.5) {
                clauseOrProseView(
                    row.value,
                    font: .system(size: 11, weight: .medium, design: .rounded),
                    color: unlabelledColor,
                    dotColor: unlabelledColor.opacity(0.45),
                    maxLines: 2
                )
                if let detail = row.detail, !detail.isEmpty {
                    clauseOrProseView(
                        detail,
                        font: .system(size: 10, weight: .medium, design: .rounded),
                        color: .primary.opacity(0.58),
                        dotColor: .primary.opacity(0.32),
                        maxLines: 2
                    )
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(primaryColor)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2.5) {
                    clauseOrProseView(
                        row.value,
                        font: .system(size: 11, weight: .medium, design: .rounded),
                        color: unlabelledColor,
                        dotColor: unlabelledColor.opacity(0.45),
                        maxLines: 2
                    )
                    if let detail = row.detail, !detail.isEmpty {
                        clauseOrProseView(
                            detail,
                            font: .system(size: 10, weight: .medium, design: .rounded),
                            color: .primary.opacity(0.58),
                            dotColor: .primary.opacity(0.32),
                            maxLines: 2
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Active Application Windows

    private func openWindowsSection(bundleID: String, titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("活动窗口", "Active Windows"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.56))
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 3.5) {
                ForEach(titles, id: \.self) { winTitle in
                    LoupeActionRowButton(
                        icon: "macwindow",
                        title: winTitle,
                        trailing: nil,
                        showsSubmenuChevron: false,
                        isHighlighted: false,
                        onHoverChanged: { isHovering, _ in
                            if isHovering { coordinator.nonSubmenuRowHovered() }
                        },
                        action: {
                            coordinator.dismissImmediately()
                            engine.focusApplicationWindow(bundleID: bundleID, windowTitle: winTitle)
                        }
                    )
                }
            }
        }
    }

    // MARK: Interactive System & Media Controls

    @ViewBuilder
    private func interactiveControlSection(_ control: LensInteractiveControl) -> some View {
        switch control {
        case .audioOutput(let volume, let isMuted, _, let devices):
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    LoupeIconSquareButton(
                        symbol: isMuted ? "speaker.slash.fill" : (volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"),
                        tint: isMuted ? BarLensPalette.ink(.orange, in: colorScheme) : BarLensPalette.ink(.cyan, in: colorScheme)
                    ) {
                        SystemTelemetryReader.shared.toggleOutputMute()
                        engine.bumpSystemTelemetry()
                    }

                    LiquidGlassVolumeBar(volume: isMuted ? 0 : volume) { newVol in
                        SystemTelemetryReader.shared.setOutputVolume(newVol)
                        engine.bumpSystemTelemetry()
                    }

                    Text(isMuted ? tr("静音", "Mute") : "\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.86))
                        .frame(width: 34, alignment: .trailing)
                }

                if devices.count > 1 {
                    VStack(alignment: .leading, spacing: 3.5) {
                        ForEach(devices) { dev in
                            LoupeActionRowButton(
                                icon: dev.isCurrent ? "checkmark.circle.fill" : "hifispeaker",
                                title: dev.name,
                                trailing: dev.isCurrent ? tr("当前", "Active") : nil,
                                showsSubmenuChevron: false,
                                isHighlighted: dev.isCurrent
                            ) {
                                SystemTelemetryReader.shared.selectOutputDevice(dev.id)
                                engine.bumpSystemTelemetry()
                            }
                        }
                    }
                }
            }

        case .inputSources(let sources):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(sources) { src in
                        LoupeChipButton(
                            title: src.name,
                            icon: src.isCurrent ? "checkmark" : nil,
                            isSelected: src.isCurrent
                        ) {
                            SystemTelemetryReader.shared.selectInputSource(id: src.id)
                            engine.bumpSystemTelemetry()
                        }
                    }
                }
            }

        case .networkInfo(let localIPv4, _, _):
            if let ip = localIPv4, !ip.isEmpty {
                HStack(spacing: 6) {
                    LoupeChipButton(
                        title: copiedIPFeedback ? tr("已复制 \(ip)", "Copied \(ip)") : tr("复制本机 IP", "Copy Local IP"),
                        icon: copiedIPFeedback ? "checkmark" : "doc.on.doc",
                        isSelected: copiedIPFeedback
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                        copiedIPFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedIPFeedback = false
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

        case .stageManager(let isEnabled):
            HStack(spacing: 6) {
                LoupeChipButton(
                    title: isEnabled ? tr("关闭台前调度", "Turn Off Stage Manager") : tr("开启台前调度", "Turn On Stage Manager"),
                    icon: "squares.leading.rectangle",
                    isSelected: isEnabled
                ) {
                    SystemTelemetryReader.shared.toggleStageManager()
                    engine.bumpSystemTelemetry()
                }
                Spacer(minLength: 0)
            }

        case .mediaPlayback(let nowPlayingHint):
            VStack(alignment: .leading, spacing: 5) {
                if let hint = nowPlayingHint, !hint.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BarLensPalette.ink(.cyan, in: colorScheme))
                        Text(hint)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                HStack(spacing: 8) {
                    LoupeTransportButton(symbol: "backward.fill", label: tr("上一首", "Prev")) {
                        SystemTelemetryReader.sendMediaCommand(.previous)
                    }
                    LoupeTransportButton(symbol: "playpause.fill", label: tr("播放 / 暂停", "Play / Pause"), isPrimary: true) {
                        SystemTelemetryReader.sendMediaCommand(.playPause)
                    }
                    LoupeTransportButton(symbol: "forward.fill", label: tr("下一首", "Next")) {
                        SystemTelemetryReader.sendMediaCommand(.next)
                    }
                }
            }
        }
    }

    // MARK: Submenu Action Tunneling (Direct Click + Hover Cascading Submenu)

    private func tunnelActionsSection(bundleID: String, actions: [LensTunnelAction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("子菜单直达", "Quick Menu Actions"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.56))
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 3.5) {
                ForEach(actions.prefix(6)) { action in
                    let isExpandedParent = (coordinator.activeSubmenu?.action.id == action.id)
                    LoupeActionRowButton(
                        icon: action.isChecked
                            ? "checkmark.circle.fill"
                            : (action.hasSubmenu ? "square.stack.3d.up" : "bolt.fill"),
                        title: action.title,
                        trailing: action.shortcutHint,
                        showsSubmenuChevron: action.hasSubmenu,
                        isHighlighted: action.isChecked || isExpandedParent,
                        onHoverChanged: { isHovering, rowScreenRect in
                            if action.hasSubmenu {
                                coordinator.submenuParentRowHoverChanged(
                                    parentItemID: item.id,
                                    bundleID: bundleID,
                                    action: action,
                                    isHovering: isHovering,
                                    rowScreenRect: rowScreenRect
                                )
                            } else if isHovering {
                                coordinator.nonSubmenuRowHovered()
                            }
                        },
                        action: {
                            if action.hasSubmenu {
                                return
                            }
                            coordinator.dismissImmediately()
                            engine.performTunnelAction(action, bundleID: bundleID)
                        }
                    )
                }
            }
        }
    }

    // MARK: Bottom Utility Bar

    private var footerQuickBar: some View {
        HStack(spacing: 6) {
            switch item.target {
            case .app(let bundleID, _):
                LoupeUtilityButton(icon: "menubar.arrow.down.rectangle", label: tr("菜单", "Menu")) {
                    triggerNativeMenu()
                }
                LoupeUtilityButton(icon: "macwindow", label: tr("唤醒", "Open")) {
                    coordinator.dismissImmediately()
                    engine.activateApplicationWindow(bundleID: bundleID)
                }
                if item.section == .visible && engine.spatialBudgetPolicy != .off {
                    let pinned = engine.isSpatiallyExempt(bundleID)
                    LoupeUtilityButton(
                        icon: pinned ? "pin.slash" : "pin.fill",
                        label: pinned ? tr("解锁", "Unpin") : tr("常驻", "Pin")
                    ) {
                        engine.toggleSpatialExemption(for: bundleID)
                    }
                }
                Spacer(minLength: 4)
                LoupeUtilityButton(icon: "power", label: tr("退出", "Quit"), isDestructive: true) {
                    coordinator.dismissImmediately()
                    engine.quitApplication(bundleID: bundleID)
                }

            case .system(let sysItem, _):
                LoupeUtilityButton(icon: "menubar.arrow.down.rectangle", label: tr("打开面板", "Open Panel")) {
                    triggerNativeMenu()
                }
                if let url = SystemTelemetryReader.systemSettingsURL(for: sysItem.identifier) {
                    LoupeUtilityButton(icon: "slider.horizontal.3", label: tr("系统设置", "Settings")) {
                        coordinator.dismissImmediately()
                        engine.setReveal(.none)
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Secondary Cascading Submenu Flyout View

private struct FloatingLensSubmenuFlyoutView: View {
    let submenu: LensLoupeCoordinator.ActiveSubmenu
    var maxListHeight: CGFloat = 240
    @ObservedObject var engine: DividerEngine
    @ObservedObject var coordinator: LensLoupeCoordinator
    @State private var expandedThirdLevelID: String?

    private var colorScheme: ColorScheme { engine.effectiveColorScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BarLensPalette.ink(.cyan, in: colorScheme))
                Text(submenu.action.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            let children = submenu.action.children
            CappedProposalLayout(maxWidth: 216, maxHeight: maxListHeight) {
                ViewThatFits(in: .vertical) {
                    submenuRowsList(children)
                    ScrollView(.vertical, showsIndicators: true) {
                        submenuRowsList(children)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 236)
        .settingsGlass(cornerRadius: 15)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.13), radius: 8, y: 3)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 2, y: 1)
        }
        // Symmetric 12pt horizontal padding creates a continuous gapless hover bridge with LoupePanel!
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 260)
        .contentShape(Rectangle())
        .environment(\.colorScheme, colorScheme)
        .preferredColorScheme(colorScheme)
        .onHover { hovering in
            coordinator.submenuFlyoutHoverChanged(hovering) { isInside in
                engine.isLensLoupeHovered = isInside
            }
        }
        .onChange(of: submenu.action.id) {
            expandedThirdLevelID = nil
        }
    }

    private func submenuRowsList(_ children: [LensTunnelAction]) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            ForEach(children) { child in
                if !child.isEnabled && !child.hasSubmenu {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 4.5, height: 4.5)
                            .padding(.top, 5)
                        Text(child.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.56))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                } else {
                    let isExpandedThird = (expandedThirdLevelID == child.id)
                    LoupeActionRowButton(
                        icon: child.isChecked
                            ? "checkmark.circle.fill"
                            : (child.hasSubmenu ? "chevron.right.circle" : "bolt.fill"),
                        title: child.title,
                        trailing: child.shortcutHint,
                        showsSubmenuChevron: child.hasSubmenu,
                        isHighlighted: child.isChecked || isExpandedThird,
                        onHoverChanged: { isHovering, _ in
                            if isHovering && child.hasSubmenu {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    expandedThirdLevelID = child.id
                                }
                            }
                        },
                        action: {
                            if child.hasSubmenu {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    expandedThirdLevelID = (expandedThirdLevelID == child.id) ? nil : child.id
                                }
                                return
                            }
                            coordinator.dismissImmediately()
                            engine.performTunnelAction(child, bundleID: submenu.bundleID)
                        }
                    )

                    if child.hasSubmenu && isExpandedThird {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(child.children) { leaf in
                                if !leaf.isEnabled {
                                    Text(leaf.title)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.52))
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                } else {
                                    LoupeActionRowButton(
                                        icon: leaf.isChecked ? "checkmark.circle.fill" : "bolt.fill",
                                        title: leaf.title,
                                        trailing: leaf.shortcutHint,
                                        showsSubmenuChevron: false,
                                        isHighlighted: leaf.isChecked
                                    ) {
                                        coordinator.dismissImmediately()
                                        engine.performTunnelAction(leaf, bundleID: submenu.bundleID)
                                    }
                                }
                            }
                        }
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(BarLensPalette.ink(.cyan, in: colorScheme).opacity(0.35))
                                .frame(width: 2)
                                .padding(.vertical, 3)
                                .padding(.leading, 3)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Universal Geometry-Driven Telemetry Layouts

/// Bounds an unspecified or oversized `ProposedViewSize` along `maxWidth` and/or `maxHeight`
/// so `ViewThatFits` inside `NSHostingController` (`sizingOptions = [.intrinsicContentSize]`)
/// receives a real screen-bounded budget: shrinking tightly to natural size when content fits,
/// and cleanly activating `ScrollView` at the exact cap when content exceeds the screen budget.
struct CappedProposalLayout: Layout {
    var maxWidth: CGFloat? = nil
    var maxHeight: CGFloat? = nil

    private func effective(_ proposal: ProposedViewSize) -> ProposedViewSize {
        // Always propose the explicit cap on any capped axis (even during HStack/VStack 0 and .infinity
        // flexibility probes) so minSize == idealSize == maxSize and parent stacks never invert flexibility.
        let w: CGFloat? = if let maxWidth {
            maxWidth
        } else if proposal.width == 0 || proposal.width == .infinity {
            nil
        } else {
            proposal.width
        }
        let h: CGFloat? = if let maxHeight {
            maxHeight
        } else if proposal.height == 0 || proposal.height == .infinity {
            nil
        } else {
            proposal.height
        }
        return ProposedViewSize(width: w, height: h)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        return first.sizeThatFits(effective(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Adaptive key-value layout that measures real CoreText/SwiftUI glyph geometry (`sizeThatFits`)
/// rather than relying on character-count heuristics:
/// 1. When `label + spacing + value` fits within the row width, places both uncompressed on one line.
/// 2. When `value` is compact (`<= 44%` of width) alongside a long `label` (e.g. Bluetooth/Display names),
///    keeps one horizontal line and truncates `label` cleanly at the tail.
/// 3. When `value` itself is wide and cannot fit beside `label`, stacks `label` above a full-width
///    left-aligned `value`, completely eliminating ragged right-aligned wrapping across all languages.
struct AdaptiveKeyValueLayout: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 2

    private enum Mode {
        case singleLineFull
        case singleLineTruncateLabel
        case stacked
    }

    private func resolveMode(availableWidth: CGFloat,
                             labelIdeal: CGSize,
                             valueIdeal: CGSize) -> Mode {
        if labelIdeal.width + horizontalSpacing + valueIdeal.width <= availableWidth + 0.5 {
            return .singleLineFull
        }
        if valueIdeal.width <= availableWidth * 0.44 {
            return .singleLineTruncateLabel
        }
        return .stacked
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let labelIdeal = subviews[0].sizeThatFits(.unspecified)
        let valueIdeal = subviews[1].sizeThatFits(.unspecified)

        guard let rawW = proposal.width, rawW.isFinite, rawW > 0 else {
            return CGSize(
                width: labelIdeal.width + horizontalSpacing + valueIdeal.width,
                height: max(labelIdeal.height, valueIdeal.height)
            )
        }
        let availableWidth = max(80, rawW)
        switch resolveMode(availableWidth: availableWidth, labelIdeal: labelIdeal, valueIdeal: valueIdeal) {
        case .singleLineFull:
            return CGSize(width: availableWidth, height: max(labelIdeal.height, valueIdeal.height))
        case .singleLineTruncateLabel:
            let valueW = min(valueIdeal.width, availableWidth * 0.44)
            let labelMaxW = max(36, availableWidth - valueW - horizontalSpacing)
            let labelFitted = subviews[0].sizeThatFits(ProposedViewSize(width: labelMaxW, height: nil))
            let valueFitted = subviews[1].sizeThatFits(ProposedViewSize(width: valueW, height: nil))
            return CGSize(width: availableWidth, height: max(labelFitted.height, valueFitted.height))
        case .stacked:
            let labelFitted = subviews[0].sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            let valueFitted = subviews[1].sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            return CGSize(
                width: availableWidth,
                height: labelFitted.height + verticalSpacing + valueFitted.height
            )
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let availableWidth = max(80, bounds.width)
        let labelIdeal = subviews[0].sizeThatFits(.unspecified)
        let valueIdeal = subviews[1].sizeThatFits(.unspecified)

        switch resolveMode(availableWidth: availableWidth, labelIdeal: labelIdeal, valueIdeal: valueIdeal) {
        case .singleLineFull:
            let rowH = max(labelIdeal.height, valueIdeal.height)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (rowH - labelIdeal.height) * 0.5),
                anchor: .topLeading,
                proposal: .unspecified
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + (rowH - valueIdeal.height) * 0.5),
                anchor: .topTrailing,
                proposal: .unspecified
            )

        case .singleLineTruncateLabel:
            let valueW = min(valueIdeal.width, availableWidth * 0.44)
            let labelMaxW = max(36, availableWidth - valueW - horizontalSpacing)
            let labelFitted = subviews[0].sizeThatFits(ProposedViewSize(width: labelMaxW, height: nil))
            let valueFitted = subviews[1].sizeThatFits(ProposedViewSize(width: valueW, height: nil))
            let rowH = max(labelFitted.height, valueFitted.height)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (rowH - labelFitted.height) * 0.5),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: labelMaxW, height: labelFitted.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + (rowH - valueFitted.height) * 0.5),
                anchor: .topTrailing,
                proposal: ProposedViewSize(width: valueW, height: valueFitted.height)
            )

        case .stacked:
            let labelFitted = subviews[0].sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            let valueFitted = subviews[1].sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: availableWidth, height: labelFitted.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + labelFitted.height + verticalSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: availableWidth, height: valueFitted.height)
            )
        }
    }
}

/// Atomic inline-facet flow layout for multi-clause telemetry (`a · b · c`).
/// Subviews alternate `[item0, dot1, item1, dot2, item2, ...]`.
/// Keeps each facet unbroken; when a facet wraps onto the next line, the preceding separator dot
/// is collapsed to `.zero` so lines never end or start with an orphan separator.
struct FlowClauseLayout: Layout {
    var horizontalGap: CGFloat = 5.5
    var dotDiameter: CGFloat = 2.6
    var verticalSpacing: CGFloat = 2.5
    var maxLines: Int = 2

    private struct Placement {
        let subviewIndex: Int
        let origin: CGPoint
        let size: CGSize
    }

    private func compute(availableWidth: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [Placement]) {
        guard !subviews.isEmpty else { return (.zero, []) }
        let itemCount = (subviews.count + 1) / 2
        var placements: [Placement] = []
        placements.reserveCapacity(subviews.count)

        var cursorX: CGFloat = 0
        var lineY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        var lineIndex = 0

        for i in 0..<itemCount {
            let itemSubIdx = i * 2
            guard itemSubIdx < subviews.count else { break }
            let sepSubIdx = (i > 0) ? (itemSubIdx - 1) : nil

            if lineIndex >= maxLines {
                if let sepSubIdx {
                    placements.append(Placement(subviewIndex: sepSubIdx, origin: CGPoint(x: cursorX, y: lineY), size: .zero))
                }
                placements.append(Placement(subviewIndex: itemSubIdx, origin: CGPoint(x: cursorX, y: lineY), size: .zero))
                continue
            }

            let rawSize = subviews[itemSubIdx].sizeThatFits(.unspecified)
            let clampedW = availableWidth.isFinite ? min(rawSize.width, availableWidth) : rawSize.width
            let itemSize = availableWidth.isFinite && rawSize.width > availableWidth
                ? subviews[itemSubIdx].sizeThatFits(ProposedViewSize(width: clampedW, height: nil))
                : CGSize(width: clampedW, height: rawSize.height)

            if i == 0 {
                placements.append(Placement(subviewIndex: itemSubIdx, origin: CGPoint(x: 0, y: lineY), size: itemSize))
                cursorX = itemSize.width
                lineHeight = itemSize.height
                maxLineWidth = max(maxLineWidth, cursorX)
            } else {
                let needed = horizontalGap + dotDiameter + horizontalGap + itemSize.width
                if cursorX + needed <= availableWidth + 0.5 {
                    if let sepSubIdx {
                        let dotY = lineY + (max(lineHeight, itemSize.height) - dotDiameter) * 0.5
                        placements.append(Placement(
                            subviewIndex: sepSubIdx,
                            origin: CGPoint(x: cursorX + horizontalGap, y: dotY),
                            size: CGSize(width: dotDiameter, height: dotDiameter)
                        ))
                    }
                    let itemX = cursorX + horizontalGap + dotDiameter + horizontalGap
                    placements.append(Placement(subviewIndex: itemSubIdx, origin: CGPoint(x: itemX, y: lineY), size: itemSize))
                    cursorX = itemX + itemSize.width
                    lineHeight = max(lineHeight, itemSize.height)
                    maxLineWidth = max(maxLineWidth, cursorX)
                } else {
                    if let sepSubIdx {
                        placements.append(Placement(subviewIndex: sepSubIdx, origin: CGPoint(x: cursorX, y: lineY), size: .zero))
                    }
                    lineIndex += 1
                    if lineIndex >= maxLines {
                        placements.append(Placement(subviewIndex: itemSubIdx, origin: CGPoint(x: 0, y: lineY), size: .zero))
                        continue
                    }
                    lineY += lineHeight + verticalSpacing
                    cursorX = itemSize.width
                    lineHeight = itemSize.height
                    placements.append(Placement(subviewIndex: itemSubIdx, origin: CGPoint(x: 0, y: lineY), size: itemSize))
                    maxLineWidth = max(maxLineWidth, cursorX)
                }
            }
        }

        let totalHeight = lineY + lineHeight
        let resolvedWidth = availableWidth.isFinite ? maxLineWidth : maxLineWidth
        return (CGSize(width: resolvedWidth, height: totalHeight), placements)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let isConstrained = (proposal.width?.isFinite == true) && (proposal.width ?? 0) > 0
        let availableW = isConstrained ? max(60, proposal.width!) : .greatestFiniteMagnitude
        let computed = compute(availableWidth: availableW, subviews: subviews)
        if isConstrained {
            // When queried inside a fixed container width, take full horizontal width only when wrapped,
            // or exact single-line width so right-alignment inside AdaptiveKeyValueLayout stays exact.
            return computed.size
        }
        return computed.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let availableW = max(60, bounds.width)
        let computed = compute(availableWidth: availableW, subviews: subviews)
        for p in computed.placements where p.subviewIndex < subviews.count {
            subviews[p.subviewIndex].place(
                at: CGPoint(x: bounds.minX + p.origin.x, y: bounds.minY + p.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(p.size)
            )
        }
    }
}

// MARK: - Optical Loupe First-Mouse Interactive Subcomponents

private struct LiquidGlassVolumeBar: View {
    let volume: Double
    let onChange: (Double) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let clamped = min(max(volume, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09))
                    .frame(height: 8)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                BarLensPalette.ink(.cyan, in: colorScheme).opacity(0.85),
                                BarLensPalette.ink(.teal, in: colorScheme),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, w * clamped), height: 8)

                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: min(max(0, w * clamped - 6.5), w - 13))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                LoupeScrubberSurface(onScrub: onChange)
            }
        }
        .frame(height: 20)
    }
}

private struct LoupeIconSquareButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 24)
            .background(
                hovered
                    ? (colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10))
                    : (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(pressed ? 0.93 : 1.0)
            .overlay {
                LoupeMouseSurface(
                    onHoverChanged: { isHov, _ in hovered = isHov },
                    onPressedChanged: { pressed = $0 },
                    onClick: action
                )
            }
    }
}

private struct LoupeTransportButton: View {
    let symbol: String
    let label: String
    var isPrimary: Bool = false
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: isPrimary ? 11.5 : 10.5, weight: .semibold))
            if isPrimary {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(
            isPrimary
                ? BarLensPalette.ink(.cyan, in: colorScheme)
                : .primary.opacity(hovered ? 0.94 : 0.78)
        )
        .frame(maxWidth: isPrimary ? .infinity : nil)
        .padding(.horizontal, isPrimary ? 10 : 11)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    hovered
                        ? (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.085))
                        : (isPrimary
                            ? BarLensPalette.badgeFill(.cyan, in: colorScheme)
                            : (colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.04)))
                )
        )
        .scaleEffect(pressed ? 0.95 : 1.0)
        .overlay {
            LoupeMouseSurface(
                onHoverChanged: { isHov, _ in hovered = isHov },
                onPressedChanged: { pressed = $0 },
                onClick: action
            )
        }
    }
}

private struct LoupeActionRowButton: View {
    let icon: String
    let title: String
    let trailing: String?
    var showsSubmenuChevron: Bool = false
    var isHighlighted: Bool = false
    var onHoverChanged: ((Bool, NSRect?) -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    isHighlighted || hovered
                        ? BarLensPalette.ink(.cyan, in: colorScheme)
                        : .primary.opacity(0.65)
                )
                .frame(width: 13)

            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            if showsSubmenuChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(
                        isHighlighted || hovered
                            ? BarLensPalette.ink(.cyan, in: colorScheme)
                            : .primary.opacity(0.45)
                    )
            }
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    hovered
                        ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.075))
                        : (isHighlighted
                            ? BarLensPalette.badgeFill(.cyan, in: colorScheme)
                            : (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)))
                )
        )
        .scaleEffect(pressed && !showsSubmenuChevron ? 0.98 : 1.0)
        .overlay {
            LoupeMouseSurface(
                onHoverChanged: { isHov, rect in
                    hovered = isHov
                    onHoverChanged?(isHov, rect)
                },
                onPressedChanged: { pressed = $0 },
                onClick: action
            )
        }
    }
}

private struct LoupeChipButton: View {
    let title: String
    let icon: String?
    var isSelected: Bool = false
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4.5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(
            isSelected
                ? BarLensPalette.ink(.cyan, in: colorScheme)
                : .primary.opacity(0.86)
        )
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(
                    isSelected
                        ? BarLensPalette.badgeFill(.cyan, in: colorScheme)
                        : (hovered
                            ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                            : (colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045)))
                )
        )
        .scaleEffect(pressed ? 0.95 : 1.0)
        .overlay {
            LoupeMouseSurface(
                onHoverChanged: { isHov, _ in hovered = isHov },
                onPressedChanged: { pressed = $0 },
                onClick: action
            )
        }
    }
}

private struct LoupeUtilityButton: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fg: Color = isDestructive && hovered
            ? Color(red: 0.92, green: 0.26, blue: 0.25)
            : .primary.opacity(hovered ? 0.94 : 0.74)

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(fg)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    hovered
                        ? (isDestructive
                            ? Color(red: 0.92, green: 0.26, blue: 0.25).opacity(colorScheme == .dark ? 0.18 : 0.12)
                            : (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.065)))
                        : Color.clear
                )
        )
        .scaleEffect(pressed ? 0.95 : 1.0)
        .overlay {
            LoupeMouseSurface(
                onHoverChanged: { isHov, _ in hovered = isHov },
                onPressedChanged: { pressed = $0 },
                onClick: action
            )
        }
    }
}

private struct LoupeMouseSurface: NSViewRepresentable {
    let onHoverChanged: (Bool, NSRect?) -> Void
    let onPressedChanged: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> LoupeMouseSurfaceView {
        let v = LoupeMouseSurfaceView()
        v.onHoverChanged = onHoverChanged
        v.onPressedChanged = onPressedChanged
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: LoupeMouseSurfaceView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onPressedChanged = onPressedChanged
        nsView.onClick = onClick
    }
}

private final class LoupeMouseSurfaceView: NSView {
    var onHoverChanged: ((Bool, NSRect?) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isTrackingMouse = false

    private var currentScreenBounds: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true, currentScreenBounds)
    }

    override func mouseExited(with event: NSEvent) {
        if !isTrackingMouse {
            onHoverChanged?(false, nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        onPressedChanged?(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingMouse else { return }
        isTrackingMouse = false
        onPressedChanged?(false)
        let localPt = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -4, dy: -4).contains(localPt) {
            onClick?()
        }
        let localNow = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        if !bounds.contains(localNow) {
            onHoverChanged?(false, nil)
        }
    }
}

private struct LoupeScrubberSurface: NSViewRepresentable {
    let onScrub: (Double) -> Void

    func makeNSView(context: Context) -> LoupeScrubberView {
        let v = LoupeScrubberView()
        v.onScrub = onScrub
        return v
    }

    func updateNSView(_ nsView: LoupeScrubberView, context: Context) {
        nsView.onScrub = onScrub
    }
}

private final class LoupeScrubberView: NSView {
    var onScrub: ((Double) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func report(for event: NSEvent) {
        let w = max(1, bounds.width)
        let pt = convert(event.locationInWindow, from: nil)
        let normalized = min(max(0, Double(pt.x / w)), 1)
        onScrub?(normalized)
    }

    override func mouseDown(with event: NSEvent) {
        report(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        report(for: event)
    }
}

// MARK: - Gear Button & Item Button

private struct FloatingBarGearButton: View {
    @ObservedObject var engine: DividerEngine
    @ObservedObject var loupeCoordinator: LensLoupeCoordinator
    let onOpenSettings: () -> Void
    let onExpandInline: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        FloatingBarCircleChrome(isActive: false, hovered: hovered, isPressed: pressed) {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.86))
                .frame(width: 38, height: 38)
        }
        .overlay {
            FloatingBarItemMouseBridge(
                toolTip: tr("点按打开设置 · 右键打开快捷菜单", "Click: Open Settings · Right-Click: Quick Actions"),
                onHoverChanged: { isHovering, _ in
                    hovered = isHovering
                    if isHovering {
                        loupeCoordinator.dismissImmediately()
                    }
                },
                onPressedChanged: { pressed = $0 },
                onClick: {
                    loupeCoordinator.dismissImmediately()
                    onOpenSettings()
                },
                onDragStarted: nil,
                onDragOffsetChanged: nil,
                onDragEnded: nil,
                onMenuOpenChanged: { isOpen in
                    if isOpen {
                        loupeCoordinator.dismissImmediately()
                        engine.isContextMenuOpen = true
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            engine.isContextMenuOpen = false
                        }
                    }
                },
                buildContextMenu: {
                    let menu = NSMenu()
                    menu.autoenablesItems = false
                    menu.addItem(MenuActionItem(
                        title: tr("切换为菜单栏内展开", "Switch to Inline"),
                        symbol: "menubar.dock.rectangle",
                        actionBlock: onExpandInline
                    ))

                    let lensItem = MenuActionItem(
                        title: tr("光学透视浮窗", "Optical Lens Loupe"),
                        symbol: "sparkle.magnifyingglass"
                    ) {
                        engine.setLensTelemetryEnabled(!engine.lensTelemetryEnabled)
                    }
                    lensItem.state = engine.lensTelemetryEnabled ? .on : .off
                    menu.addItem(lensItem)

                    let shieldItem = MenuActionItem(
                        title: tr("投屏净空盾", "Presentation Shield"),
                        symbol: "shield.lefthalf.filled"
                    ) {
                        engine.togglePresentationShield()
                    }
                    shieldItem.state = engine.isPresentationShieldActive ? .on : .off
                    menu.addItem(shieldItem)

                    menu.addItem(.separator())
                    let budgetHeader = NSMenuItem(title: tr("顶栏容量保护", "Top Bar Budget"), action: nil, keyEquivalent: "")
                    budgetHeader.isEnabled = false
                    menu.addItem(budgetHeader)
                    for policy in SpatialBudgetPolicy.allCases {
                        let item = MenuActionItem(title: policy.title, symbol: policy.symbol) {
                            engine.setSpatialBudgetPolicy(policy)
                        }
                        item.state = (engine.spatialBudgetPolicy == policy) ? .on : .off
                        menu.addItem(item)
                    }

                    menu.addItem(.separator())

                    let iconHeader = NSMenuItem(title: tr("图标样式", "Icon Style"), action: nil, keyEquivalent: "")
                    iconHeader.isEnabled = false
                    menu.addItem(iconHeader)
                    for style in FloatingBarIconDisplayStyle.allCases {
                        let item = MenuActionItem(title: style.title, symbol: style.symbol) {
                            engine.setFloatingBarIconStyle(style)
                        }
                        item.state = (engine.floatingBarIconStyle == style) ? .on : .off
                        menu.addItem(item)
                    }

                    menu.addItem(.separator())
                    let modeHeader = NSMenuItem(title: tr("外观", "Appearance"), action: nil, keyEquivalent: "")
                    modeHeader.isEnabled = false
                    menu.addItem(modeHeader)
                    for mode in AppearanceMode.allCases {
                        let item = MenuActionItem(title: mode.title, symbol: mode.symbol) {
                            engine.setAppearanceMode(mode)
                        }
                        item.state = (engine.appearanceMode == mode) ? .on : .off
                        menu.addItem(item)
                    }

                    menu.addItem(.separator())
                    let langHeader = NSMenuItem(title: tr("语言", "Language"), action: nil, keyEquivalent: "")
                    langHeader.isEnabled = false
                    menu.addItem(langHeader)
                    for lang in AppLanguage.allCases {
                        let item = MenuActionItem(title: lang.title, symbol: "globe") {
                            engine.setAppLanguage(lang)
                        }
                        item.state = (engine.appLanguage == lang) ? .on : .off
                        menu.addItem(item)
                    }

                    if !engine.floatingBarOrder.isEmpty {
                        menu.addItem(.separator())
                        menu.addItem(MenuActionItem(
                            title: tr("重置悬浮栏图标排序", "Reset Icon Order"),
                            symbol: "arrow.counterclockwise"
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                engine.resetFloatingBarOrder()
                            }
                        })
                    }

                    menu.addItem(.separator())
                    menu.addItem(MenuActionItem(
                        title: tr("智能自治设置…", "Smart Bar Settings…"),
                        symbol: "wand.and.stars"
                    ) {
                        engine.requestedSettingsPane = .smart
                        onOpenSettings()
                    })
                    menu.addItem(MenuActionItem(
                        title: tr("使用指南…", "User Guide…"),
                        symbol: "book.closed"
                    ) {
                        engine.requestedSettingsPane = .guide
                        onOpenSettings()
                    })
                    menu.addItem(MenuActionItem(
                        title: tr("打开设置…", "Open Settings…"),
                        symbol: "gearshape",
                        actionBlock: onOpenSettings
                    ))
                    return menu
                }
            )
        }
    }
}

private struct FloatingBarItemButton: View {
    let item: FloatingBarItem
    let itemIndex: Int
    let siblingIDs: [String]
    @ObservedObject var engine: DividerEngine
    @ObservedObject var loupeCoordinator: LensLoupeCoordinator
    @Binding var activeDrag: ActiveFloatingBarDrag?
    @Binding var activeDragTranslationX: CGFloat
    @Binding var settleItemID: String?
    @Binding var settleOffsetX: CGFloat

    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    private var isDraggingThis: Bool {
        activeDrag?.itemID == item.id
    }

    private var isLoupeFocusedOnThis: Bool {
        loupeCoordinator.activeTarget?.itemID == item.id
    }

    private var computedOffsetX: CGFloat {
        if let drag = activeDrag, drag.section == item.section {
            if drag.itemID == item.id {
                return drag.effectiveTranslationX(raw: activeDragTranslationX)
            }
            return drag.neighborShiftX(at: itemIndex)
        }
        if settleItemID == item.id {
            return settleOffsetX
        }
        return 0
    }

    private var isActive: Bool {
        switch item.target {
        case .app:
            return engine.isFloatingBarTargetActive(itemID: item.id)
        case .system(let sysItem, _):
            return engine.isFloatingBarTargetActive(itemID: item.id, systemItem: sysItem)
        }
    }

    private func triggerItem() {
        loupeCoordinator.dismissImmediately()
        switch item.target {
        case .app(let bundleID, _):
            engine.activateFromFloatingBar(bundleID: bundleID)
        case .system(let sysItem, _):
            engine.activateFromFloatingBar(systemItem: sysItem)
        }
    }

    var body: some View {
        FloatingBarCircleChrome(
            isActive: isActive,
            hovered: hovered || isDraggingThis || isLoupeFocusedOnThis,
            isPressed: pressed
        ) {
            ZStack {
                if let pulse = item.pulseEvent, !isActive {
                    Circle()
                        .inset(by: 0.8)
                        .strokeBorder(
                            BarLensPalette.ink(pulse.reason.tone, in: colorScheme).opacity(0.72),
                            lineWidth: 1.25
                        )
                } else if item.isShielded && !isActive {
                    Circle()
                        .inset(by: 1)
                        .strokeBorder(
                            BarLensPalette.ink(.indigo, in: colorScheme).opacity(0.50),
                            lineWidth: 1.1
                        )
                } else if item.isSpatialOverflow && !isActive {
                    Circle()
                        .inset(by: 1)
                        .strokeBorder(
                            BarLensPalette.ink(.teal, in: colorScheme).opacity(0.45),
                            lineWidth: 1.1
                        )
                }

                if let icon = item.icon {
                    if item.isTemplateIcon {
                        Image(nsImage: icon)
                            .renderingMode(.template)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .foregroundStyle(
                                isActive
                                    ? Color(red: 0.08, green: 0.10, blue: 0.16)
                                    : (item.section == .alwaysHidden ? item.section.readableTint(in: colorScheme) : .primary.opacity(0.94))
                            )
                            .frame(width: 18, height: 18)
                    } else {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .frame(width: 22, height: 22)
                    }
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(
                            isActive
                                ? Color(red: 0.08, green: 0.10, blue: 0.16)
                                : (item.section == .alwaysHidden ? item.section.readableTint(in: colorScheme) : .primary.opacity(0.94))
                        )
                        .frame(width: 22, height: 22)
                }

                // Only display genuine numeric unread counts on the icon badge — never static status dots.
                if let unread = item.telemetry.unreadBadge {
                    Text(unread)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Color(red: 0.90, green: 0.25, blue: 0.24), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.75), lineWidth: 0.7)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 3, y: -1)
                }

                if let count = item.badgeCount {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 0.5)
                        .background(
                            item.section == .alwaysHidden
                                ? Color(red: 0.50, green: 0.20, blue: 0.84)
                                : BarLensPalette.selectionFill(in: colorScheme),
                            in: Capsule()
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(x: 4, y: 3)
                }
            }
            .frame(width: 38, height: 38)
        }
        .scaleEffect(isDraggingThis ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isDraggingThis)
        .offset(x: computedOffsetX)
        .zIndex(isDraggingThis || settleItemID == item.id ? 20 : 0)
        .overlay {
            FloatingBarItemMouseBridge(
                toolTip: engine.lensTelemetryEnabled
                    ? ""
                    : tr("\(item.title) · 点按打开菜单 · 按住左右拖拽排序 · 右键快捷操作",
                         "\(item.title) · Click: Menu · Drag: Reorder · Right-Click: Actions"),
                onHoverChanged: { isHovering, screenRect in
                    hovered = isHovering
                    if activeDrag == nil && !engine.isContextMenuOpen {
                        loupeCoordinator.iconHoverChanged(
                            itemID: item.id,
                            isHovering: isHovering,
                            screenRect: screenRect,
                            lensEnabled: engine.lensTelemetryEnabled
                        )
                    }
                },
                onPressedChanged: { pressed = $0 },
                onClick: triggerItem,
                onDragStarted: {
                    loupeCoordinator.dismissImmediately()
                    settleItemID = nil
                    settleOffsetX = 0
                    activeDragTranslationX = 0
                    activeDrag = ActiveFloatingBarDrag(
                        itemID: item.id,
                        section: item.section,
                        siblingIDs: siblingIDs,
                        startIndex: itemIndex,
                        targetIndex: itemIndex
                    )
                },
                onDragOffsetChanged: { rawDX in
                    activeDragTranslationX = rawDX
                    if let current = activeDrag, current.itemID == item.id {
                        let newTarget = current.computedTargetIndex(for: rawDX)
                        if newTarget != current.targetIndex {
                            withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.92)) {
                                activeDrag?.targetIndex = newTarget
                            }
                        }
                    }
                },
                onDragEnded: {
                    guard let finished = activeDrag, finished.itemID == item.id else { return }
                    let finalTarget = finished.targetIndex
                    let currentVisualX = finished.effectiveTranslationX(raw: activeDragTranslationX)
                    let slotShiftX = CGFloat(finalTarget - finished.startIndex) * ActiveFloatingBarDrag.slotStride
                    let residualX = currentVisualX - slotShiftX

                    var snapTx = Transaction()
                    snapTx.disablesAnimations = true
                    withTransaction(snapTx) {
                        if finalTarget != finished.startIndex {
                            engine.moveFloatingBarItemToIndex(finished.itemID, toIndex: finalTarget, within: finished.siblingIDs)
                        }
                        activeDrag = nil
                        activeDragTranslationX = 0
                        settleItemID = finished.itemID
                        settleOffsetX = residualX
                    }

                    let settledID = finished.itemID
                    DispatchQueue.main.async {
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.94)) {
                            settleOffsetX = 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            if settleItemID == settledID && settleOffsetX == 0 {
                                settleItemID = nil
                            }
                        }
                    }
                },
                onMenuOpenChanged: { isOpen in
                    if isOpen {
                        loupeCoordinator.dismissImmediately()
                        engine.isContextMenuOpen = true
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            engine.isContextMenuOpen = false
                        }
                    }
                },
                buildContextMenu: {
                    buildItemContextMenu()
                }
            )
        }
    }

    private func buildItemContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let headerTitle: String
        if let vitals = item.vitals {
            headerTitle = "\(item.title) · \(vitals.compactSummary)"
        } else {
            headerTitle = item.title
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let summary = item.telemetry.fullSummary {
            let statusLine = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            statusLine.isEnabled = false
            menu.addItem(statusLine)
        }

        menu.addItem(MenuActionItem(
            title: tr("打开 / 收起菜单", "Open / Toggle Menu"),
            symbol: "menubar.arrow.down.rectangle",
            actionBlock: triggerItem
        ))

        if case .app(let bundleID, _) = item.target {
            menu.addItem(MenuActionItem(
                title: tr("唤醒应用窗口", "Open App Window"),
                symbol: "macwindow"
            ) {
                engine.activateApplicationWindow(bundleID: bundleID)
            })

            if !item.telemetry.tunnelActions.isEmpty {
                menu.addItem(.separator())
                let tunnelHeader = NSMenuItem(title: tr("子菜单直达", "Quick Menu Actions"), action: nil, keyEquivalent: "")
                tunnelHeader.isEnabled = false
                menu.addItem(tunnelHeader)
                func makeTunnelNSMenuItem(_ action: LensTunnelAction) -> NSMenuItem {
                    if action.hasSubmenu {
                        let parent = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                        if let img = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil) {
                            let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)
                            parent.image = img.withSymbolConfiguration(cfg) ?? img
                        }
                        let sub = NSMenu(title: action.title)
                        sub.autoenablesItems = false
                        for child in action.children {
                            sub.addItem(makeTunnelNSMenuItem(child))
                        }
                        parent.submenu = sub
                        return parent
                    } else if !action.isEnabled {
                        let disabled = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                        disabled.isEnabled = false
                        return disabled
                    } else {
                        let leaf = MenuActionItem(
                            title: action.title,
                            symbol: action.isChecked ? "checkmark.circle" : "bolt"
                        ) {
                            engine.performTunnelAction(action, bundleID: bundleID)
                        }
                        leaf.state = action.isChecked ? .on : .off
                        return leaf
                    }
                }
                for action in item.telemetry.tunnelActions.prefix(6) {
                    menu.addItem(makeTunnelNSMenuItem(action))
                }
            }
        }

        if case .app(let bundleID, _) = item.target,
           item.section == .visible,
           engine.hasActivePinningConsumers {
            let exempt = engine.isSpatiallyExempt(bundleID)
            let pinItem = MenuActionItem(
                title: exempt
                    ? tr("取消顶栏锁定常驻", "Unpin from Top Bar")
                    : tr("锁定顶栏常驻", "Pin to Top Bar"),
                symbol: exempt ? "pin.slash" : "pin.fill"
            ) {
                engine.toggleSpatialExemption(for: bundleID)
            }
            pinItem.state = exempt ? .on : .off
            menu.addItem(pinItem)
        }

        let orderedSiblings = engine.floatingBarOrder.sorted(siblingIDs, id: { $0 })
        if orderedSiblings.count > 1, let idx = orderedSiblings.firstIndex(of: item.id) {
            menu.addItem(.separator())
            let orderHeader = NSMenuItem(title: tr("图标排序", "Icon Order"), action: nil, keyEquivalent: "")
            orderHeader.isEnabled = false
            menu.addItem(orderHeader)

            if idx > 0 {
                menu.addItem(MenuActionItem(
                    title: tr("向左移一位", "Move Left"),
                    symbol: "arrow.left"
                ) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        engine.moveFloatingBarItemByStep(item.id, delta: -1, within: orderedSiblings)
                    }
                })
                if orderedSiblings.count > 2 {
                    menu.addItem(MenuActionItem(
                        title: tr("移至最前", "Move to Front"),
                        symbol: "arrow.left.to.line"
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            engine.moveFloatingBarItemToEdge(item.id, toFront: true, within: orderedSiblings)
                        }
                    })
                }
            }
            if idx < orderedSiblings.count - 1 {
                menu.addItem(MenuActionItem(
                    title: tr("向右移一位", "Move Right"),
                    symbol: "arrow.right"
                ) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        engine.moveFloatingBarItemByStep(item.id, delta: 1, within: orderedSiblings)
                    }
                })
                if orderedSiblings.count > 2 {
                    menu.addItem(MenuActionItem(
                        title: tr("移至最后", "Move to End"),
                        symbol: "arrow.right.to.line"
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            engine.moveFloatingBarItemToEdge(item.id, toFront: false, within: orderedSiblings)
                        }
                    })
                }
            }
            if !engine.floatingBarOrder.isEmpty {
                menu.addItem(MenuActionItem(
                    title: tr("重置图标排序", "Reset Icon Order"),
                    symbol: "arrow.counterclockwise"
                ) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        engine.resetFloatingBarOrder()
                    }
                })
            }
        }

        menu.addItem(.separator())
        let secHeader = NSMenuItem(title: tr("移至分区", "Move to Section"), action: nil, keyEquivalent: "")
        secHeader.isEnabled = false
        menu.addItem(secHeader)

        let choices: [SectionModel.Section] = engine.alwaysHiddenEnabled
            ? [.visible, .hidden, .alwaysHidden]
            : [.visible, .hidden]
        for section in choices {
            let menuItem = MenuActionItem(title: section.title, symbol: section.symbol) {
                switch item.target {
                case .app(let bundleID, _):
                    engine.setSection(section, for: bundleID)
                case .system(let sysItem, _):
                    engine.setSection(section, for: sysItem)
                }
            }
            menuItem.state = (item.section == section) ? .on : .off
            menu.addItem(menuItem)
        }

        if case .app(let bundleID, _) = item.target {
            let runningApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
            let appURL = runningApp?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            if appURL != nil || runningApp != nil {
                menu.addItem(.separator())
                if let appURL {
                    menu.addItem(MenuActionItem(
                        title: tr("在访达中显示", "Show in Finder"),
                        symbol: "folder"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    })
                }
                if let runningApp {
                    menu.addItem(MenuActionItem(
                        title: tr("退出 \(item.title)", "Quit \(item.title)"),
                        symbol: "xmark.circle"
                    ) {
                        runningApp.terminate()
                    })
                }
            }
        }

        return menu
    }
}

private struct FloatingBarCircleChrome<Content: View>: View {
    let isActive: Bool
    let hovered: Bool
    let isPressed: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .background {
                if isActive {
                    Circle()
                        .inset(by: 0.5)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.92 : 0.96))
                        .shadow(color: Color.accentColor.opacity(0.28), radius: 5, y: 1.5)
                } else if hovered {
                    Circle()
                        .inset(by: 0.5)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.13)
                                : Color.black.opacity(0.065)
                        )
                }
            }
            .overlay {
                if isActive {
                    Circle()
                        .inset(by: 0.5)
                        .strokeBorder(Color.white, lineWidth: 1)
                } else if hovered {
                    Circle()
                        .inset(by: 0.5)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.32 : 0.78),
                                    Color.white.opacity(0.06),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.85
                        )
                }
            }
            .scaleEffect(isPressed ? 0.92 : (hovered ? 1.04 : 1.0))
            .offset(y: hovered && !isPressed ? -0.5 : 0)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

private final class MenuActionItem: NSMenuItem {
    private let actionBlock: () -> Void

    init(title: String, symbol: String? = nil, actionBlock: @escaping () -> Void) {
        self.actionBlock = actionBlock
        super.init(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        self.target = self
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)
            self.image = img.withSymbolConfiguration(cfg) ?? img
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke(_ sender: Any?) {
        actionBlock()
    }
}

private struct FloatingBarItemMouseBridge: NSViewRepresentable {
    let toolTip: String
    let onHoverChanged: (Bool, NSRect?) -> Void
    let onPressedChanged: (Bool) -> Void
    let onClick: () -> Void
    let onDragStarted: (() -> Void)?
    let onDragOffsetChanged: ((CGFloat) -> Void)?
    let onDragEnded: (() -> Void)?
    let onMenuOpenChanged: (Bool) -> Void
    let buildContextMenu: () -> NSMenu

    func makeNSView(context: Context) -> FloatingBarItemMouseView {
        let view = FloatingBarItemMouseView()
        applyCallbacks(to: view)
        return view
    }

    func updateNSView(_ nsView: FloatingBarItemMouseView, context: Context) {
        applyCallbacks(to: nsView)
    }

    private func applyCallbacks(to view: FloatingBarItemMouseView) {
        view.toolTip = toolTip
        view.onHoverChanged = onHoverChanged
        view.onPressedChanged = onPressedChanged
        view.onClick = onClick
        view.onDragStarted = onDragStarted
        view.onDragOffsetChanged = onDragOffsetChanged
        view.onDragEnded = onDragEnded
        view.onMenuOpenChanged = onMenuOpenChanged
        view.buildContextMenu = buildContextMenu
    }
}

private final class FloatingBarItemMouseView: NSView {
    var onHoverChanged: ((Bool, NSRect?) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragOffsetChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onMenuOpenChanged: ((Bool) -> Void)?
    var buildContextMenu: (() -> NSMenu)?

    private var trackingArea: NSTrackingArea?
    private var isTrackingLeftMouse = false
    private var didEnterDrag = false
    private var anchorScreenX: CGFloat = 0
    private var anchorScreenY: CGFloat = 0

    private var currentScreenBounds: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true, currentScreenBounds)
    }

    override func mouseExited(with event: NSEvent) {
        if !isTrackingLeftMouse {
            onHoverChanged?(false, nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentContextMenu(with: event)
            return
        }
        isTrackingLeftMouse = true
        didEnterDrag = false
        let mouse = NSEvent.mouseLocation
        anchorScreenX = mouse.x
        anchorScreenY = mouse.y
        onPressedChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingLeftMouse else { return }
        guard onDragStarted != nil else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - anchorScreenX
        let dy = mouse.y - anchorScreenY

        if !didEnterDrag {
            guard hypot(dx, dy) >= 3.5 else { return }
            didEnterDrag = true
            anchorScreenX = mouse.x
            onPressedChanged?(false)
            onDragStarted?()
            onDragOffsetChanged?(0)
            return
        }

        onDragOffsetChanged?(dx)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingLeftMouse else { return }
        isTrackingLeftMouse = false
        onPressedChanged?(false)

        if didEnterDrag {
            didEnterDrag = false
            onDragEnded?()
        } else {
            let localPt = convert(event.locationInWindow, from: nil)
            if bounds.insetBy(dx: -4, dy: -4).contains(localPt) {
                onClick?()
            }
        }

        let localNow = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        if !bounds.contains(localNow) {
            onHoverChanged?(false, nil)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        buildContextMenu?()
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        isTrackingLeftMouse = false
        didEnterDrag = false
        onPressedChanged?(false)
        onMenuOpenChanged?(true)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        onMenuOpenChanged?(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        presentContextMenu(with: event)
    }

    private func presentContextMenu(with event: NSEvent) {
        guard let menu = buildContextMenu?() else { return }
        isTrackingLeftMouse = false
        didEnterDrag = false
        onPressedChanged?(false)
        onMenuOpenChanged?(true)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        onMenuOpenChanged?(false)
    }
}

private struct FloatingBarCapsuleStyle: ButtonStyle {
    let tint: Color
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        FloatingBarCapsuleFeedback(configuration: configuration, tint: tint, isActive: isActive)
    }
}

private struct FloatingBarCapsuleFeedback: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isActive: Bool
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let topAlpha: Double = colorScheme == .dark
            ? (hovered ? 0.38 : (isActive ? 0.32 : 0.26))
            : (hovered ? 0.24 : (isActive ? 0.20 : 0.16))
        let bottomAlpha: Double = colorScheme == .dark
            ? (hovered ? 0.20 : 0.14)
            : (hovered ? 0.13 : 0.09)

        configuration.label
            .background(
                LinearGradient(
                    colors: [tint.opacity(topAlpha), tint.opacity(bottomAlpha)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay {
                LiquidGlassRim(cornerRadius: 18, tint: tint, intensity: hovered ? 1.15 : 0.92)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : (hovered ? 1.03 : 1.0))
            .offset(y: hovered && !configuration.isPressed ? -1.0 : 0)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = $0 }
    }
}
