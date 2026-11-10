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

    private var dotItem: NSStatusItem?
    private var proxyItems: [String: NSStatusItem] = [:]
    private var proxyItemTargets: [String: SystemItem] = [:]
    private var rightClickMonitor: Any?
    private var panelKeyMonitor: Any?
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

        closeQuickPanel()
        createDot()
        monitorRightClicks()
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

    /// Open the settings window the first time the app runs.
    ///
    /// With nothing assigned there is nothing to toggle, so the dot looks inert
    /// and the app gives no clue what it is for. The window is where the three
    /// sections are explained.
    private func showWelcomeIfNeeded() {
        guard !Defaults.hasShownWelcome else { return }
        Defaults.hasShownWelcome = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.settings.present()
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        quickPopover?.animates = false
        closeQuickPanel()
        floatingBar.hide()
        quickPopover?.contentViewController = nil
        quickPopover = nil
        engine.stop()
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        if let panelKeyMonitor { NSEvent.removeMonitor(panelKeyMonitor) }
        panelKeyMonitor = nil
        if let dotItem { NSStatusBar.system.removeStatusItem(dotItem) }
        dotItem = nil
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
        }
        dotItem = item
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
            self.toggleQuickPanel()
            return nil   // consumed
        }
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
        panel.appearance = engine.appearanceMode.nsAppearance
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
            onReconnect: { [weak self] in self?.reconnectService() },
            onAssign: { [weak self] section in self?.bulkAssign(section) },
            onQuit: { [weak self] in self?.quit() },
            onClose: { [weak self] in self?.closeQuickPanel() })
            .frame(width: 368, height: height)
        panel.contentViewController = NSHostingController(rootView: content)
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
        let state: String
        if engine.nextRetryAt != nil {
            state = tr("等待自动重连", "Waiting to reconnect")
        } else if engine.isRecovering {
            state = tr("正在恢复菜单栏连接", "Recovering menu bar connection")
        } else if let error = engine.connectionError ?? engine.lastError {
            state = tr("提示：\(error)", "Notice: \(error)")
        } else if !engine.isConfigured {
            state = tr("尚未划分，打开设置指定要隐藏的应用", "Not configured yet — open Settings to assign apps")
        } else if hidden == 0 && always == 0 {
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
            state = engine.alwaysHiddenEnabled
                ? tr("可隐藏 \(hidden) 项 · 永久隐藏 \(always) 项", "Hidden: \(hidden) · Always Hidden: \(always)")
                : tr("可隐藏 \(hidden) 项", "Hidden: \(hidden)")
        }
        let gestureHint = engine.alwaysHiddenEnabled
            ? tr("单击展开 / 收起 · 双击全部显示 · 右键快速检视", "Click: Toggle Hidden · Double-Click: Reveal All · Right-Click: Quick Panel")
            : tr("单击展开 / 收起 · 右键快速检视", "Click: Toggle Hidden · Right-Click: Quick Panel")

        if let button = dotItem?.button {
            let hasWarning = engine.connectionError != nil || engine.nextRetryAt != nil
            if let symbolName = engine.statusBarIconStyle.symbolName(for: engine.reveal),
               let baseImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BarLens") {
                let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                let img = baseImg.withSymbolConfiguration(config) ?? baseImg
                img.isTemplate = !hasWarning
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
                button.image = img
                button.contentTintColor = hasWarning ? .systemOrange : nil
            } else {
                button.image = nil
                button.contentTintColor = nil
                let glyph: String
                switch engine.reveal {
                case .none:   glyph = "●"
                case .hidden: glyph = "○"
                case .all:    glyph = "◉"
                }
                let font = NSFont.systemFont(ofSize: 10, weight: .medium)
                if hasWarning {
                    button.attributedTitle = NSAttributedString(
                        string: glyph,
                        attributes: [.font: font, .foregroundColor: NSColor.systemOrange]
                    )
                } else {
                    button.attributedTitle = NSAttributedString(string: "")
                    button.title = glyph
                    button.font = font
                }
            }
            button.appearsDisabled = engine.isRecovering
            button.toolTip = state + "\n" + gestureHint
            button.setAccessibilityIdentifier("BarLens.dot")
            button.setAccessibilityTitle("BarLens.dot")
        }
        syncProxyItems()
        settings.syncAppearance()
        quickPopover?.appearance = engine.appearanceMode.nsAppearance
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
        settings.present()
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
