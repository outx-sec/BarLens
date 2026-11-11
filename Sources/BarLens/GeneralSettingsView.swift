import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {

    @ObservedObject var engine: DividerEngine
    @ObservedObject var catalog: Catalog
    @State private var profileNotice: String?

    var body: some View {
        Form {
            Section(tr("启动与交互", "Startup & Behavior")) {
                Toggle(isOn: Binding(
                    get: { engine.launchAtLogin },
                    set: { engine.setLaunchAtLogin($0) })) {
                    PreferenceLabel(symbol: "power", tint: .green, title: tr("登录时启动", "Launch at Login"))
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { engine.alwaysHiddenEnabled },
                    set: { engine.setAlwaysHiddenEnabled($0) })) {
                    PreferenceLabel(symbol: "eye.slash.fill", tint: .indigo, title: tr("启用「永久隐藏」", "Enable “Always Hidden” Section"))
                }
                .toggleStyle(.switch)

                Picker(selection: Binding(
                    get: { engine.hoverRevealDelay },
                    set: { engine.setHoverRevealDelay($0) })) {
                    ForEach(HoverRevealDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                } label: {
                    PreferenceLabel(symbol: "cursorarrow.motionlines", tint: .purple, title: tr("悬停触发图标展开", "Hover Trigger to Reveal"))
                }
                .pickerStyle(.menu)

                Picker(selection: Binding(
                    get: { engine.autoRehideInterval },
                    set: { engine.setAutoRehideInterval($0) })) {
                    ForEach(AutoRehideInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                } label: {
                    PreferenceLabel(symbol: "timer", tint: .orange, title: tr("展开后自动收起", "Auto-Collapse After"))
                }
                .pickerStyle(.menu)

                Picker(selection: Binding(
                    get: { engine.appLanguage },
                    set: { engine.setAppLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                } label: {
                    PreferenceLabel(symbol: "globe", tint: .cyan, title: tr("界面语言", "Interface Language"))
                }
                .pickerStyle(.menu)
            }

            Section(tr("默认归属", "Default Section")) {
                DefaultSectionRow(
                    title: tr("新应用", "New Applications"),
                    symbol: "app.badge",
                    tint: .blue,
                    section: Binding(get: { engine.unclassifiedSection },
                                     set: { engine.setUnclassifiedSection($0) }),
                    alwaysHiddenEnabled: engine.alwaysHiddenEnabled)

                DefaultSectionRow(
                    title: tr("新识别的系统图标", "New System Items"),
                    symbol: "menubar.rectangle",
                    tint: .teal,
                    section: Binding(get: { engine.newSystemItemSection },
                                     set: { engine.setNewSystemItemSection($0) }),
                    alwaysHiddenEnabled: engine.alwaysHiddenEnabled)
            }

            Section(tr("快捷键", "Keyboard Shortcuts")) {
                ForEach(HotkeyAction.allCases.filter {
                    $0 != .toggleAlwaysHidden || engine.alwaysHiddenEnabled
                }) { action in
                    LabeledContent {
                        HotkeyRecorder(hotkey: engine.bindings[action]) { hotkey in
                            engine.setHotkey(hotkey, for: action)
                        }
                    } label: {
                        PreferenceLabel(symbol: "keyboard", tint: .purple, title: action.title)
                    }
                }
            }

            Section(tr("圆点手势", "Trigger Gestures")) {
                GestureRow(symbol: "cursorarrow.click", title: tr("单击图标", "Single Click"),
                           detail: tr("展开 / 收起可隐藏", "Toggle Hidden Section"))
                if engine.alwaysHiddenEnabled {
                    GestureRow(symbol: "cursorarrow.click.2", title: tr("双击图标", "Double Click"),
                               detail: tr("展开 / 收起全部", "Toggle All Sections"))
                }
                GestureRow(symbol: "arrow.up.and.down.circle", title: tr("滚轮 / 触控板滑动", "Scroll / Trackpad Swipe"),
                           detail: tr("下滑 / 左滑展开 · 上滑 / 右滑收起", "Swipe Down/Left to Reveal · Up/Right to Collapse"))
                GestureRow(symbol: "computermouse", title: tr("右键图标", "Right Click"),
                           detail: tr("打开速览面板", "Open Quick Panel"))
                GestureRow(symbol: "arrow.left.and.right", title: tr("⌘ + 拖拽", "⌘ + Drag"),
                           detail: tr("调整图标位置", "Move Menu Bar Trigger"))
            }

            Section(tr("配置备份与迁移", "Configuration Backup")) {
                LabeledContent {
                    HStack(spacing: 8) {
                        if !engine.floatingBarOrder.isEmpty {
                            Button(tr("重置图标排序", "Reset Icon Order")) {
                                engine.resetFloatingBarOrder()
                                profileNotice = tr("已恢复默认悬浮栏图标顺序", "Floating bar icon order reset")
                            }
                            .controlSize(.small)
                        }
                        Button(tr("导入配置…", "Import…")) {
                            importProfileFromDisk()
                        }
                        .controlSize(.small)

                        Button(tr("导出配置…", "Export…")) {
                            exportProfileToDisk()
                        }
                        .controlSize(.small)
                    }
                } label: {
                    PreferenceLabel(symbol: "externaldrive.badge.checkmark", tint: .mint, title: tr("分区与外观配置文件", "Sections & Appearance Profile"))
                }

                if let profileNotice {
                    Text(profileNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            catalog.rebuild(model: engine.model, query: "",
                            extraOwners: engine.ledgerOnlyOwners,
                            snapshot: engine.latestScanItems)
        }
        .onChange(of: engine.catalogRevision) { _, _ in
            catalog.rebuild(model: engine.model, query: "",
                            extraOwners: engine.ledgerOnlyOwners,
                            snapshot: engine.latestScanItems)
        }
    }

    private func exportProfileToDisk() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BarLens-Profile.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try engine.exportProfile().encodedJSON()
            try data.write(to: url, options: .atomic)
            profileNotice = tr("已导出配置至 \(url.lastPathComponent)", "Exported profile to \(url.lastPathComponent)")
        } catch {
            profileNotice = tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
        }
    }

    private func importProfileFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let profile = try BarLensProfile.decode(from: data)
            engine.applyProfile(profile)
            profileNotice = tr("已导入配置 \(url.lastPathComponent)", "Imported profile \(url.lastPathComponent)")
        } catch {
            profileNotice = tr("导入失败：配置文件格式无效", "Import failed: invalid profile format")
        }
    }
}

private struct DefaultSectionRow: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var section: SectionModel.Section
    let alwaysHiddenEnabled: Bool

    var body: some View {
        Picker(selection: Binding(
            get: { !alwaysHiddenEnabled && section == .alwaysHidden ? .hidden : section },
            set: { section = $0 }
        )) {
            ForEach(options, id: \.self) { option in
                Text(option.title).tag(option)
            }
        } label: {
            PreferenceLabel(symbol: symbol, tint: tint, title: title)
        }
        .pickerStyle(.menu)
    }

    private var options: [SectionModel.Section] {
        alwaysHiddenEnabled ? [.visible, .hidden, .alwaysHidden] : [.visible, .hidden]
    }
}

private struct PreferenceLabel: View {
    let symbol: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .regular))
        }
        .padding(.vertical, 2)
    }
}

private struct GestureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 16)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
