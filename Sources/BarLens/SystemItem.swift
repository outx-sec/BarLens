import Foundation

/// A built-in menu bar item — Wi-Fi, battery, clock, Control Center, Focus Mode and friends.
///
/// Items in `MBSystemItemIdentifier` (`0...8`) are addressed by their positive
/// enum raw value in `MBAssessmentModeConfiguration`. Other Control Center items
/// (`专注模式`, `隔空投送`, `播放中`, `快速用户切换`, etc.) use `controlCenterManagedRawValue`
/// (`-1`) and are coordinated through Control Center preferences and proxy items.
struct SystemItem: Identifiable, Hashable {
    static let controlCenterManagedRawValue = -1

    private static let hostBundlesByIdentifier: [String: [String]] = [
        "com.apple.menuextra.timemachine": ["com.apple.systemuiserver"],
        "com.apple.menuextra.textinput":   ["com.apple.TextInputMenuAgent"],
        "com.apple.menuextra.spotlight":   ["com.apple.campo", "com.apple.Spotlight"],
        "com.apple.menuextra.siri":        ["com.apple.Siri"],
    ]

    private static let pressableHostBundlesByIdentifier: [String: String] = [
        "com.apple.menuextra.timemachine": "com.apple.systemuiserver",
        "com.apple.menuextra.textinput":   "com.apple.TextInputMenuAgent",
    ]

    let identifier: String
    let rawValue: Int

    var id: String { identifier }
    var title: String { SystemItemName.title(for: identifier) }
    var symbol: String { SystemItemName.symbol(for: identifier) }
    var isAddressableByAssessment: Bool { rawValue >= 0 }
    var hostBundleIDs: [String] { Self.hostBundlesByIdentifier[identifier] ?? [] }
    var pressableHostBundleID: String? { Self.pressableHostBundlesByIdentifier[identifier] }

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return SystemItemName.allTitles(for: identifier).contains {
            $0.localizedCaseInsensitiveContains(trimmed)
        } || identifier.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Display names, symbols, and canonical identifier normalization for built-in items.
enum SystemItemName {

    private static let knownZh: [String: String] = [
        "battery":             "电池",
        "clock":               "时钟",
        "wifi":                "Wi-Fi",
        "controlcenter":       "控制中心",
        "spotlight":           "聚焦",
        "bluetooth":           "蓝牙",
        "sound":               "声音",
        "display":             "显示器",
        "displays":            "显示器",
        "keyboard-brightness": "键盘亮度",
        "keyboardbrightness":  "键盘亮度",
        "airdrop":             "隔空投送",
        "focus":               "专注模式",
        "focusmode":           "专注模式",
        "nowplaying":          "播放中",
        "now-playing":         "播放中",
        "timemachine":         "时间机器",
        "timer":               "计时器",
        "user":                "快速用户切换",
        "users":               "快速用户切换",
        "appleuser":           "快速用户切换",
        "stage-manager":       "台前调度",
        "stagemanager":        "台前调度",
        "hearing":             "听觉",
        "screenrecording":     "屏幕录制",
        "screen-mirroring":    "屏幕镜像",
        "screenmirroring":     "屏幕镜像",
        "airplay":             "屏幕镜像",
        "vpn":                 "VPN",
        "music":               "音乐识别",
        "shazam":              "音乐识别",
        "siri":                "Siri",
        "weather":             "天气",
        "inputmenu":           "文字输入",
        "textinput":           "文字输入",
        "passwords":           "密码",
    ]

    private static let knownEn: [String: String] = [
        "battery":             "Battery",
        "clock":               "Clock",
        "wifi":                "Wi-Fi",
        "controlcenter":       "Control Center",
        "spotlight":           "Spotlight",
        "bluetooth":           "Bluetooth",
        "sound":               "Sound",
        "display":             "Display",
        "displays":            "Display",
        "keyboard-brightness": "Keyboard Brightness",
        "keyboardbrightness":  "Keyboard Brightness",
        "airdrop":             "AirDrop",
        "focus":               "Focus",
        "focusmode":           "Focus",
        "nowplaying":          "Now Playing",
        "now-playing":         "Now Playing",
        "timemachine":         "Time Machine",
        "timer":               "Timer",
        "user":                "Fast User Switching",
        "users":               "Fast User Switching",
        "appleuser":           "Fast User Switching",
        "stage-manager":       "Stage Manager",
        "stagemanager":        "Stage Manager",
        "hearing":             "Hearing",
        "screenrecording":     "Screen Recording",
        "screen-mirroring":    "Screen Mirroring",
        "screenmirroring":     "Screen Mirroring",
        "airplay":             "Screen Mirroring",
        "vpn":                 "VPN",
        "music":               "Music Recognition",
        "shazam":              "Music Recognition",
        "siri":                "Siri",
        "weather":             "Weather",
        "inputmenu":           "Input Menu",
        "textinput":           "Input Menu",
        "passwords":           "Passwords",
    ]

    private static let symbols: [String: String] = [
        "battery":             "battery.100",
        "clock":               "clock",
        "wifi":                "wifi",
        "controlcenter":       "switch.2",
        "spotlight":           "magnifyingglass",
        "bluetooth":           "dot.radiowaves.left.and.right",
        "sound":               "speaker.wave.2",
        "display":             "sun.max",
        "displays":            "sun.max",
        "keyboard-brightness": "light.max",
        "keyboardbrightness":  "light.max",
        "airdrop":             "airplayaudio",
        "focus":               "moon.fill",
        "focusmode":           "moon.fill",
        "nowplaying":          "play.circle",
        "now-playing":         "play.circle",
        "timemachine":         "clock.arrow.circlepath",
        "timer":               "timer",
        "user":                "person.crop.circle",
        "users":               "person.crop.circle",
        "appleuser":           "person.crop.circle",
        "stage-manager":       "squares.leading.rectangle",
        "stagemanager":        "squares.leading.rectangle",
        "hearing":             "ear",
        "screenrecording":     "record.circle",
        "screen-mirroring":    "rectangle.on.rectangle",
        "screenmirroring":     "rectangle.on.rectangle",
        "airplay":             "rectangle.on.rectangle",
        "vpn":                 "network.badge.shield.half.filled",
        "music":               "shazam.logo",
        "shazam":              "shazam.logo",
        "siri":                "waveform",
        "weather":             "cloud.sun.fill",
        "inputmenu":           "keyboard",
        "textinput":           "keyboard",
    ]

    private static let canonicalSuffixMap: [String: String] = [
        "displays":            "display",
        "screenmirroring":     "screen-mirroring",
        "airplay":             "screen-mirroring",
        "keyboardbrightness":  "keyboard-brightness",
        "keyboard":            "keyboard-brightness",
        "volume":              "sound",
        "primarybentobox":     "controlcenter",
        "focus":               "focusmode",
        "focusmodes":          "focusmode",
        "now-playing":         "nowplaying",
        "users":               "user",
        "appleuser":           "user",
        "userswitcher":        "user",
        "stage-manager":       "stagemanager",
        "shazam":              "music",
        "musicrecognition":    "music",
        "inputmenu":           "textinput",
        "textinputmenuagent":  "textinput",
    ]

    private static let prefix = "com.apple.menuextra."

    private static func normalizedSuffix(for identifier: String) -> String {
        let lower = identifier.lowercased()
        let raw = lower.hasPrefix(prefix)
            ? String(lower.dropFirst(prefix.count))
            : lower
        return canonicalSuffixMap[raw] ?? raw
    }

    static func canonicalIdentifier(for identifier: String) -> String {
        let suffix = normalizedSuffix(for: identifier)
        return prefix + suffix
    }

    static func title(for identifier: String) -> String {
        let suffix = normalizedSuffix(for: identifier)
        let dict = L10n.isEnglish ? knownEn : knownZh
        if let name = dict[suffix] { return name }
        let rawSuffix = identifier.hasPrefix(prefix)
            ? String(identifier.dropFirst(prefix.count))
            : identifier
        return rawSuffix.replacingOccurrences(of: "_", with: " ")
    }

    static func allTitles(for identifier: String) -> [String] {
        let suffix = normalizedSuffix(for: identifier)
        var titles: [String] = []
        if let zh = knownZh[suffix] { titles.append(zh) }
        if let en = knownEn[suffix], !titles.contains(en) { titles.append(en) }
        if titles.isEmpty {
            let rawSuffix = identifier.hasPrefix(prefix)
                ? String(identifier.dropFirst(prefix.count))
                : identifier
            titles.append(rawSuffix.replacingOccurrences(of: "_", with: " "))
        }
        return titles
    }

    static func symbol(for identifier: String) -> String {
        symbols[normalizedSuffix(for: identifier)] ?? "menubar.rectangle"
    }
}

/// Limits of what this API can address.
enum SystemItemCaveats {
    static let explanation = "部分系统图标通过控制中心与状态栏联动控制。"
}

/// Which raw value each built-in item has, and which section the user put it in.
struct SystemItemRegistry {

    private static let key = "systemItemRegistry"

    /// Fallback table for the 9 `MBSystemItemIdentifier` enum cases (`0...8`),
    /// supplemented at runtime by querying `MenuBarClientCore.framework` directly.
    private static let fallbackAddressableSeeds: [String: Int] = [
        "com.apple.menuextra.battery":             0,
        "com.apple.menuextra.bluetooth":           1,
        "com.apple.menuextra.clock":               2,
        "com.apple.menuextra.display":             3,
        "com.apple.menuextra.keyboard-brightness": 4,
        "com.apple.menuextra.sound":               5,
        "com.apple.menuextra.wifi":                6,
        "com.apple.menuextra.screen-mirroring":    7,
        "com.apple.menuextra.controlcenter":       8,
    ]

    /// Control Center items that do not have an `MBSystemItemIdentifier` slot.
    static let controlCenterManagedIdentifiers: [String] = [
        "com.apple.menuextra.focusmode",
        "com.apple.menuextra.airdrop",
        "com.apple.menuextra.nowplaying",
        "com.apple.menuextra.user",
        "com.apple.menuextra.textinput",
        "com.apple.menuextra.timer",
        "com.apple.menuextra.weather",
        "com.apple.menuextra.spotlight",
        "com.apple.menuextra.siri",
        "com.apple.menuextra.timemachine",
        "com.apple.menuextra.stagemanager",
        "com.apple.menuextra.hearing",
        "com.apple.menuextra.music",
    ]

    /// Queries `MenuBarClientCore.MBSystemItemIdentifier.allCases` and `.stringValue`
    /// directly from the framework in the dyld shared cache when available.
    static func runtimeAddressableSeeds() -> [String: Int] {
        let path = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            return fallbackAddressableSeeds
        }
        typealias AllCasesGetter = @convention(thin) () -> [Int]
        typealias StringGetter = @convention(thin) (Int) -> String
        guard let allSym = dlsym(handle, "$s17MenuBarClientCore22MBSystemItemIdentifierO8allCasesSayACGvgZ"),
              let strSym = dlsym(handle, "$s17MenuBarClientCore22MBSystemItemIdentifierO11stringValueSSvg") else {
            return fallbackAddressableSeeds
        }
        let getAllCases = unsafeBitCast(allSym, to: AllCasesGetter.self)
        let getString = unsafeBitCast(strSym, to: StringGetter.self)
        var result = fallbackAddressableSeeds
        for raw in getAllCases() where raw >= 0 {
            let name = getString(raw)
            let canonical = SystemItemName.canonicalIdentifier(for: name)
            result[canonical] = raw
        }
        return result
    }

    static func defaultValues() -> [String: Int] {
        var merged = runtimeAddressableSeeds()
        for id in controlCenterManagedIdentifiers where merged[id] == nil {
            merged[id] = SystemItem.controlCenterManagedRawValue
        }
        return merged
    }

    private(set) var values: [String: Int]
    private(set) var build: String

    static var currentBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: buffer)
    }

    static func load() -> SystemItemRegistry {
        let build = currentBuild
        let defaults = defaultValues()
        guard let stored = UserDefaults.standard.dictionary(forKey: key),
              stored["build"] as? String == build,
              let measured = stored["values"] as? [String: Int] else {
            let registry = SystemItemRegistry(values: defaults, build: build)
            registry.save()
            return registry
        }
        var merged = defaults
        for (rawKey, value) in measured where value >= SystemItem.controlCenterManagedRawValue {
            let canonical = SystemItemName.canonicalIdentifier(for: rawKey)
            if let defaultVal = defaults[canonical], defaultVal >= 0 {
                merged[canonical] = defaultVal
            } else {
                merged[canonical] = value
            }
        }
        let registry = SystemItemRegistry(values: merged, build: build)
        if merged != measured {
            registry.save()
        }
        return registry
    }

    private func save() {
        UserDefaults.standard.set(["build": build, "values": values], forKey: Self.key)
    }

    mutating func record(_ identifier: String, rawValue: Int) {
        guard rawValue >= SystemItem.controlCenterManagedRawValue else { return }
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        values[canonical] = rawValue
        save()
    }

    @discardableResult
    mutating func prune(keeping presentIdentifiers: Set<String>) -> Bool {
        let canonicalPresent = Set(presentIdentifiers.map(SystemItemName.canonicalIdentifier(for:)))
        let defaults = Self.defaultValues()
        let filtered = values.filter {
            defaults[$0.key] != nil || canonicalPresent.contains($0.key)
        }
        guard filtered.count != values.count else { return false }
        values = filtered
        save()
        return true
    }

    func rawValue(of identifier: String) -> Int? {
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        return values[canonical]
    }

    /// Every known item, sorted with addressable items (`0...8`) first in raw value
    /// order, followed by Control Center items in stable title/identifier order.
    var items: [SystemItem] {
        values.map { SystemItem(identifier: $0.key, rawValue: $0.value) }
            .sorted { lhs, rhs in
                if lhs.isAddressableByAssessment != rhs.isAddressableByAssessment {
                    return lhs.isAddressableByAssessment
                }
                if lhs.rawValue != rhs.rawValue {
                    return lhs.rawValue < rhs.rawValue
                }
                return lhs.identifier < rhs.identifier
            }
    }
}

/// The user's section assignments for the built-in items.
struct SystemItemModel {

    private(set) var registry: SystemItemRegistry
    private(set) var assignments: [String: SectionModel.Section] = [:]

    var unassigned: SectionModel.Section = .visible

    private static let key = "systemItemAssignments"

    static func load() -> SystemItemModel {
        var model = SystemItemModel(registry: .load())
        model.unassigned = Defaults.newSystemItemSection
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return model
        }
        var didNormalize = false
        for (identifier, rawSection) in stored {
            guard let section = SectionModel.Section(rawValue: rawSection) else { continue }
            let canonical = SystemItemName.canonicalIdentifier(for: identifier)
            if canonical != identifier { didNormalize = true }
            model.assignments[canonical] = section
        }
        if didNormalize {
            model.save()
        }
        return model
    }

    var items: [SystemItem] { registry.items }

    func section(of item: SystemItem) -> SectionModel.Section {
        let canonical = SystemItemName.canonicalIdentifier(for: item.identifier)
        return assignments[canonical] ?? assignments[item.identifier] ?? unassigned
    }

    func isClassified(_ item: SystemItem) -> Bool {
        let canonical = SystemItemName.canonicalIdentifier(for: item.identifier)
        return assignments[canonical] != nil || assignments[item.identifier] != nil
    }

    mutating func set(_ section: SectionModel.Section, for item: SystemItem) {
        let canonical = SystemItemName.canonicalIdentifier(for: item.identifier)
        assignments.removeValue(forKey: item.identifier)
        assignments[canonical] = section
        save()
    }

    mutating func removeAssignment(for item: SystemItem, persist: Bool = true) {
        let canonical = SystemItemName.canonicalIdentifier(for: item.identifier)
        assignments.removeValue(forKey: canonical)
        assignments.removeValue(forKey: item.identifier)
        if persist { save() }
    }

    mutating func clearAssignments(persist: Bool = true) {
        assignments.removeAll()
        if persist { save() }
    }

    mutating func replaceAssignments(_ newAssignments: [String: SectionModel.Section],
                                     unassigned newUnassigned: SectionModel.Section,
                                     persist: Bool = true) {
        var normalized: [String: SectionModel.Section] = [:]
        for (identifier, section) in newAssignments {
            normalized[SystemItemName.canonicalIdentifier(for: identifier)] = section
        }
        assignments = normalized
        unassigned = newUnassigned
        if persist { save() }
    }

    /// Fold a measured value into the registry. Returns false when the
    /// identifier was already known with a non-negative value.
    @discardableResult
    mutating func record(_ identifier: String, rawValue: Int) -> Bool {
        guard rawValue >= SystemItem.controlCenterManagedRawValue else { return false }
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        if let existing = registry.rawValue(of: canonical), existing == rawValue {
            return false
        }
        registry.record(canonical, rawValue: rawValue)
        return true
    }

    @discardableResult
    mutating func prune(keeping presentIdentifiers: Set<String>) -> Bool {
        registry.prune(keeping: presentIdentifiers)
    }

    private func save() {
        UserDefaults.standard.set(assignments.mapValues { $0.rawValue }, forKey: Self.key)
    }

    /// Whether the user has put anything outside the visible section.
    var isConfigured: Bool {
        registry.items.contains { section(of: $0) != .visible }
    }

    /// Whether a given item should currently be suppressed on the top menu bar.
    func isItemSuppressedOnBar(_ item: SystemItem,
                               reveal: SectionModel.Reveal,
                               alwaysHiddenEnabled: Bool) -> Bool {
        switch section(of: item) {
        case .visible:
            return false
        case .hidden:
            return reveal == .none
        case .alwaysHidden:
            if !alwaysHiddenEnabled {
                return reveal == .none
            }
            return reveal != .all
        }
    }

    /// The `MBSystemItemIdentifier` raw values (`>= 0`) that should be suppressed
    /// right now, given how much of the hidden side is currently revealed.
    func hiddenRawValues(reveal: SectionModel.Reveal,
                         alwaysHiddenEnabled: Bool,
                         excluding unavailable: Set<String> = []) -> [Int] {
        registry.items.compactMap { item in
            guard item.rawValue >= 0, !unavailable.contains(item.identifier) else { return nil }
            return isItemSuppressedOnBar(item, reveal: reveal, alwaysHiddenEnabled: alwaysHiddenEnabled)
                ? item.rawValue
                : nil
        }
    }

    /// Whether any active non-addressable Control Center item (`rawValue == -1`,
    /// such as `专注模式`) is currently supposed to be hidden from the top menu bar.
    func hasHiddenControlCenterItems(reveal: SectionModel.Reveal,
                                     alwaysHiddenEnabled: Bool,
                                     excluding unavailable: Set<String> = []) -> Bool {
        registry.items.contains { item in
            guard !item.isAddressableByAssessment, !unavailable.contains(item.identifier) else {
                return false
            }
            return isItemSuppressedOnBar(item, reveal: reveal, alwaysHiddenEnabled: alwaysHiddenEnabled)
        }
    }
}
