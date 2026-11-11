import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var engine: DividerEngine
    @State private var copiedDiagnostics = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            header
            permissions
            diagnostics
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("BarLens")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(tr("栏镜", "Liquid Glass Menu Bar"))
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.78))
                    }
                    Text(tr("版本 \(Self.version) · 构建 \(Self.build)", "Version \(Self.version) · Build \(Self.build)"))
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.72))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }

    private var permissions: some View {
        Section(tr("权限与系统", "Permissions & System")) {
            PermissionRow(
                symbol: engine.hasAccessibility ? "checkmark.shield" : "hand.raised",
                tone: engine.hasAccessibility ? .green : .orange,
                title: tr("辅助功能权限", "Accessibility Permission"),
                status: engine.hasAccessibility ? tr("已授权", "Granted") : tr("未授权", "Not Granted"),
                action: engine.hasAccessibility ? nil
                    : AboutAction(title: tr("打开设置", "Open Settings"), url: Self.accessibility))

            PermissionRow(
                symbol: engine.hasSystemLedger ? "checkmark.seal" : "list.bullet.rectangle",
                tone: engine.hasSystemLedger ? .green : .neutral,
                title: tr("完全磁盘访问", "Full Disk Access"),
                status: engine.hasSystemLedger ? tr("已启用", "Enabled") : tr("可选", "Optional"),
                action: engine.hasSystemLedger ? nil
                    : AboutAction(title: tr("打开设置", "Open Settings"), url: Self.fullDiskAccess))

            PermissionRow(
                symbol: "menubar.rectangle",
                tone: .blue,
                title: tr("系统控制中心设置", "Control Center Settings"),
                status: nil,
                action: AboutAction(title: tr("打开设置", "Open Settings"), url: Self.controlCenter))
        }
    }

    private var diagnostics: some View {
        Section(tr("运行诊断", "Runtime Diagnostics")) {
            LabeledContent(tr("连接状态", "Connection Status"), value: connectionDescription)
            if let date = engine.lastRecoveryAt {
                LabeledContent(tr("最近恢复", "Last Recovery")) {
                    Text(date, format: .dateTime.month().day().hour().minute().second())
                }
                LabeledContent(tr("恢复原因", "Recovery Reason"), value: engine.lastRecoveryReason ?? "—")
                if let duration = engine.lastRecoveryDuration {
                    LabeledContent(tr("恢复耗时", "Recovery Duration"), value: tr(String(format: "%.1f 秒", duration), String(format: "%.1fs", duration)))
                }
            } else {
                LabeledContent(tr("最近恢复", "Last Recovery"), value: tr("等待连接确认", "Awaiting confirmation"))
            }
            if let retry = engine.nextRetryAt {
                LabeledContent(tr("下次自动重试", "Next Auto-Retry")) {
                    Text(retry, format: .dateTime.hour().minute().second())
                }
            }
            if let reason = engine.lastExitReason {
                LabeledContent(tr("助手最近退出", "Last Helper Exit"), value: reason)
            }
            if let warning = engine.scanWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(BarLensPalette.ink(.orange, in: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(copiedDiagnostics ? tr("已复制", "Copied") : tr("复制诊断信息", "Copy Diagnostics"), systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc") {
                    let summary = engine.diagnosticSummary()
                    NSPasteboard.general.clearContents()
                    copiedDiagnostics = NSPasteboard.general.setString(summary, forType: .string)
                }
                Spacer()
                Button(tr("重新连接", "Reconnect")) { engine.recoverConnection() }
                    .disabled(engine.isRecovering)
            }
        }
    }

    private var connectionDescription: String {
        if engine.nextRetryAt != nil { return tr("等待自动重试", "Waiting to Retry") }
        if engine.isRecovering { return tr("正在恢复连接", "Recovering Connection") }
        if let error = engine.connectionError { return error }
        return tr("连接正常", "Connected")
    }

    private static let controlCenter =
        "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
    private static let fullDiskAccess =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    private static let accessibility =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

private struct AboutAction {
    let title: String
    let url: String
}

private struct PermissionRow: View {
    let symbol: String
    let tone: SemanticTone
    let title: String
    let status: String?
    var action: AboutAction?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = BarLensPalette.ink(tone, in: colorScheme)
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(BarLensPalette.badgeFill(tone, in: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if let status {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        tone == .green
                            ? BarLensPalette.ink(.green, in: colorScheme)
                            : (tone == .orange ? BarLensPalette.ink(.orange, in: colorScheme) : .primary.opacity(0.74))
                    )
            }
            if let action {
                Button(action.title) {
                    guard let url = URL(string: action.url) else { return }
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
