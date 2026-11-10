import AppKit
import ApplicationServices
import CMenuBarPrivate

/// How a built-in item is configured in macOS System Settings → Menu Bar.
enum ControlCenterShowMode: String, Equatable {
    /// Set to "始终显示" (Always Show) in System Settings.
    case alwaysShow
    /// Checked in System Settings and set to "启用时显示" (Show When Active).
    case showWhenActive
    /// Unchecked ("不在菜单栏中显示") in System Settings.
    case disabled
}

/// Calibrates observations confirmed by the helper and a reliable AX read.
/// Standard built-in items (`0...8` and Control Center modules) are resolved
/// directly from `MenuBarClientCore` and `com.apple.controlcenter` preferences.
@MainActor
final class SystemItemDiscovery: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(identifier: String, step: Int, totalSteps: Int)
        case finished(recorded: [String], skipped: [String], unsupported: [String])
        case nothingToFind
        case failed(String)

        var isRunning: Bool {
            if case .scanning = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    private let settle: TimeInterval = 1
    private let readWorker = AXScanWorker(label: "BarLens.built-in-reads")
    private var readCancellation = AXScanCancellation()
    private var runGeneration = 0
    private weak var scanningEngine: DividerEngine?

    func start(engine: DividerEngine) {
        guard !phase.isRunning else { return }
        guard !engine.isRecovering, engine.connectionError == nil else {
            phase = .failed(tr("菜单栏正在重新连接，请稍后再扫描。", "Menu bar is reconnecting; please scan again shortly."))
            return
        }
        invalidateReads()
        scanningEngine = engine
        phase = .scanning(identifier: tr("菜单栏", "Menu Bar"), step: 0, totalSteps: 1)
        engine.refreshControlCenterModes()
        engine.beginSystemItemScan { [weak self] in
            self?.invalidateReads()
            self?.scanningEngine = nil
            self?.phase = .failed(tr("菜单栏状态发生变化，扫描已停止，请重新扫描。", "Menu bar state changed; scan stopped. Please try again."))
        }
        observeSuspend(engine: engine) { [weak self] present in
            guard let self else { return }
            let canonicalPresent = Set(present.map(SystemItemName.canonicalIdentifier(for:)))
            engine.pruneSystemItems(keeping: canonicalPresent)
            var newlyRecorded: [String] = []
            let defaults = SystemItemRegistry.defaultValues()
            for id in canonicalPresent.sorted() {
                if engine.systemItems.registry.rawValue(of: id) == nil {
                    let raw = defaults[id] ?? SystemItem.controlCenterManagedRawValue
                    if engine.recordSystemItem(id, rawValue: raw) {
                        newlyRecorded.append(id)
                    }
                }
            }
            let unknown = canonicalPresent.filter {
                engine.systemItems.registry.rawValue(of: $0) == nil
            }.sorted()
            guard !unknown.isEmpty else {
                if !newlyRecorded.isEmpty {
                    self.phase = .finished(recorded: newlyRecorded, skipped: [], unsupported: [])
                } else {
                    self.phase = .nothingToFind
                }
                engine.endSystemItemScan()
                self.scanningEngine = nil
                return
            }
            self.calibrateAll(unknown, preRecorded: newlyRecorded, engine: engine)
        }
    }

    func cancel() {
        invalidateReads()
        scanningEngine?.endSystemItemScan()
        scanningEngine = nil
        phase = .idle
    }

    private func invalidateReads() {
        runGeneration += 1
        readCancellation.cancel()
        readCancellation = AXScanCancellation()
    }

    private func fail(_ message: String, engine: DividerEngine) {
        invalidateReads()
        engine.endSystemItemScan()
        scanningEngine = nil
        phase = .failed(message)
    }

    private func readItems(engine: DividerEngine, requiresProbe: Bool,
                           attempt: Int = 0, completion: @escaping (Set<String>) -> Void) {
        let generation = runGeneration
        let cancellation = readCancellation
        let context = MenuBarBuiltIns.captureContext()
        readWorker.perform(cancellation: cancellation, work: {
            MenuBarBuiltIns.scan(context: context, cancellation: cancellation)
        }) { [weak self] result in
            guard let self, generation == self.runGeneration else { return }
            if requiresProbe && !engine.isSystemProbeApplied {
                self.fail(tr("菜单栏尚未确认本次扫描操作，请稍后重试。", "Menu bar did not acknowledge the scan probe; please try again."), engine: engine)
                return
            }
            switch result {
            case .success(let identifiers): completion(identifiers)
            case .failure(let error):
                if attempt < 2 && error != .cancelled && error != .permissionDenied {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self, generation == self.runGeneration else { return }
                        self.readItems(engine: engine, requiresProbe: requiresProbe,
                                       attempt: attempt + 1, completion: completion)
                    }
                } else {
                    self.fail(error.description, engine: engine)
                }
            }
        }
    }

    private func observeSuspend(engine: DividerEngine,
                                completion: @escaping (Set<String>) -> Void) {
        engine.suspendForSystemItemScan()
        awaitProbe(engine: engine, deadline: ProcessInfo.processInfo.systemUptime + 4,
                   generation: runGeneration, completion: completion)
    }

    private func observeProbe(_ extra: [Int], engine: DividerEngine,
                              completion: @escaping (Set<String>) -> Void) {
        engine.probeSystemItems(extra)
        awaitProbe(engine: engine, deadline: ProcessInfo.processInfo.systemUptime + 4,
                   generation: runGeneration, completion: completion)
    }

    private func awaitProbe(engine: DividerEngine, deadline: TimeInterval, generation: Int,
                            completion: @escaping (Set<String>) -> Void) {
        guard generation == runGeneration else { return }
        if engine.isSystemProbeApplied {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self, generation == self.runGeneration else { return }
                guard engine.isSystemProbeApplied else {
                    self.fail(tr("扫描期间菜单栏连接发生变化，请重试。", "Menu bar connection changed during scan; please try again."), engine: engine)
                    return
                }
                self.readItems(engine: engine, requiresProbe: true, completion: completion)
            }
        } else if ProcessInfo.processInfo.systemUptime >= deadline || engine.connectionError != nil {
            fail(tr("菜单栏尚未确认本次扫描操作，请稍后重试。", "Menu bar did not acknowledge the scan probe; please try again."), engine: engine)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.awaitProbe(engine: engine, deadline: deadline, generation: generation,
                                 completion: completion)
            }
        }
    }

    private func calibrateAll(_ identifiers: [String],
                              preRecorded: [String],
                              engine: DividerEngine) {
        let generation = runGeneration
        let count = Int(MBSystemItemRawValueCount)
        let bitCount = SystemItemBitmaskSolver.bitCount(for: count)
        phase = .scanning(identifier: tr("系统图标", "System Items"), step: 1, totalSteps: 1 + bitCount + identifiers.count)

        observeProbe([], engine: engine) { [weak self] baseline in
            guard let self, generation == self.runGeneration else { return }
            let canonicalBaseline = Set(baseline.map(SystemItemName.canonicalIdentifier(for:)))
            let partition = SystemItemBitmaskSolver.partitionBaseline(
                identifiers: identifiers,
                baselineVisible: canonicalBaseline)
            var recorded = preRecorded
            for id in partition.unsupported {
                if engine.recordSystemItem(id, rawValue: SystemItem.controlCenterManagedRawValue) {
                    recorded.append(id)
                }
            }
            guard !partition.addressable.isEmpty else {
                self.phase = .finished(recorded: recorded, skipped: [], unsupported: [])
                engine.endSystemItemScan()
                self.scanningEngine = nil
                return
            }
            let totalSteps = 1 + bitCount + partition.addressable.count
            self.probeBits(addressable: partition.addressable,
                           unsupported: [],
                           baseline: canonicalBaseline,
                           bit: 0,
                           bitCount: bitCount,
                           rawValueCount: count,
                           totalSteps: totalSteps,
                           candidates: [:],
                           preRecorded: recorded,
                           engine: engine)
        }
    }

    private func probeBits(addressable: [String],
                           unsupported: [String],
                           baseline: Set<String>,
                           bit: Int,
                           bitCount: Int,
                           rawValueCount: Int,
                           totalSteps: Int,
                           candidates: [String: Int],
                           preRecorded: [String],
                           engine: DividerEngine) {
        let generation = runGeneration
        guard bit < bitCount else {
            verifyCandidates(addressable: addressable,
                             index: 0,
                             candidates: candidates,
                             baseline: baseline,
                             stepOffset: 1 + bitCount,
                             totalSteps: totalSteps,
                             recorded: preRecorded,
                             skipped: [],
                             unsupported: unsupported,
                             engine: engine)
            return
        }
        phase = .scanning(identifier: tr("全部系统图标", "All System Items"), step: 2 + bit, totalSteps: totalSteps)
        let known = Set(engine.systemItems.registry.values.values.filter { $0 >= 0 })
        let mask = SystemItemBitmaskSolver.probeValues(forBit: bit,
                                                       count: rawValueCount,
                                                       knownValues: known)
        observeProbe(mask, engine: engine) { [weak self] visible in
            guard let self, generation == self.runGeneration else { return }
            let canonicalVisible = Set(visible.map(SystemItemName.canonicalIdentifier(for:)))
            let nextCandidates = SystemItemBitmaskSolver.foldBitObservation(
                addressable: addressable,
                visible: canonicalVisible,
                bit: bit,
                into: candidates)
            self.probeBits(addressable: addressable,
                           unsupported: unsupported,
                           baseline: baseline,
                           bit: bit + 1,
                           bitCount: bitCount,
                           rawValueCount: rawValueCount,
                           totalSteps: totalSteps,
                           candidates: nextCandidates,
                           preRecorded: preRecorded,
                           engine: engine)
        }
    }

    private func verifyCandidates(addressable: [String],
                                  index: Int,
                                  candidates: [String: Int],
                                  baseline: Set<String>,
                                  stepOffset: Int,
                                  totalSteps: Int,
                                  recorded: [String],
                                  skipped: [String],
                                  unsupported: [String],
                                  engine: DividerEngine) {
        guard index < addressable.count else {
            phase = .finished(recorded: recorded, skipped: skipped, unsupported: unsupported)
            engine.endSystemItemScan()
            scanningEngine = nil
            return
        }
        let generation = runGeneration
        let identifier = addressable[index]
        let candidate = candidates[identifier] ?? 0
        phase = .scanning(identifier: identifier, step: stepOffset + index, totalSteps: totalSteps)

        guard candidate >= 0, candidate < Int(MBSystemItemRawValueCount) else {
            verifyCandidates(addressable: addressable, index: index + 1, candidates: candidates,
                             baseline: baseline, stepOffset: stepOffset, totalSteps: totalSteps,
                             recorded: recorded, skipped: skipped + [identifier],
                             unsupported: unsupported, engine: engine)
            return
        }

        observeProbe([candidate], engine: engine) { [weak self] after in
            guard let self, generation == self.runGeneration else { return }
            let canonicalAfter = Set(after.map(SystemItemName.canonicalIdentifier(for:)))
            let isConfirmed = baseline.contains(identifier)
                && baseline.subtracting(canonicalAfter) == [identifier]
            var nextRecorded = recorded
            var nextSkipped = skipped
            if isConfirmed, engine.recordSystemItem(identifier, rawValue: candidate) {
                nextRecorded.append(identifier)
            } else {
                nextSkipped.append(identifier)
            }
            self.verifyCandidates(addressable: addressable, index: index + 1, candidates: candidates,
                                  baseline: baseline, stepOffset: stepOffset, totalSteps: totalSteps,
                                  recorded: nextRecorded, skipped: nextSkipped,
                                  unsupported: unsupported, engine: engine)
        }
    }
}

/// Pure combinatorial bitmask solver for parallel system item calibration.
enum SystemItemBitmaskSolver {
    static func bitCount(for count: Int) -> Int {
        guard count > 1 else { return 1 }
        return Int(ceil(log2(Double(count))))
    }

    static func partitionBaseline(identifiers: [String],
                                  baselineVisible: Set<String>) -> (addressable: [String], unsupported: [String]) {
        var addressable: [String] = []
        var unsupported: [String] = []
        for id in identifiers {
            if baselineVisible.contains(id) {
                addressable.append(id)
            } else {
                unsupported.append(id)
            }
        }
        return (addressable, unsupported)
    }

    static func probeValues(forBit bit: Int, count: Int, knownValues: Set<Int> = []) -> [Int] {
        (0..<count).filter { value in
            ((value >> bit) & 1) == 1 && !knownValues.contains(value)
        }
    }

    static func foldBitObservation(addressable: [String],
                                   visible: Set<String>,
                                   bit: Int,
                                   into candidates: [String: Int]) -> [String: Int] {
        var updated = candidates
        for id in addressable {
            if !visible.contains(id) {
                updated[id, default: 0] |= (1 << bit)
            } else if updated[id] == nil {
                updated[id] = 0
            }
        }
        return updated
    }
}

struct BuiltInScanContext {
    let processID: pid_t?
    let permissionGranted: Bool
}

/// Reads and updates Control Center ByHost preferences and traverses MenuBarAgent's wrappers.
enum MenuBarBuiltIns {
    private static let domain = "com.apple.controlcenter" as CFString

    static let controlCenterPreferenceKeys: [String: String] = [
        "com.apple.menuextra.battery":             "Battery",
        "com.apple.menuextra.bluetooth":           "Bluetooth",
        "com.apple.menuextra.display":             "Display",
        "com.apple.menuextra.keyboard-brightness": "KeyboardBrightness",
        "com.apple.menuextra.sound":               "Sound",
        "com.apple.menuextra.wifi":                "WiFi",
        "com.apple.menuextra.screen-mirroring":    "ScreenMirroring",
        "com.apple.menuextra.focusmode":           "FocusModes",
        "com.apple.menuextra.airdrop":             "AirDrop",
        "com.apple.menuextra.nowplaying":          "NowPlaying",
        "com.apple.menuextra.spotlight":           "Spotlight",
        "com.apple.menuextra.siri":                "Siri",
        "com.apple.menuextra.timemachine":         "TimeMachine",
        "com.apple.menuextra.timer":               "Timer",
        "com.apple.menuextra.weather":             "Weather",
        "com.apple.menuextra.user":                "UserSwitcher",
        "com.apple.menuextra.stagemanager":        "StageManager",
        "com.apple.menuextra.hearing":             "Hearing",
        "com.apple.menuextra.music":               "MusicRecognition",
    ]

    /// Items that expose a 3-state dropdown ("始终显示" / "启用时显示" / "永不显示") in
    /// System Settings → Menu Bar (`ControlCenterSettings.appex`).
    static let dropdownCapableIdentifiers: Set<String> = [
        "com.apple.menuextra.focusmode",
        "com.apple.menuextra.screen-mirroring",
        "com.apple.menuextra.display",
        "com.apple.menuextra.sound",
        "com.apple.menuextra.nowplaying",
        "com.apple.menuextra.timer",
    ]

    /// Items that default to `0` ("启用时显示") when no key has been written yet.
    private static let defaultShowWhenActiveIdentifiers: Set<String> = [
        "com.apple.menuextra.screen-mirroring",
        "com.apple.menuextra.display",
    ]

    /// Reads the current System Settings → Menu Bar visibility mode for all known items.
    static func controlCenterModes() -> [String: ControlCenterShowMode] {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let prefs = (CFPreferencesCopyMultiple(
            nil,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any]) ?? [:]

        var modes: [String: ControlCenterShowMode] = [
            "com.apple.menuextra.clock":         .alwaysShow,
            "com.apple.menuextra.controlcenter": .alwaysShow,
        ]

        for (identifier, prefKey) in controlCenterPreferenceKeys {
            let rawValue = prefs[prefKey] as? Int
            if identifier == "com.apple.menuextra.wifi" {
                modes[identifier] = (rawValue == 8) ? .disabled : .alwaysShow
                continue
            }
            if dropdownCapableIdentifiers.contains(identifier) {
                switch rawValue {
                case 16, 18:
                    modes[identifier] = .alwaysShow
                case 2, 0:
                    modes[identifier] = .showWhenActive
                case 8:
                    modes[identifier] = .disabled
                case nil:
                    modes[identifier] = defaultShowWhenActiveIdentifiers.contains(identifier)
                        ? .showWhenActive
                        : .disabled
                default:
                    if let rawValue, (rawValue & 16) != 0 {
                        modes[identifier] = .alwaysShow
                    } else {
                        modes[identifier] = (rawValue ?? 8) == 8 ? .disabled : .showWhenActive
                    }
                }
                continue
            }
            // Weather defaults to 2 in a fresh macOS profile even when not shown
            // on the bar; treat 16/18 as alwaysShow and everything else as disabled
            // unless observed live on AXExtrasMenuBar.
            if identifier == "com.apple.menuextra.weather" {
                modes[identifier] = (rawValue == 18 || rawValue == 16) ? .alwaysShow : .disabled
                continue
            }
            // Checkbox-only items (Battery, Bluetooth, AirDrop, KeyboardBrightness,
            // UserSwitcher, Spotlight, Siri, TimeMachine, StageManager, etc.)
            switch rawValue {
            case 16, 18, 2:
                modes[identifier] = .alwaysShow
            default:
                modes[identifier] = .disabled
            }
        }

        let textInputDomain = "com.apple.TextInputMenu" as CFString
        CFPreferencesSynchronize(textInputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let textInputVisible = (CFPreferencesCopyValue(
            "visible" as CFString,
            textInputDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? NSNumber)?.boolValue ?? false
        modes["com.apple.menuextra.textinput"] = textInputVisible ? .alwaysShow : .disabled

        return modes
    }

    static func disabledInControlCenter() -> Set<String> {
        let modes = controlCenterModes()
        return Set(modes.compactMap { $0.value == .disabled ? $0.key : nil })
    }

    /// Updates a Control Center item's ByHost preference (`18` = 始终显示, `2` = 启用时显示, `8` = 不显示)
    /// and notifies `ControlCenter.app` immediately.
    static func setControlCenterMode(_ mode: ControlCenterShowMode, for identifier: String) {
        let canonical = SystemItemName.canonicalIdentifier(for: identifier)
        if canonical == "com.apple.menuextra.textinput" {
            let visible = (mode != .disabled)
            let textInputDomain = "com.apple.TextInputMenu" as CFString
            let agentDomain = "com.apple.TextInputMenuAgent" as CFString
            CFPreferencesSetValue(
                "visible" as CFString,
                visible as CFBoolean,
                textInputDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            CFPreferencesSynchronize(textInputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSetValue(
                "NSStatusItem VisibleCC Item-0" as CFString,
                (visible ? 1 : 0) as CFNumber,
                agentDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            CFPreferencesSynchronize(agentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("AppleSelectedInputSourcesChangedNotification"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return
        }
        guard let prefKey = controlCenterPreferenceKeys[canonical] else { return }
        let numericValue: Int
        switch mode {
        case .alwaysShow:     numericValue = 18
        case .showWhenActive: numericValue = 2
        case .disabled:       numericValue = 8
        }
        CFPreferencesSetValue(
            prefKey as CFString,
            numericValue as CFNumber,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.usermenuextra.styledidchange"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func captureContext() -> BuiltInScanContext {
        precondition(Thread.isMainThread)
        return BuiltInScanContext(processID: NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier,
            permissionGranted: ItemEnumerator.hasAccessibilityPermission)
    }

    static func scan(context: BuiltInScanContext, cancellation: AXScanCancellation,
                     budget: TimeInterval = 2) -> Result<Set<String>, AXScanFailure> {
        precondition(!Thread.isMainThread)
        guard context.permissionGranted else { return .failure(.permissionDenied) }
        guard let pid = context.processID else { return .failure(.unavailable) }
        let reader = AXReadBudget(seconds: budget, cancellation: cancellation)
        do {
            let extras = try reader.element(AXUIElementCreateApplication(pid), "AXExtrasMenuBar")
            let children = try reader.children(extras)
            var identifiers: Set<String> = []
            for child in children {
                if let identifier = try firstIdentifier(in: child, depth: 0, reader: reader) {
                    identifiers.insert(SystemItemName.canonicalIdentifier(for: identifier))
                }
            }
            guard !identifiers.isEmpty else { return .failure(.unavailable) }
            return .success(identifiers)
        } catch let error as AXScanFailure { return .failure(error) }
        catch { return .failure(.unavailable) }
    }

    private static func firstIdentifier(in element: AXUIElement, depth: Int,
                                        reader: AXReadBudget) throws -> String? {
        if let identifier = try reader.string(element, kAXIdentifierAttribute as String), !identifier.isEmpty {
            return identifier
        }
        guard depth < 3 else { return nil }
        let children: [AXUIElement]
        do { children = try reader.children(element) }
        catch AXScanFailure.readFailed(let code)
            where code == AXError.noValue.rawValue || code == AXError.attributeUnsupported.rawValue {
            return nil
        }
        for child in children {
            if let identifier = try firstIdentifier(in: child, depth: depth + 1, reader: reader) {
                return identifier
            }
        }
        return nil
    }
}
