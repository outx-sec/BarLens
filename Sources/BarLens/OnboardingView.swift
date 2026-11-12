import AppKit
import SwiftUI

/// Hosts the first-launch interactive Liquid Glass onboarding tour.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let engine: DividerEngine
    private let onOpenSettings: (SettingsPane) -> Void
    var onClose: (() -> Void)?

    init(engine: DividerEngine, onOpenSettings: @escaping (SettingsPane) -> Void) {
        self.engine = engine
        self.onOpenSettings = onOpenSettings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = tr("欢迎使用 BarLens", "Welcome to BarLens")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let initialAppearance = engine.effectiveNSAppearance
        window.appearance = initialAppearance

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window?.delegate = nil
        let callback = onClose
        onClose = nil
        DispatchQueue.main.async {
            callback?()
        }
    }

    func syncAppearance() {
        let target = engine.effectiveNSAppearance
        window?.appearance = target
        window?.contentView?.appearance = target
        window?.contentViewController?.view.appearance = target
    }

    func present() {
        let target = engine.effectiveNSAppearance
        if let window {
            let freshRoot = OnboardingView(
                engine: engine,
                onFinishToSettings: { [weak self] targetPane in
                    Defaults.hasCompletedOnboarding = true
                    Defaults.hasShownWelcome = true
                    let openSettings = self?.onOpenSettings
                    self?.close()
                    openSettings?(targetPane)
                },
                onDismissOnly: { [weak self] in
                    Defaults.hasCompletedOnboarding = true
                    Defaults.hasShownWelcome = true
                    self?.close()
                }
            )
            if let hosting = window.contentViewController as? NSHostingController<OnboardingView> {
                hosting.rootView = freshRoot
                hosting.view.appearance = target
            } else {
                let hosting = NSHostingController(rootView: freshRoot)
                hosting.view.appearance = target
                window.contentViewController = hosting
                window.setContentSize(NSSize(width: 660, height: 520))
            }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2
                ))
            }
        }
        syncAppearance()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Interactive 4-Step Onboarding View

struct OnboardingView: View {
    @ObservedObject var engine: DividerEngine
    let onFinishToSettings: (SettingsPane) -> Void
    let onDismissOnly: () -> Void

    @State private var step = 0
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var colorScheme: ColorScheme { engine.effectiveColorScheme }

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.35)

            Group {
                switch step {
                case 0: stepWelcomePermissions
                case 1: stepSectionsModel
                case 2: stepPresentationAndGlass
                default: stepGesturesAndFinish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider().opacity(0.35)
            bottomBar
        }
        .windowPaneGlass(cornerRadius: 22)
        .padding(12)
        .padding(.top, 24)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    SettingsBackdrop()
                    BarLensPalette.windowScrim(in: colorScheme, glassOpacity: glassOpacity)
                }
            }
        }
        .ignoresSafeArea()
        .frame(width: 660, height: 520)
        .environment(\.colorScheme, engine.effectiveColorScheme)
        .preferredColorScheme(engine.effectiveColorScheme)
    }

    // MARK: - Top & Bottom Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                Text("BarLens")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { idx in
                    Capsule()
                        .fill(idx == step ? BarLensPalette.ink(.blue, in: colorScheme) : Color.primary.opacity(0.20))
                        .frame(width: idx == step ? 22 : 7, height: 7)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
                }
            }

            Spacer()

            Menu {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        engine.setAppLanguage(lang)
                    } label: {
                        HStack {
                            Text(lang.title)
                            if engine.appLanguage == lang {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text(engine.appLanguage.title)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.88))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private var bottomBar: some View {
        HStack {
            if step == 0 {
                Button(tr("稍后自行探索", "Skip Tour"), action: onDismissOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        step = max(0, step - 1)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(tr("上一步", "Back"))
                    }
                }
                .controlSize(.regular)
            }

            Spacer()

            if step < totalSteps - 1 {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        step = min(totalSteps - 1, step + 1)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(tr("下一步", "Continue"))
                        Image(systemName: "chevron.right")
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(BarLensPalette.selectionFill(in: colorScheme))
                .controlSize(.regular)
            } else {
                HStack(spacing: 10) {
                    Button(tr("查看完整指南", "User Guide")) {
                        onFinishToSettings(.guide)
                    }
                    .controlSize(.regular)

                    Button {
                        onFinishToSettings(.sections)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(tr("开始配置分区", "Configure Sections"))
                        }
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BarLensPalette.selectionFill(in: colorScheme))
                    .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    // MARK: - Step 0: Welcome & Environment Check

    private var stepWelcomePermissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("欢迎使用 BarLens · 栏镜", "Welcome to BarLens"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(tr(
                    "专为 macOS 27 原生菜单栏架构打造的液态光学玻璃图标管理器。开始前请确认以下两项环境准备：",
                    "A native Liquid Glass menu bar manager built for macOS 27. Verify these quick checks to get started:"
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.78))
            }

            VStack(spacing: 10) {
                OnboardingCheckCard(
                    symbol: engine.isInstalledCorrectly ? "checkmark.circle.fill" : "folder.badge.questionmark",
                    tone: engine.isInstalledCorrectly ? .green : .orange,
                    title: tr("安装在「应用程序 (/Applications)」目录", "Installed in /Applications"),
                    subtitle: engine.isInstalledCorrectly
                        ? tr("位置正确，系统 MenuBarAgent 已按 Bundle ID 正常记账。", "Verified — MenuBarAgent tracks BarLens by bundle identifier.")
                        : tr("请将 BarLens.app 移入 /Applications 后重新打开，否则隐藏时自身图标会被过滤。", "Move BarLens.app to /Applications so MenuBarAgent preserves its trigger icon."),
                    actionTitle: engine.isInstalledCorrectly ? nil : tr("在访达中显示", "Show in Finder")
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }

                OnboardingCheckCard(
                    symbol: engine.hasAccessibility ? "checkmark.shield.fill" : "hand.raised.fill",
                    tone: engine.hasAccessibility ? .green : .blue,
                    title: tr("授予「辅助功能」权限", "Accessibility Permission"),
                    subtitle: engine.hasAccessibility
                        ? tr("已授权，支持扫描菜单栏图标与悬浮栏原位点击触发。", "Granted — ready to enumerate status items and proxy menu clicks.")
                        : tr("用于识别菜单栏图标并在悬浮栏内点击时打开对应原生菜单（无需屏幕录制权限）。", "Required to detect menu bar icons and open their menus from the Floating Bar (no Screen Recording needed)."),
                    actionTitle: engine.hasAccessibility ? nil : tr("前往授权", "Grant Access")
                ) {
                    engine.requestAccessibility()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }

                OnboardingCheckCard(
                    symbol: "lock.shield.fill",
                    tone: .teal,
                    title: tr("双进程防崩溃保护已激活", "Crash-Safe Guardian Active"),
                    subtitle: tr(
                        "独立守护进程 BarLensAgent 实时监测心跳——退出或强退 App 时所有隐藏图标将在 150ms 内自动恢复。",
                        "BarLensAgent monitors app heartbeat — quitting or force-quitting restores every hidden icon within 150ms."
                    ),
                    actionTitle: nil,
                    action: {}
                )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 1: Three-Tier Section Model

    private var stepSectionsModel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("三段式菜单栏分区", "Three-Tier Menu Bar Sections"))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(tr(
                    "告别混乱拥挤的刘海屏顶栏——支持全部第三方应用以及 macOS 27 内置的全部 18 项系统菜单栏控件：",
                    "Organize every third-party app and all 18 built-in macOS 27 system menu extras into three clean tiers:"
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.78))
            }

            HStack(spacing: 10) {
                OnboardingTierCard(
                    symbol: "eye.fill",
                    tone: .teal,
                    title: tr("始终显示", "Visible"),
                    desc: tr("高频核心图标，始终固定在系统顶栏右侧。", "Core daily items kept permanently on the top menu bar.")
                )
                OnboardingTierCard(
                    symbol: "sparkles.rectangle.stack",
                    tone: .blue,
                    title: tr("可隐藏", "Hidden"),
                    desc: tr("日常收起，单击、悬停或下滑手势时在悬浮栏展开。", "Tucked away until you click, hover, or swipe the trigger.")
                )
                OnboardingTierCard(
                    symbol: "eye.slash.fill",
                    tone: .purple,
                    title: tr("永久隐藏", "Always Hidden"),
                    desc: tr("低频常驻后台，仅在双击或点按紫色 +N 胶囊时现身。", "Rarely needed daemons, shown only on double-click or +N peek.")
                )
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BarLensPalette.ink(.purple, in: colorScheme))
                    Text(tr("启用「永久隐藏」第三分区", "Enable “Always Hidden” Third Tier"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { engine.alwaysHiddenEnabled },
                        set: { engine.setAlwaysHiddenEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .opticalPlatter(cornerRadius: 12, isSelected: false)

                HStack(spacing: 10) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BarLensPalette.ink(.blue, in: colorScheme))
                    Text(tr("新安装应用的默认归属", "Default Section for New Apps"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { engine.unclassifiedSection },
                        set: { engine.setUnclassifiedSection($0) }
                    )) {
                        Text(SectionModel.Section.visible.title).tag(SectionModel.Section.visible)
                        Text(SectionModel.Section.hidden.title).tag(SectionModel.Section.hidden)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .opticalPlatter(cornerRadius: 12, isSelected: false)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 2: Presentation & Liquid Glass

    private var stepPresentationAndGlass: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("展开方式与图标样式", "Choose Reveal & Icon Style"))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(tr(
                    "选项即时生效，之后可在「设置 → 外观」随时调整：",
                    "Changes apply live and can be changed anytime in Settings → Appearance:"
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.78))
            }

            HStack(spacing: 12) {
                OnboardingChoiceCard(
                    isSelected: engine.revealPresentationStyle == .floatingBar,
                    symbol: "menubar.dock.rectangle.badge.record",
                    title: tr("悬浮栏（推荐）", "Floating Bar"),
                    subtitle: tr("在顶栏下方展开玻璃胶囊，不挤占刘海空间，支持拖拽排序。", "Opens below the menu bar — immune to notch overflow and supports drag reordering.")
                ) {
                    engine.setRevealPresentationStyle(.floatingBar)
                }

                OnboardingChoiceCard(
                    isSelected: engine.revealPresentationStyle == .inline,
                    symbol: "menubar.rectangle",
                    title: tr("菜单栏内展开", "Inline Menu Bar"),
                    subtitle: tr("直接在系统顶部菜单栏内临时展开隐藏图标。", "Temporarily expands hidden icons directly inside the top menu bar.")
                ) {
                    engine.setRevealPresentationStyle(.inline)
                }
            }

            if engine.revealPresentationStyle == .floatingBar {
                HStack(spacing: 10) {
                    Image(systemName: "square.on.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BarLensPalette.ink(.purple, in: colorScheme))
                    Text(tr("图标样式", "Icon Style"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { engine.floatingBarIconStyle },
                        set: { engine.setFloatingBarIconStyle($0) }
                    )) {
                        ForEach(FloatingBarIconDisplayStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .opticalPlatter(cornerRadius: 12, isSelected: false)
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BarLensPalette.ink(.cyan, in: colorScheme))
                Text(tr("顶栏图标", "Menu Bar Icon"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(StatusBarIconStyle.allCases) { style in
                        let selected = engine.statusBarIconStyle == style
                        Button {
                            engine.setStatusBarIconStyle(style)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: style.previewSymbol)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(style.title)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .foregroundStyle(selected ? Color.white : .primary.opacity(0.90))
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(BarLensPalette.selectionFill(in: colorScheme))
                                        .shadow(color: BarLensPalette.selectionFill(in: colorScheme).opacity(0.30), radius: 4, y: 1)
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.white.opacity(0.32) : Color.primary.opacity(0.10),
                                        lineWidth: 0.75
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .opticalPlatter(cornerRadius: 12, isSelected: false)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 3: Gestures & Pro Tips

    private var stepGesturesAndFinish: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("手势、丝滑拖拽与快捷操作", "Gestures, Dragging & Quick Actions"))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(tr(
                    "无需每次打开设置窗口，日常操作一指直达：",
                    "Master everyday interactions right from your menu bar:"
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.78))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                OnboardingTipCard(
                    symbol: "cursorarrow.click.2",
                    tone: .blue,
                    title: tr("单击 · 双击 · 悬停", "Click · Double-Click · Hover"),
                    detail: tr("单击展开「可隐藏」，双击展开全部；还可在「通用」开启悬停自动展开。", "Click for Hidden, double-click for All, or enable optional hover-to-reveal in General.")
                )
                OnboardingTipCard(
                    symbol: "hand.draw.fill",
                    tone: .teal,
                    title: tr("双指滑动与鼠标滚轮", "Trackpad Swipe & Scroll"),
                    detail: tr("在顶栏触发图标上「下滑 / 左滑」逐级展开，「上滑 / 右滑」或悬浮栏上滑收起。", "Swipe/scroll down or left on the trigger to reveal; swipe up or right to collapse.")
                )
                OnboardingTipCard(
                    symbol: "hand.point.up.left.fill",
                    tone: .purple,
                    title: tr("1:1 丝滑拖拽排序", "1:1 Drag Reordering"),
                    detail: tr("在悬浮栏内按住任意图标左右拖动即可实时换位，松手自动记忆排序。", "Hold and drag any icon left or right inside the Floating Bar to arrange your layout.")
                )
                OnboardingTipCard(
                    symbol: "contextualmenu.and.cursorarrow",
                    tone: .pink,
                    title: tr("右键菜单与速览面板", "Right-Click Menus"),
                    detail: tr("右键顶栏触发图标打开「速览面板」；右键悬浮栏内图标可快速调序、换区或退出应用。", "Right-click the trigger for Quick Panel; right-click any Floating Bar icon for quick actions.")
                )
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Subviews

private struct OnboardingCheckCard: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(BarLensPalette.selectionFill(in: colorScheme))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opticalPlatter(cornerRadius: 13, isSelected: false)
    }
}

private struct OnboardingTierCard: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    let desc: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(desc)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: 118, alignment: .topLeading)
        .padding(12)
        .opticalPlatter(cornerRadius: 13, isSelected: false)
    }
}

private struct OnboardingChoiceCard: View {
    let isSelected: Bool
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(.blue, in: colorScheme)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .primary.opacity(0.72))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .primary.opacity(0.35))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: 116, alignment: .topLeading)
            .padding(13)
            .opticalPlatter(cornerRadius: 13, isSelected: isSelected, tint: .accentColor)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingTipCard: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: 118, alignment: .topLeading)
        .padding(13)
        .opticalPlatter(cornerRadius: 13, isSelected: false)
    }
}
