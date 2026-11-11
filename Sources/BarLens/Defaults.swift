import AppKit
import SwiftUI

/// Application color scheme / appearance preference.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("跟随系统", "System")
        case .light:  return tr("浅色", "Light")
        case .dark:   return tr("深色", "Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Concrete `ColorScheme` (never `nil`) so `NSHostingController` on macOS
    /// never retains a stale `.dark` environment when switching back to `.system`.
    func resolvedColorScheme(systemIsDark: Bool) -> ColorScheme {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    /// Concrete `NSAppearance` matching `resolvedColorScheme(systemIsDark:)`.
    func resolvedNSAppearance(systemIsDark: Bool) -> NSAppearance {
        let name: NSAppearance.Name = resolvedColorScheme(systemIsDark: systemIsDark) == .dark
            ? .darkAqua
            : .aqua
        return NSAppearance(named: name)!
    }
}

/// How hidden sections are presented when revealed.
enum RevealPresentationStyle: String, CaseIterable, Identifiable {
    case floatingBar = "floatingBar"
    case inline = "inline"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floatingBar: return tr("悬浮栏", "Floating Bar")
        case .inline:      return tr("菜单栏内", "Inline")
        }
    }
}

/// How application icons are rendered inside the second-row floating bar.
enum FloatingBarIconDisplayStyle: String, CaseIterable, Identifiable {
    case monochrome = "monochrome"
    case appIcon = "appIcon"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: return tr("黑白", "Monochrome")
        case .appIcon:    return tr("实物", "App Icon")
        }
    }

    var symbol: String {
        switch self {
        case .monochrome: return "circle.grid.cross"
        case .appIcon:    return "square.stack.3d.up.fill"
        }
    }
}

/// Visual style of the BarLens status item trigger in the top menu bar.
enum StatusBarIconStyle: String, CaseIterable, Identifiable {
    case dot     = "dot"
    case eclipse = "eclipse"
    case capsule = "capsule"
    case sparkle = "sparkle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot:     return tr("圆点", "Dot")
        case .eclipse: return tr("光环", "Halo")
        case .capsule: return tr("胶囊", "Capsule")
        case .sparkle: return tr("星芒", "Sparkle")
        }
    }

    var previewSymbol: String {
        switch self {
        case .dot:     return "circle.fill"
        case .eclipse: return "record.circle"
        case .capsule: return "capsule.inset.filled"
        case .sparkle: return "sparkles"
        }
    }

    func symbolName(for reveal: SectionModel.Reveal) -> String? {
        switch self {
        case .dot:
            return nil
        case .eclipse:
            switch reveal {
            case .none:   return "record.circle"
            case .hidden: return "circle.dotted.circle"
            case .all:    return "record.circle.fill"
            }
        case .capsule:
            switch reveal {
            case .none:   return "capsule.inset.filled"
            case .hidden: return "capsule"
            case .all:    return "capsule.lefthalf.filled"
            }
        case .sparkle:
            switch reveal {
            case .none:   return "sparkles"
            case .hidden: return "sparkle"
            case .all:    return "wand.and.stars"
            }
        }
    }
}

/// How long revealed hidden sections stay open before automatically collapsing.
enum AutoRehideInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off:            return tr("关闭", "Off")
        case .fiveSeconds:    return tr("5 秒", "5s")
        case .tenSeconds:     return tr("10 秒", "10s")
        case .fifteenSeconds: return tr("15 秒", "15s")
        case .thirtySeconds:  return tr("30 秒", "30s")
        }
    }

    var seconds: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }
}

/// Dwell time required when hovering over the menu bar trigger icon to automatically reveal hidden items.
enum HoverRevealDelay: Int, CaseIterable, Identifiable {
    case off = 0
    case fast = 180
    case standard = 350
    case deliberate = 600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off:        return tr("关闭", "Off")
        case .fast:       return tr("0.18 秒", "0.18s")
        case .standard:   return tr("0.35 秒", "0.35s")
        case .deliberate: return tr("0.6 秒", "0.6s")
        }
    }

    var seconds: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) / 1000.0 : nil
    }
}

/// User-customizable ordering of items inside the second-row floating bar.
struct FloatingBarOrder: Equatable, Codable {
    private(set) var orderedIDs: [String]

    init(orderedIDs: [String] = []) {
        var seen: Set<String> = []
        self.orderedIDs = orderedIDs.filter { seen.insert($0).inserted }
    }

    var isEmpty: Bool { orderedIDs.isEmpty }

    /// Sorts `items` according to `orderedIDs`, keeping any newly discovered items
    /// in their original relative order after explicitly ordered ones.
    func sorted<T>(_ items: [T], id: (T) -> String) -> [T] {
        guard !orderedIDs.isEmpty else { return items }
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { lhs, rhs in
            let r1 = rank[id(lhs.element)]
            let r2 = rank[id(rhs.element)]
            switch (r1, r2) {
            case let (.some(a), .some(b)):
                return a < b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Moves `itemID` to `toIndex` within `currentIDs` while preserving the
    /// exact positions of any items outside `currentIDs` (e.g. another section
    /// or currently quit applications).
    mutating func moveToIndex(itemID: String, toIndex: Int, within currentIDs: [String]) {
        guard !currentIDs.isEmpty else { return }
        var slice = sorted(currentIDs, id: { $0 })
        guard let fromIdx = slice.firstIndex(of: itemID) else { return }
        let clampedTo = min(max(0, toIndex), slice.count - 1)
        guard fromIdx != clampedTo else { return }
        let moved = slice.remove(at: fromIdx)
        slice.insert(moved, at: clampedTo)

        var working = mergedOrder(with: currentIDs)
        let currentSet = Set(currentIDs)
        let sliceSlots = working.indices.filter { currentSet.contains(working[$0]) }
        for (slot, id) in zip(sliceSlots, slice) {
            working[slot] = id
        }
        orderedIDs = working
    }

    /// Reorders `movingID` relative to `targetID` within the currently visible `currentIDs` slice.
    mutating func move(itemID movingID: String, to targetID: String, within currentIDs: [String]) {
        guard movingID != targetID else { return }
        let slice = sorted(currentIDs, id: { $0 })
        guard let targetIdx = slice.firstIndex(of: targetID) else { return }
        moveToIndex(itemID: movingID, toIndex: targetIdx, within: slice)
    }

    /// Moves `itemID` one slot earlier (`delta = -1`) or later (`delta = +1`) within `currentIDs`.
    mutating func moveByStep(itemID: String, delta: Int, within currentIDs: [String]) {
        guard delta != 0 else { return }
        let slice = sorted(currentIDs, id: { $0 })
        guard let idx = slice.firstIndex(of: itemID) else { return }
        let targetIdx = idx + delta
        guard slice.indices.contains(targetIdx) else { return }
        moveToIndex(itemID: itemID, toIndex: targetIdx, within: slice)
    }

    /// Moves `itemID` to the start or end of the `currentIDs` group.
    mutating func moveToEdge(itemID: String, toFront: Bool, within currentIDs: [String]) {
        let slice = sorted(currentIDs, id: { $0 })
        guard !slice.isEmpty else { return }
        moveToIndex(itemID: itemID, toIndex: toFront ? 0 : slice.count - 1, within: slice)
    }

    mutating func reset() {
        orderedIDs.removeAll()
    }

    private func mergedOrder(with currentIDs: [String]) -> [String] {
        var result = orderedIDs
        var seen = Set(result)
        for id in currentIDs where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}

/// The handful of preferences this app has.
///
/// Deliberately not an ObservableObject: the engine owns the published copies
/// and writes through here, so there is one source of truth for each value.
enum Defaults {

    private enum Key {
        static let alwaysHiddenEnabled = "alwaysHiddenEnabled"
        static let autoRehideInterval = "autoRehideInterval"
        static let hoverRevealDelay = "hoverRevealDelay"
        static let floatingBarOrder = "floatingBarOrder"
        static let revealPresentationStyle = "revealPresentationStyle"
        static let floatingBarIconStyle = "floatingBarIconStyle"
        static let statusBarIconStyle = "statusBarIconStyle"
        static let appearanceMode = "appearanceMode"
        static let appLanguage = "appLanguage"
        static let glassOpacity = "glassOpacity"
        static let rimIntensity = "rimIntensity"
        static let hasShownWelcome = "hasShownWelcome"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hotkeys = "hotkeys"
        static let settingsPane = "settingsPane"
        static let unclassifiedSection = "unclassifiedSection"
        static let newSystemItemSection = "newSystemItemSection"
    }

    static var appLanguage: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: Key.appLanguage)
                .flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.appLanguage)
        }
    }

    static var statusBarIconStyle: StatusBarIconStyle {
        get {
            UserDefaults.standard.string(forKey: Key.statusBarIconStyle)
                .flatMap(StatusBarIconStyle.init(rawValue:)) ?? .eclipse
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.statusBarIconStyle)
        }
    }

    static var appearanceMode: AppearanceMode {
        get {
            UserDefaults.standard.string(forKey: Key.appearanceMode)
                .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceMode)
        }
    }

    static var glassOpacity: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.glassOpacity) != nil else {
                return 0.36
            }
            return min(max(UserDefaults.standard.double(forKey: Key.glassOpacity), 0.0), 0.90)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.0), 0.90), forKey: Key.glassOpacity)
        }
    }

    static var rimIntensity: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.rimIntensity) != nil else {
                return 1.15
            }
            return min(max(UserDefaults.standard.double(forKey: Key.rimIntensity), 0.2), 1.6)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.2), 1.6), forKey: Key.rimIntensity)
        }
    }

    static var revealPresentationStyle: RevealPresentationStyle {
        get {
            UserDefaults.standard.string(forKey: Key.revealPresentationStyle)
                .flatMap(RevealPresentationStyle.init(rawValue:)) ?? .floatingBar
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.revealPresentationStyle) }
    }

    static var floatingBarIconStyle: FloatingBarIconDisplayStyle {
        get {
            UserDefaults.standard.string(forKey: Key.floatingBarIconStyle)
                .flatMap(FloatingBarIconDisplayStyle.init(rawValue:)) ?? .monochrome
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.floatingBarIconStyle) }
    }

    static var alwaysHiddenEnabled: Bool {
        get {
            // Absent means on: the section is only interesting once the user
            // has put something in it.
            UserDefaults.standard.object(forKey: Key.alwaysHiddenEnabled) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.alwaysHiddenEnabled) }
    }

    static var autoRehideInterval: AutoRehideInterval {
        get {
            let raw = UserDefaults.standard.integer(forKey: Key.autoRehideInterval)
            return AutoRehideInterval(rawValue: raw) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.autoRehideInterval) }
    }

    static var hoverRevealDelay: HoverRevealDelay {
        get {
            let raw = UserDefaults.standard.integer(forKey: Key.hoverRevealDelay)
            return HoverRevealDelay(rawValue: raw) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.hoverRevealDelay) }
    }

    static var floatingBarOrder: FloatingBarOrder {
        get {
            let ids = UserDefaults.standard.stringArray(forKey: Key.floatingBarOrder) ?? []
            return FloatingBarOrder(orderedIDs: ids)
        }
        set {
            UserDefaults.standard.set(newValue.orderedIDs, forKey: Key.floatingBarOrder)
        }
    }

    static var hasShownWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hasShownWelcome) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hasShownWelcome) }
    }

    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    static var settingsPane: String {
        get { UserDefaults.standard.string(forKey: Key.settingsPane) ?? "sections" }
        set { UserDefaults.standard.set(newValue, forKey: Key.settingsPane) }
    }

    /// Which section an application goes in when the user has never classified
    /// it. Stored as the raw string, like `settingsPane`.
    ///
    /// Ships as `.visible` — the behaviour the app had before this setting
    /// existed. Anything else means a freshly installed app's icon vanishes
    /// before its owner has any idea this app is why, so it is a choice the
    /// user has to make rather than one they discover.
    static var unclassifiedSection: SectionModel.Section {
        get {
            UserDefaults.standard.string(forKey: Key.unclassifiedSection)
                .flatMap(SectionModel.Section.init(rawValue:)) ?? .visible
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.unclassifiedSection) }
    }

    /// Where a built-in item goes the moment a scan records it.
    ///
    /// Separate from `unclassifiedSection` because the two sets are discovered
    /// in completely different ways: applications appear on their own as the
    /// user installs and runs them, while system items only ever arrive from a
    /// scan the user asked for. Wanting one hidden and not the other is normal.
    ///
    /// Ships as `.visible` for the same reason: a newly measured icon
    /// disappearing before its owner has looked at the list is alarming.
    static var newSystemItemSection: SectionModel.Section {
        get {
            UserDefaults.standard.string(forKey: Key.newSystemItemSection)
                .flatMap(SectionModel.Section.init(rawValue:)) ?? .visible
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.newSystemItemSection) }
    }

    static var hotkeys: [HotkeyAction: Hotkey] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.hotkeys),
                  let decoded = try? JSONDecoder().decode([String: Hotkey].self, from: data) else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                HotkeyAction(rawValue: key).map { ($0, value) }
            })
        }
        set {
            // JSON object keys have to be strings, so the action's raw value is
            // the key and the enum is rebuilt on the way back.
            let encoded = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(encoded), forKey: Key.hotkeys)
        }
    }
}
