import AppKit
import SwiftUI

/// The menu bar dot, its quick panel, and the settings window.
///
/// One status item only. An earlier version also had a marker for the
/// always-hidden boundary, but a boundary defined by a marker has to stay on
/// the bar at all times to mean anything — and that marker was both in the way
/// and easy to mis-drop, which could sweep the whole bar into the hidden
/// section. Sections are lists now, so the only thing that needs to be in the
/// bar is the thing the user clicks.
///
/// The dot must be a real `NSStatusItem` — that is what makes ⌘-drag reorder it
/// like any other item. It only survives while the app is installed in
/// /Applications; MenuBarAgent files status items under the owning app's bundle
/// identifier only when LaunchServices knows the bundle, and looks items up
/// that way while a visibility restriction is active. See build.sh.
final class DividerController: NSObject, NSPopoverDelegate {

    private let engine = DividerEngine()
    private lazy var settings = SettingsWindowController(engine: engine)
    private lazy var onboarding = OnboardingWindowController(
        engine: engine,
        onOpenSettings: { [weak self] pane in
            self?.settings.present(pane: pane)
        }
    )

    private var dotItem: NSStatusItem?
    private var dotPulseBadgeView: DotPulseBadgeView?
    private var proxyItems: [String: NSStatusItem] = [:]
    private var proxyItemTargets: [String: SystemItem] = [:]
    private var rightClickMonitor: Any?
    private var topBarClickMonitor: Any?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var panelKeyMonitor: Any?
    private var hoverRevealWork: DispatchWorkItem?
    private var lastHandledScrollTimestamp: TimeInterval = -1
    private var lastScrollSampleAt: Date = .distantPast
    private var lastDiscreteStepAt: Date = .distantPast
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private var scrollPhaseConsumed = false
    private var quickPopover: NSPopover?
    private let quickCatalog = Catalog()
    private lazy var floatingBar = FloatingBarController(
        engine: engine,
        catalog: quickCatalog,
        onOpenSettings: { [weak self] in self?.openSettings() }
    )

    /// When the dot was last clicked, for detecting a double click by hand.
    private var lastDotClick: Date?
    /// The reveal state before the current click, so the second click of a
    /// double click can undo the first one's toggle and peek instead.
    private var revealBeforeClick: SectionModel.Reveal = .none

    func start() {
        engine.start()             // heartbeat + permission polling
        engine.onChange = { [weak self] in self?.refresh() }
        engine.onReplayOnboarding = { [weak self] in
            self?.onboarding.present()
        }

        closeQuickPanel()
        createDot()
        monitorRightClicks()
        monitorTopBarClicks()
        monitorScrollWheel()
        monitorPanelKeys()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(systemChanged), name: name, object: nil)
        }

        refresh()
        engine.apply()
        showWelcomeIfNeeded()
    }

    /// Present the interactive 4-step Liquid Glass onboarding tour the first
    /// time BarLens runs on a new installation.
    private func showWelcomeIfNeeded() {
        guard !Defaults.hasCompletedOnboarding && !Defaults.hasShownWelcome else { return }
        Defaults.hasShownWelcome = true
        Defaults.hasCompletedOnboarding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.onboarding.present()
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        onboarding.close()
        quickPopover?.animates = false
        closeQuickPanel()
        floatingBar.hide()
        quickPopover?.contentViewController = nil
        quickPopover = nil
        engine.stop()
        hoverRevealWork?.cancel()
        hoverRevealWork = nil
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        if let topBarClickMonitor { NSEvent.removeMonitor(topBarClickMonitor) }
        topBarClickMonitor = nil
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        localScrollMonitor = nil
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        globalScrollMonitor = nil
        if let panelKeyMonitor { NSEvent.removeMonitor(panelKeyMonitor) }
        panelKeyMonitor = nil
        if let dotItem { NSStatusBar.system.removeStatusItem(dotItem) }
        dotItem = nil
        dotPulseBadgeView = nil
        for (_, item) in proxyItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        proxyItems.removeAll()
        proxyItemTargets.removeAll()
    }

    // MARK: - The dot

    private func createDot() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The autosave name is what MenuBarAgent files the item under, and what
        // makes macOS remember where the user dragged it.
        item.autosaveName = "BarLens.dot"
        item.behavior = []
        if let button = item.button {
            button.title = "●"
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.toolTip = tr("单击展开 · 双击全部显示 · 右键快速检视", "Click: Toggle Hidden · Double-Click: Reveal All · Right-Click: Quick Panel")
            // Third-party status items carry no identifier, so this is how the
            // dot is picked out of an Accessibility snapshot.
            button.setAccessibilityIdentifier("BarLens.dot")
            button.setAccessibilityTitle("BarLens.dot")
            button.target = self
            button.action = #selector(dotClicked)
            // Deliberately left on the default action mask. Adding
            // `.rightMouseUp` through `sendAction(on:)` stops the button
            // delivering *any* action — measured, and the reason clicks did
            // nothing for a while. Right clicks are picked up by a monitor
            // instead; see monitorRightClicks().
            let tracker = DotHoverTrackingView(
                frame: button.bounds,
                onHoverChanged: { [weak self] hovering in
                    self?.handleDotHover(hovering)
                }
            )
            tracker.autoresizingMask = [.width, .height]
            button.addSubview(tracker)

            let badgeView = DotPulseBadgeView(frame: button.bounds)
            badgeView.autoresizingMask = [.width, .height]
            button.addSubview(badgeView)
            dotPulseBadgeView = badgeView
        }
        dotItem = item
    }

    private func handleDotHover(_ hovering: Bool) {
        hoverRevealWork?.cancel()
        hoverRevealWork = nil
        guard hovering,
              let delay = engine.hoverRevealDelay.seconds,
              engine.reveal == .none,
              quickPopover?.isShown != true else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.engine.reveal == .none,
                  self.quickPopover?.isShown != true else { return }
            self.engine.setReveal(.hidden)
            self.refresh()
        }
        hoverRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Open the quick panel when the dot is right-clicked.
    ///
    /// A local monitor rather than `sendAction(on:)`, which would let the
    /// button report right clicks but costs it every other action too. The
    /// event must belong to our actual status button window.
    private func monitorRightClicks() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let buttonWindow = self.dotItem?.button?.window,
                  event.window === buttonWindow else { return event }
            self.hoverRevealWork?.cancel()
            self.hoverRevealWork = nil
            self.toggleQuickPanel()
            return nil   // consumed
        }
    }

    /// Passively observes user clicks in the macOS top menu bar band so frequently used
    /// `.visible` status items refresh their activity timestamp and never falsely auto-decay.
    private func monitorTopBarClicks() {
        topBarClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.engine.recordNativeTopBarClick(at: NSEvent.mouseLocation)
        }
    }

    /// Scroll or two-finger swipe on the trigger icon (both while BarLens is in
    /// the background and while active) to reveal or collapse hidden sections:
    /// - Swipe/scroll down or swipe left on the trigger expands (.none -> .hidden -> .all).
    /// - Swipe/scroll up or swipe right collapses (.all -> .hidden -> .none).
    /// - Vertical swipe-up directly over the open Floating Bar also collapses it.
    private func monitorScrollWheel() {
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollOrSwipe(event) ? nil : event
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            _ = self?.handleScrollOrSwipe(event)
        }
    }

    private func isMouseOverDot(at screenPoint: NSPoint) -> Bool {
        guard let button = dotItem?.button,
              let buttonWindow = button.window,
              buttonWindow.isVisible else { return false }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(rectInWindow).insetBy(dx: -6, dy: -4)
        return screenRect.contains(screenPoint)
    }

    private func handleScrollOrSwipe(_ event: NSEvent) -> Bool {
        guard abs(event.timestamp - lastHandledScrollTimestamp) > 0.002 else { return false }
        let mouse = NSEvent.mouseLocation
        let overDot = isMouseOverDot(at: mouse)
        let overFloatingBar = !overDot && (floatingBar.barCapsuleScreenFrame?.contains(mouse) == true)
        guard overDot || overFloatingBar else { return false }

        if event.type == .swipe {
            lastHandledScrollTimestamp = event.timestamp
            let dx = CGFloat(event.deltaX)
            let dy = CGFloat(event.deltaY)
            let isVertical = abs(dy) >= abs(dx)
            if overFloatingBar {
                guard isVertical, dy > 0 else { return false }
                engine.setReveal(.none)
                refresh()
                return true
            }
            let expand = isVertical ? (dy < 0) : (dx > 0)
            applyScrollRevealStep(expand: expand)
            return true
        }

        // Ignore trackpad post-lift inertia so a single flick only steps once.
        if event.momentumPhase != [] {
            return overDot
        }

        let now = Date()
        if event.hasPreciseScrollingDeltas {
            let rawDX = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaX : event.scrollingDeltaX
            let rawDY = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY

            if event.phase == .began || now.timeIntervalSince(lastScrollSampleAt) > 0.28 {
                scrollAccumX = 0
                scrollAccumY = 0
                scrollPhaseConsumed = false
            }
            lastScrollSampleAt = now

            if event.phase == .ended || event.phase == .cancelled {
                let wasConsumed = scrollPhaseConsumed
                scrollAccumX = 0
                scrollAccumY = 0
                scrollPhaseConsumed = false
                return overDot && wasConsumed
            }

            if scrollPhaseConsumed {
                return overDot
            }

            scrollAccumX += rawDX
            scrollAccumY += rawDY

            let threshold: CGFloat = 5.0
            guard abs(scrollAccumY) >= threshold || abs(scrollAccumX) >= threshold else {
                return false
            }

            let isVertical = abs(scrollAccumY) >= abs(scrollAccumX)
            if overFloatingBar {
                guard isVertical, abs(scrollAccumY) > abs(scrollAccumX) * 1.3, scrollAccumY > 0 else {
                    return false
                }
                lastHandledScrollTimestamp = event.timestamp
                scrollPhaseConsumed = true
                engine.setReveal(.none)
                refresh()
                return true
            }

            // rawDY < 0: physical fingers moved downward; rawDX > 0: physical fingers moved left.
            let expand = isVertical ? (scrollAccumY < 0) : (scrollAccumX > 0)
            lastHandledScrollTimestamp = event.timestamp
            scrollPhaseConsumed = true
            applyScrollRevealStep(expand: expand)
            return true
        }

        // Discrete mouse wheel (line-based deltas such as ±0.1 .. ±1.0).
        let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : CGFloat(event.deltaY)
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : CGFloat(event.deltaX)
        let discreteDX = event.isDirectionInvertedFromDevice ? -dx : dx
        let discreteDY = event.isDirectionInvertedFromDevice ? -dy : dy
        guard abs(discreteDY) > 0.001 || abs(discreteDX) > 0.001 else { return false }
        guard now.timeIntervalSince(lastDiscreteStepAt) >= 0.18 else { return overDot }

        let isVertical = abs(discreteDY) >= abs(discreteDX)
        if overFloatingBar {
            guard isVertical, discreteDY > 0 else { return false }
            lastDiscreteStepAt = now
            lastHandledScrollTimestamp = event.timestamp
            engine.setReveal(.none)
            refresh()
            return true
        }

        lastDiscreteStepAt = now
        lastHandledScrollTimestamp = event.timestamp
        let expand = isVertical ? (discreteDY < 0) : (discreteDX > 0)
        applyScrollRevealStep(expand: expand)
        return true
    }

    private func applyScrollRevealStep(expand: Bool) {
        hoverRevealWork?.cancel()
        hoverRevealWork = nil
        closeQuickPanel(resetClicks: true)
        if expand {
            if engine.reveal == .none {
                engine.setReveal(.hidden)
            } else if engine.reveal == .hidden, engine.alwaysHiddenEnabled {
                engine.setReveal(.all)
            }
        } else {
            if engine.reveal == .all {
                engine.setReveal(.hidden)
            } else if engine.reveal != .none {
                engine.setReveal(.none)
            }
        }
        refresh()
    }

    // MARK: - Quick panel

    private func toggleQuickPanel() {
        lastDotClick = nil
        if quickPopover?.isShown == true {
            closeQuickPanel()
            return
        }
        guard let button = dotItem?.button, let screen = button.window?.screen else { return }
        if engine.revealPresentationStyle == .floatingBar, engine.reveal != .none {
            engine.setReveal(.none)
        }
        refresh()

        let height = min(CGFloat(500), max(CGFloat(1), screen.visibleFrame.height - 24))
        let panel = quickPopover ?? NSPopover()
        panel.delegate = self
        panel.behavior = .transient
        let targetAppearance = engine.effectiveNSAppearance
        panel.appearance = targetAppearance
        panel.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let content = QuickPanelView(
            engine: engine,
            catalog: quickCatalog,
            onReveal: { [weak self] reveal in
                guard let self else { return }
                self.lastDotClick = nil
                if reveal != .none, self.engine.revealPresentationStyle == .floatingBar {
                    self.closeQuickPanel()
                }
                self.engine.setReveal(reveal)
            },
            onManage: { [weak self] in self?.openSettings() },
            onOpenGuide: { [weak self] in
                self?.closeQuickPanel()
                self?.settings.present(pane: .guide)
            },
            onReconnect: { [weak self] in self?.reconnectService() },
            onAssign: { [weak self] section in self?.bulkAssign(section) },
            onQuit: { [weak self] in self?.quit() },
            onClose: { [weak self] in self?.closeQuickPanel() })
            .frame(width: 368, height: height)
        let hosting = NSHostingController(rootView: content)
        hosting.view.appearance = targetAppearance
        panel.contentViewController = hosting
        panel.contentSize = NSSize(width: 368, height: height)
        quickPopover = panel
        // Anchor to the status item itself so the panel follows its display and
        // macOS can keep the panel on-screen near either edge of the menu bar.
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        engine.isQuickPanelOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.contentViewController?.view.window?.makeKey()
    }

    private func closeQuickPanel(resetClicks: Bool = true) {
        if resetClicks { lastDotClick = nil }
        engine.isQuickPanelOpen = false
        quickPopover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        engine.isQuickPanelOpen = false
        quickPopover?.contentViewController = nil
    }

    /// Escape belongs to the panel only. Other app windows and system key
    /// events retain their usual behavior, including Command-drag of the dot.
    private func monitorPanelKeys() {
        panelKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let panel = self.quickPopover, panel.isShown,
                  event.keyCode == 53,
                  event.window === panel.contentViewController?.view.window else { return event }
            self.closeQuickPanel()
            return nil
        }
    }

    private func refresh() {
        let hidden = engine.revealableCount
        let always = engine.alwaysHiddenCount
        let tucked = engine.tuckedOverflowCount
        let shieldActive = engine.isPresentationShieldActive
        let latestBubble = engine.activeStatusBubbles.values.max(by: { $0.triggeredAt < $1.triggeredAt })
        let state: String
        if engine.nextRetryAt != nil {
            state = tr("等待自动重连", "Waiting to reconnect")
        } else if engine.isRecovering {
            state = tr("正在恢复菜单栏连接", "Recovering menu bar connection")
        } else if let error = engine.connectionError ?? engine.lastError {
            state = tr("提示：\(error)", "Notice: \(error)")
        } else if shieldActive {
            let shieldedCount = engine.shieldedBundleIDs.count
            state = tr(
                "投屏净空盾已开启 · 已临时收纳 \(shieldedCount + hidden) 项",
                "Presentation Shield Active · \(shieldedCount + hidden) items tucked"
            )
        } else if let bubble = latestBubble {
            state = "\(bubble.appName) · \(bubble.reason.badgeText)"
        } else if !engine.isConfigured && tucked == 0 {
            state = tr("尚未划分，打开设置指定要隐藏的应用", "Not configured yet — open Settings to assign apps")
        } else if hidden == 0 && always == 0 && tucked == 0 {
            state = tr("所有图标保持显示", "All items remain visible")
        } else if engine.reveal == .all {
            state = tr(
                "全部展开 · 可隐藏 \(hidden) 项 · 永久隐藏 \(always) 项",
                "All Revealed · Hidden: \(hidden) · Always Hidden: \(always)"
            )
        } else if engine.reveal == .hidden {
            state = engine.alwaysHiddenEnabled
                ? tr("可隐藏分区已展开 · 永久隐藏 \(always) 项", "Hidden Section Revealed · Always Hidden: \(always)")
                : tr("可隐藏分区已展开（\(hidden) 项）", "Hidden Section Revealed (\(hidden))")
        } else {
            let base = engine.alwaysHiddenEnabled
                ? tr("可隐藏 \(hidden) 项 · 永久隐藏 \(always) 项", "Hidden: \(hidden) · Always Hidden: \(always)")
                : tr("可隐藏 \(hidden) 项", "Hidden: \(hidden)")
            state = tucked > 0
                ? base + tr(" · 容量暂收 \(tucked) 项", " · Tucked: \(tucked)")
                : base
        }
        let gestureHint = engine.alwaysHiddenEnabled
            ? tr("单击展开 / 收起 · 双击全部显示 · 右键快速检视", "Click: Toggle Hidden · Double-Click: Reveal All · Right-Click: Quick Panel")
            : tr("单击展开 / 收起 · 右键快速检视", "Click: Toggle Hidden · Right-Click: Quick Panel")

        if let button = dotItem?.button {
            let hasWarning = engine.connectionError != nil || engine.nextRetryAt != nil
            let effectiveSymbolName: String? = shieldActive
                ? (engine.reveal == .none ? "shield.lefthalf.filled" : "shield")
                : engine.statusBarIconStyle.symbolName(for: engine.reveal)
            let hasPulse = !hasWarning && !shieldActive && latestBubble != nil
            let badgeTone: SemanticTone? = {
                if hasWarning { return .orange }
                if let bubble = latestBubble, hasPulse { return bubble.reason.tone }
                return nil
            }()

            // Keep `contentTintColor == nil` and `button.image` as a pure native SF Symbol
            // template image at all times. Setting `contentTintColor` on `NSStatusBarButton`
            // disables macOS's menu-bar wallpaper vibrancy shader, causing the trigger icon
            // to render black and vanish over dark wallpapers when macOS is in Light Mode.
            button.contentTintColor = nil
            if let symbolName = effectiveSymbolName,
               let baseImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BarLens") {
                let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                let symbolImg = baseImg.withSymbolConfiguration(config) ?? baseImg
                symbolImg.isTemplate = true
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
                button.image = symbolImg
            } else {
                button.image = nil
                let glyph: String
                switch engine.reveal {
                case .none:   glyph = "●"
                case .hidden: glyph = "○"
                case .all:    glyph = "◉"
                }
                let font = NSFont.systemFont(ofSize: 10, weight: .medium)
                button.attributedTitle = NSAttributedString(string: "")
                button.title = glyph
                button.font = font
            }
            dotPulseBadgeView?.configure(tone: badgeTone)
            button.appearsDisabled = engine.isRecovering
            button.toolTip = state + "\n" + gestureHint
            button.setAccessibilityIdentifier("BarLens.dot")
            button.setAccessibilityTitle("BarLens.dot")
        }
        syncProxyItems()
        settings.syncAppearance()
        onboarding.syncAppearance()
        let targetAppearance = engine.effectiveNSAppearance
        quickPopover?.appearance = targetAppearance
        quickPopover?.contentViewController?.view.appearance = targetAppearance
        floatingBar.update(relativeTo: dotItem?.button)
    }

    private func syncProxyItems() {
        let desired = engine.topBarProxySystemItems
        let desiredIDs = Set(desired.map(\.identifier))

        for (id, statusItem) in proxyItems where !desiredIDs.contains(id) {
            NSStatusBar.system.removeStatusItem(statusItem)
            proxyItems.removeValue(forKey: id)
            proxyItemTargets.removeValue(forKey: id)
        }

        for sysItem in desired {
            proxyItemTargets[sysItem.identifier] = sysItem
            if proxyItems[sysItem.identifier] == nil {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.autosaveName = "BarLens.proxy.\(sysItem.identifier)"
                statusItem.behavior = []
                if let button = statusItem.button {
                    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                    let img = NSImage(systemSymbolName: sysItem.symbol, accessibilityDescription: sysItem.title)?
                        .withSymbolConfiguration(config)
                    img?.isTemplate = true
                    button.image = img
                    button.toolTip = sysItem.title
                    button.setAccessibilityIdentifier("BarLens.proxy.\(sysItem.identifier)")
                    button.setAccessibilityTitle(sysItem.title)
                    button.target = self
                    button.action = #selector(proxyItemClicked(_:))
                }
                proxyItems[sysItem.identifier] = statusItem
            }
        }
    }

    @objc private func proxyItemClicked(_ sender: NSStatusBarButton) {
        guard let id = proxyItems.first(where: { $0.value.button === sender })?.key,
              let sysItem = proxyItemTargets[id] else { return }
        engine.activateSystemItem(sysItem, fromFloatingBar: false)
    }

    // MARK: - Actions

    @objc private func dotClicked() {
        hoverRevealWork?.cancel()
        hoverRevealWork = nil
        // A left click keeps its established reveal behavior even while the
        // quick panel is open. Closing must not break double-click pairing.
        closeQuickPanel(resetClicks: false)
        if engine.reveal == .none,
           Date().timeIntervalSince(engine.lastMonitorDismissedRevealAt) < 0.25 {
            refresh()
            return
        }
        guard engine.alwaysHiddenEnabled else {
            lastDotClick = nil
            engine.toggleHidden()
            refresh()
            return
        }
        // Double clicks are detected here rather than read from the event:
        // a status bar button reports `clickCount == 1` for every click, even
        // when they arrive as a double click. Measured — eleven double clicks,
        // twenty-two actions, never a 2.
        //
        // The first click acts immediately, so a single click costs nothing.
        // If a second arrives inside the double-click interval the pair is
        // treated as one gesture: the first click's toggle is replaced by a
        // peek relative to where things stood before it, which also means
        // repeating the double click restores the previous state.
        let now = Date()
        let isSecondOfPair = lastDotClick
            .map { now.timeIntervalSince($0) < NSEvent.doubleClickInterval } ?? false
        lastDotClick = isSecondOfPair ? nil : now

        if isSecondOfPair {
            engine.setReveal(revealBeforeClick == .all ? .none : .all)
        } else {
            revealBeforeClick = engine.reveal
            engine.toggleHidden()
        }
        refresh()
    }

    @objc private func openSettings() {
        closeQuickPanel()
        settings.present(pane: engine.requestedSettingsPane)
    }

    @objc private func reconnectService() {
        lastDotClick = nil
        engine.recoverConnection()
    }

    /// The screen comes from our own status item window without querying AX.
    /// The engine reads the dot's position only after revealing the full bar.
    private func bulkAssign(_ section: SectionModel.Section) {
        // Capture the invoking display before dismissing/activating windows.
        let screen = dotItem?.button?.window?.screen
        let display = screen.flatMap { ItemEnumerator.displayID(for: $0) }
        closeQuickPanel()
        guard let display else {
            engine.setLastError(tr("无法确定圆点所在的屏幕，请重新打开快速面板后重试。", "Could not determine the display of the trigger icon; please reopen Quick Panel and try again."))
            return
        }
        engine.assignEverythingLeftOfDot(on: display, to: section) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func systemChanged() {
        engine.refreshRunningApplications()
        engine.apply()
    }

    @objc private func quit() {
        closeQuickPanel()
        stop()
        NSApp.terminate(nil)
    }
}

/// Zero-hit-testing tracking view placed inside the status bar button so
/// hover-to-reveal uses AppKit's native `NSTrackingArea` with zero background CPU polling.
private final class DotHoverTrackingView: NSView {
    private let onHoverChanged: (Bool) -> Void
    private var trackingArea: NSTrackingArea?

    init(frame frameRect: NSRect, onHoverChanged: @escaping (Bool) -> Void) {
        self.onHoverChanged = onHoverChanged
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged(false)
    }
}

/// Non-vibrant, zero-hit-testing true-color sRGB badge overlay placed inside `NSStatusBarButton`.
/// Because `allowsVibrancy == false`, AppKit's status-bar monochrome vibrancy shader leaves this
/// subview's vivid sRGB colors untouched while keeping the parent button's template icon 100%
/// wallpaper-adaptive (bright white over dark wallpapers, dark charcoal over light wallpapers).
private final class DotPulseBadgeView: NSView {
    private var activeTone: SemanticTone?

    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(tone: SemanticTone?) {
        guard activeTone != tone else { return }
        activeTone = tone
        isHidden = (tone == nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let activeTone, bounds.width > 8, bounds.height > 8 else { return }
        let diameter: CGFloat = 5.6
        let pipRect = NSRect(
            x: round((bounds.midX + 4.2) * 2.0) / 2.0,
            y: round((bounds.midY - 8.2) * 2.0) / 2.0,
            width: diameter,
            height: diameter
        )

        let outerHalo = pipRect.insetBy(dx: -1.1, dy: -1.1)
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42).setFill()
        NSBezierPath(ovalIn: outerHalo).fill()

        let innerRim = pipRect.insetBy(dx: -0.55, dy: -0.55)
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: innerRim).fill()

        let coreColor: NSColor = (activeTone == .orange)
            ? NSColor(srgbRed: 1.00, green: 0.58, blue: 0.04, alpha: 1.0)
            : NSColor(srgbRed: 0.18, green: 0.76, blue: 0.98, alpha: 1.0)
        coreColor.setFill()
        NSBezierPath(ovalIn: pipRect).fill()
    }
}
