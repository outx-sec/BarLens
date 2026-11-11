import SwiftUI

/// The panes of the settings window.
///
/// A sidebar rather than a flat window from the start: the app is small today,
/// but this is the shape that can take 外观 / 热键 / 关于 later without the
/// window turning into one long scroll.
enum SettingsPane: String, CaseIterable, Identifiable {
    case sections
    case appearance
    case general
    case guide
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sections:   return tr("分区管理", "Sections")
        case .appearance: return tr("外观", "Appearance")
        case .general:    return tr("通用", "General")
        case .guide:      return tr("使用指南", "Guide")
        case .about:      return tr("关于", "About")
        }
    }

    var symbol: String {
        switch self {
        case .sections:   return "rectangle.3.group"
        case .appearance: return "sparkles"
        case .general:    return "gearshape"
        case .guide:      return "book.closed"
        case .about:      return "info.circle"
        }
    }
}

struct SettingsView: View {

    @ObservedObject var engine: DividerEngine
    /// Owned here rather than by the 划分 pane so both panes share one sweep:
    /// the 通用 pane shows how many apps a default change would move, and that
    /// count comes from the same list. It also means switching panes no longer
    /// throws the list away and rebuilds it.
    @StateObject private var catalog = Catalog()
    /// Remembered so reopening the window lands where the user left off.
    @State private var pane = SettingsPane(rawValue: Defaults.settingsPane) ?? .sections
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            sidebar
            VStack(spacing: 0) {
                paneHeader
                Banners(engine: engine)
                switch pane {
                case .sections:   SectionsSettingsView(engine: engine, catalog: catalog)
                case .appearance: AppearanceSettingsView(engine: engine)
                case .general:    GeneralSettingsView(engine: engine, catalog: catalog)
                case .guide:      GuideSettingsView(engine: engine)
                case .about:      AboutSettingsView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowPaneGlass(cornerRadius: 20)
        }
        .padding(12)
        .padding(.top, 28)
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
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(engine.appearanceMode.colorScheme)
        .onAppear {
            if let target = engine.requestedSettingsPane {
                pane = target
                engine.requestedSettingsPane = nil
            }
        }
        .onChange(of: engine.requestedSettingsPane) { _, target in
            guard let target else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                pane = target
            }
            engine.requestedSettingsPane = nil
        }
        .onChange(of: pane) { _, newValue in Defaults.settingsPane = newValue.rawValue }
    }

    /// A plain list rather than `NavigationSplitView`.
    ///
    /// The split view puts a collapse button in the title bar, and there is
    /// nothing to collapse here — two fixed panes. Hiding the button through
    /// the toolbar API did not take effect, and building the sidebar directly
    /// avoids the question entirely.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .frame(width: 32, height: 32)
                Text("BarLens")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)

            VStack(spacing: 5) {
                ForEach([SettingsPane.sections, .appearance, .general, .guide, .about]) { item in
                    let isSelected = pane == item
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            pane = item
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? BarLensPalette.ink(.blue, in: colorScheme) : .primary.opacity(0.76))
                                .frame(width: 20)
                            Text(item.title)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .opticalPlatter(cornerRadius: 11, isSelected: isSelected, tint: .accentColor)
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Spacer(minLength: 24)
            HStack(spacing: 7) {
                Circle().fill(connectionTint).frame(width: 6, height: 6)
                Text(connectionTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.84))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { engine.recoverConnection() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(engine.isRecovering)
                .help(tr("重新连接菜单栏服务", "Reconnect Menu Bar Service"))
                .accessibilityLabel(tr("重新连接菜单栏服务", "Reconnect Menu Bar Service"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .opticalPlatter(cornerRadius: 10, isSelected: false)
        }
        .padding(12)
        .frame(width: 180)
        .windowPaneGlass(cornerRadius: 20)
    }

    private var connectionTitle: String {
        if engine.nextRetryAt != nil { return tr("等待重试", "Waiting to Retry") }
        if engine.isRecovering { return tr("正在恢复…", "Recovering…") }
        if engine.connectionError != nil { return tr("连接异常", "Connection Error") }
        return engine.isConfigured ? tr("服务已就绪", "Service Ready") : tr("等待划分", "Unconfigured")
    }

    private var connectionTint: Color {
        if engine.connectionError != nil { return BarLensPalette.ink(.orange, in: colorScheme) }
        return engine.isRecovering ? BarLensPalette.ink(.blue, in: colorScheme) : BarLensPalette.ink(.teal, in: colorScheme)
    }

    private var paneHeader: some View {
        HStack {
            Text(pane.title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - Banners

/// Conditions that make the app misbehave, shown above whichever pane is open
/// rather than buried in one of them.
struct Banners: View {
    @ObservedObject var engine: DividerEngine

    var body: some View {
        if let error = engine.connectionError {
            Banner(symbol: "arrow.triangle.2.circlepath", tone: .orange,
                   title: error) {
                Button(tr("重新连接", "Reconnect")) { engine.recoverConnection() }
                    .controlSize(.small)
                    .disabled(engine.isRecovering)
            }
        }
        if !engine.isInstalledCorrectly {
            Banner(symbol: "exclamationmark.triangle.fill",
                   tone: .orange,
                   title: tr("请移至「应用程序」文件夹后重新打开", "Move BarLens to /Applications and reopen")) {
                Button(tr("在访达中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .controlSize(.small)
            }
        }
        if !engine.hasAccessibility {
            Banner(symbol: "hand.raised.fill",
                   tone: .blue,
                   title: tr("需要辅助功能权限", "Accessibility Permission Required")) {
                Button(tr("打开系统设置", "Open System Settings")) {
                    engine.requestAccessibility()
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .controlSize(.small)
            }
        }
        if let message = engine.lastError, engine.connectionError == nil {
            Banner(symbol: "info.circle.fill",
                   tone: .orange,
                   title: message) {
                Button(tr("知道了", "Dismiss")) { engine.clearLastError() }
                    .controlSize(.small)
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(accent)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 0.8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
