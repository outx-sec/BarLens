import AppKit
import Combine
import SwiftUI

/// Borderless panel that does not let AppKit clamp `frame.maxY` to `visibleFrame.maxY`,
/// allowing the capsule's top shadow padding to overlap the menu bar bottom edge
/// so the capsule itself sits snugly 4pt below the menu bar.
private final class FloatingBarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Manages the horizontal Liquid Glass floating menu bar below the status item dot.
final class FloatingBarController {
    private let engine: DividerEngine
    private let catalog: Catalog
    private let onOpenSettings: () -> Void
    private var panel: NSPanel?
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
                }
            }
            .store(in: &cancellables)
    }

    var isShown: Bool {
        panel?.isVisible == true
    }

    var panelScreenFrame: NSRect? {
        guard isShown, let panel else { return nil }
        return panel.frame
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
        panel.appearance = engine.appearanceMode.nsAppearance
        let maxBarWidth = max(260, screen.visibleFrame.width - 32)
        let rootView = FloatingBarView(
            engine: engine,
            catalog: catalog,
            maxBarWidth: maxBarWidth,
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            },
            onExpandInline: { [weak self] in
                guard let self else { return }
                let targetReveal = self.engine.reveal == .none ? SectionModel.Reveal.hidden : self.engine.reveal
                self.engine.setRevealPresentationStyle(.inline)
                self.engine.setReveal(targetReveal)
            }
        )

        if let hosting = panel.contentViewController as? NSHostingController<FloatingBarView> {
            hosting.rootView = rootView
        } else {
            let hosting = NSHostingController(rootView: rootView)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentViewController = hosting
        }

        layoutAndPositionPanel()
        if !panel.isVisible {
            engine.refreshRunningApplications()
            panel.orderFrontRegardless()
            installMonitors(statusButtonWindow: buttonWindow)
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

    func hide() {
        removeMonitors()
        engine.isFloatingBarHovered = false
        panel?.orderOut(nil)
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
        // Disable WindowServer's rectangular frame shadow so only the SwiftUI
        // capsule's soft Liquid Glass shadow renders.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
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
            self.engine.noteMonitorDismissedReveal()
            self.engine.setReveal(.none)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown, !self.engine.isContextMenuOpen, let panel = self.panel else { return event }
            if event.window === panel
                || event.window === statusButtonWindow
                || event.window?.title == "BarLens"
                || event.window?.className.contains("StatusBar") == true {
                return event
            }
            self.engine.noteMonitorDismissedReveal()
            self.engine.setReveal(.none)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isShown, event.keyCode == 53 else { return event }
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

struct FloatingBarView: View {
    @ObservedObject var engine: DividerEngine
    @ObservedObject var catalog: Catalog
    let maxBarWidth: CGFloat
    let onOpenSettings: () -> Void
    let onExpandInline: () -> Void

    @State private var draggedItemID: String?

    private var hiddenItems: [FloatingBarItem] {
        items(in: .hidden)
    }

    private var alwaysHiddenItems: [FloatingBarItem] {
        guard engine.alwaysHiddenEnabled else { return [] }
        return items(in: .alwaysHidden)
    }

    private func effective(_ section: SectionModel.Section) -> SectionModel.Section {
        !engine.alwaysHiddenEnabled && section == .alwaysHidden ? .hidden : section
    }

    private func items(in section: SectionModel.Section) -> [FloatingBarItem] {
        let useMono = engine.floatingBarIconStyle == .monochrome
        let appItems = catalog.entries
            .filter { $0.isRunning && $0.itemCount > 0 && effective(engine.model.section(of: $0.bundleID)) == section }
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
                    target: .app(bundleID: entry.bundleID, isClassified: entry.isClassified)
                )
            }
        let sysItems = engine.activeSystemItems
            .filter { effective(engine.systemItems.section(of: $0)) == section }
            .map { sys in
                FloatingBarItem(
                    id: "sys:\(sys.identifier)",
                    title: sys.title,
                    icon: nil,
                    isTemplateIcon: false,
                    symbol: sys.symbol,
                    badgeCount: nil,
                    section: section,
                    target: .system(sys, isClassified: engine.systemItems.isClassified(sys))
                )
            }
        return engine.floatingBarOrder.sorted(appItems + sysItems, id: \.id)
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        barContent
            .padding(.top, 5)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .preferredColorScheme(engine.appearanceMode.colorScheme)
            .onHover { hovering in
                engine.isFloatingBarHovered = hovering
            }
    }

    private var barContent: some View {
        HStack(spacing: 7) {
            if hiddenItems.isEmpty && (engine.reveal != .all || alwaysHiddenItems.isEmpty) {
                Button(action: onOpenSettings) {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(tr("暂无隐藏图标 · 打开设置", "No Hidden Items · Open Settings"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        let hiddenIDs = hiddenItems.map(\.id)
                        ForEach(hiddenItems) { item in
                            FloatingBarItemButton(
                                item: item,
                                siblingIDs: hiddenIDs,
                                engine: engine,
                                draggedItemID: $draggedItemID
                            )
                        }

                        if engine.reveal == .all, !alwaysHiddenItems.isEmpty {
                            if !hiddenItems.isEmpty {
                                FloatingBarSeparator()
                            }
                            let alwaysIDs = alwaysHiddenItems.map(\.id)
                            ForEach(alwaysHiddenItems) { item in
                                FloatingBarItemButton(
                                    item: item,
                                    siblingIDs: alwaysIDs,
                                    engine: engine,
                                    draggedItemID: $draggedItemID
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: maxBarWidth - 130)
            }

            if engine.alwaysHiddenEnabled && !alwaysHiddenItems.isEmpty {
                FloatingBarSeparator()

                Button {
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
                onOpenSettings: onOpenSettings,
                onExpandInline: onExpandInline
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .settingsGlass(cornerRadius: 26)
        .background {
            // Cast soft capsule shadow strictly from a pure SwiftUI shape so
            // AppKit's NSViewRepresentable never casts a rectangular bounds shadow.
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

private struct FloatingBarItem: Identifiable {
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
    let target: Target
}

private struct FloatingBarGearButton: View {
    @ObservedObject var engine: DividerEngine
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
                onHoverChanged: { hovered = $0 },
                onPressedChanged: { pressed = $0 },
                onClick: onOpenSettings,
                onDragStarted: nil,
                onDragOffsetChanged: nil,
                onStepSwap: nil,
                onDragEnded: nil,
                onMenuOpenChanged: { isOpen in
                    if isOpen {
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
                        title: tr("临时切换为菜单栏内展开", "Switch to Inline Menu Bar"),
                        symbol: "menubar.dock.rectangle",
                        actionBlock: onExpandInline
                    ))
                    menu.addItem(.separator())

                    let iconHeader = NSMenuItem(title: tr("悬浮栏图标样式", "Floating Bar Icons"), action: nil, keyEquivalent: "")
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
                    let modeHeader = NSMenuItem(title: tr("外观模式", "Appearance Mode"), action: nil, keyEquivalent: "")
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
                    let langHeader = NSMenuItem(title: tr("界面语言", "Interface Language"), action: nil, keyEquivalent: "")
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
    let siblingIDs: [String]
    @ObservedObject var engine: DividerEngine
    @Binding var draggedItemID: String?

    @State private var hovered = false
    @State private var pressed = false
    @State private var dragOffsetX: CGFloat = 0

    private var isDraggingThis: Bool {
        draggedItemID == item.id
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
            hovered: hovered || isDraggingThis,
            isPressed: pressed
        ) {
            ZStack(alignment: .bottomTrailing) {
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
                                    : (item.section == .alwaysHidden ? item.section.tint : .primary.opacity(0.92))
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
                                ? Color.accentColor
                                : (item.section == .alwaysHidden ? item.section.tint : .primary)
                        )
                        .frame(width: 22, height: 22)
                }
                if let count = item.badgeCount {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 0.5)
                        .background(item.section.tint, in: Capsule())
                        .offset(x: 4, y: 3)
                }
            }
            .frame(width: 38, height: 38)
        }
        .scaleEffect(isDraggingThis ? 1.10 : 1.0)
        .offset(x: dragOffsetX)
        .zIndex(isDraggingThis ? 20 : 0)
        .overlay {
            FloatingBarItemMouseBridge(
                toolTip: tr("\(item.title) · 点按打开菜单 · 按住左右拖拽排序 · 右键快捷操作", "\(item.title) · Click: Menu · Drag: Reorder · Right-Click: Actions"),
                onHoverChanged: { hovered = $0 },
                onPressedChanged: { pressed = $0 },
                onClick: triggerItem,
                onDragStarted: {
                    draggedItemID = item.id
                },
                onDragOffsetChanged: { dx in
                    dragOffsetX = dx
                },
                onStepSwap: { stepDelta in
                    let latestSiblings = engine.floatingBarOrder.sorted(siblingIDs, id: { $0 })
                    guard let currentIdx = latestSiblings.firstIndex(of: item.id) else { return false }
                    let nextIdx = currentIdx + stepDelta
                    guard latestSiblings.indices.contains(nextIdx) else { return false }
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                        engine.moveFloatingBarItemByStep(item.id, delta: stepDelta, within: latestSiblings)
                    }
                    return true
                },
                onDragEnded: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                        dragOffsetX = 0
                        draggedItemID = nil
                    }
                },
                onMenuOpenChanged: { isOpen in
                    if isOpen {
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

        let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(MenuActionItem(
            title: tr("打开 / 收起菜单", "Open / Toggle Menu"),
            symbol: "menubar.arrow.down.rectangle",
            actionBlock: triggerItem
        ))

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
    let onHoverChanged: (Bool) -> Void
    let onPressedChanged: (Bool) -> Void
    let onClick: () -> Void
    let onDragStarted: (() -> Void)?
    let onDragOffsetChanged: ((CGFloat) -> Void)?
    let onStepSwap: ((Int) -> Bool)?
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
        view.onStepSwap = onStepSwap
        view.onDragEnded = onDragEnded
        view.onMenuOpenChanged = onMenuOpenChanged
        view.buildContextMenu = buildContextMenu
    }
}

/// Native AppKit mouse handler for icons inside the non-activating FloatingBarPanel.
/// Accepts first-mouse events without activating BarLens, tracks screen-space
/// horizontal dragging for 1:1 icon reordering, and presents a native NSMenu on right-click.
private final class FloatingBarItemMouseView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragOffsetChanged: ((CGFloat) -> Void)?
    var onStepSwap: ((Int) -> Bool)?
    var onDragEnded: (() -> Void)?
    var onMenuOpenChanged: ((Bool) -> Void)?
    var buildContextMenu: (() -> NSMenu)?

    private var trackingArea: NSTrackingArea?
    private var isTrackingLeftMouse = false
    private var didEnterDrag = false
    private var anchorScreenX: CGFloat = 0
    private var anchorScreenY: CGFloat = 0

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
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !isTrackingLeftMouse {
            onHoverChanged?(false)
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
        var dx = mouse.x - anchorScreenX
        let dy = mouse.y - anchorScreenY

        if !didEnterDrag {
            guard hypot(dx, dy) >= 5.0 else { return }
            didEnterDrag = true
            onPressedChanged?(false)
            onDragStarted?()
        }

        if let onStepSwap {
            let slotStride: CGFloat = 45.0
            let swapThreshold: CGFloat = 23.0
            while dx >= swapThreshold && onStepSwap(1) {
                anchorScreenX += slotStride
                dx -= slotStride
            }
            while dx <= -swapThreshold && onStepSwap(-1) {
                anchorScreenX -= slotStride
                dx += slotStride
            }
        }
        onDragOffsetChanged?(max(-34, min(34, dx)))
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
            onHoverChanged?(false)
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
