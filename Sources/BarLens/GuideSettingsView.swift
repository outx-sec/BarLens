import AppKit
import SwiftUI

/// Structured bilingual user guide inside Settings → Guide (`使用指南`).
struct GuideSettingsView: View {
    @ObservedObject var engine: DividerEngine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            heroSection
            quickStartSection
            triggerGesturesSection
            floatingBarSection
            faqSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Hero

    private var heroSection: some View {
        let heroAccent = BarLensPalette.ink(.blue, in: colorScheme)
        return Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BarLensPalette.badgeFill(.blue, in: colorScheme))
                        .frame(width: 48, height: 48)
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(heroAccent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("BarLens 交互与功能指南", "BarLens User Guide"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(tr("原生菜单栏白名单隐藏 · 液态光学玻璃第二栏 · 全部 18 项系统控件管理", "Native allow-list hiding · Liquid Glass floating bar · Full control over all 18 system items"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        engine.setReveal(engine.reveal == .none ? .hidden : .none)
                    } label: {
                        Label(
                            engine.reveal == .none ? tr("试一下展开", "Preview Reveal") : tr("收起展开", "Collapse"),
                            systemImage: engine.reveal == .none ? "eye" : "eye.slash"
                        )
                    }
                    .controlSize(.small)

                    Button {
                        engine.onReplayOnboarding?()
                    } label: {
                        Label(tr("重新打开新手引导", "Replay Welcome Tour"), systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 3-Step Quick Start

    private var quickStartSection: some View {
        Section(tr("三步快速上手", "3-Step Quick Start")) {
            GuideStepRow(
                step: "1",
                tone: engine.isInstalledCorrectly && engine.hasAccessibility ? .green : .orange,
                title: tr("确认安装位置与辅助功能权限", "Verify /Applications & Accessibility"),
                detail: tr(
                    "BarLens 需位于「应用程序 (/Applications)」文件夹并授予辅助功能权限，以便枚举菜单栏布局并代理点击。",
                    "Keep BarLens in /Applications and grant Accessibility permission so it can read menu bar items and proxy clicks."
                ),
                badge: (engine.isInstalledCorrectly && engine.hasAccessibility)
                    ? tr("已完成", "Ready")
                    : tr("待处理", "Action Needed")
            )

            GuideStepRow(
                step: "2",
                tone: .blue,
                title: tr("将应用与系统图标归入三段式分区", "Assign Apps & System Items to Sections"),
                detail: tr(
                    "前往「分区管理」，将常驻图标设为「始终显示」，低频图标设为「可隐藏」，极少查看的后台工具设为「永久隐藏」。",
                    "In Sections, keep daily essentials in Visible, occasional tools in Hidden, and rare background utilities in Always Hidden."
                ),
                actionTitle: tr("前往分区管理", "Open Sections"),
                action: { engine.requestedSettingsPane = .sections }
            )

            GuideStepRow(
                step: "3",
                tone: .purple,
                title: tr("选择展开方式与图标样式", "Choose Reveal & Icon Style"),
                detail: tr(
                    "在「外观」中可切换「悬浮栏」（支持黑白或实物图标）与「菜单栏内」展开。",
                    "In Appearance, switch between the Floating Bar (Monochrome or App Icon) and Inline expansion."
                ),
                actionTitle: tr("前往外观", "Open Appearance"),
                action: { engine.requestedSettingsPane = .appearance }
            )
        }
    }

    // MARK: - Menu Bar Trigger Gestures

    private var triggerGesturesSection: some View {
        Section(tr("顶栏触发图标操作大全", "Menu Bar Trigger Gestures")) {
            GuideItemRow(
                symbol: "cursorarrow.click",
                tone: .blue,
                title: tr("左键单击", "Left Click"),
                detail: tr("展开或收起「可隐藏」分区", "Reveal or collapse the Hidden section")
            )
            GuideItemRow(
                symbol: "cursorarrow.click.2",
                tone: .indigo,
                title: tr("左键双击", "Double Click"),
                detail: tr("同时展开或收起「可隐藏 + 永久隐藏」全部图标", "Reveal or collapse both Hidden and Always Hidden items")
            )
            GuideItemRow(
                symbol: "cursorarrow.motionlines",
                tone: .purple,
                title: tr("鼠标悬停展开（可选）", "Hover to Reveal (Optional)"),
                detail: tr("可在「通用」中开启 0.18s / 0.35s / 0.6s 停留自动展开", "Enable configurable 0.18s / 0.35s / 0.6s dwell reveal in General")
            )
            GuideItemRow(
                symbol: "hand.draw",
                tone: .teal,
                title: tr("双指滑动 / 鼠标滚轮", "Two-Finger Swipe / Scroll Wheel"),
                detail: tr("在触发图标上「下滑 / 左滑」逐级展开，「上滑 / 右滑」收起", "Swipe/scroll down or left to step through sections; up or right to collapse")
            )
            GuideItemRow(
                symbol: "computermouse",
                tone: .cyan,
                title: tr("右键单击", "Right Click"),
                detail: tr("打开「速览面板」，查看各分区数量、搜索或批量移动图标", "Open Quick Panel to inspect counts, search, or batch-assign items")
            )
            GuideItemRow(
                symbol: "arrow.left.and.right",
                tone: .orange,
                title: tr("按住 ⌘ 拖拽触发图标", "⌘ + Drag Trigger Icon"),
                detail: tr("像系统原生图标一样调整 BarLens 触发器在菜单栏的位置", "Freely reposition the BarLens trigger anywhere in your macOS menu bar")
            )
        }
    }

    // MARK: - Floating Bar Interactions

    private var floatingBarSection: some View {
        Section(tr("Liquid Glass 悬浮菜单栏技巧", "Floating Bar Tips & Tricks")) {
            GuideItemRow(
                symbol: "menubar.arrow.down.rectangle",
                tone: .blue,
                title: tr("原位唤起原生菜单", "In-Place Native Menus"),
                detail: tr("点按悬浮栏内任意应用或系统图标即可打开其原生菜单，再次点按同一图标即可收起", "Click any app or system icon in the Floating Bar to open its native menu; click again to close")
            )
            GuideItemRow(
                symbol: "hand.point.up.left.and.text",
                tone: .mint,
                title: tr("按住左右拖拽 1:1 排序", "Hold & Drag to Reorder"),
                detail: tr("直接在悬浮栏内按住任意图标左右拖动，即可无延迟调整常用顺序", "Press and drag icons left or right inside the Floating Bar to customize their order")
            )
            GuideItemRow(
                symbol: "contextualmenu.and.cursorarrow",
                tone: .pink,
                title: tr("右键任意图标快捷操作", "Right-Click Icon Quick Actions"),
                detail: tr("支持左移 / 右移 / 置顶 / 置底 / 重置排序、切换所属分区、在访达中显示及退出应用", "Step left/right, move to front/end, change section, Show in Finder, or Quit app")
            )
            GuideItemRow(
                symbol: "eye.slash.fill",
                tone: .purple,
                title: tr("紫色「+N」胶囊与双指上滑收起", "Always-Hidden Pill & Swipe-Up Dismiss"),
                detail: tr("点按悬浮栏右侧紫色胶囊可临时偷看「永久隐藏」项；在悬浮栏上双指上滑即可推回顶栏收起", "Click the purple +N pill to peek at Always Hidden items; swipe up on the bar to dismiss")
            )
            GuideItemRow(
                symbol: "gearshape.fill",
                tone: .neutral,
                title: tr("右侧齿轮右键菜单", "Gear Button Context Menu"),
                detail: tr("右键悬浮栏齿轮可一键切换深浅色、单色/彩色实物图标、中英文语言或重置排序", "Right-click the gear icon to switch theme, icon rendering, language, or reset order")
            )
        }
    }

    // MARK: - FAQ & Safety

    private var faqSection: some View {
        Section(tr("安全机制与常见疑问", "Safety Architecture & FAQ")) {
            GuideFAQRow(
                question: tr("如果 BarLens 退出或异常强退，隐藏的菜单栏图标会丢失吗？", "What happens to hidden icons if BarLens quits or crashes?"),
                answer: tr(
                    "绝不会丢失。BarLens 采用双进程守护架构（BarLens + BarLensAgent），主进程退出或被强制结束后的 150ms 内，守护进程会自动释放系统白名单断言，所有隐藏图标立即完整恢复。",
                    "Never. BarLens uses a dual-process guardian architecture (BarLens + BarLensAgent). Within 150ms of quitting or force-killing, the helper releases the system assertion and every hidden icon reappears immediately."
                )
            )
            GuideFAQRow(
                question: tr("为什么不采用传统的「超宽透明占位符」方案？", "Why doesn't BarLens use invisible spacer items or screen recording?"),
                answer: tr(
                    "传统占位符在 MacBook 刘海屏上极易把图标挤进摄像头盲区，而截图拼接方案又需要常驻「屏幕录制」权限。BarLens 直接调用 macOS 27 原生 MenuBarAgent 账本与控制中心接口，零刘海冲突且无需录屏权限。",
                    "Spacer hacks get trapped behind MacBook camera notches, while pixel-strip bars require continuous Screen Recording permission. BarLens uses native macOS 27 MenuBarAgent allow-lists—100% notch-safe with no Screen Recording needed."
                )
            )
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("备份或迁移你的配置", "Back Up or Migrate Your Setup"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(tr("支持将分区规则、悬浮栏图标顺序、快捷键与光学参数导出为 JSON 文件。", "Export sections, icon order, shortcuts, and Liquid Glass settings to a single JSON file."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.76))
                }
                Spacer(minLength: 12)
                Button(tr("前往备份设置", "Configuration Backup")) {
                    engine.requestedSettingsPane = .general
                }
                .controlSize(.small)
            }
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Row Components

private struct GuideStepRow: View {
    let step: String
    let tone: SemanticTone
    let title: String
    let detail: String
    var badge: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        let fill = BarLensPalette.badgeFill(tone, in: colorScheme)
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(fill, in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(fill, in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct GuideItemRow: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct GuideFAQRow: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text(answer)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}
