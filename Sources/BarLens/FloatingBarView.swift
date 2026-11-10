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
            guard let self, self.isShown else { return }
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
            guard let self, self.isShown, let panel = self.panel else { return event }
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
        return appItems + sysItems
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
                        ForEach(hiddenItems) { item in
                            FloatingBarItemButton(item: item, engine: engine)
                        }

                        if engine.reveal == .all, !alwaysHiddenItems.isEmpty {
                            if !hiddenItems.isEmpty {
                                FloatingBarSeparator()
                            }
                            ForEach(alwaysHiddenItems) { item in
                                FloatingBarItemButton(item: item, engine: engine)
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

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.86))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(FloatingBarIconStyle(isActive: false))
            .help(tr("打开设置（右键可快速切换外观模式）", "Open Settings (Right-click for Appearance & Language)"))
            .contextMenu {
                Section(tr("悬浮栏图标", "Floating Bar Icons")) {
                    ForEach(FloatingBarIconDisplayStyle.allCases) { style in
                        Button {
                            engine.setFloatingBarIconStyle(style)
                        } label: {
                            Label(
                                style.title,
                                systemImage: engine.floatingBarIconStyle == style ? "checkmark.circle.fill" : style.symbol
                            )
                        }
                    }
                }
                Section(tr("外观模式", "Appearance Mode")) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            engine.setAppearanceMode(mode)
                        } label: {
                            Label(
                                mode.title,
                                systemImage: engine.appearanceMode == mode ? "checkmark.circle.fill" : mode.symbol
                            )
                        }
                    }
                }
                Section(tr("界面语言", "Interface Language")) {
                    ForEach(AppLanguage.allCases) { lang in
                        Button {
                            engine.setAppLanguage(lang)
                        } label: {
                            Label(
                                lang.title,
                                systemImage: engine.appLanguage == lang ? "checkmark.circle.fill" : "globe"
                            )
                        }
                    }
                }
                Divider()
                Button(tr("打开设置…", "Open Settings…"), action: onOpenSettings)
            }
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

private struct FloatingBarItemButton: View {
    let item: FloatingBarItem
    @ObservedObject var engine: DividerEngine

    private var isActive: Bool {
        switch item.target {
        case .app:
            return engine.isFloatingBarTargetActive(itemID: item.id)
        case .system(let sysItem, _):
            return engine.isFloatingBarTargetActive(itemID: item.id, systemItem: sysItem)
        }
    }

    var body: some View {
        Button {
            switch item.target {
            case .app(let bundleID, _):
                engine.activateFromFloatingBar(bundleID: bundleID)
            case .system(let sysItem, _):
                engine.activateFromFloatingBar(systemItem: sysItem)
            }
        } label: {
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
            .contentShape(Circle())
        }
        .buttonStyle(FloatingBarIconStyle(isActive: isActive))
        .help(tr("\(item.title) · 点按打开 / 收起菜单", "\(item.title) · Click to toggle menu"))
        .contextMenu {
            let choices: [SectionModel.Section] = engine.alwaysHiddenEnabled
                ? [.visible, .hidden, .alwaysHidden]
                : [.visible, .hidden]
            ForEach(choices, id: \.self) { section in
                Button {
                    switch item.target {
                    case .app(let bundleID, _):
                        engine.setSection(section, for: bundleID)
                    case .system(let sysItem, _):
                        engine.setSection(section, for: sysItem)
                    }
                } label: {
                    Label(section.title, systemImage: section.symbol)
                }
            }
        }
    }
}

private struct FloatingBarIconStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        FloatingBarIconFeedback(configuration: configuration, isActive: isActive)
    }
}

private struct FloatingBarIconFeedback: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        configuration.label
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
            .scaleEffect(configuration.isPressed ? 0.92 : (hovered ? 1.04 : 1.0))
            .offset(y: hovered && !configuration.isPressed ? -0.5 : 0)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovered = $0 }
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
