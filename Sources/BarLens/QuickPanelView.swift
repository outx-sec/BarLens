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

    private var colorScheme: ColorScheme { engine.effectiveColorScheme }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 12) {
                revealControls
                sectionOverview
                inspection
                if let message = engine.connectionError ?? engine.lastError ?? engine.scanWarning {
                    let warnColor = BarLensPalette.ink(.orange, in: colorScheme)
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(warnColor)
                        Text(message)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if engine.connectionError == nil, engine.lastError != nil {
                            Button {
                                engine.clearLastError()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary.opacity(0.68))
                            }
                            .buttonStyle(.plain)
                            .help(tr("关闭提示", "Dismiss"))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BarLensPalette.badgeFill(.orange, in: colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(warnColor.opacity(0.28), lineWidth: 0.75)
                    }
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
        .environment(\.colorScheme, engine.effectiveColorScheme)
        .preferredColorScheme(engine.effectiveColorScheme)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                BarLensPalette.windowScrim(in: colorScheme, glassOpacity: glassOpacity)
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
        let statusColor = BarLensPalette.ink(connectionTone, in: colorScheme)
        return HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("BarLens")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                if engine.isRecovering {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(statusColor).frame(width: 5.5, height: 5.5)
                }
                Text(connectionTitle).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8.5).padding(.vertical, 5)
            .background(BarLensPalette.badgeFill(connectionTone, in: colorScheme), in: Capsule())
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
            .foregroundStyle(selected ? Color.white : .primary.opacity(0.88))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(BarLensPalette.selectionFill(in: colorScheme))
                        .shadow(color: BarLensPalette.selectionFill(in: colorScheme).opacity(0.28), radius: 3, y: 1)
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
        let accent = section.readableTint(in: colorScheme)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selectedSection = section }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer(minLength: 2)
                    Text(count(in: section), format: .number)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                Text(disabled ? tr("已并入可隐藏", "Merged into Hidden") : section.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(selected ? 1.0 : 0.78))
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
        let sectionAccent = selectedSection.readableTint(in: colorScheme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(selectedSection.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(sectionVisibility)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sectionAccent)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(BarLensPalette.badgeFill(selectedSection.tone, in: colorScheme), in: Capsule())
                if selectedSection == .visible && engine.tuckedOverflowCount > 0 {
                    let tealInk = BarLensPalette.ink(.teal, in: colorScheme)
                    Text(tr("暂收 \(engine.tuckedOverflowCount)", "\(engine.tuckedOverflowCount) Tucked"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tealInk)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(BarLensPalette.badgeFill(.teal, in: colorScheme), in: Capsule())
                }
                Spacer()
                if catalog.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            if previewRows.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: catalog.isLoading ? "ellipsis" : "tray")
                        .font(.system(size: 18)).foregroundStyle(.primary.opacity(0.45))
                    Text(catalog.isLoading ? tr("正在读取…", "Loading…") : tr("暂无项目", "No items"))
                        .font(.system(size: 11.5)).foregroundStyle(.primary.opacity(0.72))
                    if !catalog.isLoading {
                        Button(tr("打开设置", "Open Settings"), action: onManage).buttonStyle(.link).font(.system(size: 11.5))
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
                                        .font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22)
                                        .foregroundStyle(sectionAccent)
                                }
                                Text(row.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let statusBadge = row.statusBadge {
                                    Text(statusBadge.text)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(BarLensPalette.ink(statusBadge.tone, in: colorScheme))
                                        .lineLimit(1)
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(BarLensPalette.badgeFill(statusBadge.tone, in: colorScheme), in: Capsule())
                                }
                                Spacer(minLength: 6)
                                Menu {
                                    rowMenuItems(for: row)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(row.detail)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.primary.opacity(0.70))
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(.primary.opacity(0.55))
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
            if selectedSection == .visible, engine.spatialBudgetPolicy != .off {
                Divider()
                let exempt = engine.isSpatiallyExempt(bundleID)
                Button {
                    engine.toggleSpatialExemption(for: bundleID)
                } label: {
                    Label(
                        exempt
                            ? tr("取消顶栏锁定常驻", "Unpin from Top Bar")
                            : tr("锁定顶栏常驻（免暂收）", "Pin to Top Bar (Never Tuck)"),
                        systemImage: exempt ? "pin.slash" : "pin.fill"
                    )
                }
            }
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
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.primary.opacity(0.75))
                    Text(tr("将圆点左侧设为", "Assign Items Left of Trigger"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: showingAssignment ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.primary.opacity(0.68))
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
        .opticalPlatter(cornerRadius: 11, isSelected: false)
    }

    private func assignButton(_ section: SectionModel.Section) -> some View {
        let accent = section.readableTint(in: colorScheme)
        return Button { onAssign(section) } label: {
            HStack(spacing: 5) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(section.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(BarLensPalette.badgeFill(section.tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accent.opacity(0.24), lineWidth: 0.75)
            }
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
                        Text("⌘ ,").font(.system(size: 10, weight: .medium)).foregroundStyle(.primary.opacity(0.60))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(QuickPanelButtonStyle()).keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button(action: onOpenGuide) {
                    Image(systemName: "book.closed").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QuickPanelButtonStyle())
                .foregroundStyle(.primary.opacity(0.80))
                .help(tr("查看使用指南", "Open User Guide")).accessibilityLabel(tr("查看使用指南", "Open User Guide"))
                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QuickPanelButtonStyle()).disabled(engine.isRecovering)
                .foregroundStyle(.primary.opacity(0.80))
                .help(tr("重新连接菜单栏服务", "Reconnect Menu Bar Service")).accessibilityLabel(tr("重新连接菜单栏服务", "Reconnect Menu Bar Service"))
                Button(action: onQuit) {
                    Image(systemName: "power").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QuickPanelButtonStyle()).keyboardShortcut("q", modifiers: .command)
                .foregroundStyle(.primary.opacity(0.80)).help(tr("退出 BarLens · ⌘Q", "Quit BarLens · ⌘Q"))
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
            .map { entry -> QuickPanelRow in
                let isTucked = engine.overflowDemotedBundleIDs.contains(entry.bundleID)
                let status = isTucked
                    ? tr("容量暂收", "Tucked")
                    : (!entry.isClassified && engine.unclassifiedSection != .visible ? tr("默认", "Default") : tr("运行中", "Running"))
                let badge: QuickPanelRow.StatusBadge?
                if engine.lensTelemetryEnabled, let unread = entry.telemetry.unreadBadge {
                    badge = .init(text: unread, tone: .orange)
                } else if engine.lensTelemetryEnabled, let chip = entry.telemetry.shortChip {
                    badge = .init(text: chip, tone: .cyan)
                } else if isTucked {
                    badge = .init(text: tr("暂收", "Tucked"), tone: .teal)
                } else {
                    badge = nil
                }
                return QuickPanelRow(id: "app:" + entry.bundleID, title: entry.displayName, icon: entry.icon,
                                     symbol: "app", detail: status, statusBadge: badge, isRunning: true,
                                     target: .app(bundleID: entry.bundleID, isClassified: entry.isClassified))
            }
        let system = engine.activeSystemItems
            .filter { effective(engine.systemItems.section(of: $0)) == selectedSection }
            .map { sysItem -> QuickPanelRow in
                let classified = engine.systemItems.isClassified(sysItem)
                let sysTel = engine.telemetry(for: sysItem)
                let badge: QuickPanelRow.StatusBadge? = sysTel.shortChip.map { .init(text: $0, tone: .cyan) }
                return QuickPanelRow(id: "system:" + sysItem.identifier, title: sysItem.title, icon: nil,
                                     symbol: sysItem.symbol, detail: classified ? tr("系统项目", "System") : tr("系统 · 默认", "System · Default"),
                                     statusBadge: badge,
                                     isRunning: true,
                                     target: .system(sysItem, isClassified: classified))
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

    private var connectionTone: SemanticTone {
        if engine.connectionError != nil || engine.nextRetryAt != nil { return .orange }
        return engine.isRecovering ? .blue : .teal
    }
}

private struct QuickPanelRow: Identifiable {
    struct StatusBadge {
        let text: String
        let tone: SemanticTone
    }

    enum Target {
        case app(bundleID: String, isClassified: Bool)
        case system(SystemItem, isClassified: Bool)
    }

    let id: String
    let title: String
    let icon: NSImage?
    let symbol: String
    let detail: String
    var statusBadge: StatusBadge? = nil
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
