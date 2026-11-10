import SwiftUI

private enum PreviewBackdropStyle: String, CaseIterable, Identifiable {
    case nebula = "nebula"
    case aurora = "aurora"
    case white  = "white"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nebula: return tr("星云流光", "Nebula")
        case .aurora: return tr("拂晓柔光", "Aurora")
        case .white:  return tr("纯白桌面", "Daylight")
        }
    }
}

private struct AppearancePreset: Identifiable {
    let id: String
    let titleZh: String
    let titleEn: String
    let subtitleZh: String
    let subtitleEn: String
    let symbol: String
    let tint: Color
    let mode: AppearanceMode?
    let opacity: Double
    let rim: Double

    var title: String { tr(titleZh, titleEn) }
    var subtitle: String { tr(subtitleZh, subtitleEn) }

    static let all: [AppearancePreset] = [
        AppearancePreset(
            id: "optimal",
            titleZh: "最佳冰晶透镜",
            titleEn: "Crystal Lens",
            subtitleZh: "推荐 · 兼顾深浅背景对比度与 135° 折射立体感",
            subtitleEn: "Recommended · Balanced contrast & 135° Fresnel refraction",
            symbol: "sparkles",
            tint: .cyan,
            mode: nil,
            opacity: 0.36,
            rim: 1.15
        ),
        AppearancePreset(
            id: "obsidian",
            titleZh: "深邃黑曜石",
            titleEn: "Obsidian Glass",
            subtitleZh: "深色烟熏高对比玻璃，契合深色顶部菜单栏",
            subtitleEn: "Smoked dark-tinted glass tailored for dark menu bars",
            symbol: "moon.stars.fill",
            tint: .indigo,
            mode: .dark,
            opacity: 0.46,
            rim: 1.22
        ),
        AppearancePreset(
            id: "prism",
            titleZh: "高透棱镜流光",
            titleEn: "Prism Sheen",
            subtitleZh: "低底色浓度 + 强折射亮边，通透轻盈",
            subtitleEn: "Airy low-density tint with vivid specular rim highlights",
            symbol: "drop.degreesign.fill",
            tint: .mint,
            mode: nil,
            opacity: 0.22,
            rim: 1.32
        ),
    ]
}

struct AppearanceSettingsView: View {
    @ObservedObject var engine: DividerEngine
    @State private var backdrop: PreviewBackdropStyle = .nebula
    @State private var sampleActiveIndex: Int = 2
    @Environment(\.colorScheme) private var colorScheme

    private func isPresetSelected(_ preset: AppearancePreset) -> Bool {
        let opacityMatch = abs(engine.glassOpacity - preset.opacity) < 0.02
        let rimMatch = abs(engine.rimIntensity - preset.rim) < 0.04
        let modeMatch = preset.mode == nil || engine.appearanceMode == preset.mode
        return opacityMatch && rimMatch && modeMatch
    }

    var body: some View {
        Form {
            Section {
                livePreviewStage
            } header: {
                HStack {
                    Text(tr("实时效果预览", "Live Preview"))
                    Spacer()
                    Picker(tr("预览背景", "Preview Backdrop"), selection: $backdrop) {
                        ForEach(PreviewBackdropStyle.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 210)
                }
            }

            Section(tr("一键最佳预设", "Optical Presets")) {
                HStack(spacing: 10) {
                    ForEach(AppearancePreset.all) { preset in
                        let selected = isPresetSelected(preset)
                        Button {
                            if let mode = preset.mode {
                                engine.setAppearanceMode(mode)
                            }
                            engine.setGlassOpacity(preset.opacity)
                            engine.setRimIntensity(preset.rim)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: preset.symbol)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(preset.tint)
                                    Text(preset.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Spacer(minLength: 0)
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(preset.tint)
                                    }
                                }
                                Text(preset.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opticalPlatter(cornerRadius: 12, isSelected: selected, tint: preset.tint)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            Section(tr("主题与呈现", "Theme & Presentation")) {
                Picker(
                    selection: Binding(
                        get: { engine.appearanceMode },
                        set: { engine.setAppearanceMode($0) }
                    )
                ) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    AppearanceRowLabel(symbol: "circle.lefthalf.filled", tint: .indigo, title: tr("外观模式", "Appearance Mode"))
                }
                .pickerStyle(.segmented)

                Picker(
                    selection: Binding(
                        get: { engine.statusBarIconStyle },
                        set: { engine.setStatusBarIconStyle($0) }
                    )
                ) {
                    ForEach(StatusBarIconStyle.allCases) { style in
                        Label(style.title, systemImage: style.previewSymbol).tag(style)
                    }
                } label: {
                    AppearanceRowLabel(symbol: "record.circle", tint: .blue, title: tr("顶部触发图标", "Menu Bar Trigger Icon"))
                }
                .pickerStyle(.menu)

                Picker(
                    selection: Binding(
                        get: { engine.revealPresentationStyle },
                        set: { style in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                engine.setRevealPresentationStyle(style)
                            }
                        }
                    )
                ) {
                    ForEach(RevealPresentationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                } label: {
                    AppearanceRowLabel(symbol: "Dock.rectangle", fallbackSymbol: "menubar.dock.rectangle", tint: .cyan, title: tr("展开呈现方式", "Reveal Style"))
                }
                .pickerStyle(.segmented)

                if engine.revealPresentationStyle == .floatingBar {
                    Picker(
                        selection: Binding(
                            get: { engine.floatingBarIconStyle },
                            set: { style in
                                withAnimation(.easeOut(duration: 0.16)) {
                                    engine.setFloatingBarIconStyle(style)
                                }
                            }
                        )
                    ) {
                        ForEach(FloatingBarIconDisplayStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        AppearanceRowLabel(
                            symbol: "circle.grid.cross",
                            tint: .purple,
                            title: tr("悬浮栏图标渲染", "Floating Bar Icons"),
                            subtitle: tr("仅在「悬浮菜单栏」下生效 · 单色模板或应用彩色实物图标", "Floating Bar only · Monochrome glyph or full-color app icon"),
                            isSubItem: true
                        )
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section(tr("Liquid Glass 光学精调", "Liquid Glass Fine-Tuning")) {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { engine.glassOpacity },
                                set: { engine.setGlassOpacity($0) }
                            ),
                            in: 0.08...0.75
                        )
                        .frame(width: 160)
                        Text("\(Int(round(engine.glassOpacity * 100)))%")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    AppearanceRowLabel(
                        symbol: "drop.halffull",
                        tint: .mint,
                        title: tr("玻璃浓度", "Glass Density"),
                        subtitle: tr("调节透镜底色烟熏 / 冰晶浓度", "Adjust smoked / crystal tint density")
                    )
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { engine.rimIntensity },
                                set: { engine.setRimIntensity($0) }
                            ),
                            in: 0.40...1.50
                        )
                        .frame(width: 160)
                        Text("\(Int(round(engine.rimIntensity * 100)))%")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    AppearanceRowLabel(
                        symbol: "sparkles",
                        tint: .cyan,
                        title: tr("折射边强度", "Refractive Rim Intensity"),
                        subtitle: tr("调节 135° 菲涅尔高光边缘与顶部焦散亮度", "Adjust 135° Fresnel specular rim & top caustic sheen")
                    )
                }

                HStack {
                    Text(tr("提示：悬浮栏开启时，拖动滑块可同步实时预览桌面顶部悬浮栏效果。", "Tip: Drag sliders while the floating bar is open to preview live on your desktop."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("恢复最佳默认", "Reset to Optimal")) {
                        engine.applyOptimalAppearancePreset()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Live Preview Stage

    private var livePreviewStage: some View {
        let showAppIconStyle = engine.revealPresentationStyle == .floatingBar && engine.floatingBarIconStyle == .appIcon
        return ZStack {
            previewBackground
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    let sampleItems: [(symbol: String, appColors: [Color])] = [
                        ("sparkles", [Color(red: 0.20, green: 0.52, blue: 0.98), Color(red: 0.42, green: 0.25, blue: 0.92)]),
                        ("bolt.horizontal.fill", [Color(red: 0.96, green: 0.36, blue: 0.58), Color(red: 0.58, green: 0.26, blue: 0.94)]),
                        ("terminal.fill", [Color(red: 0.14, green: 0.72, blue: 0.58), Color(red: 0.08, green: 0.46, blue: 0.68)]),
                        ("wifi", []),
                    ]
                    ForEach(Array(sampleItems.enumerated()), id: \.offset) { index, item in
                        let isActive = sampleActiveIndex == index
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                sampleActiveIndex = (sampleActiveIndex == index) ? -1 : index
                            }
                        } label: {
                            Group {
                                if showAppIconStyle, !item.appColors.isEmpty {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: item.appColors,
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
                                            }
                                        Image(systemName: item.symbol)
                                            .font(.system(size: 11.5, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 21, height: 21)
                                    .shadow(color: .black.opacity(0.20), radius: 2, y: 1)
                                } else {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundStyle(isActive ? Color.accentColor : .primary)
                                }
                            }
                            .frame(width: 36, height: 36)
                            .background {
                                if isActive {
                                    Circle()
                                        .inset(by: 0.5)
                                        .fill(Color.white.opacity(colorScheme == .dark ? 0.92 : 0.96))
                                        .shadow(color: Color.accentColor.opacity(0.28), radius: 5, y: 1.5)
                                }
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    if engine.alwaysHiddenEnabled {
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

                        HStack(spacing: 5) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("4")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(
                            colorScheme == .dark
                                ? Color(red: 0.94, green: 0.82, blue: 1.0)
                                : Color(red: 0.48, green: 0.12, blue: 0.64)
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.purple.opacity(colorScheme == .dark ? 0.32 : 0.20),
                                    Color.purple.opacity(colorScheme == .dark ? 0.16 : 0.10),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .overlay {
                            LiquidGlassRim(cornerRadius: 17, tint: .purple, intensity: 0.95)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .settingsGlass(cornerRadius: 25)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.14), radius: 8, y: 4)

                Text(tr("点按上方预览图标可测试激活高光态", "Click any preview icon above to test the active highlight state"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(backdrop == .white ? Color.black.opacity(0.5) : Color.white.opacity(0.78))
            }
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var previewBackground: some View {
        switch backdrop {
        case .nebula:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.05, blue: 0.16),
                        Color(red: 0.12, green: 0.09, blue: 0.26),
                        Color(red: 0.05, green: 0.13, blue: 0.22),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(red: 1.0, green: 0.23, blue: 0.55).opacity(0.55))
                    .frame(width: 110, height: 110)
                    .blur(radius: 24)
                    .offset(x: -95, y: -15)
                Circle()
                    .fill(Color(red: 0.22, green: 0.56, blue: 1.0).opacity(0.58))
                    .frame(width: 130, height: 130)
                    .blur(radius: 26)
                    .offset(x: 85, y: 10)
            }
        case .aurora:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.84, green: 0.90, blue: 1.0),
                        Color(red: 0.95, green: 0.88, blue: 1.0),
                        Color(red: 0.84, green: 0.96, blue: 0.90),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(red: 1.0, green: 0.58, blue: 0.72).opacity(0.55))
                    .frame(width: 110, height: 110)
                    .blur(radius: 22)
                    .offset(x: -85, y: -10)
                Circle()
                    .fill(Color(red: 0.38, green: 0.78, blue: 0.98).opacity(0.55))
                    .frame(width: 120, height: 120)
                    .blur(radius: 24)
                    .offset(x: 90, y: 12)
            }
        case .white:
            Color.white
        }
    }
}

private struct AppearanceRowLabel: View {
    let symbol: String
    var fallbackSymbol: String = "sparkles"
    let tint: Color
    let title: String
    var subtitle: String? = nil
    var isSubItem: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if isSubItem {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : fallbackSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
