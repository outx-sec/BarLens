import SwiftUI

/// The 划分 pane: every app that owns a status item, and which section it is in.
struct SectionsSettingsView: View {

    @ObservedObject var engine: DividerEngine
    /// Owned by the settings window so the 通用 pane can share the same list.
    @ObservedObject var catalog: Catalog

    @StateObject private var discovery = SystemItemDiscovery()
    @State private var query = ""
    @State private var showingClearConfirmation = false

    private var entries: [AppEntry] { catalog.entries }

    /// The always-hidden section is left out entirely when it is switched off,
    /// so the list only offers choices that do something.
    private var visibleSections: [SectionModel.Section] {
        engine.alwaysHiddenEnabled
            ? [.visible, .hidden, .alwaysHidden]
            : [.visible, .hidden]
    }

    var body: some View {
        VStack(spacing: 0) {
            revealControls
            searchField
            list
            if engine.isConfigured {
                Divider()
                footer
            }
        }
        .onAppear {
            engine.refreshRunningApplications()
            rebuild()
        }
        // Anything that can change which apps are listed: an app launching or
        // quitting, a permission being granted, or an assignment being made.
        .onChange(of: engine.catalogRevision) { _, _ in rebuild() }
        .onChange(of: query) { _, value in catalog.filter(query: value) }
        .alert(tr("清除所有分区？", "Clear All Sections?"), isPresented: $showingClearConfirmation) {
            Button(tr("取消", "Cancel"), role: .cancel) {}
            Button(tr("清除划分", "Clear Sections"), role: .destructive) { engine.clearSections() }
        } message: {
            Text(tr("应用与系统图标会恢复显示，默认归属也会重置为「始终显示」。", "All application and system icons will return to Visible, and default assignments will be reset."))
        }
    }

    private var filteredSystemItems: [SystemItem] {
        engine.activeSystemItems.filter { $0.matches(query: query) }
    }

    private func count(for section: SectionModel.Section) -> Int {
        switch section {
        case .visible:      return engine.visibleCount
        case .hidden:       return engine.revealableCount
        case .alwaysHidden: return engine.alwaysHiddenCount
        }
    }

    private func isSectionRevealed(_ section: SectionModel.Section) -> Bool {
        switch section {
        case .visible:      return true
        case .hidden:       return engine.reveal == .hidden || engine.reveal == .all
        case .alwaysHidden: return engine.reveal == .all
        }
    }

    private var revealControls: some View {
        HStack(spacing: 8) {
            ForEach(visibleSections, id: \.self) { section in
                let revealed = isSectionRevealed(section)
                Button {
                    switch section {
                    case .visible:      engine.setReveal(.none)
                    case .hidden:       engine.toggleHidden()
                    case .alwaysHidden: engine.toggleAlwaysHidden()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(section.tint)
                        Spacer(minLength: 4)
                        if revealed && section != .visible {
                            Text(tr("已展开", "Revealed"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(section.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(section.tint.opacity(0.14), in: Capsule())
                        }
                        Text("\(count(for: section))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(section.tint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .opticalPlatter(
                        cornerRadius: 12,
                        isSelected: revealed && section != .visible,
                        tint: section.tint
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help(section == .visible ? tr("收起隐藏分区", "Collapse Hidden Sections") : tr("点按切换此分区的展开状态", "Click to toggle this section"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("搜索应用或系统图标", "Search apps or system items"), text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("清除搜索", "Clear Search"))
            }
            Divider().frame(height: 14)
            refreshButton
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .opticalPlatter(cornerRadius: 12, isSelected: false)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    /// Rescanning is not just a redraw: an app that launched since the list was
    /// built owns a status item now, and the engine's cached set of running
    /// applications has to hear about it before the next apply can admit it.
    private var refreshButton: some View {
        Button {
            engine.refreshRunningApplications()
            rebuild()
        } label: {
            if catalog.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .disabled(catalog.isLoading)
        .accessibilityLabel(tr("刷新应用列表", "Refresh App List"))
        .help(tr("重新扫描菜单栏，刷新应用列表", "Rescan menu bar and refresh list"))
    }

    // MARK: - List

    private var list: some View {
        List {
            if query.isEmpty || !filteredSystemItems.isEmpty { systemItems }

            ForEach(visibleSections, id: \.self) { section in
                let rows = entries.filter {
                    $0.section == section || (section == .hidden && !engine.alwaysHiddenEnabled
                                              && $0.section == .alwaysHidden)
                }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { entry in
                            AppRow(entry: entry, engine: engine)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Label(section.title, systemImage: section.symbol)
                            Spacer()
                            Text("\(rows.count)").monospacedDigit()
                        }
                        .font(.subheadline)
                        .foregroundStyle(section.tint)
                    }
                }
            }

            if !catalog.isLoading && entries.isEmpty && (query.isEmpty || filteredSystemItems.isEmpty) {
                Section {
                    Text(query.isEmpty ? tr("暂无状态栏图标", "No menu bar items found") : tr("无匹配项目", "No matching items"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if catalog.isLoading && entries.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .windowBackgroundColor))
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("正在扫描…", "Scanning…")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Built-in items

    private var systemItems: some View {
        Section {
            ForEach(filteredSystemItems) { item in
                SystemItemRow(item: item, engine: engine)
            }
            if query.isEmpty {
                scanRow
            }
        } header: {
            HStack(spacing: 6) {
                Label(tr("系统图标", "System Items"), systemImage: "gearshape.2")
                Spacer()
                Text("\(filteredSystemItems.count)").monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var scanRow: some View {
        switch discovery.phase {
        case .scanning(let identifier, let step, let total):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(tr("正在识别 \(SystemItemName.title(for: identifier)) (\(step)/\(total))", "Calibrating \(SystemItemName.title(for: identifier)) (\(step)/\(total))"))
                    .font(.system(size: 12))
                Spacer()
                Button(tr("停止", "Stop")) { discovery.cancel() }
                    .controlSize(.small)
            }
            .padding(.vertical, 2)

        default:
            HStack(spacing: 10) {
                Button(tr("扫描系统图标", "Scan System Items")) { discovery.start(engine: engine) }
                    .controlSize(.small)
                    .disabled(!engine.hasAccessibility)
                Spacer()
                if let summary = scanSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var scanSummary: String? {
        func names(_ ids: [String]) -> String {
            ids.map(SystemItemName.title(for:)).joined(separator: tr("、", ", "))
        }
        switch discovery.phase {
        case .finished(let recorded, let skipped, let unsupported):
            var parts: [String] = []
            if !recorded.isEmpty { parts.append(tr("新增 \(names(recorded))", "Added \(names(recorded))")) }
            if !skipped.isEmpty { parts.append(tr("未确认 \(names(skipped))", "Skipped \(names(skipped))")) }
            if !unsupported.isEmpty { parts.append(tr("不支持单独控制 \(names(unsupported))", "Unsupported \(names(unsupported))")) }
            return parts.isEmpty ? tr("无新系统图标", "No new system items") : parts.joined(separator: " · ")
        case .nothingToFind:
            return tr("已全部识别", "All items recognized")
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(engine.reveal == .none ? tr("临时显示", "Reveal Hidden") : tr("收起图标", "Collapse")) {
                engine.toggleHidden()
            }
            Button(tr("清除划分", "Clear All")) { showingClearConfirmation = true }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Data

    private func rebuild() {
        catalog.rebuild(model: engine.model, query: query,
                        extraOwners: engine.ledgerOnlyOwners,
                        snapshot: engine.latestScanItems)
    }
}

// MARK: - Rows

private struct SystemItemRow: View {
    let item: SystemItem
    @ObservedObject var engine: DividerEngine

    private var isClassified: Bool {
        engine.systemItems.isClassified(item)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))

            Text(item.title)
                .font(.system(size: 13))

            if engine.systemItemModes[item.identifier] == .showWhenActive && !engine.isSystemItemActive(item) {
                BadgeTag(text: tr("启用时显示", "When Active"))
            }

            if !isClassified && engine.newSystemItemSection != .visible {
                BadgeTag(text: tr("默认", "Default"))
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: {
                    let section = engine.systemItems.section(of: item)
                    return !engine.alwaysHiddenEnabled && section == .alwaysHidden ? .hidden : section
                },
                set: { engine.setSection($0, for: item) })) {
                ForEach(engine.alwaysHiddenEnabled
                        ? [SectionModel.Section.visible, .hidden, .alwaysHidden]
                        : [.visible, .hidden], id: \.self) { section in
                    Text(section.title).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .help(item.isAddressableByAssessment
              ? tr("\(item.identifier) · 编号 \(item.rawValue)", "\(item.identifier) · ID \(item.rawValue)")
              : tr("\(item.identifier) · 控制中心联动", "\(item.identifier) · Control Center Managed"))
        .contextMenu {
            ForEach(engine.alwaysHiddenEnabled
                    ? [SectionModel.Section.visible, .hidden, .alwaysHidden]
                    : [.visible, .hidden], id: \.self) { section in
                Button {
                    engine.setSection(section, for: item)
                } label: {
                    Label(section.title, systemImage: section.symbol)
                }
            }
            if engine.systemItemModes[item.identifier] == .showWhenActive {
                Divider()
                Button(tr("设为菜单栏常驻", "Always Show in Menu Bar")) {
                    engine.setControlCenterShowMode(.alwaysShow, for: item)
                }
            } else if MenuBarBuiltIns.dropdownCapableIdentifiers.contains(item.identifier) {
                Divider()
                Button(tr("恢复系统「启用时显示」", "Show When Active in System")) {
                    engine.setControlCenterShowMode(.showWhenActive, for: item)
                }
            }
            if isClassified {
                Divider()
                Button(tr("恢复默认归属", "Reset to Default Section")) {
                    engine.removeAssignment(for: item)
                }
            }
        }
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @ObservedObject var engine: DividerEngine

    @State private var isShowingInfo = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: entry.icon ?? NSImage(named: NSImage.applicationIconName)!)
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(entry.isRunning ? 1.0 : 0.6)

            HStack(spacing: 6) {
                Text(entry.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if entry.itemCount > 1 {
                    BadgeTag(text: "×\(entry.itemCount)")
                }

                if !entry.isRunning {
                    BadgeTag(text: tr("未运行", "Not Running"))
                }

                if !entry.isClassified && engine.unclassifiedSection != .visible {
                    BadgeTag(text: tr("默认", "Default"))
                }

                if entry.isLedgerOnly {
                    Button {
                        isShowingInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
                        Text(entry.hoverDetail)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 320, alignment: .leading)
                            .padding(14)
                            .textSelection(.enabled)
                    }
                }
            }
            .contentShape(Rectangle())
            .help(entry.hoverDetail)

            Spacer(minLength: 12)

            if !entry.isRunning && entry.isClassified {
                Button {
                    engine.removeAssignment(for: entry.bundleID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(tr("移除此未运行的应用", "Remove this non-running app"))
                .accessibilityLabel(tr("移除 \(entry.displayName)", "Remove \(entry.displayName)"))
            }

            Picker("", selection: Binding(
                get: {
                    !engine.alwaysHiddenEnabled && entry.section == .alwaysHidden ? .hidden : entry.section
                },
                set: { engine.setSection($0, for: entry.bundleID) })) {
                ForEach(engine.alwaysHiddenEnabled
                        ? [SectionModel.Section.visible, .hidden, .alwaysHidden]
                        : [.visible, .hidden], id: \.self) { section in
                    Text(section.title).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .contextMenu {
            ForEach(engine.alwaysHiddenEnabled
                    ? [SectionModel.Section.visible, .hidden, .alwaysHidden]
                    : [.visible, .hidden], id: \.self) { section in
                Button {
                    engine.setSection(section, for: entry.bundleID)
                } label: {
                    Label(section.title, systemImage: section.symbol)
                }
            }
            if entry.isClassified {
                Divider()
                if entry.isRunning {
                    Button(tr("恢复默认归属", "Reset to Default Section")) {
                        engine.removeAssignment(for: entry.bundleID)
                    }
                } else {
                    Button(tr("从列表中移除", "Remove from List"), role: .destructive) {
                        engine.removeAssignment(for: entry.bundleID)
                    }
                }
            }
            Divider()
            Button(tr("复制 Bundle ID", "Copy Bundle ID")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.bundleID, forType: .string)
            }
        }
    }
}

private struct BadgeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.quaternary, in: Capsule())
    }
}
