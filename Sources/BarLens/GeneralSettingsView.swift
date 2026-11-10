import SwiftUI

struct GeneralSettingsView: View {

    @ObservedObject var engine: DividerEngine
    @ObservedObject var catalog: Catalog

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
                GestureRow(symbol: "computermouse", title: tr("右键图标", "Right Click"),
                           detail: tr("打开速览面板", "Open Quick Panel"))
                GestureRow(symbol: "arrow.left.and.right", title: tr("⌘ + 拖拽", "⌘ + Drag"),
                           detail: tr("调整图标位置", "Move Menu Bar Trigger"))
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
