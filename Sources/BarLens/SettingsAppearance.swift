import AppKit
import SwiftUI

/// Use the system material so refraction, contrast and inactive-window behavior
/// follow macOS. Older systems keep a vibrancy fallback.
struct SettingsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = context.environment.colorScheme == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = context.environment.colorScheme == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }
}

/// Masked behind-window visual effect view that stays active even in a
/// non-activating floating `NSPanel` and strictly clips its WindowServer
/// backdrop (`maskImage`) to the continuous rounded rectangle so no
/// rectangular corner mask ever bleeds outside the curve.
final class MaskedVisualEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 20 {
        didSet {
            if abs(oldValue - cornerRadius) > 0.1 {
                needsLayout = true
            }
        }
    }

    override var allowsVibrancy: Bool { false }

    override func layout() {
        super.layout()
        wantsLayer = true
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        updateMask(radius: radius)
    }

    private func updateMask(radius: CGFloat) {
        let size = bounds.size
        guard size.width > 2, size.height > 2 else { return }
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.fill()
            return true
        }
        self.maskImage = image
    }
}

struct LiquidGlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> MaskedVisualEffectView {
        let view = MaskedVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.cornerRadius = cornerRadius
        applyAppearance(to: view, isDark: context.environment.colorScheme == .dark)
        return view
    }

    func updateNSView(_ view: MaskedVisualEffectView, context: Context) {
        view.blendingMode = .behindWindow
        view.state = .active
        view.cornerRadius = cornerRadius
        applyAppearance(to: view, isDark: context.environment.colorScheme == .dark)
    }

    private func applyAppearance(to view: MaskedVisualEffectView, isDark: Bool) {
        view.material = isDark ? .hudWindow : .popover
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

struct LiquidGlassRim: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("rimIntensity") private var rimIntensity: Double = 1.15
    var cornerRadius: CGFloat
    var tint: Color = .white
    var intensity: Double = 1.0

    var body: some View {
        let k = intensity * rimIntensity
        let topLead = min(1.0, (colorScheme == .dark ? 0.84 : 1.0) * k)
        let midLead = min(1.0, (colorScheme == .dark ? 0.24 : 0.42) * k)
        let midTrail = min(1.0, (colorScheme == .dark ? 0.03 : 0.08) * k)
        let bottomTrail = min(1.0, (colorScheme == .dark ? 0.58 : 0.82) * k)
        let innerRadius = max(1, cornerRadius - 0.7)
        let cushionRadius = max(1, cornerRadius - 1.8)

        ZStack {
            // 1. Crisp outer contour hairline so the capsule boundary is sharp
            // even against a pure white (#FFFFFF) window.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark
                        ? Color.black.opacity(0.52)
                        : Color(red: 0.10, green: 0.15, blue: 0.26).opacity(0.16),
                    lineWidth: 0.75
                )

            // 2. Inner optical cushion shading just inside the specular rim:
            // gives the white 135° Fresnel rim high contrast even in Light mode!
            RoundedRectangle(cornerRadius: cushionRadius, style: .continuous)
                .inset(by: 1.6)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(
                                color: colorScheme == .dark
                                    ? Color.black.opacity(0.32)
                                    : Color(red: 0.16, green: 0.24, blue: 0.42).opacity(0.11 * min(1.3, k)),
                                location: 0.0
                            ),
                            .init(
                                color: colorScheme == .dark
                                    ? Color.black.opacity(0.18)
                                    : Color(red: 0.16, green: 0.24, blue: 0.42).opacity(0.05 * min(1.3, k)),
                                location: 0.5
                            ),
                            .init(
                                color: colorScheme == .dark
                                    ? Color.black.opacity(0.42)
                                    : Color(red: 0.12, green: 0.18, blue: 0.34).opacity(0.14 * min(1.3, k)),
                                location: 1.0
                            ),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.2
                )

            // 3. 135° Diagonal Fresnel refractive rim (bright top-left, invisible middle, bottom-right return)
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .inset(by: 0.7)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: tint.opacity(topLead), location: 0.0),
                            .init(color: tint.opacity(midLead), location: 0.32),
                            .init(color: tint.opacity(midTrail), location: 0.62),
                            .init(color: tint.opacity(bottomTrail), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.45
                )

            // 4. Top-edge optical caustic highlight
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .inset(by: 0.7)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(min(1.0, (colorScheme == .dark ? 0.68 : 0.96) * k)), location: 0.0),
                            .init(color: .clear, location: 0.26),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.65
                )
        }
        .allowsHitTesting(false)
    }
}

struct LiquidGlassCircleRim: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("rimIntensity") private var rimIntensity: Double = 1.15
    var tint: Color = .white
    var intensity: Double = 1.0

    var body: some View {
        let k = intensity * rimIntensity
        let topLead = min(1.0, (colorScheme == .dark ? 0.80 : 0.96) * k)
        let midLead = min(1.0, (colorScheme == .dark ? 0.22 : 0.36) * k)
        let midTrail = min(1.0, (colorScheme == .dark ? 0.03 : 0.06) * k)
        let bottomTrail = min(1.0, (colorScheme == .dark ? 0.54 : 0.72) * k)
        ZStack {
            Circle()
                .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.42 : 0.12), lineWidth: 0.65)
            Circle()
                .inset(by: 0.65)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: tint.opacity(topLead), location: 0.0),
                            .init(color: tint.opacity(midLead), location: 0.34),
                            .init(color: tint.opacity(midTrail), location: 0.64),
                            .init(color: tint.opacity(bottomTrail), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.25
                )
        }
        .allowsHitTesting(false)
    }
}

private struct OpticalLensSheen: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("rimIntensity") private var rimIntensity: Double = 1.15
    var cornerRadius: CGFloat

    var body: some View {
        let k = rimIntensity
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    stops: colorScheme == .dark
                        ? [
                            .init(color: Color(red: 0.72, green: 0.86, blue: 1.0).opacity(min(0.42, 0.20 * k)), location: 0.0),
                            .init(color: Color.white.opacity(min(0.14, 0.04 * k)), location: 0.36),
                            .init(color: Color.clear, location: 0.62),
                            .init(color: Color.black.opacity(0.28), location: 1.0),
                        ]
                        : [
                            .init(color: Color(red: 0.82, green: 0.89, blue: 0.98).opacity(min(0.52, 0.28 * k)), location: 0.0),
                            .init(color: Color.white.opacity(0.18), location: 0.44),
                            .init(color: Color(red: 0.76, green: 0.83, blue: 0.94).opacity(min(0.55, 0.32 * k)), location: 1.0),
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
    }
}

private struct SettingsGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.36
    var cornerRadius: CGFloat

    private var tintColor: Color {
        if colorScheme == .dark {
            // Deep smoked optical slate responsive to `glassOpacity` (玻璃浓度)
            // with a contrast floor so white glyphs stay crisp even over bright windows.
            return Color(red: 0.08, green: 0.09, blue: 0.13)
                .opacity(min(0.94, max(0.54, glassOpacity * 1.30)))
        } else {
            // Cool ice-crystal tint so dark glyphs and the 135° Fresnel specular rim
            // stand out cleanly over both dark and pure white (#FFFFFF) windows.
            return Color(red: 0.89, green: 0.92, blue: 0.98)
                .opacity(min(0.94, max(0.52, glassOpacity * 1.25)))
        }
    }

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else {
            content
                .background {
                    ZStack {
                        LiquidGlassBackdrop(cornerRadius: cornerRadius)
                        shape.fill(tintColor)
                        OpticalLensSheen(cornerRadius: cornerRadius)
                    }
                    .clipShape(shape)
                }
                .overlay {
                    LiquidGlassRim(cornerRadius: cornerRadius)
                }
        }
    }
}

/// Elevated glass surface for reading-heavy window panes (Settings & Onboarding).
/// Unlike `SettingsGlass` (which uses a behind-window `NSVisualEffectView` for the
/// standalone Floating Bar), this layers *above* the window's grounded scrim instead
/// of punching through to bright desktop windows behind `NSWindow`.
private struct WindowPaneGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(
                            colorScheme == .dark
                                ? Color(red: 0.10, green: 0.11, blue: 0.15).opacity(0.90)
                                : Color.white.opacity(0.88)
                        )
                        OpticalLensSheen(cornerRadius: cornerRadius)
                    }
                    .clipShape(shape)
                }
                .overlay {
                    LiquidGlassRim(cornerRadius: cornerRadius, intensity: 0.72)
                }
        }
    }
}

/// In-window refractive capsule preview used on the Appearance live preview stage
/// so the sample capsule blurs the simulated desktop backdrop directly behind it.
private struct PreviewCapsuleGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.36
    var cornerRadius: CGFloat

    private var tintColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.08, green: 0.09, blue: 0.13)
                .opacity(min(0.94, max(0.54, glassOpacity * 1.30)))
        } else {
            return Color(red: 0.89, green: 0.92, blue: 0.98)
                .opacity(min(0.94, max(0.52, glassOpacity * 1.25)))
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tintColor)
                    OpticalLensSheen(cornerRadius: cornerRadius)
                }
                .clipShape(shape)
            }
            .overlay {
                LiquidGlassRim(cornerRadius: cornerRadius)
            }
    }
}

private struct OpticalPlatter: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat
    var isSelected: Bool
    var tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if isSelected {
                    ZStack {
                        shape.fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.13)
                                : Color.white.opacity(0.88)
                        )
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(colorScheme == .dark ? 0.22 : 0.13),
                                    tint.opacity(colorScheme == .dark ? 0.08 : 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                } else {
                    shape.fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.white.opacity(0.84)
                    )
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                (colorScheme == .dark ? Color.white.opacity(0.48) : tint.opacity(0.55)),
                                tint.opacity(colorScheme == .dark ? 0.42 : 0.30),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.15
                    )
                } else {
                    ZStack {
                        if colorScheme == .light {
                            shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.75)
                        }
                        shape.strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(colorScheme == .dark ? 0.16 : 0.85), location: 0.0),
                                    .init(color: Color.white.opacity(colorScheme == .dark ? 0.04 : 0.24), location: 0.5),
                                    .init(color: Color.white.opacity(colorScheme == .dark ? 0.09 : 0.48), location: 1.0),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                    }
                }
            }
    }
}

enum SemanticTone {
    case blue
    case purple
    case teal
    case green
    case orange
    case indigo
    case cyan
    case mint
    case pink
    case neutral
}

enum BarLensPalette {
    /// High-contrast adaptive foreground color guaranteed legible in both Dark and Light glass surfaces.
    static func ink(_ tone: SemanticTone, in scheme: ColorScheme) -> Color {
        switch (tone, scheme) {
        case (.blue, .dark):    return Color(red: 0.54, green: 0.80, blue: 1.00)
        case (.blue, _):        return Color(red: 0.02, green: 0.36, blue: 0.82)
        case (.purple, .dark):  return Color(red: 0.86, green: 0.68, blue: 1.00)
        case (.purple, _):      return Color(red: 0.46, green: 0.14, blue: 0.74)
        case (.teal, .dark):    return Color(red: 0.42, green: 0.91, blue: 0.88)
        case (.teal, _):        return Color(red: 0.00, green: 0.44, blue: 0.48)
        case (.green, .dark):   return Color(red: 0.44, green: 0.93, blue: 0.60)
        case (.green, _):       return Color(red: 0.05, green: 0.48, blue: 0.21)
        case (.orange, .dark):  return Color(red: 1.00, green: 0.79, blue: 0.38)
        case (.orange, _):      return Color(red: 0.72, green: 0.33, blue: 0.00)
        case (.indigo, .dark):  return Color(red: 0.70, green: 0.72, blue: 1.00)
        case (.indigo, _):      return Color(red: 0.25, green: 0.22, blue: 0.75)
        case (.cyan, .dark):    return Color(red: 0.46, green: 0.88, blue: 1.00)
        case (.cyan, _):        return Color(red: 0.00, green: 0.43, blue: 0.62)
        case (.mint, .dark):    return Color(red: 0.46, green: 0.94, blue: 0.78)
        case (.mint, _):        return Color(red: 0.02, green: 0.47, blue: 0.38)
        case (.pink, .dark):    return Color(red: 1.00, green: 0.64, blue: 0.80)
        case (.pink, _):        return Color(red: 0.72, green: 0.12, blue: 0.40)
        case (.neutral, .dark): return Color.white.opacity(0.88)
        case (.neutral, _):     return Color.black.opacity(0.78)
        }
    }

    static func badgeFill(_ tone: SemanticTone, in scheme: ColorScheme) -> Color {
        ink(tone, in: scheme).opacity(scheme == .dark ? 0.16 : 0.12)
    }

    /// High-contrast solid fill for selected pills/segments where the label is pure `.white`
    /// (>= 5.4:1 contrast even if the user chose a bright yellow/green macOS Accent Color).
    static func selectionFill(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.06, green: 0.41, blue: 0.88)
            : Color(red: 0.04, green: 0.38, blue: 0.84)
    }

    /// Grounded window scrim behind reading-heavy windows (Settings & Onboarding)
    /// so bright desktop windows never wash Dark Mode out into low-contrast mid-gray.
    static func windowScrim(in scheme: ColorScheme, glassOpacity: Double) -> Color {
        if scheme == .dark {
            return Color(red: 0.07, green: 0.08, blue: 0.11)
                .opacity(min(0.95, max(0.84, glassOpacity * 0.45 + 0.68)))
        } else {
            return Color(red: 0.94, green: 0.96, blue: 0.99)
                .opacity(min(0.96, max(0.86, glassOpacity * 0.40 + 0.72)))
        }
    }
}

extension View {
    func settingsGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(SettingsGlass(cornerRadius: cornerRadius))
    }

    func windowPaneGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(WindowPaneGlass(cornerRadius: cornerRadius))
    }

    func previewCapsuleGlass(cornerRadius: CGFloat = 25) -> some View {
        modifier(PreviewCapsuleGlass(cornerRadius: cornerRadius))
    }

    func opticalPlatter(cornerRadius: CGFloat = 12, isSelected: Bool = false, tint: Color = .accentColor) -> some View {
        modifier(OpticalPlatter(cornerRadius: cornerRadius, isSelected: isSelected, tint: tint))
    }
}

extension SectionModel.Section {
    var tone: SemanticTone {
        switch self {
        case .visible:      return .teal
        case .hidden:       return .blue
        case .alwaysHidden: return .purple
        }
    }

    var tint: Color {
        switch self {
        case .visible:      return .teal
        case .hidden:       return .blue
        case .alwaysHidden: return .purple
        }
    }

    func readableTint(in scheme: ColorScheme) -> Color {
        BarLensPalette.ink(tone, in: scheme)
    }
}
