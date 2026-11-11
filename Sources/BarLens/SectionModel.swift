import AppKit

/// Which section an app's status items belong to.
///
///     [ alwaysHidden ] │ [ hidden / revealable ] │ [ visible ]
///
/// Assignment is by bundle identifier, because the allow list MenuBarAgent
/// takes is keyed that way. An app that owns several status items therefore
/// moves as a group.
///
/// Sections are *lists*, not positions. An earlier version derived them from
/// where two markers sat in the menu bar, which meant the always-hidden marker
/// had to stay on the bar at all times and re-dividing had to reveal everything
/// to measure. Lists have neither problem, and moving an app is a click instead
/// of a drag across the whole bar.
struct SectionModel {

    /// How much of the hidden side is currently on screen.
    ///
    /// - `.none`  only the visible section
    /// - `.hidden` the revealable section is showing too (plain click on the dot)
    /// - `.all`   the always-hidden section is showing too (double click on the dot)
    enum Reveal {
        case none
        case hidden
        case all
    }

    enum Section: String, CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        var title: String {
            switch self {
            case .visible:      return tr("始终显示", "Visible")
            case .hidden:       return tr("可隐藏", "Hidden")
            case .alwaysHidden: return tr("永久隐藏", "Always Hidden")
            }
        }

        var symbol: String {
            switch self {
            case .visible:      return "eye"
            case .hidden:       return "eye.slash"
            case .alwaysHidden: return "eye.slash.fill"
            }
        }

        var explanation: String {
            switch self {
            case .visible:      return tr("一直留在菜单栏上。", "Stays visible in the menu bar at all times.")
            case .hidden:       return tr("平时隐藏，点菜单栏上的圆点可以显示出来。", "Hidden by default; click the menu bar trigger to reveal.")
            case .alwaysHidden: return tr("始终不显示，双击圆点才会临时露出来。", "Always hidden; double-click the trigger to peek.")
            }
        }
    }

    /// Bundles that own menu bar items but cannot be classified per-application.
    ///
    /// `com.apple.MenuBarAgent` is the system process behind every built-in item
    /// — Wi-Fi, battery, clock, Control Center, Spotlight. They all share its
    /// bundle identifier, so hiding it takes the whole lot at once, and listing
    /// it as one row would be a lie about what the row does. Those items are
    /// addressed individually through `SystemItem` instead.
    static let notClassifiable: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.campo",
        "com.apple.Siri",
        "com.apple.Spotlight",
    ]

    private(set) var alwaysHidden: Set<String> = []
    private(set) var hidden: Set<String> = []
    /// Applications the user has explicitly put in the visible section.
    ///
    /// Needed only because there is a default. Deriving "visible" from absence
    /// worked while absence was the *only* way to be visible — but the moment
    /// `unclassified` can be something else, "not in either hidden set" and
    /// "visible" stop meaning the same thing, and classifying an app as visible
    /// becomes impossible: removing it from both sets drops it straight back
    /// into the default. Which is exactly what happened.
    private(set) var visible: Set<String> = []

    /// Where an application goes when the user has never classified it.
    ///
    /// Held here rather than read from `Defaults` at each use so the model stays
    /// a pure function of its inputs — the engine owns the published copy and
    /// pushes it in, the same way it does for `alwaysHiddenEnabled`.
    ///
    /// Changing this is retroactive by construction: it is a default, not a
    /// snapshot, so every unclassified app moves at once. The settings window
    /// says so and shows the count.
    var unclassified: Section = .visible

    // MARK: - Persistence

    private enum Key {
        static let alwaysHidden = "alwaysHiddenBundleIDs"
        static let hidden = "hiddenBundleIDs"
        static let visible = "visibleBundleIDs"
    }

    static func load() -> SectionModel {
        var model = SectionModel()
        let defaults = UserDefaults.standard
        model.alwaysHidden = Set(defaults.stringArray(forKey: Key.alwaysHidden) ?? [])
        model.hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        // Absent for anyone upgrading from a build that had no explicit visible
        // set — which is correct, since back then absence did mean visible.
        model.visible = Set(defaults.stringArray(forKey: Key.visible) ?? [])
        // An assignment made before these were filtered out would be stuck for
        // good: the row it belongs to no longer appears, so there is no way to
        // take it back. Drop them on the way in rather than leaving one hiding
        // every built-in item with no visible cause.
        model.alwaysHidden.subtract(notClassifiable)
        model.hidden.subtract(notClassifiable)
        model.visible.subtract(notClassifiable)
        model.unclassified = Defaults.unclassifiedSection
        return model
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(Array(alwaysHidden).sorted(), forKey: Key.alwaysHidden)
        defaults.set(Array(hidden).sorted(), forKey: Key.hidden)
        defaults.set(Array(visible).sorted(), forKey: Key.visible)
    }

    // MARK: - Reading and writing assignments

    func section(of bundleID: String) -> Section {
        if alwaysHidden.contains(bundleID) { return .alwaysHidden }
        if hidden.contains(bundleID) { return .hidden }
        // Before the default: an app the user pinned to the visible section
        // stays there, however the default changes.
        if visible.contains(bundleID) { return .visible }
        return unclassified
    }

    /// Whether this app has been classified, as opposed to inheriting the
    /// default. The settings list shows both the same way; this is for the
    /// count in the default section setting.
    func isClassified(_ bundleID: String) -> Bool {
        alwaysHidden.contains(bundleID) || hidden.contains(bundleID) || visible.contains(bundleID)
    }

    mutating func set(_ section: Section, for bundleID: String) {
        guard !Self.notClassifiable.contains(bundleID) else { return }
        alwaysHidden.remove(bundleID)
        hidden.remove(bundleID)
        visible.remove(bundleID)
        switch section {
        case .alwaysHidden: alwaysHidden.insert(bundleID)
        case .hidden:       hidden.insert(bundleID)
        // Recorded explicitly rather than implied by absence — see `visible`.
        case .visible:      visible.insert(bundleID)
        }
        save()
    }

    /// Removes an explicit assignment so a running app inherits `unclassified`
    /// and a stopped or uninstalled app is removed from the saved list.
    mutating func removeAssignment(for bundleID: String, persist: Bool = true) {
        alwaysHidden.remove(bundleID)
        hidden.remove(bundleID)
        visible.remove(bundleID)
        if persist { save() }
    }

    mutating func clear() {
        alwaysHidden = []
        hidden = []
        visible = []
        save()
    }

    mutating func replaceAll(visible newVisible: Set<String>,
                             hidden newHidden: Set<String>,
                             alwaysHidden newAlwaysHidden: Set<String>,
                             unclassified newUnclassified: Section,
                             persist: Bool = true) {
        let validAlwaysHidden = newAlwaysHidden.subtracting(Self.notClassifiable)
        let validHidden = newHidden.subtracting(Self.notClassifiable).subtracting(validAlwaysHidden)
        let validVisible = newVisible.subtracting(Self.notClassifiable).subtracting(validAlwaysHidden).subtracting(validHidden)
        alwaysHidden = validAlwaysHidden
        hidden = validHidden
        visible = validVisible
        unclassified = newUnclassified
        if persist { save() }
    }

    // MARK: - Bulk assignment from the dot's position

    enum BulkError: Error, CustomStringConvertible {
        case nothingToDo
        case wouldHideEverything

        var description: String {
            switch self {
            case .nothingToDo:
                return tr("圆点左边没有别的图标。", "There are no items to the left of the trigger icon.")
            case .wouldHideEverything:
                return tr("这会把整条菜单栏都划走 —— 把圆点往右挪一点再试。", "This would hide the entire menu bar — move the trigger icon slightly right and try again.")
            }
        }
    }

    /// Assign everything sitting left of `x` on `display` to `section`.
    ///
    /// This is the shortcut that keeps the immediacy of a divider: put the dot
    /// where the hidden section should end, ask once, and everything to its
    /// left is classified. Afterwards each app can be moved individually from
    /// the settings window, which is where refinement belongs.
    ///
    /// `items` must come from a snapshot taken with nothing hidden — a hidden
    /// item keeps reporting the frame it had before, so its coordinates cannot
    /// be trusted for this.
    mutating func assignEverything(leftOf x: CGFloat,
                                   on display: DisplayID,
                                   from items: [MenuBarItem],
                                   to section: Section) throws {
        var affected: Set<String> = []
        var candidates: Set<String> = []

        for item in items where item.display == display {
            candidates.insert(item.ownerBundleID)
            if item.frame.minX < x { affected.insert(item.ownerBundleID) }
        }

        affected.subtract(Self.ownIdentifiers)
        guard !affected.isEmpty else { throw BulkError.nothingToDo }
        // Refuse rather than obey: sweeping the whole bar into a hidden section
        // is never the intent and is alarming to undo.
        guard affected.count < candidates.subtracting(Self.ownIdentifiers).count else {
            throw BulkError.wouldHideEverything
        }

        for bundleID in affected { set(section, for: bundleID) }
        save()
    }

    // MARK: - Turning the sections into an allow list

    /// Every identity this process might be filed under by MenuBarAgent.
    ///
    /// It files each status item under whatever identity it resolved for the
    /// owning process, and that is not always the bundle identifier: only apps
    /// in an installed location get the bundle identifier, everything else is
    /// filed under the process name. Both spellings show up in its bookkeeping.
    static var ownIdentifiers: Set<String> {
        var ids: Set<String> = []
        if let bundleID = Bundle.main.bundleIdentifier { ids.insert(bundleID) }
        ids.insert(ProcessInfo.processInfo.processName)
        if let executable = Bundle.main.executableURL?.lastPathComponent {
            ids.insert(executable)
        }
        return ids
    }

    /// The bundle identifiers whose items should stay visible.
    ///
    /// The API has no deny list — anything absent from this array is hidden —
    /// so `running` must be every running application, not just the ones that
    /// currently have a status item. A status item's owner is always a running
    /// process, which makes "running applications" a complete superset and one
    /// that never needs the private group-container plists.
    func allowedBundles(running: Set<String>,
                        reveal: Reveal,
                        alwaysHiddenEnabled: Bool,
                        listable: Set<String>) -> [String] {
        // Unclassified apps inherit the default section. Folding them in up
        // front keeps everything below a plain three-set calculation, rather
        // than a fourth case threaded through both conditions.
        var hiddenSet = hidden
        var alwaysHiddenSet = alwaysHidden
        if unclassified != .visible {
            // `listable` only: the default is a guess about something the user
            // has not decided yet, so it may only be applied to things they can
            // see and therefore correct. An item AX does not publish has no row,
            // and hiding it would strand it.
            // `notClassifiable` is excluded here as well as in `load`/`set`: the
            // default is a guess about apps the user has not decided on, and
            // these are not apps you can decide about at all. Without this,
            // granting Full Disk Access put `com.apple.MenuBarAgent` — the owner
            // of every built-in item — through the default and denied it.
            for bundleID in running
            where !isClassified(bundleID)
                && listable.contains(bundleID)
                && !Self.notClassifiable.contains(bundleID) {
                if unclassified == .hidden {
                    hiddenSet.insert(bundleID)
                } else {
                    alwaysHiddenSet.insert(bundleID)
                }
            }
        }

        // Turning the always-hidden section off folds its apps into the
        // revealable one rather than leaving them hidden — the assignments are
        // kept, so switching it back on restores the previous arrangement.
        if !alwaysHiddenEnabled {
            hiddenSet.formUnion(alwaysHiddenSet)
            alwaysHiddenSet.removeAll()
        }

        var allowed = running
        // The always-hidden section is only ever shown as a peek; the hidden
        // one follows the plain toggle.
        if reveal != .all {
            allowed.subtract(alwaysHiddenSet)
        }
        if reveal == .none {
            allowed.subtract(hiddenSet)
        }
        allowed.formUnion(Self.ownIdentifiers)
        // Stable order also keeps an unchanged rule from looking like a new
        // command to the helper after a running-application refresh.
        return allowed.sorted()
    }
}

/// Portable, versioned snapshot of a user's BarLens configuration.
struct BarLensProfile: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var visibleBundles: [String]
    var hiddenBundles: [String]
    var alwaysHiddenBundles: [String]
    var systemItemAssignments: [String: String]
    var floatingBarOrder: [String]
    var alwaysHiddenEnabled: Bool
    var unclassifiedSection: String
    var newSystemItemSection: String
    var appearanceMode: String
    var revealPresentationStyle: String
    var floatingBarIconStyle: String
    var statusBarIconStyle: String
    var glassOpacity: Double
    var rimIntensity: Double
    var autoRehideInterval: Int
    var hoverRevealDelay: Int
    var appLanguage: String
    var hotkeys: [String: Hotkey]
    var lensTelemetryEnabled: Bool? = nil

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> BarLensProfile {
        var profile = try JSONDecoder().decode(BarLensProfile.self, from: data)
        profile.glassOpacity = min(max(profile.glassOpacity, 0.08), 0.75)
        profile.rimIntensity = min(max(profile.rimIntensity, 0.40), 1.50)
        profile.visibleBundles = profile.visibleBundles.filter { !SectionModel.notClassifiable.contains($0) }
        profile.hiddenBundles = profile.hiddenBundles.filter { !SectionModel.notClassifiable.contains($0) }
        profile.alwaysHiddenBundles = profile.alwaysHiddenBundles.filter { !SectionModel.notClassifiable.contains($0) }
        var normalizedSystem: [String: String] = [:]
        for (key, value) in profile.systemItemAssignments where SectionModel.Section(rawValue: value) != nil {
            normalizedSystem[SystemItemName.canonicalIdentifier(for: key)] = value
        }
        profile.systemItemAssignments = normalizedSystem
        return profile
    }
}
