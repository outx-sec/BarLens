import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit.ps

/// Raw Accessibility strings observed on a single status item element.
struct RawAXItemTelemetry: Equatable, Hashable {
    var title: String?
    var description: String?
    var value: String?
    var help: String?

    init(title: String? = nil, description: String? = nil, value: String? = nil, help: String? = nil) {
        self.title = title
        self.description = description
        self.value = value
        self.help = help
    }
}

/// Distilled, zero-screen-recording live state surfaced by BarLens's Semantic Lens.
struct LensTelemetry: Equatable, Hashable {
    /// Positive unread or activity counter extracted from a numeric status item title (e.g. "1", "4", "99+").
    let unreadBadge: String?
    /// Compact single-clause telemetry token for inline row chips / idle strip (<= 26 chars).
    let shortChip: String?
    /// Rich multi-clause telemetry readout for the Optical Lens HUD bar & hover inspector (<= 96 chars).
    let fullSummary: String?

    static let empty = LensTelemetry(unreadBadge: nil, shortChip: nil, fullSummary: nil)

    var hasLiveSignal: Bool {
        unreadBadge != nil || shortChip != nil || fullSummary != nil
    }
}

/// Pure, deterministic distiller that converts noisy Accessibility attributes
/// (`AXTitle`, `AXDescription`, `AXValue`, `AXHelp`) into high-signal `LensTelemetry`
/// while stripping redundant app-name headers, version strings, and static shortcut hints.
enum SemanticLensExtractor {

    static func extract(appName: String,
                        bundleID: String,
                        items: [RawAXItemTelemetry]) -> LensTelemetry {
        guard !items.isEmpty else { return .empty }

        var numericCountTotal = 0
        var hasOverflowPlusBadge = false
        var clauses: [String] = []
        var seenNormalized: Set<String> = []

        func appendClause(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !isNoiseOrHeader(trimmed, appName: appName, bundleID: bundleID) else { return }
            let key = normalizeKey(trimmed)
            guard !key.isEmpty, seenNormalized.insert(key).inserted else { return }
            clauses.append(collapseWhitespace(trimmed))
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

        let unreadBadge: String?
        if hasOverflowPlusBadge || numericCountTotal > 99 {
            unreadBadge = "99+"
        } else if numericCountTotal > 0 {
            unreadBadge = "\(numericCountTotal)"
        } else {
            unreadBadge = nil
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
            fullSummary: fullSummary
        )
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

    // MARK: - Line Splitting & Filtering

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isNoiseOrHeader(_ line: String, appName: String, bundleID: String) -> Bool {
        // Pure zero or placeholder identifiers.
        if line == "0" || line == "-" || line == "—" || line == "BarLens.dot" {
            return true
        }
        let lower = line.lowercased()
        if lower == "nsstatusitem" || lower == "menubarextra" || lower.hasPrefix("item-") {
            return true
        }
        // Key with an empty value, e.g. "贴图快捷键:" or "Shortcut: ".
        if line.hasSuffix(":") || line.hasSuffix("：") {
            return true
        }
        // Pure static interaction instructions or shortcut hints rather than live state.
        let staticInstructionMarkers = [
            "快捷键", "shortcut", "单击", "双击", "右键",
            "click:", "right-click", "double-click",
            "打开 ", "open "
        ]
        if staticInstructionMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        // Exact match with bundleID or trailing bundle component (e.g. "Command-X", "Command").
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
        // Command X's status item sets AXTitle="Command" while appName="Command X".
        if !normalizedApp.isEmpty, normalizedLine.count >= 3,
           normalizedApp.hasPrefix(normalizedLine), !line.contains(where: \.isNumber),
           !line.contains(":"), !line.contains("：") {
            return true
        }
        // iStat Menus sets AXDescription="iStat Menus Battery" — strip pure "<AppName> <Module>" labels
        // when they carry no numbers, colons, percentages, or degree symbols.
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

    /// Matches suffixes like "2.5.8", "v1.4.2", "2.11.3 免费版", "Pro", "(Beta)".
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

    /// Strips verbose parenthetical breakdowns for compact chip display, e.g.
    /// `"Today: 180M tokens (12M in · 1.0M out · 167M cached)"` -> `"Today: 180M tokens"`.
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

/// Zero-permission native telemetry reader for built-in macOS system menu bar items.
/// Uses lightweight system APIs (IOKit PowerSources, Carbon TIS, CoreAudio, Foundation)
/// with a short main-thread cache so SwiftUI body evaluations stay instantaneous.
final class SystemTelemetryReader {
    static let shared = SystemTelemetryReader()

    private struct CachedEntry {
        let timestamp: TimeInterval
        let telemetry: LensTelemetry
    }

    private var cache: [String: CachedEntry] = [:]
    private let ttl: TimeInterval = 2.0
    private lazy var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private lazy var fullClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE M/d HH:mm"
        return f
    }()

    func telemetry(for item: SystemItem, fallbackAX: LensTelemetry = .empty) -> LensTelemetry {
        let canonical = SystemItemName.canonicalIdentifier(for: item.identifier)
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = cache[canonical], now - hit.timestamp < ttl {
            return hit.telemetry
        }

        let resolved: LensTelemetry
        switch canonical {
        case "com.apple.menuextra.battery":
            resolved = readBatteryTelemetry() ?? fallbackAX
        case "com.apple.menuextra.textinput":
            resolved = readInputSourceTelemetry() ?? fallbackAX
        case "com.apple.menuextra.sound":
            resolved = readAudioVolumeTelemetry() ?? fallbackAX
        case "com.apple.menuextra.clock":
            let date = Date()
            resolved = LensTelemetry(
                unreadBadge: nil,
                shortChip: clockFormatter.string(from: date),
                fullSummary: fullClockFormatter.string(from: date)
            )
        default:
            resolved = fallbackAX
        }

        cache[canonical] = CachedEntry(timestamp: now, telemetry: resolved)
        return resolved
    }

    private func readBatteryTelemetry() -> LensTelemetry? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return nil
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int else {
                continue
            }
            let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) == true
            let isCharged = (desc[kIOPSIsChargedKey as String] as? Bool) == true
            let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
            let onAC = (powerState == (kIOPSACPowerValue as String))

            let short: String
            let full: String
            if isCharging {
                short = tr("\(capacity)% · 充电中", "\(capacity)% · Charging")
                full = tr("电量 \(capacity)% · 正在充电", "Battery \(capacity)% · Charging")
            } else if isCharged && onAC {
                short = tr("\(capacity)% · 已满", "\(capacity)% · Full")
                full = tr("电量 \(capacity)% · 外接电源已充满", "Battery \(capacity)% · Charged on AC")
            } else if onAC {
                short = tr("\(capacity)% · 电源", "\(capacity)% · AC")
                full = tr("电量 \(capacity)% · 使用外接电源", "Battery \(capacity)% · On AC Power")
            } else {
                short = "\(capacity)%"
                full = tr("电量 \(capacity)% · 使用电池", "Battery \(capacity)% · On Battery")
            }
            return LensTelemetry(unreadBadge: nil, shortChip: short, fullSummary: full)
        }
        return nil
    }

    private func readInputSourceTelemetry() -> LensTelemetry? {
        let fetch: () -> String? = {
            guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let ptr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else {
                return nil
            }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        let rawName: String? = Thread.isMainThread ? fetch() : DispatchQueue.main.sync(execute: fetch)
        guard let rawName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            return nil
        }
        let compact = rawName
            .replacingOccurrences(of: "Pinyin – Simplified", with: tr("简体拼音", "Pinyin"))
            .replacingOccurrences(of: "Pinyin - Simplified", with: tr("简体拼音", "Pinyin"))
            .replacingOccurrences(of: "Shuangpin – Simplified", with: tr("简体双拼", "Shuangpin"))
        return LensTelemetry(
            unreadBadge: nil,
            shortChip: compact.count > 16 ? String(compact.prefix(15)) + "…" : compact,
            fullSummary: tr("当前输入法：\(compact)", "Input Source: \(compact)")
        )
    }

    private func readAudioVolumeTelemetry() -> LensTelemetry? {
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

        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMute = AudioObjectGetPropertyData(devID, &muteAddr, 0, nil, &muteSize, &mute) == noErr

        var volume: Float32 = -1
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasVol = AudioObjectGetPropertyData(devID, &volAddr, 0, nil, &volSize, &volume) == noErr

        if hasMute && mute != 0 {
            return LensTelemetry(
                unreadBadge: nil,
                shortChip: tr("静音", "Muted"),
                fullSummary: tr("系统音量：已静音", "Output Volume: Muted")
            )
        }
        if hasVol, volume >= 0 {
            let pct = Int((min(max(volume, 0), 1) * 100).rounded())
            if pct == 0 {
                return LensTelemetry(
                    unreadBadge: nil,
                    shortChip: tr("静音", "Muted"),
                    fullSummary: tr("系统音量：0%", "Output Volume: 0%")
                )
            }
            return LensTelemetry(
                unreadBadge: nil,
                shortChip: "\(pct)%",
                fullSummary: tr("系统音量：\(pct)%", "Output Volume: \(pct)%")
            )
        }
        return nil
    }
}
