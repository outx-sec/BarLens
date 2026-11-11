import AppKit
import SwiftUI

/// The right-click surface uses the same live model and materials as Settings.
/// Selecting a section only inspects it; reveal actions are explicitly separate.
struct QuickPanelView: View {
    @ObservedObject var engine: DividerEngine
    @ObservedObject var catalog: Catalog
    var onReveal: (SectionModel.Reveal) -> Void
    var onManage: () -> Void
    var onOpenGuide: () -> Void = {}
    var onReconnect: () -> Void
    var onAssign: (SectionModel.Section) -> Void
    var onQuit: () -> Void
    var onClose: () -> Void

    @State private var selectedSection: SectionModel.Section = .hidden
    @State private var showingAssignment = false
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 12) {
                revealControls
                sectionOverview
                inspection
                if let message = engine.connectionError ?? engine.lastError ?? engine.scanWarning {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if engine.connectionError == nil, engine.lastError != nil {
                            Button {
                                engine.clearLastError()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(tr("关闭提示", "Dismiss"))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                }
                assignment
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: 368)
        .frame(maxHeight: .infinity)
        .preferredColorScheme(engine.appearanceMode.colorScheme)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                (colorScheme == .dark ? Color.black : Color.white).opacity(glassOpacity)
            }
        }
        .onAppear {
            if !engine.alwaysHiddenEnabled, selectedSection == .alwaysHidden { selectedSection = .hidden }
            engine.refreshRunningApplications()
            refreshCatalog()
        }
        .onChange(of: engine.catalogRevision) { _, _ in refreshCatalog() }
        .onChange(of: engine.alwaysHiddenEnabled) { _, enabled in
            if !enabled, selectedSection == .alwaysHidden { selectedSection = .hidden }
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("BarLens")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                if engine.isRecovering {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(connectionColor).frame(width: 5, height: 5)
                }
                Text(connectionTitle).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(connectionColor)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(connectionColor.opacity(0.09), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private var revealControls: some View {
        HStack(spacing: 5) {
            revealButton(tr("收起", "Collapse"), symbol: "eye.slash", value: .none)
            revealButton(tr("展开", "Reveal"), symbol: "eye", value: .hidden)
            if engine.alwaysHiddenEnabled {
                revealButton(tr("全部", "All"), symbol: "square.stack.3d.up", value: .all)
            }
        }
        .padding(5)
        .opticalPlatter(cornerRadius: 13, isSelected: false)
    }

    private func revealButton(_ title: String, symbol: String, value: SectionModel.Reveal) -> some View {
        let selected = engine.reveal == value
        return Button { onReveal(value) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).symbolRenderingMode(.monochrome)
                Text(title)
            }
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .foregroundStyle(selected ? Color.accentColor
                                 : colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.82))
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.86))
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 3, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(QuickPanelButtonStyle())
        .accessibilityLabel(value == .none ? tr("收起所有隐藏分区", "Collapse Hidden Sections") : value == .hidden ? tr("展开可隐藏分区", "Reveal Hidden Section") : tr("展开全部分区", "Reveal All Sections"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(value == .none ? tr("只保留始终显示的项目", "Show only Visible items") : value == .hidden ? tr("显示可隐藏分区", "Show Hidden section") : tr("临时显示所有分区", "Peek at all sections"))
    }

    private var sectionOverview: some View {
        HStack(spacing: 8) {
            ForEach(SectionModel.Section.allCases, id: \.self) { section in
                sectionCard(section)
            }
        }
    }

    private func sectionCard(_ section: SectionModel.Section) -> some View {
        let selected = selectedSection == section
        let disabled = section == .alwaysHidden && !engine.alwaysHiddenEnabled
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selectedSection = section }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center) {
                    Image(systemName: section.symbol).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 2)
                    Text(count(in: section), format: .number)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(section.tint)
                Text(disabled ? tr("已并入可隐藏", "Merged into Hidden") : section.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .opticalPlatter(cornerRadius: 13, isSelected: selected, tint: section.tint)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(QuickPanelButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(tr("\(section.title)，\(count(in: section)) 项", "\(section.title), \(count(in: section)) items"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var inspection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(selectedSection.title).font(.system(size: 12, weight: .semibold))
                Text(sectionVisibility)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selectedSection.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(selectedSection.tint.opacity(0.14), in: Capsule())
                Spacer()
                if catalog.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            if previewRows.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: catalog.isLoading ? "ellipsis" : "tray")
                        .font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text(catalog.isLoading ? tr("正在读取…", "Loading…") : tr("暂无项目", "No items"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !catalog.isLoading {
                        Button(tr("打开设置", "Open Settings"), action: onManage).buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 110)
                .opticalPlatter(cornerRadius: 12, isSelected: false)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(previewRows) { row in
                            HStack(spacing: 9) {
                                if let icon = row.icon {
                                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                        .opacity(row.isRunning ? 1.0 : 0.65)
                                } else {
                                    Image(systemName: row.symbol)
                                        .font(.system(size: 13)).frame(width: 22, height: 22)
                                        .foregroundStyle(selectedSection.tint)
                                }
                                Text(row.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 6)
                                Menu {
                                    rowMenuItems(for: row)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(row.detail)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .padding(.vertical, 6).padding(.horizontal, 9)
                            .contentShape(Rectangle())
                            .contextMenu {
                                rowMenuItems(for: row)
                            }
                        }
                    }
                }
                .frame(minHeight: 110, maxHeight: .infinity)
                .scrollIndicators(.automatic)
                .opticalPlatter(cornerRadius: 12, isSelected: false)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenuItems(for row: QuickPanelRow) -> some View {
        Button {
            onClose()
            switch row.target {
            case .app(let bundleID, _):
                engine.activateFromFloatingBar(bundleID: bundleID)
            case .system(let item, _):
                engine.activateFromFloatingBar(systemItem: item)
            }
        } label: {
            Label(tr("打开菜单", "Open Menu"), systemImage: "menubar.arrow.down.rectangle")
        }

        if selectedSection != .visible, previewRows.count > 1 {
            let siblingIDs = engine.floatingBarOrder.sorted(previewRows.map(\.id), id: { $0 })
            Divider()
            if siblingIDs.first != row.id {
                Button {
                    engine.moveFloatingBarItemToEdge(row.id, toFront: true, within: siblingIDs)
                } label: {
                    Label(tr("在悬浮栏移至最前", "Move to Front in Floating Bar"), systemImage: "arrow.left.to.line")
                }
            }
            if siblingIDs.last != row.id {
                Button {
                    engine.moveFloatingBarItemToEdge(row.id, toFront: false, within: siblingIDs)
                } label: {
                    Label(tr("在悬浮栏移至最后", "Move to End in Floating Bar"), systemImage: "arrow.right.to.line")
                }
            }
        }

        Divider()
        let choices: [SectionModel.Section] = engine.alwaysHiddenEnabled
            ? [.visible, .hidden, .alwaysHidden]
            : [.visible, .hidden]
        ForEach(choices, id: \.self) { section in
            Button {
                switch row.target {
                case .app(let bundleID, _):
                    engine.setSection(section, for: bundleID)
                case .system(let item, _):
                    engine.setSection(section, for: item)
                }
            } label: {
                Label(section.title, systemImage: section.symbol)
            }
        }
        switch row.target {
        case .app(let bundleID, let isClassified):
            if isClassified {
                Divider()
                if row.isRunning {
                    Button(tr("恢复默认归属", "Reset to Default Section")) {
                        engine.removeAssignment(for: bundleID)
                    }
                } else {
                    Button(tr("从列表中移除", "Remove from List"), role: .destructive) {
                        engine.removeAssignment(for: bundleID)
                    }
                }
            }
            if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                Divider()
                if let appURL = runningApp.bundleURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    } label: {
                        Label(tr("在访达中显示", "Show in Finder"), systemImage: "folder")
                    }
                }
                Button(role: .destructive) {
                    runningApp.terminate()
                } label: {
                    Label(tr("退出 \(row.title)", "Quit \(row.title)"), systemImage: "xmark.circle")
                }
            }
        case .system(let item, let isClassified) where isClassified:
            Divider()
            Button(tr("恢复默认归属", "Reset to Default Section")) {
                engine.removeAssignment(for: item)
            }
        default:
            EmptyView()
        }
    }

    private var assignment: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { showingAssignment.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                    Text(tr("将圆点左侧设为", "Assign Items Left of Trigger")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: showingAssignment ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(11).contentShape(Rectangle())
            }
            .buttonStyle(QuickPanelButtonStyle())
            .accessibilityValue(showingAssignment ? tr("已展开", "Expanded") : tr("已收起", "Collapsed"))
            if showingAssignment {
                HStack(spacing: 8) {
                    assignButton(.hidden)
                    if engine.alwaysHiddenEnabled { assignButton(.alwaysHidden) }
                }
                .padding(.horizontal, 11).padding(.bottom, 11)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func assignButton(_ section: SectionModel.Section) -> some View {
        Button { onAssign(section) } label: {
            Label(section.title, systemImage: section.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(section.tint)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(section.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(QuickPanelButtonStyle())
        .disabled(engine.isRecovering)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Divider()
            HStack(spacing: 6) {
                Button(action: onManage) {
                    HStack(spacing: 7) {
                        Image(systemName: "gearshape")
                        Text(tr("打开设置", "Settings"))
                        Text("⌘ ,").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(QuickPanelButtonStyle()).keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button(action: onOpenGuide) {
                    Image(systemName: "book.closed").font(.system(size: 12))
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QuickPanelButtonStyle())
                .foregroundStyle(.secondary)
                .help(tr("查看使用指南", "Open User Guide")).accessibilityLabel(tr("查看使用指南", "Open User Guide"))
                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QuickPanelButtonStyle()).disabled(engine.isRecovering)
                .foregroundStyle(.secondary)
                .help(tr("重新连接菜单栏服务", "Reconnect Menu Bar Service")).accessibilityLabel(tr("重新连接菜单栏服务", "Reconnect Menu Bar Service"))
                Button(action: onQuit) {
                    Image(systemName: "power").font(.system(size: 12))
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QuickPanelButtonStyle()).keyboardShortcut("q", modifiers: .command)
                .foregroundStyle(.secondary).help(tr("退出 BarLens · ⌘Q", "Quit BarLens · ⌘Q"))
                .accessibilityLabel(tr("退出 BarLens", "Quit BarLens"))
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    private func refreshCatalog() {
        catalog.rebuild(model: engine.model, query: "",
                        extraOwners: engine.ledgerOnlyOwners,
                        snapshot: engine.latestScanItems)
    }

    private func count(in section: SectionModel.Section) -> Int {
        switch section {
        case .visible: return engine.visibleCount
        case .hidden: return engine.revealableCount
        case .alwaysHidden: return engine.alwaysHiddenCount
        }
    }

    private func effective(_ section: SectionModel.Section) -> SectionModel.Section {
        !engine.alwaysHiddenEnabled && section == .alwaysHidden ? .hidden : section
    }

    private var previewRows: [QuickPanelRow] {
        let apps = catalog.entries
            .filter { $0.isRunning && $0.itemCount > 0 && effective(engine.model.section(of: $0.bundleID)) == selectedSection }
            .map {
                let status = !$0.isClassified && engine.unclassifiedSection != .visible ? tr("默认", "Default") : tr("运行中", "Running")
                return QuickPanelRow(id: "app:" + $0.bundleID, title: $0.displayName, icon: $0.icon,
                                     symbol: "app", detail: status, isRunning: true,
                                     target: .app(bundleID: $0.bundleID, isClassified: $0.isClassified))
            }
        let system = engine.activeSystemItems
            .filter { effective(engine.systemItems.section(of: $0)) == selectedSection }
            .map {
                let classified = engine.systemItems.isClassified($0)
                return QuickPanelRow(id: "system:" + $0.identifier, title: $0.title, icon: nil,
                                     symbol: $0.symbol, detail: classified ? tr("系统项目", "System") : tr("系统 · 默认", "System · Default"),
                                     isRunning: true,
                                     target: .system($0, isClassified: classified))
            }
        return (apps + system).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var sectionVisibility: String {
        switch selectedSection {
        case .visible: return tr("始终保留", "Always Shown")
        case .hidden: return engine.reveal == .none ? tr("已收起", "Collapsed") : tr("已展开", "Revealed")
        case .alwaysHidden: return engine.reveal == .all ? tr("临时展开", "Peeking") : tr("已收起", "Collapsed")
        }
    }

    private var connectionTitle: String {
        if engine.nextRetryAt != nil { return tr("等待重试", "Retrying") }
        if engine.isRecovering { return tr("恢复中", "Recovering") }
        if engine.connectionError != nil { return tr("连接异常", "Error") }
        return tr("已就绪", "Ready")
    }

    private var connectionColor: Color {
        if engine.connectionError != nil || engine.nextRetryAt != nil { return .orange }
        return engine.isRecovering ? .blue : .teal
    }
}

private struct QuickPanelRow: Identifiable {
    enum Target {
        case app(bundleID: String, isClassified: Bool)
        case system(SystemItem, isClassified: Bool)
    }

    let id: String
    let title: String
    let icon: NSImage?
    let symbol: String
    let detail: String
    let isRunning: Bool
    let target: Target
}

private struct QuickPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuickPanelButtonFeedback(configuration: configuration)
    }
}

private struct QuickPanelButtonFeedback: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.primary.opacity(hovered && isEnabled ? 0.045 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}
