import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - 1. Usage Auto-Decay (使用热度自沉淀)

/// Inactivity window after which an unpinned `.visible` third-party menu bar icon
/// automatically settles into `.hidden` so newly installed background daemons
/// do not permanently clutter the top menu bar.
enum UsageDecayPolicy: String, CaseIterable, Identifiable, Codable {
    case off    = "off"
    case days3  = "days3"
    case days7  = "days7"
    case days14 = "days14"
    case days30 = "days30"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return tr("关闭", "Off")
        case .days3:  return tr("闲置 3 天后", "After 3 Idle Days")
        case .days7:  return tr("闲置 7 天后", "After 7 Idle Days")
        case .days14: return tr("闲置 14 天后", "After 14 Idle Days")
        case .days30: return tr("闲置 30 天后", "After 30 Idle Days")
        }
    }

    var shortTitle: String {
        switch self {
        case .off:    return tr("关闭", "Off")
        case .days3:  return tr("3 天", "3 Days")
        case .days7:  return tr("7 天", "7 Days")
        case .days14: return tr("14 天", "14 Days")
        case .days30: return tr("30 天", "30 Days")
        }
    }

    var thresholdDays: Int? {
        switch self {
        case .off:    return nil
        case .days3:  return 3
        case .days7:  return 7
        case .days14: return 14
        case .days30: return 30
        }
    }

    var thresholdSeconds: TimeInterval? {
        thresholdDays.map { TimeInterval($0) * 86_400.0 }
    }
}

struct UsageDecayCandidate: Equatable {
    let bundleID: String
    /// Unified "Pin to Top Bar" exemption (`spatialExemptBundleIDs`).
    let isPinnedExempt: Bool
    /// Epoch timestamp when BarLens first observed this app on the menu bar.
    let firstSeenAt: TimeInterval
    /// Epoch timestamp of the user's most recent interaction (top bar or Lens), or `0` if untouched.
    let lastInteractedAt: TimeInterval
}

enum UsageDecayPlanner {
    /// Effective reference timestamp from which idle time is measured.
    /// Guarantees newly discovered apps and newly enabled policies always grant
    /// a full observation grace window before any automatic demotion occurs.
    static func referenceTimestamp(for candidate: UsageDecayCandidate,
                                   policyBaselineAt: TimeInterval) -> TimeInterval {
        max(candidate.firstSeenAt, max(policyBaselineAt, candidate.lastInteractedAt))
    }

    /// Evaluates which `.visible` candidates have exceeded the configured inactivity window.
    static func evaluate(policy: UsageDecayPolicy,
                         candidates: [UsageDecayCandidate],
                         policyBaselineAt: TimeInterval,
                         now: TimeInterval) -> Set<String> {
        guard let threshold = policy.thresholdSeconds, threshold > 0 else { return [] }
        var decayed: Set<String> = []
        for candidate in candidates where !candidate.isPinnedExempt {
            let anchor = referenceTimestamp(for: candidate, policyBaselineAt: policyBaselineAt)
            guard anchor > 0, now - anchor >= threshold else { continue }
            decayed.insert(candidate.bundleID)
        }
        return decayed
    }

    /// Human-readable activity freshness badge for Settings inspection rows.
    static func activityBadgeText(lastInteractedAt: TimeInterval,
                                  firstSeenAt: TimeInterval,
                                  isPinnedExempt: Bool,
                                  policy: UsageDecayPolicy,
                                  policyBaselineAt: TimeInterval,
                                  now: TimeInterval) -> String {
        if isPinnedExempt {
            return tr("已锁常驻", "Pinned")
        }
        if lastInteractedAt > 0 {
            let elapsed = max(0, now - lastInteractedAt)
            if elapsed < 120 {
                return tr("刚刚使用", "Active just now")
            } else if elapsed < 3600 {
                let mins = max(1, Int(elapsed / 60))
                return tr("\(mins) 分钟前", "\(mins)m ago")
            } else if elapsed < 86_400 {
                let hours = max(1, Int(elapsed / 3600))
                return tr("\(hours) 小时前", "\(hours)h ago")
            } else {
                let days = max(1, Int(elapsed / 86_400))
                return tr("闲置 \(days) 天", "Idle \(days)d")
            }
        }
        if let threshold = policy.thresholdSeconds {
            let candidate = UsageDecayCandidate(
                bundleID: "",
                isPinnedExempt: false,
                firstSeenAt: firstSeenAt,
                lastInteractedAt: 0
            )
            let anchor = referenceTimestamp(for: candidate, policyBaselineAt: policyBaselineAt)
            if anchor > 0 {
                let remaining = max(0, threshold - (now - anchor))
                let daysLeft = max(1, Int(ceil(remaining / 86_400.0)))
                return tr("观察期剩 \(daysLeft) 天", "Grace \(daysLeft)d left")
            }
        }
        return tr("暂未点击", "Untouched")
    }
}

/// Passive coordinate matcher that maps a native mouse click in the macOS top menu bar
/// to the owning application's `bundleID` using the latest cached AX scan snapshot,
/// avoiding any synchronous AX IPC on mouse-down.
enum TopBarClickTracker {
    struct ScreenDescriptor: Equatable {
        let displayID: DisplayID
        /// Screen frame in AppKit global bottom-left coordinates (`NSScreen.frame`).
        let appKitFrame: CGRect
        /// Quartz / Accessibility top-left coordinate frame (`CGDisplayBounds`).
        let cgBounds: CGRect
    }

    static func matchedOwnerBundleID(appKitClickPoint: CGPoint,
                                     screens: [ScreenDescriptor],
                                     items: [MenuBarItem],
                                     ownIdentifiers: Set<String>,
                                     notClassifiable: Set<String>) -> String? {
        guard !items.isEmpty else { return nil }
        guard let screen = screens.first(where: { $0.appKitFrame.contains(appKitClickPoint) }) else {
            return nil
        }
        // Only consider clicks inside the top 42pt menu bar band of this screen.
        let distanceFromTop = screen.appKitFrame.maxY - appKitClickPoint.y
        guard distanceFromTop >= -2, distanceFromTop <= 42 else { return nil }

        // Convert AppKit (bottom-left) point into Quartz/AX (top-left) coordinates on the same display.
        let cgPoint = CGPoint(
            x: screen.cgBounds.minX + (appKitClickPoint.x - screen.appKitFrame.minX),
            y: screen.cgBounds.minY + distanceFromTop
        )

        for item in items where item.display == screen.displayID {
            guard !ownIdentifiers.contains(item.ownerBundleID),
                  !notClassifiable.contains(item.ownerBundleID) else { continue }
            let hitRect = item.frame.insetBy(dx: -2, dy: -4)
            if hitRect.contains(cgPoint) {
                return item.ownerBundleID
            }
        }
        return nil
    }
}

// MARK: - 2. Zero-Capture Status Bubble-Up (隐藏项状态突变冒泡)

/// How BarLens surfaces meaningful semantic state transitions from hidden applications
/// without requiring Screen Recording permission.
enum StatusBubbleMode: String, CaseIterable, Identifiable, Codable {
    case off           = "off"
    case dotPulse      = "dotPulse"
    case surfaceTopBar = "surfaceTopBar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:           return tr("关闭", "Off")
        case .dotPulse:      return tr("仅圆点微光", "Dot Badge Only")
        case .surfaceTopBar: return tr("顶栏临时浮现", "Surface on Top Bar")
        }
    }

    var shortTitle: String {
        switch self {
        case .off:           return tr("关闭", "Off")
        case .dotPulse:      return tr("圆点微光", "Dot Badge")
        case .surfaceTopBar: return tr("顶栏浮现", "Surface")
        }
    }
}

/// User-centric dwell & retraction policy for surfaced status bubbles.
enum StatusBubbleDwell: String, CaseIterable, Identifiable, Codable {
    /// Unread counts & warning alerts stay until handled (clicked, app focused, or condition cleared,
    /// with a 15-minute ceiling); calm state flips peek for 10 seconds and auto-retract.
    case smart        = "smart"
    case seconds6     = "6s"
    case seconds15    = "15s"
    case seconds30    = "30s"
    case untilHandled = "untilHandled"

    var id: String { rawValue }

    static let smartActionableCeiling: TimeInterval = 15 * 60
    static let untilHandledCeiling: TimeInterval = 12 * 3600
    static let postInteractionRetractDelay: TimeInterval = 2.2
    static let postAppFocusRetractDelay: TimeInterval = 3.0

    var title: String {
        switch self {
        case .smart:        return tr("智能驻留", "Smart Dwell")
        case .seconds6:     return tr("6 秒", "6 Seconds")
        case .seconds15:    return tr("15 秒", "15 Seconds")
        case .seconds30:    return tr("30 秒", "30 Seconds")
        case .untilHandled: return tr("直至处理", "Until Handled")
        }
    }

    var shortTitle: String {
        switch self {
        case .smart:        return tr("智能驻留", "Smart")
        case .seconds6:     return tr("6 秒", "6s")
        case .seconds15:    return tr("15 秒", "15s")
        case .seconds30:    return tr("30 秒", "30s")
        case .untilHandled: return tr("直至处理", "Until Handled")
        }
    }

    func detailDescription(for mode: StatusBubbleMode) -> String {
        let isSurface = (mode == .surfaceTopBar)
        switch self {
        case .smart:
            return isSurface
                ? tr("未读与告警保留至处理，普通状态切换 10 秒后自动收起",
                     "Unread & alerts stay until handled; state flips auto-tuck after 10s")
                : tr("未读与告警保持微光至处理，状态切换 10 秒后自动消退",
                     "Unread & alerts keep badge until handled; state flips clear after 10s")
        case .seconds6:
            return isSurface
                ? tr("浮现 6 秒后收起；点击提前收起，移向顶栏暂停计时",
                     "Auto-tucks after 6s; retracts early on click, pauses while hovering bar")
                : tr("微光提示 6 秒后消退；切入应用或恢复正常时提前清除",
                     "Clears badge after 6s, or earlier once focused or resolved")
        case .seconds15:
            return isSurface
                ? tr("浮现 15 秒后收起；点击提前收起，移向顶栏暂停计时",
                     "Auto-tucks after 15s; retracts early on click, pauses while hovering bar")
                : tr("微光提示 15 秒后消退；切入应用或恢复正常时提前清除",
                     "Clears badge after 15s, or earlier once focused or resolved")
        case .seconds30:
            return isSurface
                ? tr("浮现 30 秒后收起；点击提前收起，移向顶栏暂停计时",
                     "Auto-tucks after 30s; retracts early on click, pauses while hovering bar")
                : tr("微光提示 30 秒后消退；切入应用或恢复正常时提前清除",
                     "Clears badge after 30s, or earlier once focused or resolved")
        case .untilHandled:
            return tr("持续保留提醒，直到点击图标、切入应用或状态恢复正常",
                      "Stays active until clicked, app-focused, or unread/alert clears")
        }
    }

    func awaitsUserHandling(for reason: StatusBubbleReason) -> Bool {
        switch self {
        case .smart:
            switch reason {
            case .unreadIncreased, .warningAlert: return true
            case .stateChanged:                   return false
            }
        case .untilHandled:
            return true
        case .seconds6, .seconds15, .seconds30:
            return false
        }
    }

    func initialDuration(for reason: StatusBubbleReason) -> TimeInterval {
        switch self {
        case .smart:
            switch reason {
            case .unreadIncreased, .warningAlert: return Self.smartActionableCeiling
            case .stateChanged:                   return 10.0
            }
        case .seconds6:     return 6.0
        case .seconds15:    return 15.0
        case .seconds30:    return 30.0
        case .untilHandled: return Self.untilHandledCeiling
        }
    }
}

enum StatusBubbleReason: Equatable {
    case unreadIncreased(badge: String)
    case warningAlert(summary: String)
    case stateChanged(summary: String)

    var badgeText: String {
        switch self {
        case .unreadIncreased(let badge):
            return tr("新未读 \(badge)", "New Unread \(badge)")
        case .warningAlert(let summary):
            return summary.isEmpty ? tr("状态异常", "Alert") : summary
        case .stateChanged(let summary):
            return summary.isEmpty ? tr("状态更新", "Updated") : summary
        }
    }

    var tone: SemanticTone {
        switch self {
        case .unreadIncreased, .warningAlert:
            return .orange
        case .stateChanged:
            return .cyan
        }
    }
}

struct StatusBubbleEvent: Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let reason: StatusBubbleReason
    let triggeredAt: TimeInterval
    var expiresAt: TimeInterval
    var awaitsHandling: Bool = false
    var wasHandled: Bool = false
}

/// Distilled semantic snapshot of one hidden application used for noise-resistant transition diffing.
struct ObservedSemanticSnapshot: Equatable {
    let unreadCount: Int
    let unreadOverflow: Bool
    let statusTone: LensFactRow.ValueTone
    /// Discrete state token with volatile numbers, rates, units, and timestamps stripped out.
    let discreteStateSignature: String?
    /// Concise human-readable summary to surface when a discrete transition fires.
    let displaySummary: String?
}

/// Stateful, deterministic zero-capture event detector with startup grace, per-app cooldown,
/// and a rolling chatter damper that suppresses scrolling lyrics, stock tickers, and rate meters.
struct StatusBubbleTracker {
    /// Duration an icon remains temporarily surfaced on the top menu bar (or highlighted).
    static let defaultBubbleDuration: TimeInterval = 8.0
    /// Minimum interval between discrete state-change bubbles for the same application.
    static let stateChangeCooldown: TimeInterval = 22.0
    /// Sliding window used to detect streaming text tickers (e.g. scrolling music lyrics).
    static let chatterWindowSeconds: TimeInterval = 36.0
    /// Maximum discrete text mutations allowed inside `chatterWindowSeconds` before muting text diffs.
    static let maxMutationsBeforeChatterMute: Int = 2
    /// Rolling window used to suppress background `A <-> B` ping-pong state oscillations without user interaction.
    static let pingPongWindowSeconds: TimeInterval = 240.0
    /// Maximum unhandled `.stateChanged` surface bubbles allowed inside `pingPongWindowSeconds`.
    static let maxUnhandledStateBubblesPerWindow: Int = 2

    private(set) var baselines: [String: ObservedSemanticSnapshot] = [:]
    private var recentTextChangeTimes: [String: [TimeInterval]] = [:]
    private var recentSeenStateSignatures: [String: [String: TimeInterval]] = [:]
    private var recentStateBubbleTimes: [String: [TimeInterval]] = [:]
    private var lastBubbledAt: [String: TimeInterval] = [:]

    mutating func reset() {
        baselines.removeAll()
        recentTextChangeTimes.removeAll()
        recentSeenStateSignatures.removeAll()
        recentStateBubbleTimes.removeAll()
        lastBubbledAt.removeAll()
    }

    mutating func removeOwner(_ bundleID: String) {
        baselines.removeValue(forKey: bundleID)
        recentTextChangeTimes.removeValue(forKey: bundleID)
        recentSeenStateSignatures.removeValue(forKey: bundleID)
        recentStateBubbleTimes.removeValue(forKey: bundleID)
        lastBubbledAt.removeValue(forKey: bundleID)
    }

    /// Clears state-flip ping-pong suppression for `bundleID` when the user actively interacts with it.
    mutating func noteUserInteraction(_ bundleID: String) {
        recentSeenStateSignatures.removeValue(forKey: bundleID)
        recentStateBubbleTimes.removeValue(forKey: bundleID)
        if let currentSig = baselines[bundleID]?.discreteStateSignature {
            recentSeenStateSignatures[bundleID] = [currentSig: Date().timeIntervalSince1970]
        }
    }

    /// Builds a noise-filtered semantic snapshot from `LensTelemetry`.
    static func snapshot(from telemetry: LensTelemetry,
                         categoryType: String? = nil) -> ObservedSemanticSnapshot {
        let count: Int
        let overflow: Bool
        if let badge = telemetry.unreadBadge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
            overflow = badge.contains("+")
            let digits = badge.filter(\.isNumber)
            count = Int(digits) ?? (overflow ? 99 : 0)
        } else {
            count = 0
            overflow = false
        }

        let hasMediaPlayback: Bool = {
            if case .mediaPlayback = telemetry.interactiveControl { return true }
            return false
        }()

        // Media & music players often stream lyrics or track titles in the menu bar;
        // suppress text-diff bubbling for music apps while still allowing warning/unread signals.
        let isMediaApp = categoryType == "public.app-category.music"
            || categoryType == "public.app-category.entertainment"
            || hasMediaPlayback

        let resolvedTone: LensFactRow.ValueTone
        if telemetry.rows.contains(where: { $0.tone == .warning }) {
            resolvedTone = .warning
        } else if telemetry.rows.contains(where: { $0.tone == .active }) {
            resolvedTone = .active
        } else if telemetry.rows.contains(where: { $0.tone == .accent }) {
            resolvedTone = .accent
        } else {
            resolvedTone = .neutral
        }

        let warningRowText = telemetry.rows.first(where: { $0.tone == .warning })?.value
        let candidateSummary = warningRowText ?? telemetry.shortChip ?? telemetry.fullSummary
        let signature: String? = isMediaApp
            ? nil
            : normalizeDiscreteState(candidateSummary)

        return ObservedSemanticSnapshot(
            unreadCount: count,
            unreadOverflow: overflow,
            statusTone: resolvedTone,
            discreteStateSignature: signature,
            displaySummary: candidateSummary
        )
    }

    /// Strips volatile digits, transfer rates, percentages, temperatures, currency amounts,
    /// and clock tokens. Returns `nil` when the input is purely a continuous numeric meter
    /// (such as `"↑ 1.4 MB/s"`, `"CPU 24%"`, `"274M tokens"`, `"Wed 9:41 AM"`).
    static func normalizeDiscreteState(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }

        let lower = trimmed.lowercased()
        let continuousUnitMarkers = [
            "kb/s", "mb/s", "gb/s", "b/s", "kbps", "mbps", "gbps",
            "tokens", "requests", "rpm", "tpm", "fps", "ghz", "mhz",
            "mah", "wh", "°c", "°f", "↑", "↓"
        ]
        if continuousUnitMarkers.contains(where: { lower.contains($0) }) {
            return nil
        }

        // Remove digits and numeric punctuation; inspect whether meaningful words remain.
        var strippedScalars: [UnicodeScalar] = []
        let strippedPunctuation = CharacterSet(charactersIn: "0123456789.,:%$¥€£+-~≈/\\|()[]•·")
        for scalar in lower.unicodeScalars {
            if strippedPunctuation.contains(scalar) {
                strippedScalars.append(" ")
            } else {
                strippedScalars.append(scalar)
            }
        }
        let collapsed = String(String.UnicodeScalarView(strippedScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        // Reject pure clock/weekday tokens or strings that had digits and left <= 2 letters.
        let clockWords: Set<String> = [
            "am", "pm", "mon", "tue", "wed", "thu", "fri", "sat", "sun",
            "周一", "周二", "周三", "周四", "周五", "周六", "周日",
            "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"
        ]
        let remainingTokens = collapsed.split(separator: " ").map(String.init)
        let nonClockTokens = remainingTokens.filter { !clockWords.contains($0) }
        guard !nonClockTokens.isEmpty else { return nil }

        let meaningfulText = nonClockTokens.joined(separator: " ")
        let hasDigitsInOriginal = trimmed.contains(where: \.isNumber)
        if hasDigitsInOriginal && meaningfulText.count < 3 {
            return nil
        }
        return meaningfulText
    }

    /// Evaluates a fresh observation for one hidden app.
    /// First observation always establishes a silent baseline without bubbling.
    mutating func observe(bundleID: String,
                          appName: String,
                          snapshot: ObservedSemanticSnapshot,
                          allowBubbling: Bool,
                          now: TimeInterval,
                          dwell: StatusBubbleDwell = .smart,
                          duration: TimeInterval? = nil) -> StatusBubbleEvent? {
        guard let previous = baselines[bundleID] else {
            baselines[bundleID] = snapshot
            if let sig = snapshot.discreteStateSignature {
                recentSeenStateSignatures[bundleID] = [sig: now]
            }
            return nil
        }
        baselines[bundleID] = snapshot

        // Track rolling text-signature mutations even if bubbling is temporarily suppressed,
        // so streaming lyric/quote tickers are recognized immediately.
        var isChatteringTicker = false
        if previous.discreteStateSignature != snapshot.discreteStateSignature {
            var history = (recentTextChangeTimes[bundleID] ?? []).filter {
                now - $0 <= Self.chatterWindowSeconds
            }
            if history.count >= Self.maxMutationsBeforeChatterMute {
                isChatteringTicker = true
            }
            history.append(now)
            recentTextChangeTimes[bundleID] = history
        }

        guard allowBubbling else { return nil }

        func makeEvent(reason: StatusBubbleReason) -> StatusBubbleEvent {
            let resolvedDuration = duration ?? dwell.initialDuration(for: reason)
            let awaiting = (duration == nil) && dwell.awaitsUserHandling(for: reason)
            return StatusBubbleEvent(
                bundleID: bundleID,
                appName: appName,
                reason: reason,
                triggeredAt: now,
                expiresAt: now + resolvedDuration,
                awaitsHandling: awaiting,
                wasHandled: false
            )
        }

        // Priority 1: Unread badge increased (e.g. 0 -> 2, 2 -> 5, or newly entered 99+ overflow).
        let unreadGrew = (snapshot.unreadOverflow && !previous.unreadOverflow)
            || (snapshot.unreadCount > previous.unreadCount)
        if unreadGrew {
            let badge = snapshot.unreadOverflow ? "99+" : "\(max(1, snapshot.unreadCount))"
            lastBubbledAt[bundleID] = now
            return makeEvent(reason: .unreadIncreased(badge: badge))
        }

        // Priority 2: Semantic tone escalated into `.warning` (e.g. Disconnected, Error, Sync Failed).
        if snapshot.statusTone == .warning && previous.statusTone != .warning {
            let lastFire = lastBubbledAt[bundleID] ?? 0
            if now - lastFire >= 8.0 {
                lastBubbledAt[bundleID] = now
                return makeEvent(reason: .warningAlert(summary: snapshot.displaySummary ?? ""))
            }
        }

        // Priority 3: Calm, non-chattering discrete state flip (e.g. Proxy Off -> On, Idle -> Recording).
        if !isChatteringTicker,
           let prevSig = previous.discreteStateSignature,
           let nextSig = snapshot.discreteStateSignature,
           prevSig != nextSig {
            var seenMap = (recentSeenStateSignatures[bundleID] ?? [:]).filter {
                now - $0.value <= Self.pingPongWindowSeconds
            }
            seenMap[prevSig] = seenMap[prevSig] ?? now
            let wasRecentlySeen = (seenMap[nextSig] != nil)
            seenMap[nextSig] = now
            recentSeenStateSignatures[bundleID] = seenMap

            let stateHistory = (recentStateBubbleTimes[bundleID] ?? []).filter {
                now - $0 <= Self.pingPongWindowSeconds
            }
            recentStateBubbleTimes[bundleID] = stateHistory

            let lastFire = lastBubbledAt[bundleID] ?? 0
            if !wasRecentlySeen,
               stateHistory.count < Self.maxUnhandledStateBubblesPerWindow,
               now - lastFire >= Self.stateChangeCooldown {
                lastBubbledAt[bundleID] = now
                recentStateBubbleTimes[bundleID, default: []].append(now)
                return makeEvent(reason: .stateChanged(summary: snapshot.displaySummary ?? ""))
            }
        }

        return nil
    }
}

// MARK: - 3. Presentation & Mirroring Shield (投屏 / 镜像净空盾)

/// Controls which `.visible` third-party icons are swept behind the Lens while Presentation Shield is active.
enum PresentationShieldPolicy: String, CaseIterable, Identifiable, Codable {
    case allThirdParty  = "allThirdParty"
    case keepPinnedOnly = "keepPinnedOnly"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allThirdParty:  return tr("隐藏全部第三方", "All Third-Party")
        case .keepPinnedOnly: return tr("仅留锁定常驻", "Keep Pinned Only")
        }
    }

    var shortTitle: String {
        switch self {
        case .allThirdParty:  return tr("全部第三方", "All 3rd-Party")
        case .keepPinnedOnly: return tr("仅留常驻锁定", "Pinned Only")
        }
    }
}

enum PresentationShieldEvaluator {
    /// Computes the set of `.visible` third-party `bundleID`s temporarily hidden by Presentation Shield.
    /// Never mutates stored section assignments; releasing the shield restores the exact prior bar.
    static func shieldedBundleIDs(isActive: Bool,
                                  policy: PresentationShieldPolicy,
                                  visibleThirdPartyCandidates: Set<String>,
                                  pinnedExempt: Set<String>) -> Set<String> {
        guard isActive, !visibleThirdPartyCandidates.isEmpty else { return [] }
        switch policy {
        case .allThirdParty:
            return visibleThirdPartyCandidates
        case .keepPinnedOnly:
            return visibleThirdPartyCandidates.subtracting(pinnedExempt)
        }
    }
}

enum ScreenPresentationSource: String, Equatable {
    case hardwareMirror      = "hardwareMirror"
    case softwareScreenShare = "softwareScreenShare"

    var badgeText: String {
        switch self {
        case .hardwareMirror:      return tr("镜像中", "Mirrored")
        case .softwareScreenShare: return tr("共享屏幕中", "Screen Sharing")
        }
    }
}

struct ReplaydTelemetrySample: Equatable {
    let timestamp: TimeInterval
    let pid: pid_t
    let cpuNanoseconds: UInt64
    let machSyscalls: Int32
    let contextSwitches: Int32

    /// Detects active `ScreenCaptureKit` (`SCStream`) delivery through `/usr/libexec/replayd`.
    /// Idle `replayd` (even during active voice/video calls) sits below `0.1` Mach syscalls/s
    /// and `< 0.001%` CPU, whereas any active full-screen or single-window `SCStream` drives
    /// continuous frame/idle status IPC well above `30` Mach syscalls/s or `0.15%` CPU.
    static func isStreamingDelta(from previous: ReplaydTelemetrySample,
                                 to current: ReplaydTelemetrySample) -> Bool {
        guard previous.pid == current.pid else { return false }
        let dt = current.timestamp - previous.timestamp
        guard dt >= 0.20, dt <= 10.0 else { return false }

        let cpuDelta = current.cpuNanoseconds >= previous.cpuNanoseconds
            ? (current.cpuNanoseconds - previous.cpuNanoseconds)
            : 0
        let machDelta = current.machSyscalls >= previous.machSyscalls
            ? Int64(current.machSyscalls) - Int64(previous.machSyscalls)
            : 0
        let cswDelta = current.contextSwitches >= previous.contextSwitches
            ? Int64(current.contextSwitches) - Int64(previous.contextSwitches)
            : 0

        let cpuPerSec = Double(cpuDelta) / dt
        let machPerSec = Double(machDelta) / dt
        let cswPerSec = Double(cswDelta) / dt

        return cpuPerSec >= 2_500_000.0 || (machPerSec >= 50.0 && cswPerSec >= 30.0)
    }
}

struct ScreenShareObservation: Equatable {
    var isHardwareMirrored: Bool
    var isScreenWatcherActive: Bool
    var isReplaydStreaming: Bool
    var hasMenuBarIndicator: Bool

    var isActivelyCapturing: Bool {
        isScreenWatcherActive || isReplaydStreaming
    }

    var isSoftwareSharingCandidate: Bool {
        isActivelyCapturing || hasMenuBarIndicator
    }
}

/// Debounces OS-level screen-sharing & mirroring signals with dual-track confirmation:
/// - Hardware HDMI / AirPlay mirroring engages immediately (`1` sample).
/// - Authoritative Indicator Fast-Path (`~0.55s – 0.80s`): when active stream capture
///   (`replayd` / `WindowServer`) coincides with `MenuBarAgent`'s active sharing pill
///   (`"当前正在共享"` / `"Currently Sharing"`, which `replayd` only publishes via
///   `RPClientProxy` on `startCapture` and never on window-picker `approveOnScreenshot`),
///   shield engages after `indicatorFastPathTicks` (`2` fast samples).
/// - Universal Stream Fallback (`~1.85s`): when the menu bar pill is suppressed or unavailable,
///   unbroken high-cadence (`0.25s`) capture across `activationConfirmationTicks` (`7` samples)
///   AND `minimumSustainedDuration` (`1.85s`) engages cleanly while rejecting `< 1.5s` bursts
///   from conferencing app startup preflights, "Start Share" picker thumbnails, and screenshots.
/// - Static-Window Hold & Smooth Release: once active, `hasMenuBarIndicator` keeps the shield
///   steady even on 0-fps static slides, and stopping share releases after `releaseGraceTicks` (`~1.65s`).
struct ScreenShareSessionMonitor {
    let activationConfirmationTicks: Int
    let indicatorFastPathTicks: Int
    let releaseGraceTicks: Int
    let minSampleInterval: TimeInterval
    let minimumSustainedDuration: TimeInterval

    private(set) var activeSource: ScreenPresentationSource?
    private var previousReplaydSample: ReplaydTelemetrySample?
    private var lastReplaydStreaming: Bool = false
    private var lastSoftwareStepAt: TimeInterval?
    private var candidateStartedAt: TimeInterval?
    private var softwarePositiveStreak: Int = 0
    private var softwareInactiveStreak: Int = 0

    var hasPendingCandidate: Bool {
        activeSource == nil && softwarePositiveStreak > 0
    }

    init(activationConfirmationTicks: Int = 7,
         indicatorFastPathTicks: Int = 2,
         releaseGraceTicks: Int = 3,
         minSampleInterval: TimeInterval = 0.20,
         minimumSustainedDuration: TimeInterval = 1.85) {
        self.activationConfirmationTicks = max(1, activationConfirmationTicks)
        self.indicatorFastPathTicks = max(1, indicatorFastPathTicks)
        self.releaseGraceTicks = max(1, releaseGraceTicks)
        self.minSampleInterval = max(0.1, minSampleInterval)
        self.minimumSustainedDuration = max(0, minimumSustainedDuration)
    }

    mutating func reset() {
        activeSource = nil
        previousReplaydSample = nil
        lastReplaydStreaming = false
        lastSoftwareStepAt = nil
        candidateStartedAt = nil
        softwarePositiveStreak = 0
        softwareInactiveStreak = 0
    }

    mutating func ingestReplaydSample(_ sample: ReplaydTelemetrySample?) -> Bool {
        guard let curr = sample else {
            previousReplaydSample = nil
            lastReplaydStreaming = false
            return false
        }
        guard let prev = previousReplaydSample, prev.pid == curr.pid else {
            previousReplaydSample = curr
            lastReplaydStreaming = false
            return false
        }
        let dt = curr.timestamp - prev.timestamp
        if dt >= 0 && dt < minSampleInterval {
            return lastReplaydStreaming
        }
        let streaming = ReplaydTelemetrySample.isStreamingDelta(from: prev, to: curr)
        previousReplaydSample = curr
        lastReplaydStreaming = streaming
        return streaming
    }

    @discardableResult
    mutating func update(with observation: ScreenShareObservation,
                         now: TimeInterval? = nil) -> ScreenPresentationSource? {
        if observation.isHardwareMirrored {
            softwarePositiveStreak = 0
            softwareInactiveStreak = 0
            candidateStartedAt = nil
            lastSoftwareStepAt = now
            activeSource = .hardwareMirror
            return activeSource
        }

        if let now, let lastAt = lastSoftwareStepAt, now >= lastAt, (now - lastAt) < minSampleInterval {
            if activeSource == .hardwareMirror {
                activeSource = observation.isSoftwareSharingCandidate ? .softwareScreenShare : nil
            } else if activeSource == nil,
                      observation.isActivelyCapturing,
                      observation.hasMenuBarIndicator,
                      softwarePositiveStreak >= indicatorFastPathTicks {
                activeSource = .softwareScreenShare
            }
            return activeSource
        }
        lastSoftwareStepAt = now

        if activeSource == .softwareScreenShare {
            if observation.isSoftwareSharingCandidate {
                softwareInactiveStreak = 0
                return activeSource
            }
            softwarePositiveStreak = 0
            candidateStartedAt = nil
            softwareInactiveStreak += 1
            if softwareInactiveStreak >= releaseGraceTicks {
                softwareInactiveStreak = 0
                activeSource = nil
            }
            return activeSource
        }

        if observation.isActivelyCapturing {
            softwareInactiveStreak = 0
            if softwarePositiveStreak == 0 {
                candidateStartedAt = now
            }
            softwarePositiveStreak += 1
            let metFastPath = observation.hasMenuBarIndicator
                && softwarePositiveStreak >= indicatorFastPathTicks
            let metDuration: Bool
            if minimumSustainedDuration <= 0 {
                metDuration = true
            } else if let now, let started = candidateStartedAt {
                metDuration = (now - started) >= minimumSustainedDuration
            } else {
                metDuration = softwarePositiveStreak >= activationConfirmationTicks
            }
            if metFastPath || (softwarePositiveStreak >= activationConfirmationTicks && metDuration) {
                activeSource = .softwareScreenShare
            } else if activeSource == .hardwareMirror {
                activeSource = .softwareScreenShare
            }
            return activeSource
        }

        softwarePositiveStreak = 0
        candidateStartedAt = nil
        softwareInactiveStreak = 0
        if activeSource == .hardwareMirror {
            activeSource = observation.hasMenuBarIndicator ? .softwareScreenShare : nil
        }
        return activeSource
    }
}

enum DisplayMirrorDetector {
    private static let screenWatcherFn: (@convention(c) () -> Bool)? = {
        let paths = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        ]
        let symbols = ["CGSIsScreenWatcherPresent", "SLSIsScreenWatcherPresent"]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            for sym in symbols {
                if let ptr = dlsym(handle, sym) {
                    return unsafeBitCast(ptr, to: (@convention(c) () -> Bool).self)
                }
            }
        }
        return nil
    }()

    private static let localizedScreenSharePhrases: [String] = {
        var phrases: Set<String> = [
            "currently sharing",
            "content sharing",
            "is capturing your screen",
            "currently being shared",
            "viewing my screen",
            "当前正在共享",
            "内容共享",
            "正在捕捉你的屏幕",
            "当前正被共享",
            "正在观看我的屏幕",
        ]
        if let bundle = Bundle(path: "/System/Library/CoreServices/ControlCenter.app") {
            // Deliberately exclude `SensorIndicators` ("录屏" / "Screen Recording"), which
            // `STMediaStatusDomainPublisher` lights up on one-shot `CGWindowListCreateImage`
            // screenshots (such as opening a share-picker grid) and lingers for ~15s.
            // Only match active session strings published via `RPClientProxy` (`AudioVideo*` / `FaceTime`).
            let queries: [(table: String, keys: [String])] = [
                ("AudioVideoLiveActivities", ["Currently Sharing", "Content Sharing", "%@ is capturing your screen."]),
                ("AudioVideo", ["Currently Sharing", "%@ is capturing your screen."]),
                ("FaceTime", ["Currently Sharing", "Currently Being Shared", "Viewing My Screen"]),
            ]
            for query in queries {
                for key in query.keys {
                    let localized = bundle.localizedString(forKey: key, value: key, table: query.table)
                        .replacingOccurrences(of: "%[tt]@", with: "")
                        .replacingOccurrences(of: "%@", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if localized.count >= 2 {
                        phrases.insert(localized)
                    }
                }
            }
        }
        return Array(phrases)
    }()

    /// Returns `true` when any active display is currently participating in hardware screen mirroring,
    /// projector mirroring, or AirPlay / Sidecar mirrored presentation.
    static func isAnyDisplayMirrored() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
        }
        for i in 0..<Int(displayCount) {
            if CGDisplayIsInMirrorSet(displays[i]) != 0 {
                return true
            }
        }
        return false
    }

    /// Queries WindowServer (`CGSIsScreenWatcherPresent` / `SLSIsScreenWatcherPresent`) without
    /// requiring Screen Recording permission. Returns `true` during `CGDisplayStream` / display-watcher sharing.
    static func isWindowServerScreenWatcherActive() -> Bool {
        screenWatcherFn?() ?? false
    }

    /// Samples `/usr/libexec/replayd` (`ScreenCaptureKit` system daemon for the current user) via `<libproc.h>`.
    static func sampleReplaydTelemetry(now: TimeInterval = Date().timeIntervalSince1970,
                                       cachedPID: inout pid_t?) -> ReplaydTelemetrySample? {
        guard let pid = resolveReplaydPID(cachedPID: &cachedPID) else { return nil }

        var rusage = rusage_info_v4()
        let rusageRC = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard rusageRC == 0 else {
            cachedPID = nil
            return nil
        }

        var taskAll = proc_taskallinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskallinfo>.stride)
        let gotSize = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &taskAll, expectedSize)
        guard gotSize == expectedSize else {
            cachedPID = nil
            return nil
        }

        return ReplaydTelemetrySample(
            timestamp: now,
            pid: pid,
            cpuNanoseconds: rusage.ri_user_time + rusage.ri_system_time,
            machSyscalls: taskAll.ptinfo.pti_syscalls_mach,
            contextSwitches: taskAll.ptinfo.pti_csw
        )
    }

    /// Checks whether `MenuBarAgent` / `ControlCenter` is currently exposing an active system
    /// screen-sharing or video-recording pill in its Accessibility menu bar extras (across all
    /// system locales), while ignoring `ControlCenter` (`BentoBox`) sensor dots and mic/cam-only calls.
    static func hasControlCenterScreenShareIndicator(in items: [MenuBarItem]) -> Bool {
        for item in items where item.ownerBundleID == "com.apple.MenuBarAgent" || item.ownerBundleID == "com.apple.controlcenter" {
            if let axID = item.axIdentifier?.lowercased() {
                if axID.contains("controlcenter") || axID.contains("bentobox") {
                    continue
                }
                if axID.contains("screenrecording") || axID.contains("screen-recording") || axID.contains("contentsharing") {
                    return true
                }
            }
            let candidates = [item.axTitle, item.axDescription, item.axValue, item.label]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            for text in candidates {
                for phrase in localizedScreenSharePhrases {
                    let hasCJK = phrase.unicodeScalars.contains { $0.value >= 0x3000 }
                    if !hasCJK && phrase.count <= 4 {
                        if text == phrase { return true }
                    } else if text.contains(phrase) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func resolveReplaydPID(cachedPID: inout pid_t?) -> pid_t? {
        let uid = getuid()
        if let existing = cachedPID, existing > 0 {
            if isUserReplaydProcess(pid: existing, uid: uid) {
                return existing
            }
            cachedPID = nil
        }

        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return nil }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualBytes = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listpids(UInt32(PROC_ALL_PIDS), 0, base, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard actualBytes > 0 else { return nil }
        let count = Int(actualBytes) / MemoryLayout<pid_t>.stride
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, isUserReplaydProcess(pid: pid, uid: uid) else { continue }
            cachedPID = pid
            return pid
        }
        return nil
    }

    private static func isUserReplaydProcess(pid: pid_t, uid: uid_t) -> Bool {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              bsd.pbi_uid == uid else {
            return false
        }
        let comm = withUnsafeBytes(of: bsd.pbi_comm) { raw -> String in
            let prefix = raw.prefix { $0 != 0 }
            return String(decoding: prefix, as: UTF8.self)
        }
        guard comm == "replayd" else { return false }

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard pathLen > 0 else { return false }
        return String(cString: pathBuf) == "/usr/libexec/replayd"
    }
}
