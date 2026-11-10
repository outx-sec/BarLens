import Foundation

/// Who owns a status item, according to the system's own bookkeeping.
///
/// Accessibility is the usual answer and the one everything else here is built
/// on — but it is a third-party-facing interface, and an app is free not to
/// publish it. Little Snitch's agent exposes three attributes (`AXFrame`,
/// `AXPosition`, `AXSize`) and not even an `AXRole`; there is no AX query that
/// will ever see its icon.
///
/// The system has no such option. Every status item is registered with
/// MenuBarAgent, and two preferences files record the result — the same data
/// System Settings builds its "允许在菜单栏显示" list from. Both live in group
/// containers, which are unreadable without Full Disk Access.
///
/// Hence the shape of this type: everything returns `nil` rather than an empty
/// set when the files cannot be read, so callers can tell "we could not look"
/// from "nothing is there" and fall back to AX-only silently.
enum MenuBarLedger {

    /// Bundle identifiers that own at least one status item.
    ///
    /// `nil` when neither file could be read — no Full Disk Access, most
    /// likely. An empty set would mean the files were readable and named
    /// nothing, which does not happen in practice.
    static func ownerBundleIDs() -> Set<String>? {
        let menuBar = readMenuBarLedger()
        let controlCenter = readControlCenterLedger()
        if menuBar == nil && controlCenter == nil { return nil }
        let disabled = disabledBundleIDs()
        return (menuBar ?? []).union(controlCenter ?? []).subtracting(disabled)
    }

    /// Bundle identifiers explicitly disabled in System Settings → Menu Bar ("Allow in the Menu Bar" = off).
    static func disabledBundleIDs() -> Set<String> {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.controlcenter"
                       + "/Library/Preferences/group.com.apple.controlcenter.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let tracked = plist["trackedApplications"] else {
            return []
        }
        let entries: [[String: Any]]
        if let raw = tracked as? Data {
            guard let inner = try? PropertyListSerialization.propertyList(
                from: raw, options: [], format: nil) as? [[String: Any]] else { return [] }
            entries = inner
        } else if let list = tracked as? [[String: Any]] {
            entries = list
        } else {
            return []
        }

        var disabled: Set<String> = []
        func collect(_ node: Any?) {
            guard let node = node as? [String: Any] else { return }
            if let bundle = node["bundle"] as? [String: Any], let id = bundle["_0"] as? String {
                disabled.insert(id)
            }
        }
        for entry in entries {
            if let isAllowed = entry["isAllowed"] as? Bool, !isAllowed {
                collect(entry["location"])
                for location in entry["menuItemLocations"] as? [Any] ?? [] { collect(location) }
            }
        }
        return disabled
    }

    /// `com.apple.MenuBar`'s ledger, whose keys are `status:<identity>::<name>`.
    ///
    /// The identity is a bundle identifier when LaunchServices knows the app and
    /// the process name when it does not — which is how an app run from a build
    /// directory ends up filed under its executable. Callers intersect this with
    /// running applications, so the process-name form drops out on its own.
    private static func readMenuBarLedger() -> Set<String>? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/com.apple.MenuBar"
                       + "/Library/Preferences/com.apple.MenuBar.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let positions = plist["TrailingItemPreferredPositions"] as? [String: Any] else {
            return nil
        }

        var owners: Set<String> = []
        for key in positions.keys where key.hasPrefix("status:") {
            // status:<identity>::<autosaveName> — the autosave name may itself
            // contain colons, so split once and cut at the first separator.
            let rest = key.dropFirst("status:".count)
            guard let separator = rest.range(of: "::") else { continue }
            owners.insert(String(rest[rest.startIndex..<separator.lowerBound]))
        }
        return owners
    }

    /// ControlCenter's `trackedApplications`.
    ///
    /// This is the list System Settings shows. Each entry names the app the row
    /// is *displayed* as, and separately the bundle whose item it actually is —
    /// `com.example.App` for the row, `com.example.App.agent` for the item.
    /// Both are collected, because either may be the one the visibility
    /// restriction matches on.
    private static func readControlCenterLedger() -> Set<String>? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.controlcenter"
                       + "/Library/Preferences/group.com.apple.controlcenter.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let tracked = plist["trackedApplications"] else {
            return nil
        }

        // Stored as a nested binary plist inside the outer one.
        let entries: [[String: Any]]
        if let raw = tracked as? Data {
            guard let inner = try? PropertyListSerialization.propertyList(
                from: raw, options: [], format: nil) as? [[String: Any]] else { return nil }
            entries = inner
        } else if let list = tracked as? [[String: Any]] {
            entries = list
        } else {
            return nil
        }

        var owners: Set<String> = []
        func collect(_ node: Any?) {
            guard let node = node as? [String: Any] else { return }
            if let bundle = node["bundle"] as? [String: Any], let id = bundle["_0"] as? String {
                owners.insert(id)
            }
        }
        for entry in entries {
            if let isAllowed = entry["isAllowed"] as? Bool, !isAllowed {
                continue
            }
            let itemLocations = entry["menuItemLocations"] as? [Any] ?? []
            if !itemLocations.isEmpty {
                for location in itemLocations { collect(location) }
            } else {
                collect(entry["location"])
            }
        }
        return owners
    }
}
