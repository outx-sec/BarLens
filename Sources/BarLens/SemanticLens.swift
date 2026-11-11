import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import CoreWLAN
import Darwin
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps
import SystemConfiguration

/// Snapshot of a single `AXMenuItem` inside a status item's attached `AXMenu`.
/// Read passively without opening or flashing the menu.
struct AXMenuSnapshotEntry: Equatable, Hashable {
    let statusItemIndex: Int
    let menuIndex: Int
    let title: String
    let isEnabled: Bool
    let markChar: String?
    let shortcutHint: String?

    init(statusItemIndex: Int = 0,
         menuIndex: Int,
         title: String,
         isEnabled: Bool,
         markChar: String? = nil,
         shortcutHint: String? = nil) {
        self.statusItemIndex = statusItemIndex
        self.menuIndex = menuIndex
        self.title = title
        self.isEnabled = isEnabled
        self.markChar = markChar
        self.shortcutHint = shortcutHint
    }
}

/// Raw Accessibility strings and menu entries observed on a single status item element.
struct RawAXItemTelemetry: Equatable, Hashable {
    var title: String?
    var description: String?
    var value: String?
    var help: String?
    var menuEntries: [AXMenuSnapshotEntry]

    init(title: String? = nil,
         description: String? = nil,
         value: String? = nil,
         help: String? = nil,
         menuEntries: [AXMenuSnapshotEntry] = []) {
        self.title = title
        self.description = description
        self.value = value
        self.help = help
        self.menuEntries = menuEntries
    }
}

/// Structured key-value or status row rendered inside the Liquid Glass Optical Loupe.
struct LensFactRow: Equatable, Hashable, Identifiable {
    enum ValueTone: Equatable, Hashable {
        case neutral
        case active
        case accent
        case warning
    }

    var id: String { "\(label ?? "_")::\(value)" }
    let label: String?
    let value: String
    let tone: ValueTone

    init(label: String? = nil, value: String, tone: ValueTone = .neutral) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

/// Direct 1-click submenu action tunneled via `AXPress` without revealing or opening the top menu bar.
struct LensTunnelAction: Equatable, Hashable, Identifiable {
    var id: String { "\(statusItemIndex):\(menuIndex):\(title)" }
    let statusItemIndex: Int
    let menuIndex: Int
    let title: String
    let isChecked: Bool
    let shortcutHint: String?

    init(statusItemIndex: Int = 0,
         menuIndex: Int,
         title: String,
         isChecked: Bool = false,
         shortcutHint: String? = nil) {
        self.statusItemIndex = statusItemIndex
        self.menuIndex = menuIndex
        self.title = title
        self.isChecked = isChecked
        self.shortcutHint = shortcutHint
    }
}

/// Live process footprint and CPU activity sampled via `proc_pid_rusage`.
struct ProcessVitals: Equatable, Hashable {
    let memoryBytes: UInt64
    let cpuPercent: Double

    var memoryMB: Double {
        Double(memoryBytes) / 1_048_576.0
    }

    var isHighMemory: Bool {
        memoryMB >= 800
    }

    var isHighCPU: Bool {
        cpuPercent >= 25.0
    }

    var formattedMemory: String {
        if memoryMB >= 1024 {
            return String(format: "%.2f GB", memoryMB / 1024.0)
        }
        return String(format: "%.0f MB", max(1, memoryMB.rounded()))
    }

    var formattedCPU: String {
        if cpuPercent >= 10 {
            return String(format: "%.0f%%", cpuPercent)
        }
        return String(format: "%.1f%%", max(0, cpuPercent))
    }

    var compactSummary: String {
        if cpuPercent >= 0.4 {
            return "\(formattedMemory) · \(formattedCPU)"
        }
        return formattedMemory
    }
}

struct AudioOutputDeviceOption: Equatable, Hashable, Identifiable {
    let id: UInt32
    let name: String
    let isCurrent: Bool
}

struct KeyboardInputSourceOption: Equatable, Hashable, Identifiable {
    let id: String
    let name: String
    let isCurrent: Bool
}

enum LensInteractiveControl: Equatable, Hashable {
    case audioOutput(volume: Double, isMuted: Bool, currentDevice: String?, devices: [AudioOutputDeviceOption])
    case networkInfo(localIPv4: String?, gatewayIPv4: String?, interfaceName: String?)
    case inputSources(sources: [KeyboardInputSourceOption])
    case stageManager(isEnabled: Bool)
}

/// Distilled, zero-screen-recording live state & direct actions surfaced by BarLens's Optical Lens.
struct LensTelemetry: Equatable, Hashable {
    /// Positive unread or activity counter extracted from status item title or Dock badge (e.g. "1", "4", "99+").
    let unreadBadge: String?
    /// Compact single-clause telemetry token for inline row chips (<= 26 chars).
    let shortChip: String?
    /// Single-line telemetry summary for menus / search matching (<= 96 chars).
    let fullSummary: String?
    /// Structured untruncated status rows for the Optical Loupe card.
    let rows: [LensFactRow]
    /// Direct submenu actions executable via closed-menu `AXPress`.
    let tunnelActions: [LensTunnelAction]
    /// Optional native interactive control module for built-in macOS system items.
    let interactiveControl: LensInteractiveControl?

    init(unreadBadge: String? = nil,
         shortChip: String? = nil,
         fullSummary: String? = nil,
         rows: [LensFactRow] = [],
         tunnelActions: [LensTunnelAction] = [],
         interactiveControl: LensInteractiveControl? = nil) {
        self.unreadBadge = unreadBadge
        self.shortChip = shortChip
        self.fullSummary = fullSummary
        self.rows = rows
        self.tunnelActions = tunnelActions
        self.interactiveControl = interactiveControl
    }

    static let empty = LensTelemetry()

    var hasLiveSignal: Bool {
        unreadBadge != nil
            || shortChip != nil
            || fullSummary != nil
            || !rows.isEmpty
            || !tunnelActions.isEmpty
            || interactiveControl != nil
    }
}

/// Pure, deterministic distiller that converts Accessibility attributes, passive `AXMenu`
/// snapshots, and Dock unread badges into structured `LensTelemetry`.
enum SemanticLensExtractor {

    static func extract(appName: String,
                        bundleID: String,
                        items: [RawAXItemTelemetry],
                        dockBadge: String? = nil) -> LensTelemetry {
        guard !items.isEmpty || dockBadge != nil else { return .empty }

        var numericCountTotal = 0
        var hasOverflowPlusBadge = false
        var clauses: [String] = []
        var rows: [LensFactRow] = []
        var seenNormalized: Set<String> = []

        func appendClause(_ candidate: String, preferredTone: LensFactRow.ValueTone? = nil) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !isNoiseOrHeader(trimmed, appName: appName, bundleID: bundleID) else { return }
            let key = normalizeKey(trimmed)
            guard !key.isEmpty, seenNormalized.insert(key).inserted else { return }
            let collapsed = collapseWhitespace(trimmed)
            clauses.append(collapsed)
            if rows.count < 5 {
                rows.append(parseFactRow(from: collapsed, preferredTone: preferredTone))
            }
        }

        for item in items {
            if let badge = parseUnreadCounter(item.title) ?? parseUnreadCounter(item.value) {
                switch badge {
                case .count(let n):
                    numericCountTotal += n
                case .overflow:
                    hasOverflowPlusBadge = true
                }
            } else {
                if let title = item.title {
                    for line in splitLines(title) { appendClause(line) }
                }
                if let value = item.value {
                    for line in splitLines(value) { appendClause(line) }
                }
            }

            if let desc = item.description {
                for line in splitLines(desc) { appendClause(line) }
            }

            if let help = item.help {
                for line in splitLines(help) { appendClause(line) }
            }
        }

        // Extract live status rows & direct actions from passive AXMenu snapshots.
        var primaryActions: [LensTunnelAction] = []
        var secondaryActions: [LensTunnelAction] = []
        var seenActionTitles: Set<String> = []

        for item in items {
            for entry in item.menuEntries {
                let title = collapseWhitespace(entry.title)
                guard !title.isEmpty else { continue }
                let isChecked = (entry.markChar == "✓" || entry.markChar == "✔" || entry.markChar == "•")

                if !entry.isEnabled {
                    if !isPureVersionLine(title) {
                        appendClause(title, preferredTone: inferTone(forValue: title))
                    }
                    continue
                }

                if isChecked, rows.count < 5 {
                    let norm = normalizeKey(title)
                    if seenNormalized.insert(norm).inserted {
                        rows.append(LensFactRow(
                            label: tr("当前选项", "Active"),
                            value: title,
                            tone: .active
                        ))
                        clauses.append(title)
                    }
                }

                if isIgnoredMenuBoilerplate(title, appName: appName) {
                    continue
                }
                let actionKey = title.lowercased()
                guard seenActionTitles.insert(actionKey).inserted else { continue }

                let action = LensTunnelAction(
                    statusItemIndex: entry.statusItemIndex,
                    menuIndex: entry.menuIndex,
                    title: title,
                    isChecked: isChecked,
                    shortcutHint: entry.shortcutHint
                )
                if isSecondaryPreferencesAction(title) {
                    secondaryActions.append(action)
                } else {
                    primaryActions.append(action)
                }
            }
        }

        let tunnelActions = Array((primaryActions + secondaryActions).prefix(5))

        // Fuse status item unread counter with Dock status badge (taking max when both report numbers).
        if let dockParsed = parseDockBadge(dockBadge) {
            switch dockParsed {
            case .overflow:
                hasOverflowPlusBadge = true
            case .count(let dockN):
                numericCountTotal = max(numericCountTotal, dockN)
            }
        }

        let unreadBadge: String?
        if hasOverflowPlusBadge || numericCountTotal > 99 {
            unreadBadge = "99+"
        } else if numericCountTotal > 0 {
            unreadBadge = "\(numericCountTotal)"
        } else {
            unreadBadge = nil
        }

        if let badge = unreadBadge, rows.isEmpty {
            rows.append(LensFactRow(
                label: tr("未读消息", "Unread"),
                value: tr("\(badge) 条待处理", "\(badge) pending"),
                tone: .warning
            ))
        }

        let shortChip: String?
        if let first = clauses.first {
            shortChip = truncate(compactClauseForChip(first), maxCount: 24)
        } else {
            shortChip = nil
        }

        let fullSummary: String?
        if !clauses.isEmpty {
            let joined = clauses.prefix(3).map(compactLongParenthetical).joined(separator: " · ")
            fullSummary = truncate(joined, maxCount: 92)
        } else if let badge = unreadBadge {
            fullSummary = tr("\(badge) 条未读动态", "\(badge) active / unread")
        } else {
            fullSummary = nil
        }

        return LensTelemetry(
            unreadBadge: unreadBadge,
            shortChip: shortChip,
            fullSummary: fullSummary,
            rows: rows,
            tunnelActions: tunnelActions
        )
    }

    // MARK: - Fact Row & Menu Parsing

    private static func parseFactRow(from clause: String,
                                     preferredTone: LensFactRow.ValueTone?) -> LensFactRow {
        if let colonIndex = findKeyValueSeparator(in: clause) {
            let rawKey = String(clause[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let afterIdx = clause.index(after: colonIndex)
            var rawVal = String(clause[afterIdx...]).trimmingCharacters(in: .whitespaces)
            if rawVal.lowercased().hasSuffix(".yaml") || rawVal.lowercased().hasSuffix(".yml") {
                rawVal = String(rawVal.dropLast(rawVal.lowercased().hasSuffix(".yaml") ? 5 : 4))
            }
            if !rawKey.isEmpty, !rawVal.isEmpty, rawKey.count <= 18 {
                return LensFactRow(
                    label: rawKey,
                    value: rawVal,
                    tone: preferredTone ?? inferTone(forValue: rawVal)
                )
            }
        }
        return LensFactRow(
            label: nil,
            value: clause,
            tone: preferredTone ?? inferTone(forValue: clause)
        )
    }

    private static func findKeyValueSeparator(in text: String) -> String.Index? {
        // Avoid splitting time strings like "14:52" by requiring a non-digit before ':'.
        for idx in text.indices {
            let ch = text[idx]
            if ch == "：" { return idx }
            if ch == ":" {
                if idx > text.startIndex {
                    let prev = text[text.index(before: idx)]
                    if prev.isNumber { continue }
                }
                return idx
            }
        }
        return nil
    }

    private static func inferTone(forValue text: String) -> LensFactRow.ValueTone {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "on" || lower == "enabled" || lower == "connected"
            || lower.contains("running") || lower.contains("运行中")
            || lower.contains("已连接") || lower.contains("已开启") || lower.contains("充电") {
            return .active
        }
        if lower == "off" || lower == "disabled" || lower.contains("未连接") || lower.contains("已关闭") {
            return .neutral
        }
        if lower.contains("token") || lower.contains("$") || lower.contains("¥")
            || lower.contains("◈") || lower.contains("hz") || lower.contains("mbps") {
            return .accent
        }
        if lower.contains("error") || lower.contains("异常") || lower.contains("静音") || lower.contains("muted") {
            return .warning
        }
        return .accent
    }

    private static func isPureVersionLine(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("version ") || lower.hasPrefix("版本 ") || lower.hasPrefix("版本：") || lower.hasPrefix("v") {
            let rest = lower
                .replacingOccurrences(of: "version", with: "")
                .replacingOccurrences(of: "版本", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " :：vV()-_beta"))
            if !rest.isEmpty, rest.allSatisfy({ $0.isNumber || $0 == "." }) {
                return true
            }
        }
        return false
    }

    private static func isIgnoredMenuBoilerplate(_ title: String, appName: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let exactPrefixes = [
            "quit", "退出", "about", "关于", "check for update", "检查更新",
            "support", "feedback", "反馈", "faq", "website", "访问网站", "官网",
            "rate app", "share app", "more apps", "help", "帮助", "services", "服务",
            "hide ", "隐藏 " + appName.lowercased(), "show all", "全部显示"
        ]
        if exactPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0) }) {
            return true
        }
        if lower == "quit \(appName.lowercased())" || lower == "退出 \(appName.lowercased())" || lower == "退出\(appName.lowercased())" {
            return true
        }
        return false
    }

    private static func isSecondaryPreferencesAction(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("settings") || lower.contains("preferences")
            || lower.contains("设置") || lower.contains("首选项") || lower.contains("偏好设置")
    }

    // MARK: - Unread Counter Parsing

    private enum ParsedCounter {
        case count(Int)
        case overflow
    }

    private static func parseUnreadCounter(_ raw: String?) -> ParsedCounter? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 5 else { return nil }
        if s == "99+" || s == "999+" {
            return .overflow
        }
        if s.allSatisfy(\.isASCIIWholeNumber), let n = Int(s), n > 0, n <= 9999 {
            return .count(n)
        }
        return nil
    }

    private static func parseDockBadge(_ raw: String?) -> ParsedCounter? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        if cleaned.hasSuffix("+") {
            return .overflow
        }
        return parseUnreadCounter(cleaned)
    }

    // MARK: - Line Splitting & Filtering

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isNoiseOrHeader(_ line: String, appName: String, bundleID: String) -> Bool {
        if line == "0" || line == "-" || line == "—" || line == "BarLens.dot" {
            return true
        }
        let lower = line.lowercased()
        if lower == "nsstatusitem" || lower == "menubarextra" || lower.hasPrefix("item-") {
            return true
        }
        if line.hasSuffix(":") || line.hasSuffix("：") {
            return true
        }
        let staticInstructionMarkers = [
            "快捷键", "shortcut", "单击", "双击", "右键",
            "click:", "right-click", "double-click",
            "打开 ", "open "
        ]
        if staticInstructionMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let bundleTail = bundleID.split(separator: ".").last.map(String.init) ?? ""
        let normalizedLine = normalizeKey(line)
        let normalizedApp = normalizeKey(appName)
        let normalizedTail = normalizeKey(bundleTail)

        if !normalizedApp.isEmpty && normalizedLine == normalizedApp {
            return true
        }
        if !normalizedTail.isEmpty && normalizedLine == normalizedTail {
            return true
        }
        if !normalizedApp.isEmpty, normalizedLine.count >= 3,
           normalizedApp.hasPrefix(normalizedLine), !line.contains(where: \.isNumber),
           !line.contains(":"), !line.contains("：") {
            return true
        }
        if !normalizedApp.isEmpty, lower.hasPrefix(appName.lowercased()),
           !line.contains(":"), !line.contains("："), !line.contains("%"), !line.contains("°") {
            let remainder = String(line.dropFirst(appName.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty || isVersionOrEditionSuffix(remainder) || !remainder.contains(where: \.isNumber) {
                return true
            }
        }
        if !normalizedTail.isEmpty, lower.hasPrefix(bundleTail.lowercased()),
           !line.contains(":"), !line.contains("："), !line.contains("%"), !line.contains("°") {
            let remainder = String(line.dropFirst(bundleTail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty || isVersionOrEditionSuffix(remainder) {
                return true
            }
        }
        return false
    }

    private static func isVersionOrEditionSuffix(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "免费版", with: "")
            .replacingOccurrences(of: "专业版", with: "")
            .replacingOccurrences(of: "正式版", with: "")
            .replacingOccurrences(of: "beta", with: "")
            .replacingOccurrences(of: "pro", with: "")
            .replacingOccurrences(of: "free", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]-vV._"))
        guard !cleaned.isEmpty else { return true }
        return cleaned.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func normalizeKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func compactClauseForChip(_ clause: String) -> String {
        var result = clause
        if let openIdx = result.firstIndex(of: "("),
           let closeIdx = result.lastIndex(of: ")"),
           openIdx < closeIdx,
           result.distance(from: openIdx, to: closeIdx) > 8 {
            let prefix = result[..<openIdx].trimmingCharacters(in: .whitespaces)
            if prefix.count >= 4 {
                result = prefix
            }
        }
        return collapseWhitespace(result)
    }

    private static func compactLongParenthetical(_ clause: String) -> String {
        if clause.count <= 36 { return clause }
        return compactClauseForChip(clause)
    }

    private static func truncate(_ text: String, maxCount: Int) -> String {
        guard text.count > maxCount, maxCount > 2 else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxCount - 1)
        return String(text[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }
}

// MARK: - Live Process Vitals Reader (`proc_pid_rusage`)

final class ProcessVitalsReader {
    static let shared = ProcessVitalsReader()

    private struct Sample {
        let wallNs: UInt64
        let cpuNs: UInt64
        let vitals: ProcessVitals
    }

    private let lock = NSLock()
    private var samplesByPID: [pid_t: Sample] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(numer: 1, denom: 1)
        mach_timebase_info(&info)
        return info
    }()

    func vitals(for bundleID: String) -> ProcessVitals? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              app.processIdentifier > 0 else {
            return nil
        }
        return vitals(forPID: app.processIdentifier)
    }

    func vitals(forPID pid: pid_t) -> ProcessVitals? {
        guard pid > 0 else { return nil }
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        if let prev = samplesByPID[pid], nowNs >= prev.wallNs, (nowNs - prev.wallNs) < 900_000_000 {
            lock.unlock()
            return prev.vitals
        }
        let previous = samplesByPID[pid]
        lock.unlock()

        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }

        let rawTicks = info.ri_user_time &+ info.ri_system_time
        let denom = UInt64(max(1, timebase.denom))
        let cpuNs = (rawTicks / denom) * UInt64(timebase.numer)
            + ((rawTicks % denom) * UInt64(timebase.numer)) / denom

        var cpuPct: Double = 0
        if let prev = previous, nowNs > prev.wallNs, cpuNs >= prev.cpuNs {
            let deltaWall = Double(nowNs - prev.wallNs)
            let deltaCPU = Double(cpuNs - prev.cpuNs)
            if deltaWall >= 50_000_000 {
                cpuPct = min(400.0, max(0.0, (deltaCPU / deltaWall) * 100.0))
            } else {
                cpuPct = prev.vitals.cpuPercent
            }
        }

        let resolved = ProcessVitals(memoryBytes: info.ri_phys_footprint, cpuPercent: cpuPct)
        lock.lock()
        if samplesByPID.count > 160 {
            samplesByPID.removeAll(keepingCapacity: true)
        }
        samplesByPID[pid] = Sample(wallNs: nowNs, cpuNs: cpuNs, vitals: resolved)
        lock.unlock()
        return resolved
    }
}

// MARK: - Rich System Telemetry & Interactive Controls

final class SystemTelemetryReader {
    static let shared = SystemTelemetryReader()

    private struct CachedEntry {
        let timestamp: TimeInterval
        let telemetry: LensTelemetry
    }

    private var cache: [String: CachedEntry] = [:]
    private var preMuteVolume: Float32 = 0.45

    private lazy var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private lazy var fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.isEnglish ? "en_US" : "zh_CN")
        f.dateFormat = L10n.isEnglish ? "EEE, MMM d · HH:mm" : "M月d日 EEEE · HH:mm"
        return f
    }()
    private lazy var lunarFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .chinese)
        f.locale = Locale(identifier: "zh_CN")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    func invalidate(_ canonicalIdentifier: String? = nil) {
        if let canonicalIdentifier {
            cache.removeValue(forKey: SystemItemName.canonicalIdentifier(for: canonicalIdentifier))
        } else {
            cache.removeAll()
        }
    }

    func telemetry(for item: SystemItem, fallbackAX: LensTelemetry = .empty) -> LensTelemetry {
        let canonical = SystemItemName.canonicalIdentifier(for: item.identifier)
        let now = ProcessInfo.processInfo.systemUptime
        let itemTTL: TimeInterval = (canonical == "com.apple.menuextra.bluetooth") ? 4.0 : 1.8
        if let hit = cache[canonical], now - hit.timestamp < itemTTL {
            return hit.telemetry
        }

        let resolved: LensTelemetry
        switch canonical {
        case "com.apple.menuextra.wifi":
            resolved = readNetworkTelemetry() ?? fallbackAX
        case "com.apple.menuextra.bluetooth":
            resolved = readBluetoothTelemetry() ?? fallbackAX
        case "com.apple.menuextra.battery":
            resolved = readBatteryTelemetry() ?? fallbackAX
        case "com.apple.menuextra.sound":
            resolved = readAudioVolumeTelemetry() ?? fallbackAX
        case "com.apple.menuextra.display":
            resolved = readDisplayTelemetry() ?? fallbackAX
        case "com.apple.menuextra.textinput":
            resolved = readInputSourceTelemetry() ?? fallbackAX
        case "com.apple.menuextra.clock":
            resolved = readClockTelemetry()
        case "com.apple.menuextra.stagemanager":
            resolved = readStageManagerTelemetry()
        case "com.apple.menuextra.screen-mirroring":
            resolved = readScreenMirroringTelemetry()
        case "com.apple.menuextra.timemachine":
            resolved = readStorageAndBackupTelemetry(fallbackAX: fallbackAX)
        default:
            resolved = enrichGenericSystemItem(canonical: canonical, fallbackAX: fallbackAX)
        }

        cache[canonical] = CachedEntry(timestamp: now, telemetry: resolved)
        return resolved
    }

    // MARK: Interactive System Mutations

    func setOutputVolume(_ normalized: Double) {
        guard let devID = defaultOutputDeviceID() else { return }
        let clamped = Float32(min(max(normalized, 0), 1))
        if clamped > 0.02 {
            preMuteVolume = clamped
        }
        var vol = clamped
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(devID, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)

        var muteVal: UInt32 = (clamped <= 0.004) ? 1 : 0
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(devID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        invalidate("com.apple.menuextra.sound")
    }

    func toggleOutputMute() {
        guard let devID = defaultOutputDeviceID() else { return }
        var muteVal: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMute = AudioObjectGetPropertyData(devID, &muteAddr, 0, nil, &muteSize, &muteVal) == noErr

        var curVol: Float32 = 0.5
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(devID, &volAddr, 0, nil, &volSize, &curVol)

        if hasMute {
            var next: UInt32 = (muteVal == 0) ? 1 : 0
            if AudioObjectSetPropertyData(devID, &muteAddr, 0, nil, muteSize, &next) == noErr {
                if next == 0 && curVol <= 0.01 {
                    var restore = max(0.25, preMuteVolume)
                    _ = AudioObjectSetPropertyData(devID, &volAddr, 0, nil, volSize, &restore)
                }
                invalidate("com.apple.menuextra.sound")
                return
            }
        }
        if curVol > 0.01 {
            preMuteVolume = curVol
            setOutputVolume(0)
        } else {
            setOutputVolume(Double(max(0.25, preMuteVolume)))
        }
    }

    func selectOutputDevice(_ deviceID: UInt32) {
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        invalidate("com.apple.menuextra.sound")
    }

    func selectInputSource(id targetID: String) {
        let applySelection: () -> Void = {
            let filter: [CFString: Any] = [
                kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
                kTISPropertyInputSourceIsSelectCapable: true,
                kTISPropertyInputSourceIsEnabled: true,
            ]
            guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
                return
            }
            for src in list {
                if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                    let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                    if id == targetID {
                        TISSelectInputSource(src)
                        break
                    }
                }
            }
        }
        if Thread.isMainThread {
            applySelection()
        } else {
            DispatchQueue.main.sync(execute: applySelection)
        }
        invalidate("com.apple.menuextra.textinput")
    }

    func toggleStageManager() {
        let suite = "com.apple.WindowManager" as CFString
        let key = "GloballyEnabled" as CFString
        let current = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        let next: CFBoolean = (!current) ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetAppValue(key, next, suite)
        CFPreferencesAppSynchronize(suite)
        invalidate("com.apple.menuextra.stagemanager")
    }

    static func systemSettingsURL(for identifier: String) -> URL? {
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        let urlString: String?
        switch canonical {
        case "com.apple.menuextra.wifi":
            urlString = "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case "com.apple.menuextra.bluetooth":
            urlString = "x-apple.systempreferences:com.apple.BluetoothSettings"
        case "com.apple.menuextra.sound":
            urlString = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case "com.apple.menuextra.display", "com.apple.menuextra.screen-mirroring":
            urlString = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        case "com.apple.menuextra.battery":
            urlString = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        case "com.apple.menuextra.focusmode":
            urlString = "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        case "com.apple.menuextra.textinput", "com.apple.menuextra.keyboard-brightness":
            urlString = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case "com.apple.menuextra.clock":
            urlString = "x-apple.systempreferences:com.apple.Date-Time-Settings.extension"
        case "com.apple.menuextra.timemachine":
            urlString = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
        case "com.apple.menuextra.controlcenter", "com.apple.menuextra.stagemanager":
            urlString = "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
        case "com.apple.menuextra.siri", "com.apple.menuextra.spotlight":
            urlString = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        default:
            urlString = nil
        }
        return urlString.flatMap(URL.init(string:))
    }

    // MARK: - Individual Readers

    private func readNetworkTelemetry() -> LensTelemetry? {
        let wifiIface = CWWiFiClient.shared().interface()
        let wifiPower = wifiIface?.powerOn() ?? false
        let ssid = wifiIface?.ssid()
        let rssi = wifiIface?.rssiValue() ?? 0
        let txRate = wifiIface?.transmitRate() ?? 0

        var primaryIF: String?
        var routerIP: String?
        if let store = SCDynamicStoreCreate(nil, "BarLens.net" as CFString, nil, nil),
           let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primaryIF = dict["PrimaryInterface"] as? String
            routerIP = dict["Router"] as? String
        }

        let ipsByIF = activeIPv4ByInterface()
        let wifiIFName = wifiIface?.interfaceName ?? "en0"
        let wifiIP = ipsByIF[wifiIFName]
        let activeIP = (primaryIF.flatMap { ipsByIF[$0] }) ?? wifiIP ?? ipsByIF.first?.value

        var rows: [LensFactRow] = []
        let shortChip: String
        let fullSummary: String

        if wifiPower, (ssid != nil || wifiIP != nil || (rssi < 0 && rssi > -100)) {
            let networkLabel = ssid ?? tr("已连接无线局域网", "Wi-Fi Connected")
            rows.append(LensFactRow(label: "Wi-Fi", value: networkLabel, tone: .active))
            if rssi < 0 && rssi > -100 {
                let rateText = txRate > 0 ? String(format: " · %.0f Mbps", txRate) : ""
                rows.append(LensFactRow(
                    label: tr("信号链路", "Link"),
                    value: "\(rssi) dBm\(rateText)",
                    tone: .accent
                ))
            }
            if let ip = wifiIP ?? activeIP {
                rows.append(LensFactRow(label: tr("本机 IP", "Local IP"), value: ip, tone: .accent))
            }
            if let gw = routerIP {
                rows.append(LensFactRow(label: tr("网关路由", "Gateway"), value: gw, tone: .neutral))
            }
            shortChip = ssid ?? (wifiIP ?? tr("已连接", "Connected"))
            fullSummary = [networkLabel, wifiIP].compactMap { $0 }.joined(separator: " · ")
        } else if let pIF = primaryIF, let ip = activeIP {
            let wifiState = wifiPower ? tr("已开启（待机）", "On (Standby)") : tr("已关闭", "Off")
            rows.append(LensFactRow(label: "Wi-Fi", value: wifiState, tone: .neutral))
            rows.append(LensFactRow(
                label: tr("活跃网络", "Active Link"),
                value: tr("有线以太网 (\(pIF))", "Ethernet (\(pIF))"),
                tone: .active
            ))
            rows.append(LensFactRow(label: tr("本机 IP", "Local IP"), value: ip, tone: .accent))
            if let gw = routerIP {
                rows.append(LensFactRow(label: tr("网关路由", "Gateway"), value: gw, tone: .neutral))
            }
            shortChip = ip
            fullSummary = tr("有线 \(pIF) · \(ip)", "Ethernet \(pIF) · \(ip)")
        } else {
            let stateText = wifiPower ? tr("未连接网络", "Not Connected") : tr("Wi-Fi 已关闭", "Wi-Fi Off")
            rows.append(LensFactRow(label: "Wi-Fi", value: stateText, tone: wifiPower ? .neutral : .warning))
            shortChip = wifiPower ? tr("待机", "Standby") : tr("已关闭", "Off")
            fullSummary = stateText
        }

        return LensTelemetry(
            unreadBadge: nil,
            shortChip: shortChip,
            fullSummary: fullSummary,
            rows: rows,
            interactiveControl: .networkInfo(
                localIPv4: activeIP,
                gatewayIPv4: routerIP,
                interfaceName: primaryIF ?? wifiIFName
            )
        )
    }

    private func activeIPv4ByInterface() -> [String: String] {
        var map: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return map }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            if (flags & (IFF_UP | IFF_RUNNING)) != 0,
               (flags & IFF_LOOPBACK) == 0,
               !name.hasPrefix("bridge"),
               !name.hasPrefix("utun"),
               let sa = current.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    map[name] = String(cString: host)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return map
    }

    private func readBluetoothTelemetry() -> LensTelemetry? {
        let poweredOn = (IOBluetoothHostController.default()?.powerState.rawValue ?? 1) != 0
        guard poweredOn else {
            let text = tr("蓝牙已关闭", "Bluetooth Off")
            return LensTelemetry(
                shortChip: tr("已关闭", "Off"),
                fullSummary: text,
                rows: [LensFactRow(label: tr("蓝牙状态", "Bluetooth"), value: tr("已关闭", "Off"), tone: .warning)]
            )
        }

        let hidBatteries = readHIDPeripheralBatteries()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connectedNames = paired
            .filter { $0.isConnected() }
            .compactMap { $0.nameOrAddress?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var rows: [LensFactRow] = []
        if connectedNames.isEmpty {
            rows.append(LensFactRow(
                label: tr("蓝牙状态", "Bluetooth"),
                value: tr("已开启 · 暂无连接设备", "On · No Devices Connected"),
                tone: .neutral
            ))
            for hid in hidBatteries.prefix(3) {
                rows.append(LensFactRow(
                    label: hid.name,
                    value: "\(hid.percent)%",
                    tone: hid.percent <= 20 ? .warning : .accent
                ))
            }
            return LensTelemetry(
                shortChip: tr("待机", "Standby"),
                fullSummary: tr("蓝牙已开启 · 暂无已连接设备", "Bluetooth On · Idle"),
                rows: rows
            )
        }

        for devName in connectedNames.prefix(4) {
            if let pct = matchHIDBattery(for: devName, in: hidBatteries) {
                rows.append(LensFactRow(
                    label: devName,
                    value: "\(pct)%",
                    tone: pct <= 20 ? .warning : .accent
                ))
            } else {
                rows.append(LensFactRow(
                    label: devName,
                    value: tr("已连接", "Connected"),
                    tone: .active
                ))
            }
        }

        let count = connectedNames.count
        let chip = tr("\(count) 台设备", "\(count) Connected")
        let summary = connectedNames.prefix(3).joined(separator: " · ")
        return LensTelemetry(
            shortChip: chip,
            fullSummary: summary,
            rows: rows
        )
    }

    private func readHIDPeripheralBatteries() -> [(name: String, percent: Int)] {
        var results: [(name: String, percent: Int)] = []
        var seen: Set<String> = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iter
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let pct = dict["BatteryPercent"] as? Int,
               pct >= 0, pct <= 100 {
                let rawName = ((dict["Product"] as? String) ?? tr("无线外设", "Wireless HID"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawName.isEmpty, seen.insert(rawName.lowercased()).inserted {
                    results.append((name: rawName, percent: pct))
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return results
    }

    private func matchHIDBattery(for deviceName: String, in hidList: [(name: String, percent: Int)]) -> Int? {
        let devLower = deviceName.lowercased()
        for hid in hidList {
            let hidLower = hid.name.lowercased()
            if devLower == hidLower || devLower.contains(hidLower) || hidLower.contains(devLower) {
                return hid.percent
            }
        }
        return nil
    }

    private func readBatteryTelemetry() -> LensTelemetry? {
        let hidBatteries = readHIDPeripheralBatteries()
        var rows: [LensFactRow] = []

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           !sources.isEmpty {
            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                      let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int else {
                    continue
                }
                let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) == true
                let isCharged = (desc[kIOPSIsChargedKey as String] as? Bool) == true
                let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
                let onAC = (powerState == (kIOPSACPowerValue as String))

                let stateText: String
                let short: String
                if isCharging {
                    short = tr("\(capacity)% · 充电中", "\(capacity)% · Charging")
                    stateText = tr("正在充电", "Charging")
                } else if isCharged && onAC {
                    short = tr("\(capacity)% · 已满", "\(capacity)% · Full")
                    stateText = tr("外接电源已充满", "Charged on AC")
                } else if onAC {
                    short = tr("\(capacity)% · 电源", "\(capacity)% · AC")
                    stateText = tr("使用外接电源", "On AC Power")
                } else {
                    short = "\(capacity)%"
                    stateText = tr("使用电池供电", "On Battery")
                }

                rows.append(LensFactRow(
                    label: tr("内置电池", "Internal"),
                    value: "\(capacity)% · \(stateText)",
                    tone: capacity <= 20 && !onAC ? .warning : (isCharging ? .active : .accent)
                ))

                if let mins = desc[kIOPSTimeToEmptyKey as String] as? Int, !onAC, mins > 0, mins < 2400 {
                    rows.append(LensFactRow(
                        label: tr("预计续航", "Remaining"),
                        value: String(format: "%dh %02dm", mins / 60, mins % 60),
                        tone: .neutral
                    ))
                } else if let mins = desc[kIOPSTimeToFullChargeKey as String] as? Int, isCharging, mins > 0, mins < 1200 {
                    rows.append(LensFactRow(
                        label: tr("充满还需", "To Full"),
                        value: String(format: "%dh %02dm", mins / 60, mins % 60),
                        tone: .active
                    ))
                }

                for hid in hidBatteries.prefix(3) {
                    rows.append(LensFactRow(
                        label: hid.name,
                        value: "\(hid.percent)%",
                        tone: hid.percent <= 20 ? .warning : .accent
                    ))
                }

                return LensTelemetry(
                    shortChip: short,
                    fullSummary: "\(capacity)% · \(stateText)",
                    rows: rows
                )
            }
        }

        // Desktop Mac fallback: AC power + wireless peripheral batteries!
        rows.append(LensFactRow(
            label: tr("供电模式", "Power"),
            value: tr("外接交流电源", "AC Mains Power"),
            tone: .active
        ))
        for hid in hidBatteries.prefix(4) {
            rows.append(LensFactRow(
                label: hid.name,
                value: "\(hid.percent)%",
                tone: hid.percent <= 20 ? .warning : .accent
            ))
        }
        let firstHID = hidBatteries.first
        return LensTelemetry(
            shortChip: firstHID.map { "\($0.percent)%" } ?? tr("交流电", "AC"),
            fullSummary: firstHID.map { "\($0.name): \($0.percent)%" } ?? tr("使用外接电源供电", "AC Power"),
            rows: rows
        )
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            0,
            nil,
            &size,
            &devID
        ) == noErr, devID != 0 else {
            return nil
        }
        return devID
    }

    private func audioDeviceName(_ id: AudioDeviceID) -> String? {
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfName) == noErr,
              let name = cfName?.takeUnretainedValue() as String? else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func listOutputDevices(currentID: AudioDeviceID) -> [AudioOutputDeviceOption] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else {
            return []
        }

        var options: [AudioOutputDeviceOption] = []
        for id in ids {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0,
                  let name = audioDeviceName(id) else {
                continue
            }
            let lower = name.lowercased()
            if id != currentID && (lower.contains("virtual") || lower.contains("zoomaudio") || lower.contains("teams audio")) {
                continue
            }
            options.append(AudioOutputDeviceOption(id: id, name: name, isCurrent: id == currentID))
        }
        options.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Array(options.prefix(4))
    }

    private func readAudioVolumeTelemetry() -> LensTelemetry? {
        guard let devID = defaultOutputDeviceID() else { return nil }
        let devName = audioDeviceName(devID)
        let devices = listOutputDevices(currentID: devID)

        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMute = AudioObjectGetPropertyData(devID, &muteAddr, 0, nil, &muteSize, &mute) == noErr

        var volume: Float32 = 0.5
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasVol = AudioObjectGetPropertyData(devID, &volAddr, 0, nil, &volSize, &volume) == noErr
        let normalizedVol = hasVol ? Double(min(max(volume, 0), 1)) : 0.5
        let pct = Int((normalizedVol * 100).rounded())
        let isMuted = (hasMute && mute != 0) || (hasVol && pct == 0)

        let shortChip = isMuted ? tr("静音", "Muted") : "\(pct)%"
        let deviceClause = devName.map { " · \($0)" } ?? ""
        let fullSummary = isMuted
            ? tr("已静音\(deviceClause)", "Muted\(deviceClause)")
            : tr("音量 \(pct)%\(deviceClause)", "Volume \(pct)%\(deviceClause)")

        var rows: [LensFactRow] = []
        if let devName {
            rows.append(LensFactRow(label: tr("输出设备", "Output"), value: devName, tone: .active))
        }

        return LensTelemetry(
            shortChip: shortChip,
            fullSummary: fullSummary,
            rows: rows,
            interactiveControl: .audioOutput(
                volume: isMuted ? 0 : normalizedVol,
                isMuted: isMuted,
                currentDevice: devName,
                devices: devices
            )
        )
    }

    private func readDisplayTelemetry() -> LensTelemetry? {
        let screens: [(name: String, width: Int, height: Int, hz: Int)] = (Thread.isMainThread
            ? NSScreen.screens
            : DispatchQueue.main.sync { NSScreen.screens }
        ).map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
            let hz = id != 0 ? Int((CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0).rounded()) : 0
            return (screen.localizedName, Int(screen.frame.width), Int(screen.frame.height), hz)
        }
        guard !screens.isEmpty else { return nil }

        let rows = screens.prefix(4).map { s -> LensFactRow in
            let hzSuffix = s.hz > 0 ? " · \(s.hz) Hz" : ""
            return LensFactRow(
                label: s.name,
                value: "\(s.width)×\(s.height)\(hzSuffix)",
                tone: .accent
            )
        }
        let primary = screens[0]
        let chip = primary.hz > 0 ? "\(primary.hz) Hz" : "\(primary.width)×\(primary.height)"
        let summary = screens.map { "\($0.name) (\($0.width)×\($0.height))" }.joined(separator: " · ")
        return LensTelemetry(shortChip: chip, fullSummary: summary, rows: rows)
    }

    private func readInputSourceTelemetry() -> LensTelemetry? {
        let fetch: () -> (current: String?, options: [KeyboardInputSourceOption]) = {
            var currentID: String?
            var currentName: String?
            if let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
                if let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                    currentID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                }
                if let namePtr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
                    currentName = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
                }
            }

            let filter: [CFString: Any] = [
                kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
                kTISPropertyInputSourceIsSelectCapable: true,
                kTISPropertyInputSourceIsEnabled: true,
            ]
            var options: [KeyboardInputSourceOption] = []
            var seenNames: Set<String> = []
            if let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] {
                for src in list {
                    guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID),
                          let namePtr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else {
                        continue
                    }
                    let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                    if id.contains("CharacterPalette") || id.contains("KeyboardViewer") || id.contains("PressAndHold") {
                        continue
                    }
                    let raw = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
                    let clean = Self.compactInputName(raw)
                    guard seenNames.insert(clean).inserted else { continue }
                    options.append(KeyboardInputSourceOption(id: id, name: clean, isCurrent: id == currentID))
                }
            }
            return (currentName.map(Self.compactInputName), Array(options.prefix(5)))
        }

        let result = Thread.isMainThread ? fetch() : DispatchQueue.main.sync(execute: fetch)
        guard let current = result.current, !current.isEmpty else { return nil }
        return LensTelemetry(
            shortChip: current.count > 16 ? String(current.prefix(15)) + "…" : current,
            fullSummary: tr("当前输入法：\(current)", "Input Source: \(current)"),
            rows: [LensFactRow(label: tr("当前输入法", "Active Input"), value: current, tone: .active)],
            interactiveControl: result.options.count > 1 ? .inputSources(sources: result.options) : nil
        )
    }

    private static func compactInputName(_ rawName: String) -> String {
        rawName
            .replacingOccurrences(of: "Pinyin – Simplified", with: tr("简体拼音", "Pinyin"))
            .replacingOccurrences(of: "Pinyin - Simplified", with: tr("简体拼音", "Pinyin"))
            .replacingOccurrences(of: "Shuangpin – Simplified", with: tr("简体双拼", "Shuangpin"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readClockTelemetry() -> LensTelemetry {
        let now = Date()
        let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: now)
        let uptimeSec = Int(ProcessInfo.processInfo.systemUptime)
        let days = uptimeSec / 86_400
        let hours = (uptimeSec % 86_400) / 3600
        let mins = (uptimeSec % 3600) / 60
        let uptimeText = days > 0
            ? tr("\(days) 天 \(hours) 小时", "\(days)d \(hours)h")
            : tr("\(hours) 小时 \(mins) 分钟", "\(hours)h \(mins)m")

        var rows: [LensFactRow] = [
            LensFactRow(label: tr("日期时间", "Date"), value: fullDateFormatter.string(from: now), tone: .accent)
        ]
        if !L10n.isEnglish {
            let lunar = lunarFormatter.string(from: now)
            rows.append(LensFactRow(label: "农历周次", value: "\(lunar) · 第 \(week) 周", tone: .neutral))
        } else {
            rows.append(LensFactRow(label: "Calendar", value: "Week \(week)", tone: .neutral))
        }
        rows.append(LensFactRow(label: tr("系统运行", "Uptime"), value: uptimeText, tone: .active))

        return LensTelemetry(
            shortChip: clockFormatter.string(from: now),
            fullSummary: fullDateFormatter.string(from: now),
            rows: rows
        )
    }

    private func readStageManagerTelemetry() -> LensTelemetry {
        let enabled = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        let state = enabled ? tr("已开启", "Enabled") : tr("已关闭", "Off")
        return LensTelemetry(
            shortChip: state,
            fullSummary: tr("台前调度：\(state)", "Stage Manager: \(state)"),
            rows: [LensFactRow(label: tr("台前调度", "Stage Manager"), value: state, tone: enabled ? .active : .neutral)],
            interactiveControl: .stageManager(isEnabled: enabled)
        )
    }

    private func readScreenMirroringTelemetry() -> LensTelemetry {
        let screenCount = Thread.isMainThread ? NSScreen.screens.count : DispatchQueue.main.sync { NSScreen.screens.count }
        let mirrored = CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
        let modeText = mirrored
            ? tr("正在镜像屏幕", "Mirroring Active")
            : (screenCount > 1
                ? tr("扩展桌面 · \(screenCount) 台显示器", "Extended Desktop · \(screenCount) Displays")
                : tr("单显示器输出", "Single Display"))
        return LensTelemetry(
            shortChip: mirrored ? tr("镜像中", "Mirroring") : "\(screenCount)x",
            fullSummary: modeText,
            rows: [LensFactRow(label: tr("显示布局", "Layout"), value: modeText, tone: mirrored ? .active : .accent)]
        )
    }

    private func readStorageAndBackupTelemetry(fallbackAX: LensTelemetry) -> LensTelemetry {
        var rows = fallbackAX.rows
        var chip = fallbackAX.shortChip
        var summary = fallbackAX.fullSummary

        if let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ), let avail = values.volumeAvailableCapacityForImportantUsage, avail > 0 {
            let freeGB = Double(avail) / 1_000_000_000.0
            let freeText = freeGB >= 1000
                ? String(format: "%.2f TB", freeGB / 1000.0)
                : String(format: "%.0f GB", freeGB)
            rows.append(LensFactRow(
                label: tr("磁盘可用", "Free Space"),
                value: freeText,
                tone: freeGB < 25 ? .warning : .accent
            ))
            if chip == nil { chip = freeText }
            if summary == nil { summary = tr("本机可用空间 \(freeText)", "Available Disk: \(freeText)") }
        }
        return LensTelemetry(
            unreadBadge: fallbackAX.unreadBadge,
            shortChip: chip,
            fullSummary: summary,
            rows: rows
        )
    }

    private func enrichGenericSystemItem(canonical: String, fallbackAX: LensTelemetry) -> LensTelemetry {
        if fallbackAX.hasLiveSignal { return fallbackAX }
        let hint: String
        switch canonical {
        case "com.apple.menuextra.controlcenter":
            hint = tr("快速调用系统控制中心面板", "Open macOS Control Center")
        case "com.apple.menuextra.focusmode":
            hint = tr("管理专注与勿扰模式", "Toggle Focus & Do Not Disturb")
        case "com.apple.menuextra.spotlight":
            hint = tr("全盘检索应用、文件与计算", "Search apps, files, and actions")
        case "com.apple.menuextra.passwords":
            hint = tr("打开系统密码与通行密钥管理", "Open Apple Passwords & Passkeys")
        case "com.apple.menuextra.weather":
            hint = tr("查看实时天气预报", "Open Weather conditions")
        case "com.apple.menuextra.siri":
            hint = tr("唤起 Siri 智能助手", "Invoke Siri assistant")
        default:
            hint = tr("点按打开原生系统控件", "Click to open system control")
        }
        return LensTelemetry(
            rows: [LensFactRow(label: nil, value: hint, tone: .neutral)]
        )
    }
}
