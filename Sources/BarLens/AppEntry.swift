import AppKit

/// One application in the settings list.
struct AppEntry: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var monochromeIcon: NSImage? = nil
    let section: SectionModel.Section
    /// Resolved while the list is built, off the main thread. An app that is
    /// not running keeps its assignment but has nothing on the bar to hide.
    let isRunning: Bool
    /// What this app's menu bar items call themselves, from `AXTitle`.
    ///
    /// Frequently *state* rather than identity — WeChat's is its unread count —
    /// and frequently missing entirely: the timer-machine item
    /// `com.apple.systemuiserver` puts on the bar publishes no title at all,
    /// and its only human-readable identity is inside the menu it opens
    /// ("自动备份：关闭"). So this is a best effort, never a complete list.
    let itemLabels: [String]
    /// True when this row exists because of the system's ledger rather than
    /// Accessibility — an app that owns an item but publishes no AX tree. There
    /// is nothing to enumerate about it, so the row says so instead of showing
    /// an empty item list that would read as a bug.
    let isLedgerOnly: Bool
    /// How many items the owner actually has on the bar, named or not.
    ///
    /// Deliberately not `itemLabels.count`: a bundle with one named item and one
    /// anonymous one would otherwise look like a single-item bundle and get
    /// called after the named one — which is how the Siri row spent a while
    /// claiming to be Siri while also carrying Time Machine.
    let itemCount: Int
    /// Whether this app has an explicit user assignment rather than inheriting
    /// the default section (`unclassified`).
    var isClassified: Bool = true
    /// Zero-capture live Accessibility telemetry distilled for BarLens's Semantic Lens.
    var telemetry: LensTelemetry = .empty
    /// Live memory footprint and CPU activity sampled via `proc_pid_rusage`.
    var vitals: ProcessVitals? = nil

    var id: String { bundleID }

    /// What to call this row.
    ///
    /// The item's own name when the bundle owns exactly one item and that name
    /// is a name; the app's otherwise.
    ///
    /// The app's name is a bad label for its item more often than you would
    /// expect. `com.apple.campo` is displayed as "Siri", and the only thing it
    /// puts on the bar is labelled "Spotlight" — a row called "Siri" would hide
    /// Spotlight while claiming to be Siri. Measured, after getting this wrong
    /// in both directions.
    ///
    /// The one-item condition is what keeps it honest for a bundle that carries
    /// several: `com.apple.systemuiserver` holds both Siri and Time Machine, and
    /// naming the row after either would misdescribe the other.
    ///
    /// The character test rejects state wearing a name's clothes: WeChat's item
    /// title is its unread count, and the row briefly read "4".
    var displayName: String {
        // One item *in total*, not one named item. A second, anonymous item is
        // still an item, and the row would be lying about what it controls.
        guard itemCount == 1, itemLabels.count == 1, let rawLabel = itemLabels.first else { return name }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count > 1, label.contains(where: \.isLetter) else { return name }
        // Only system helper bundles (such as `com.apple.campo` whose bundle is "Siri"
        // while its sole bar item is "Spotlight") or unnamed processes (`name == bundleID`)
        // should promote a static item label over the bundle's localized application name.
        // Third-party apps routinely publish live status strings ("Enhanced Mode",
        // "Wed 4:40 PM", "↑ 1.4 MB/s") in `AXTitle` that must never replace the app's name.
        guard bundleID.hasPrefix("com.apple.") || name == bundleID else { return name }
        guard !Self.looksLikeLiveTelemetryLabel(label) else { return name }
        // Keep the fuller name when one contains the other: Command X's item
        // calls itself "Command", which says less than the app's name does.
        let app = name.lowercased()
        let item = label.lowercased()
        guard !app.contains(item), !item.contains(app) else { return name }
        return label
    }

    static func looksLikeLiveTelemetryLabel(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.count > 28 || trimmed.contains("\n") { return true }
        if trimmed.contains(where: \.isNumber) { return true }
        let telemetrySymbols = CharacterSet(charactersIn: ":：%°$¥€£↑↓←→·•|/\\≈~<>+=")
        return trimmed.unicodeScalars.contains { telemetrySymbols.contains($0) }
    }

    /// The full explanation, for a tooltip.
    ///
    /// The subtitle has one line and a half a window to work with, so anything
    /// that needs a sentence goes here instead of being clipped. Hovering is
    /// also the right place for a caveat: it is there when you go looking and
    /// does not shout at everyone else.
    var hoverDetail: String {
        if isLedgerOnly {
            return tr(
                "来自系统清单，不是辅助功能，我们看不到它。\n\n清单记的是「注册过的项」，不是「此刻栏上的项」—— 若图标已在 App 内关闭，这里怎么设都不会有变化。\n\n\(bundleID)",
                "Discovered from the system menu bar ledger rather than Accessibility.\n\nThe ledger tracks registered items rather than currently visible ones — if the icon is disabled inside the app itself, changing its section here will have no effect.\n\n\(bundleID)"
            )
        }
        let what: String
        switch (itemCount, itemLabels.isEmpty) {
        case (1, true):
            what = tr("有一个菜单栏图标，未公布名字", "Owns 1 unnamed menu bar item")
        case (1, false):
            what = tr("菜单栏图标显示为「\(itemLabels[0])」", "Menu bar item displayed as “\(itemLabels[0])”")
        case (_, true):
            what = tr("有 \(itemCount) 个菜单栏图标", "Owns \(itemCount) menu bar items")
        default:
            what = tr(
                "有 \(itemCount) 个图标：\(itemLabels.joined(separator: "、"))",
                "Owns \(itemCount) items: \(itemLabels.joined(separator: ", "))"
            )
        }
        return tr(
            "\(what)。\n\n隐藏按 App 生效，会同时影响它的全部图标。\n\n" + (isRunning ? bundleID : "未运行 · \(bundleID)"),
            "\(what).\n\nHiding is applied per app and affects all of its menu bar items together.\n\n" + (isRunning ? bundleID : "Not Running · \(bundleID)")
        )
    }

    /// The second line: what this row controls, and the bundle identifier — the
    /// thing worth quoting when something goes wrong.
    ///
    /// The other item names are listed when there is more than one, because
    /// hiding this row takes all of them: `com.apple.systemuiserver` genuinely
    /// carries both Siri and Time Machine, and this is where you find that out
    /// *before* hiding it rather than after the icon vanishes.
    var detail: String {
        let bundle = isRunning ? bundleID : tr("未运行 · \(bundleID)", "Not Running · \(bundleID)")
        if isLedgerOnly { return tr("系统清单 · \(bundle)", "System Ledger · \(bundle)") }
        guard itemCount > 1 else { return bundle }
        let named = itemLabels.isEmpty
            ? "" : tr("「\(itemLabels.joined(separator: "、"))」", " (\(itemLabels.joined(separator: ", ")))")
        return tr("菜单栏上 \(itemCount) 个图标\(named) · \(bundle)", "\(itemCount) menu bar items\(named) · \(bundle)")
    }
}

struct AppInfo {
    let name: String
    let icon: NSImage?
    var monochromeIcon: NSImage? = nil
    var categoryType: String? = nil
}

/// Builds the settings list away from the main thread.
///
/// Filling the list means an Accessibility sweep across every running app plus
/// a name and icon lookup per row. On the main thread that is long enough to be
/// felt as a stutter when switching to the 划分 pane — the 通用 pane is static,
/// which is why going the other way never did.
final class Catalog: ObservableObject {

    @Published private(set) var entries: [AppEntry] = []
    /// True while a rebuild is in flight, so the refresh button can show it.
    @Published private(set) var isLoading = false
    /// How many listed apps have no explicit assignment and would therefore
    /// move if the default section changed. Counted here because this is the
    /// only place that knows which apps actually own a status item — counting
    /// running processes instead would report every background daemon.
    @Published private(set) var unclassifiedCount = 0

    private let queue = DispatchQueue(label: "BarLens.catalog", qos: .userInitiated)
    /// Bumped on the main thread; a result whose generation is stale is dropped.
    private var generation = 0
    /// Only touched on `queue`.
    private var info: [String: AppInfo] = [:]
    private var allEntries: [AppEntry] = []
    private var query = ""

    /// Typing filters the latest snapshot immediately; it must not enqueue an
    /// Accessibility sweep for every keystroke.
    func filter(query: String) {
        self.query = query
        entries = allEntries.filter { AppCatalog.matches($0, query: query) }
    }

    func rebuild(model: SectionModel, query: String,
                 extraOwners: Set<String> = [],
                 snapshot: [MenuBarItem]? = nil) {
        generation += 1
        let expected = generation
        self.query = query
        isLoading = true

        queue.async { [weak self] in
            guard let self else { return }
            let all = AppCatalog.entries(model: model, info: &self.info,
                                         extraOwners: extraOwners,
                                         snapshot: snapshot)
            // Counted over every app, not the filtered list: one the search is
            // hiding still moves when the default changes.
            let unclassified = all.filter { !model.isClassified($0.bundleID) }.count
            DispatchQueue.main.async {
                guard expected == self.generation else { return }
                self.allEntries = all
                self.entries = all.filter { AppCatalog.matches($0, query: self.query) }
                self.unclassifiedCount = unclassified
                self.isLoading = false
            }
        }
    }
}

enum AppCatalog {

    /// Every app worth listing: the ones that currently own a status item, plus
    /// anything already assigned, minus our own items.
    ///
    /// Apps with no status item are left out because there is nothing to decide
    /// about them; assigned ones stay listed even when not running, so an
    /// assignment cannot be silently lost by quitting an app.
    ///
    /// `info` memoises the LaunchServices lookups across rebuilds, which was
    /// most of the cost of opening the pane.
    ///
    /// Returns every app, unfiltered — the caller filters. Splitting it that way
    /// lets the caller count over the whole set without a second sweep.
    static func entries(model: SectionModel,
                        info: inout [String: AppInfo],
                        extraOwners: Set<String> = [],
                        snapshot: [MenuBarItem]? = nil) -> [AppEntry] {
        let discovered = snapshot ?? ItemEnumerator.enumerate()
        var ids = Set(discovered.map(\.ownerBundleID))
        // Owners the system ledger knows and AX does not. Without Full Disk
        // Access this is empty and nothing changes.
        ids.formUnion(extraOwners)
        ids.formUnion(model.alwaysHidden)
        ids.formUnion(model.hidden)
        // Including the explicitly-visible ones: otherwise classifying an app
        // visible and then quitting it would drop it from the list, taking the
        // only evidence of that decision with it.
        ids.formUnion(model.visible)
        ids.subtract(SectionModel.ownIdentifiers)
        ids.subtract(SectionModel.notClassifiable)

        var counts: [String: Int] = [:]
        for item in discovered { counts[item.ownerBundleID, default: 0] += 1 }

        var labels: [String: [String]] = [:]
        var rawTelemetryByOwner: [String: [RawAXItemTelemetry]] = [:]
        var dockBadgeByOwner: [String: String] = [:]
        var openWindowsByOwner: [String: [String]] = [:]
        for item in discovered {
            rawTelemetryByOwner[item.ownerBundleID, default: []].append(
                RawAXItemTelemetry(
                    indexInApp: item.indexInApp,
                    identifier: item.axIdentifier,
                    title: item.axTitle ?? item.label,
                    description: item.axDescription,
                    value: item.axValue,
                    help: item.axHelp,
                    menuEntries: item.axMenuEntries
                )
            )
            if let badge = item.dockBadge, !badge.isEmpty {
                dockBadgeByOwner[item.ownerBundleID] = badge
            }
            if !item.openWindowTitles.isEmpty {
                openWindowsByOwner[item.ownerBundleID] = item.openWindowTitles
            }
            // Digits are state, not identity: WeChat publishes its unread count
            // as its title, and a count in a list of names is noise that changes
            // underfoot. Words are kept even when they are also state —
            // Time Machine's item says "自动备份：关闭" and publishes nothing else.
            guard let label = item.label, label.count > 1,
                  label.contains(where: \.isLetter) else { continue }
            labels[item.ownerBundleID, default: []].append(label)
        }

        // Names and icons are worth caching; process liveness is not. Using a
        // single fresh snapshot makes quit/relaunch visible on every rebuild.
        let running = NSWorkspace.shared.runningApplications.reduce(into: [String: NSRunningApplication]()) {
            if let bundleID = $1.bundleIdentifier { $0[bundleID] = $1 }
        }
        let entries = ids.map { bundleID -> AppEntry in
            let app = running[bundleID]
            let details: AppInfo
            if let cached = info[bundleID],
               cached.name != bundleID,
               cached.icon != nil,
               (app == nil || cached.monochromeIcon != nil) {
                details = cached
            } else {
                details = resolveAppInfo(bundleID: bundleID, runningApp: app)
                info[bundleID] = details
            }
            let extractedTelemetry = (app != nil)
                ? SemanticLensExtractor.extract(
                    appName: details.name,
                    bundleID: bundleID,
                    items: rawTelemetryByOwner[bundleID] ?? [],
                    dockBadge: dockBadgeByOwner[bundleID],
                    categoryType: details.categoryType,
                    openWindows: openWindowsByOwner[bundleID] ?? []
                )
                : .empty
            let sampledVitals = app.flatMap { ProcessVitalsReader.shared.vitals(forPID: $0.processIdentifier) }
            return AppEntry(bundleID: bundleID,
                            name: details.name,
                            icon: details.icon,
                            monochromeIcon: details.monochromeIcon,
                            section: model.section(of: bundleID),
                            isRunning: app != nil,
                            itemLabels: labels[bundleID] ?? [],
                            isLedgerOnly: extraOwners.contains(bundleID)
                                && !counts.keys.contains(bundleID),
                            itemCount: counts[bundleID] ?? 0,
                            isClassified: model.isClassified(bundleID),
                            telemetry: extractedTelemetry,
                            vitals: sampledVitals)
        }

        return entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func enclosingApplicationBundleURL(for bundleURL: URL) -> URL? {
        var cursor = bundleURL.standardizedFileURL.deletingLastPathComponent()
        var outermostPath: String?
        while cursor.path.count > 1 && cursor.path != "/" {
            if cursor.pathExtension.lowercased() == "app" {
                outermostPath = cursor.path
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path { break }
            cursor = next
        }
        return outermostPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func preferredApplicationName(primaryName: String?,
                                         parentAppName: String?,
                                         bundleID: String) -> String {
        let cleanPrimary = primaryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanParent = parentAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if cleanPrimary.isEmpty || cleanPrimary == bundleID {
            return cleanParent.isEmpty ? bundleID : cleanParent
        }
        guard !cleanParent.isEmpty else { return cleanPrimary }

        let lowerPrimary = cleanPrimary.lowercased()
        let lowerParent = cleanParent.lowercased()
        if lowerPrimary.contains(".") && !cleanPrimary.contains(" ") {
            return cleanParent
        }
        let words = identifierWords(cleanPrimary)
        let singleWordHelperSuffixes: Set<String> = [
            "helper", "agent", "launcher", "daemon", "service",
            "loginitem", "menubarextra", "menubar", "statusitem"
        ]
        if let lastWord = words.last, singleWordHelperSuffixes.contains(lastWord) {
            return cleanParent
        }
        let multiWordHelperSuffixes: [[String]] = [
            ["login", "item"],
            ["menu", "bar"],
            ["menu", "bar", "extra"],
            ["status", "item"]
        ]
        if multiWordHelperSuffixes.contains(where: { Array(words.suffix($0.count)) == $0 }) {
            return cleanParent
        }
        if lowerPrimary.hasPrefix(lowerParent)
            && words.contains(where: { singleWordHelperSuffixes.contains($0) }) {
            return cleanParent
        }
        return cleanPrimary
    }

    private static func identifierWords(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        var words: [String] = []
        var current = ""
        for index in scalars.indices {
            let scalar = scalars[index]
            if !CharacterSet.alphanumerics.contains(scalar) {
                if !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                continue
            }
            if !current.isEmpty, CharacterSet.uppercaseLetters.contains(scalar) {
                let prev = scalars[index - 1]
                let prevIsLowerOrDigit = CharacterSet.lowercaseLetters.contains(prev)
                    || CharacterSet.decimalDigits.contains(prev)
                let nextIsLower = (index + 1 < scalars.count)
                    && CharacterSet.lowercaseLetters.contains(scalars[index + 1])
                if prevIsLowerOrDigit || (CharacterSet.uppercaseLetters.contains(prev) && nextIsLower) {
                    words.append(current.lowercased())
                    current = ""
                }
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty {
            words.append(current.lowercased())
        }
        return words
    }

    private static func localizedBundleDisplayName(for appURL: URL) -> String? {
        if let bundle = Bundle(url: appURL) {
            if let locDisplay = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
               !locDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return locDisplay
            }
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return display
            }
            if let locName = bundle.localizedInfoDictionary?["CFBundleName"] as? String,
               !locName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return locName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        let raw = appURL.deletingPathExtension().lastPathComponent
        return raw.isEmpty ? nil : raw
    }

    private static func hasCustomBundleIcon(at appURL: URL?) -> Bool {
        guard let appURL, let bundle = Bundle(url: appURL) else { return false }
        if let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    static func lightweightIdentity(bundleID: String,
                                    runningApp: NSRunningApplication?) -> (name: String, categoryType: String?) {
        let resolvedURL = runningApp?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let parentAppURL = resolvedURL.flatMap { enclosingApplicationBundleURL(for: $0) }
        let directName = runningApp?.localizedName ?? resolvedURL.flatMap { localizedBundleDisplayName(for: $0) }
        let parentName = parentAppURL.flatMap { localizedBundleDisplayName(for: $0) }
        let finalName = preferredApplicationName(
            primaryName: directName,
            parentAppName: parentName,
            bundleID: bundleID
        )
        let catType = (resolvedURL.flatMap(Bundle.init(url:))?.infoDictionary?["LSApplicationCategoryType"] as? String)
            ?? (parentAppURL.flatMap(Bundle.init(url:))?.infoDictionary?["LSApplicationCategoryType"] as? String)
        return (finalName, catType)
    }

    private static func resolveAppInfo(bundleID: String, runningApp: NSRunningApplication?) -> AppInfo {
        let resolvedURL = runningApp?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let parentAppURL = resolvedURL.flatMap { enclosingApplicationBundleURL(for: $0) }

        let directName = runningApp?.localizedName ?? resolvedURL.flatMap { localizedBundleDisplayName(for: $0) }
        let parentName = parentAppURL.flatMap { localizedBundleDisplayName(for: $0) }
        let finalName = preferredApplicationName(
            primaryName: directName,
            parentAppName: parentName,
            bundleID: bundleID
        )

        let rawIcon: NSImage?
        if let parentAppURL, !hasCustomBundleIcon(at: resolvedURL) {
            rawIcon = NSWorkspace.shared.icon(forFile: parentAppURL.path)
        } else if let appIcon = runningApp?.icon {
            rawIcon = appIcon
        } else if let resolvedURL {
            rawIcon = NSWorkspace.shared.icon(forFile: resolvedURL.path)
        } else {
            rawIcon = nil
        }

        let monoIcon = AppIconGlyphExtractor.extractMonochromeGlyph(
            bundleURL: resolvedURL,
            fallbackBundleURL: parentAppURL,
            appIcon: rawIcon
        )

        let catType = (resolvedURL.flatMap(Bundle.init(url:))?.infoDictionary?["LSApplicationCategoryType"] as? String)
            ?? (parentAppURL.flatMap(Bundle.init(url:))?.infoDictionary?["LSApplicationCategoryType"] as? String)

        return AppInfo(
            name: finalName,
            icon: rawIcon,
            monochromeIcon: monoIcon,
            categoryType: catType
        )
    }

    static func matches(_ entry: AppEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return entry.name.localizedCaseInsensitiveContains(trimmed)
            || entry.displayName.localizedCaseInsensitiveContains(trimmed)
            || entry.bundleID.localizedCaseInsensitiveContains(trimmed)
            || entry.itemLabels.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            || (entry.telemetry.fullSummary?.localizedCaseInsensitiveContains(trimmed) == true)
    }
}

/// Extracts a clean monochrome menu-bar template glyph from an application's
/// bundle resources or Dock icon without requiring Screen Recording permission.
enum AppIconGlyphExtractor {

    static func extractMonochromeGlyph(bundleURL: URL?,
                                       fallbackBundleURL: URL? = nil,
                                       appIcon: NSImage?,
                                       outSize: CGFloat = 64) -> NSImage? {
        for candidateURL in [bundleURL, fallbackBundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: candidateURL),
               let resURL = bundle.resourceURL,
               let files = try? FileManager.default.contentsOfDirectory(at: resURL, includingPropertiesForKeys: nil),
               let match = files.first(where: {
                   let name = $0.lastPathComponent.lowercased()
                   return (name.contains("template") || name.contains("statusbar") || name.contains("menubar") || name.contains("tray"))
                       && (name.hasSuffix(".png") || name.hasSuffix(".pdf") || name.hasSuffix(".svg"))
                       && !name.contains("picker")
               }),
               let img = NSImage(contentsOf: match) {
                return renderAsTemplateAlpha(img, outSize: outSize)
            }
        }

        guard let appIcon else { return nil }
        let N = 128
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: N, pixelsHigh: N,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: N * 4, bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        appIcon.draw(in: NSRect(x: 0, y: 0, width: N, height: N), from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let ptr = rep.bitmapData else { return nil }

        func pixel(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let cx = max(0, min(N - 1, x))
            let cy = max(0, min(N - 1, y))
            let idx = (cy * N + cx) * 4
            let a = CGFloat(ptr[idx + 3]) / 255.0
            guard a > 0.01 else { return (0, 0, 0, 0) }
            return (min(1, CGFloat(ptr[idx]) / 255.0 / a),
                    min(1, CGFloat(ptr[idx + 1]) / 255.0 / a),
                    min(1, CGFloat(ptr[idx + 2]) / 255.0 / a),
                    a)
        }

        let cx = Double(N) * 0.5
        let cy = Double(N) * 0.5

        var outerRingSamples: [(r: CGFloat, g: CGFloat, b: CGFloat, y: Double)] = []
        var innerRingSamples: [(r: CGFloat, g: CGFloat, b: CGFloat, y: Double)] = []
        for i in 0..<64 {
            let ang = Double(i) * (.pi * 2.0 / 64.0)
            let yOut = cy + sin(ang) * Double(N) * 0.37
            let pOut = pixel(Int(cx + cos(ang) * Double(N) * 0.37), Int(yOut))
            if pOut.a > 0.85 { outerRingSamples.append((pOut.r, pOut.g, pOut.b, yOut)) }
            let yIn = cy + sin(ang) * Double(N) * 0.285
            let pIn = pixel(Int(cx + cos(ang) * Double(N) * 0.285), Int(yIn))
            if pIn.a > 0.85 { innerRingSamples.append((pIn.r, pIn.g, pIn.b, yIn)) }
        }

        var hasInnerBadge = false
        if !outerRingSamples.isEmpty && !innerRingSamples.isEmpty {
            var diffCount = 0
            for i in 0..<min(outerRingSamples.count, innerRingSamples.count) {
                let o = outerRingSamples[i]
                let inn = innerRingSamples[i]
                let d = hypot(hypot(o.r - inn.r, o.g - inn.g), o.b - inn.b)
                let satIn = max(inn.r, max(inn.g, inn.b)) - min(inn.r, min(inn.g, inn.b))
                if d > 0.22 && satIn > 0.22 { diffCount += 1 }
            }
            hasInnerBadge = diffCount >= min(outerRingSamples.count, innerRingSamples.count) * 70 / 100
        }

        let ring = hasInnerBadge ? innerRingSamples : outerRingSamples
        func medianColor(_ items: [(r: CGFloat, g: CGFloat, b: CGFloat, y: Double)]) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            guard !items.isEmpty else { return (1, 1, 1) }
            let rs = items.map(\.r).sorted()
            let gs = items.map(\.g).sorted()
            let bs = items.map(\.b).sorted()
            let mid = items.count / 2
            return (rs[mid], gs[mid], bs[mid])
        }
        let topBG = medianColor(ring.filter { $0.y <= cy })
        let botBG = medianColor(ring.filter { $0.y >= cy })

        let activeRadius = hasInnerBadge ? Double(N) * 0.245 : Double(N) * 0.31
        let cropMin = Int(Double(N) * 0.18)
        let cropMax = Int(Double(N) * 0.82)
        let M = cropMax - cropMin

        var maxDist: CGFloat = 0.01
        var dists = [CGFloat](repeating: 0, count: M * M)

        for y in 0..<M {
            let sy = cropMin + y
            let ty = CGFloat(max(0, min(1, Double(y) / Double(max(1, M - 1)))))
            let bg = (
                r: topBG.r * (1 - ty) + botBG.r * ty,
                g: topBG.g * (1 - ty) + botBG.g * ty,
                b: topBG.b * (1 - ty) + botBG.b * ty
            )

            for x in 0..<M {
                let sx = cropMin + x
                let dx = (Double(sx) - cx) / activeRadius
                let dy = (Double(sy) - cy) / activeRadius
                let r2 = dx * dx + dy * dy
                if r2 > 1.0 { continue }

                let p = pixel(sx, sy)
                guard p.a > 0.25 else { continue }
                let d = hypot(hypot(p.r - bg.r, p.g - bg.g), p.b - bg.b)
                let edgeFade = CGFloat(max(0.0, min(1.0, (1.0 - r2) * 5.0)))
                let val = d * p.a * edgeFade
                dists[y * M + x] = val
                if val > maxDist { maxDist = val }
            }
        }

        let low = maxDist * 0.24
        let high = maxDist * 0.50
        var alphas = [CGFloat](repeating: 0, count: M * M)
        var minX = M, maxX = 0, minY = M, maxY = 0
        for y in 0..<M {
            for x in 0..<M {
                let i = y * M + x
                let t = max(0, min(1, (dists[i] - low) / max(0.01, high - low)))
                alphas[i] = t
                if t > 0.15 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX > minX, maxY > minY else { return nil }
        let K = 64
        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: K, pixelsHigh: K,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: K * 4, bitsPerPixel: 32
        ), let outPtr = outRep.bitmapData else { return nil }

        let bw = CGFloat(maxX - minX + 1)
        let bh = CGFloat(maxY - minY + 1)
        let span = max(bw, bh)
        let targetSpan = CGFloat(K) * 0.78
        let scale = min(1.30, targetSpan / max(1, span))
        let dw = bw * scale
        let dh = bh * scale
        let ox = (CGFloat(K) - dw) * 0.5
        let oy = (CGFloat(K) - dh) * 0.5

        for ky in 0..<K {
            for kx in 0..<K {
                let fx = (CGFloat(kx) + 0.5 - ox) / scale + CGFloat(minX) - 0.5
                let fy = (CGFloat(ky) + 0.5 - oy) / scale + CGFloat(minY) - 0.5
                guard fx >= CGFloat(minX) - 0.5, fx <= CGFloat(maxX) + 0.5,
                      fy >= CGFloat(minY) - 0.5, fy <= CGFloat(maxY) + 0.5 else { continue }
                let x0 = max(0, min(M - 1, Int(floor(fx))))
                let y0 = max(0, min(M - 1, Int(floor(fy))))
                let x1 = max(0, min(M - 1, x0 + 1))
                let y1 = max(0, min(M - 1, y0 + 1))
                let tx = max(0, min(1, fx - floor(fx)))
                let ty = max(0, min(1, fy - floor(fy)))
                let a00 = alphas[y0 * M + x0]
                let a10 = alphas[y0 * M + x1]
                let a01 = alphas[y1 * M + x0]
                let a11 = alphas[y1 * M + x1]
                let a = (a00 * (1 - tx) + a10 * tx) * (1 - ty) + (a01 * (1 - tx) + a11 * tx) * ty
                let byte = UInt8(round(max(0, min(1, a)) * 255.0))
                let idx = (ky * K + kx) * 4
                outPtr[idx] = byte
                outPtr[idx + 1] = byte
                outPtr[idx + 2] = byte
                outPtr[idx + 3] = byte
            }
        }

        let finalImg = NSImage(size: NSSize(width: outSize, height: outSize))
        outRep.size = NSSize(width: outSize, height: outSize)
        finalImg.addRepresentation(outRep)
        finalImg.isTemplate = true
        return finalImg
    }

    private static func renderAsTemplateAlpha(_ src: NSImage, outSize: CGFloat) -> NSImage {
        let M = 64
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: M, pixelsHigh: M,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: M * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let copy = (src.copy() as? NSImage) ?? src
        copy.isTemplate = false
        copy.draw(in: NSRect(x: 6, y: 6, width: M - 12, height: M - 12), from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        if let ptr = rep.bitmapData {
            for i in 0..<(M * M) {
                let a = ptr[i * 4 + 3]
                ptr[i * 4] = a
                ptr[i * 4 + 1] = a
                ptr[i * 4 + 2] = a
            }
        }
        let out = NSImage(size: NSSize(width: outSize, height: outSize))
        rep.size = NSSize(width: outSize, height: outSize)
        out.addRepresentation(rep)
        out.isTemplate = true
        return out
    }
}
