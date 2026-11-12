import AppKit
import SwiftUI

/// Dedicated settings pane for BarLens's Self-Curating Menu Bar (`智能自治`):
/// 1. Presentation & Screen-Mirroring Shield (`投屏净空盾`)
/// 2. Zero-Capture Status Bubble-Up (`隐藏项状态突变冒泡`)
/// 3. Usage Auto-Decay & Unified Top-Bar Pinning (`使用热度自沉淀与常驻锁定`)
struct SmartBarSettingsView: View {

    @ObservedObject var engine: DividerEngine
    @ObservedObject var catalog: Catalog
    @Environment(\.colorScheme) private var colorScheme

    private var visibleRunningApps: [AppEntry] {
        catalog.entries.filter {
            $0.isRunning
                && $0.itemCount > 0
                && engine.model.section(of: $0.bundleID) == .visible
        }
    }

    private var autoDecayedEntries: [AppEntry] {
        catalog.entries.filter {
            engine.autoDecayedBundleIDs.contains($0.bundleID)
                && engine.model.section(of: $0.bundleID) == .hidden
        }
    }

    var body: some View {
        Form {
            presentationShieldSection
            statusPulseSection
            autoDecayAndBudgetSection
            visibleAppsPinningSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            catalog.rebuild(
                model: engine.model,
                query: "",
                extraOwners: engine.ledgerOnlyOwners,
                snapshot: engine.latestScanItems
            )
        }
        .onChange(of: engine.catalogRevision) { _, _ in
            catalog.rebuild(
                model: engine.model,
                query: "",
                extraOwners: engine.ledgerOnlyOwners,
                snapshot: engine.latestScanItems
            )
        }
    }

    // MARK: - 1. Presentation & Mirroring Shield

    private var presentationShieldSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { engine.isPresentationShieldActive },
                set: { engine.setPresentationShieldActive($0) }
            )) {
                HStack(alignment: .top, spacing: 8) {
                    SmartPreferenceLabel(
                        symbol: "shield.lefthalf.filled",
                        tone: .indigo,
                        title: tr("投屏净空盾", "Presentation Shield"),
                        subtitle: tr(
                            "一键隐去顶栏第三方图标，结束演示后按原布局恢复",
                            "Temporarily sweep third-party icons off the bar; restores exact layout when turned off"
                        )
                    )
                    if engine.isPresentationShieldActive {
                        SmartPillBadge(
                            text: engine.shieldedBundleIDs.isEmpty
                                ? (engine.activePresentationSource?.badgeText ?? tr("已开启", "Active"))
                                : tr("已净空 \(engine.shieldedBundleIDs.count) 项", "\(engine.shieldedBundleIDs.count) Shielded"),
                            tone: .indigo
                        )
                        .padding(.top, 2)
                    } else if let source = engine.activePresentationSource {
                        SmartPillBadge(text: source.badgeText, tone: .teal)
                            .padding(.top, 2)
                    }
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { engine.autoPresentationShieldOnMirroring },
                set: { engine.setAutoPresentationShieldOnMirroring($0) }
            )) {
                SmartSubPreferenceLabel(
                    tone: .indigo,
                    title: tr("共享屏幕或镜像投屏时自动开启", "Auto-Enable on Screen Sharing or Mirroring")
                )
            }
            .toggleStyle(.switch)

            Picker(selection: Binding(
                get: { engine.presentationShieldPolicy },
                set: { engine.setPresentationShieldPolicy($0) }
            )) {
                ForEach(PresentationShieldPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            } label: {
                SmartSubPreferenceLabel(
                    tone: .indigo,
                    title: tr("净空保护范围", "Shield Scope")
                )
            }
            .pickerStyle(.menu)
        } header: {
            Text(tr("投屏与会议隐私保护", "Presentation & Screen-Sharing Privacy"))
        }
    }

    // MARK: - 2. Zero-Capture Status Pulse

    private var statusPulseSection: some View {
        Section {
            Picker(selection: Binding(
                get: { engine.statusBubbleMode },
                set: { mode in
                    withAnimation(.easeOut(duration: 0.16)) {
                        engine.setStatusBubbleMode(mode)
                    }
                }
            )) {
                ForEach(StatusBubbleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SmartPreferenceLabel(
                    symbol: "bell.badge.waveform",
                    tone: .orange,
                    title: tr("隐藏项状态突变冒泡", "Hidden App Status Pulse"),
                    subtitle: tr(
                        "免录屏捕获未读、告警与状态切换，过滤网速歌词",
                        "Zero Screen Recording; surfaces unread counts, alerts & state flips"
                    )
                )
            }
            .pickerStyle(.menu)

            if engine.statusBubbleMode != .off {
                Picker(selection: Binding(
                    get: { engine.statusBubbleDwell },
                    set: { engine.setStatusBubbleDwell($0) }
                )) {
                    ForEach(StatusBubbleDwell.allCases) { dwell in
                        Text(dwell.title).tag(dwell)
                    }
                } label: {
                    SmartSubPreferenceLabel(
                        tone: .orange,
                        title: engine.statusBubbleMode == .surfaceTopBar
                            ? tr("浮现驻留策略", "Surface Dwell")
                            : tr("微光驻留策略", "Badge Dwell"),
                        subtitle: engine.statusBubbleDwell.detailDescription(for: engine.statusBubbleMode)
                    )
                }
                .pickerStyle(.menu)
            }

            if !engine.recentStatusBubbleHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("最近状态脉搏", "Recent Pulses"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.60))
                        Spacer()
                        Button(tr("清空", "Clear")) {
                            engine.clearStatusBubbleHistory()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }

                    ForEach(engine.recentStatusBubbleHistory.prefix(5)) { event in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(BarLensPalette.ink(event.reason.tone, in: colorScheme))
                                .frame(width: 6, height: 6)
                            Text(event.appName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            SmartPillBadge(text: event.reason.badgeText, tone: event.reason.tone, maxWidth: 180)
                            Spacer(minLength: 6)
                            Text(Self.relativeTimeString(since: event.triggeredAt))
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary.opacity(0.55))
                        }
                        .padding(.vertical, 1.5)
                    }
                }
                .padding(.leading, 39)
                .padding(.vertical, 2)
            }
        } header: {
            Text(tr("有事浮现 · 无事隐退", "Zero-Capture Semantic Pulse"))
        }
    }

    // MARK: - 3. Usage Auto-Decay & Spatial Budget

    private var autoDecayAndBudgetSection: some View {
        let dormantCount = engine.dormantVisibleBundleIDs().count
        return Section {
            Picker(selection: Binding(
                get: { engine.usageDecayPolicy },
                set: { engine.setUsageDecayPolicy($0) }
            )) {
                ForEach(UsageDecayPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            } label: {
                SmartPreferenceLabel(
                    symbol: "sparkles.rectangle.stack",
                    tone: .purple,
                    title: tr("低频图标自动沉淀", "Usage Auto-Decay"),
                    subtitle: tr(
                        "长期未点的常驻图标自动归入「可隐藏」分区",
                        "Moves untouched Visible icons into Hidden after idle days"
                    )
                )
            }
            .pickerStyle(.menu)

            if dormantCount > 0 {
                HStack(spacing: 8) {
                    SmartSubPreferenceLabel(
                        tone: .purple,
                        title: tr("发现 \(dormantCount) 个已超过观察期的闲置图标", "\(dormantCount) idle items exceeded threshold")
                    )
                    Spacer(minLength: 8)
                    Button(tr("立即收纳", "Tuck Now")) {
                        _ = engine.sweepDormantVisibleAppsNow()
                    }
                    .controlSize(.small)
                }
            }

            if !autoDecayedEntries.isEmpty {
                HStack(spacing: 8) {
                    SmartSubPreferenceLabel(
                        tone: .purple,
                        title: tr(
                            "已自动沉淀 \(autoDecayedEntries.count) 项：\(autoDecayedEntries.prefix(3).map(\.displayName).joined(separator: "、"))",
                            "Auto-tucked \(autoDecayedEntries.count): \(autoDecayedEntries.prefix(3).map(\.displayName).joined(separator: ", "))"
                        )
                    )
                    Spacer(minLength: 6)
                    Button(tr("查看分区", "View Sections")) {
                        engine.requestedSettingsPane = .sections
                    }
                    .controlSize(.small)
                }
            }

            Picker(selection: Binding(
                get: { engine.spatialBudgetPolicy },
                set: { engine.setSpatialBudgetPolicy($0) }
            )) {
                ForEach(SpatialBudgetPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    SmartPreferenceLabel(
                        symbol: "menubar.dock.rectangle.badge.record",
                        tone: .cyan,
                        title: tr("顶栏容量与防刘海保护", "Top Bar Spatial Budget"),
                        subtitle: tr(
                            "空间紧俏或超上限时暂收低频项，避让刘海与菜单",
                            "Tucks lower-priority icons when bar space runs tight"
                        )
                    )
                    if !engine.overflowDemotedBundleIDs.isEmpty {
                        SmartPillBadge(
                            text: tr("容量暂收 \(engine.overflowDemotedBundleIDs.count)", "\(engine.overflowDemotedBundleIDs.count) Tucked"),
                            tone: .teal
                        )
                        .padding(.top, 2)
                    }
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text(tr("热度自沉淀与容量预算", "Auto-Decay & Spatial Budget"))
        }
    }

    // MARK: - 4. Per-App Pinning & Freshness Inspection

    private var visibleAppsPinningSection: some View {
        Section {
            if visibleRunningApps.isEmpty {
                Text(tr("当前没有处于「始终显示」的运行中第三方应用。", "No running third-party apps in the Visible section."))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.68))
                    .padding(.vertical, 4)
            } else {
                ForEach(visibleRunningApps) { entry in
                    let isPinned = engine.isSpatiallyExempt(entry.bundleID)
                    let isShielded = engine.shieldedBundleIDs.contains(entry.bundleID)
                    let isOverflow = engine.overflowDemotedBundleIDs.contains(entry.bundleID)
                    let activityText = engine.activityBadgeText(for: entry.bundleID)

                    HStack(spacing: 10) {
                        Image(nsImage: entry.icon ?? NSImage(named: NSImage.applicationIconName)!)
                            .resizable()
                            .frame(width: 24, height: 24)

                        Text(entry.displayName)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        if isShielded {
                            SmartPillBadge(text: tr("净空暂收", "Shielded"), tone: .indigo)
                        } else if isOverflow {
                            SmartPillBadge(text: tr("容量暂收", "Tucked"), tone: .teal)
                        } else {
                            SmartPillBadge(
                                text: activityText,
                                tone: isPinned ? .blue : .neutral
                            )
                        }

                        Spacer(minLength: 8)

                        Button {
                            engine.toggleSpatialExemption(for: entry.bundleID)
                        } label: {
                            Label(
                                isPinned ? tr("已锁常驻", "Pinned") : tr("锁定常驻", "Pin"),
                                systemImage: isPinned ? "pin.fill" : "pin"
                            )
                            .font(.system(size: 11.5, weight: isPinned ? .semibold : .regular))
                        }
                        .controlSize(.small)
                        .tint(isPinned ? .accentColor : nil)
                        .help(tr(
                            "锁定后免于热度自动沉淀、容量暂收，并在「仅留常驻锁定」净空模式下保留在顶栏",
                            "Pinned apps never auto-decay, never tuck for spatial budget, and stay visible when Presentation Shield is set to Keep Pinned Only"
                        ))

                        Button {
                            engine.setSection(.hidden, for: entry.bundleID)
                        } label: {
                            Text(tr("收纳", "Hide"))
                                .font(.system(size: 11.5))
                        }
                        .controlSize(.small)
                        .help(tr("立即移入「可隐藏」分区", "Move into Hidden section now"))
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text(tr("顶栏常驻应用活跃度与锁定豁免", "Visible App Freshness & Pinning"))
        }
    }

    private static func relativeTimeString(since timestamp: TimeInterval) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - timestamp))
        if elapsed < 10 {
            return tr("刚刚", "Just now")
        } else if elapsed < 60 {
            return tr("\(elapsed) 秒前", "\(elapsed)s ago")
        } else if elapsed < 3600 {
            return tr("\(elapsed / 60) 分钟前", "\(elapsed / 60)m ago")
        } else {
            return tr("\(elapsed / 3600) 小时前", "\(elapsed / 3600)h ago")
        }
    }
}

private struct SmartPreferenceLabel: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    var subtitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, subtitle == nil ? 0 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SmartSubPreferenceLabel: View {
    let tone: SemanticTone
    let title: String
    var subtitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 11) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent.opacity(0.62))
                .frame(width: 28, alignment: .trailing)
                .padding(.top, subtitle == nil ? 0 : 3.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

private struct SmartPillBadge: View {
    let text: String
    let tone: SemanticTone
    var maxWidth: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let label = Text(text)
            .font(.system(size: 10, weight: tone == .neutral ? .medium : .semibold))
            .foregroundStyle(
                tone == .neutral
                    ? .primary.opacity(0.76)
                    : BarLensPalette.ink(tone, in: colorScheme)
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(
                tone == .neutral
                    ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.065))
                    : BarLensPalette.badgeFill(tone, in: colorScheme),
                in: Capsule()
            )
        if let maxWidth {
            label.frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            label.fixedSize(horizontal: true, vertical: false)
        }
    }
}
