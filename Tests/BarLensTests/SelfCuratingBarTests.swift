import XCTest
@testable import BarLens

final class SelfCuratingBarTests: XCTestCase {

    // MARK: - 1. Usage Auto-Decay & Grace Windows

    func testUsageDecayGrantsGracePeriodAndExemptsPinnedApps() {
        let day: TimeInterval = 86_400
        let t0: TimeInterval = 1_750_000_000

        let candidates = [
            // Newly installed 2 days ago, untouched -> still inside 7-day grace window
            UsageDecayCandidate(
                bundleID: "com.app.fresh",
                isPinnedExempt: false,
                firstSeenAt: t0 + 5 * day,
                lastInteractedAt: 0
            ),
            // Installed 10 days ago, untouched -> exceeds 7-day idle window
            UsageDecayCandidate(
                bundleID: "com.app.stale",
                isPinnedExempt: false,
                firstSeenAt: t0 - 3 * day,
                lastInteractedAt: 0
            ),
            // Installed 20 days ago, clicked yesterday -> active, must stay visible
            UsageDecayCandidate(
                bundleID: "com.app.clickedRecently",
                isPinnedExempt: false,
                firstSeenAt: t0 - 13 * day,
                lastInteractedAt: t0 + 6 * day
            ),
            // Installed 60 days ago, untouched, but Pinned -> exempt forever
            UsageDecayCandidate(
                bundleID: "com.app.pinned",
                isPinnedExempt: true,
                firstSeenAt: t0 - 53 * day,
                lastInteractedAt: 0
            ),
        ]

        let now = t0 + 7 * day
        let decayed = UsageDecayPlanner.evaluate(
            policy: .days7,
            candidates: candidates,
            policyBaselineAt: t0,
            now: now
        )
        XCTAssertEqual(decayed, ["com.app.stale"])

        // Re-enabling policy at `now - 2 days` must grant a fresh 7-day grace period even to old untouched apps!
        let graceProtected = UsageDecayPlanner.evaluate(
            policy: .days7,
            candidates: candidates,
            policyBaselineAt: now - 2 * day,
            now: now
        )
        XCTAssertTrue(graceProtected.isEmpty)

        // `.off` never decays anything
        let offResult = UsageDecayPlanner.evaluate(
            policy: .off,
            candidates: candidates,
            policyBaselineAt: 0,
            now: now + 90 * day
        )
        XCTAssertTrue(offResult.isEmpty)
    }

    func testActivityBadgeTextFormatting() {
        let day: TimeInterval = 86_400
        let now: TimeInterval = 1_750_100_000

        let pinnedBadge = UsageDecayPlanner.activityBadgeText(
            lastInteractedAt: 0,
            firstSeenAt: now - 30 * day,
            isPinnedExempt: true,
            policy: .days7,
            policyBaselineAt: now - 30 * day,
            now: now
        )
        XCTAssertFalse(pinnedBadge.isEmpty)

        let graceBadge = UsageDecayPlanner.activityBadgeText(
            lastInteractedAt: 0,
            firstSeenAt: now - 2 * day,
            isPinnedExempt: false,
            policy: .days7,
            policyBaselineAt: now - 10 * day,
            now: now
        )
        XCTAssertTrue(graceBadge.contains("5"))

        let idleBadge = UsageDecayPlanner.activityBadgeText(
            lastInteractedAt: now - 4 * day,
            firstSeenAt: now - 20 * day,
            isPinnedExempt: false,
            policy: .days7,
            policyBaselineAt: now - 20 * day,
            now: now
        )
        XCTAssertTrue(idleBadge.contains("4"))
    }

    // MARK: - 2. Passive Top-Bar Coordinate Hit-Testing

    func testTopBarClickTrackerMapsAppKitBottomLeftToQuartzTopLeftAcrossDisplays() {
        let primaryID = DisplayID(rawValue: 1, localizedName: "Primary")
        let secondaryID = DisplayID(rawValue: 2, localizedName: "Left External")

        let screens = [
            TopBarClickTracker.ScreenDescriptor(
                displayID: primaryID,
                appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
            ),
            TopBarClickTracker.ScreenDescriptor(
                displayID: secondaryID,
                appKitFrame: CGRect(x: -1920, y: -98, width: 1920, height: 1080),
                cgBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            ),
        ]

        let items = [
            MenuBarItem(
                ownerBundleID: "com.apple.MenuBarAgent",
                ownerPID: 100,
                frame: CGRect(x: 1400, y: 4, width: 32, height: 24),
                display: primaryID,
                axIdentifier: nil,
                label: "Clock",
                indexInApp: 0
            ),
            MenuBarItem(
                ownerBundleID: "com.barlens.app",
                ownerPID: 101,
                frame: CGRect(x: 1200, y: 4, width: 24, height: 24),
                display: primaryID,
                axIdentifier: "BarLens.dot",
                label: "BarLens.dot",
                indexInApp: 0
            ),
            MenuBarItem(
                ownerBundleID: "com.raycast.macos",
                ownerPID: 102,
                frame: CGRect(x: 1120, y: 4, width: 28, height: 24),
                display: primaryID,
                axIdentifier: nil,
                label: nil,
                indexInApp: 0
            ),
            MenuBarItem(
                ownerBundleID: "com.tinyspeck.slackmacgap",
                ownerPID: 103,
                frame: CGRect(x: -420, y: 6, width: 28, height: 24),
                display: secondaryID,
                axIdentifier: nil,
                label: nil,
                indexInApp: 0
            ),
        ]

        // Click on Raycast in primary top menu bar (AppKit y = 970 -> distanceFromTop = 12 -> Quartz y = 12)
        let hitPrimary = TopBarClickTracker.matchedOwnerBundleID(
            appKitClickPoint: CGPoint(x: 1132, y: 970),
            screens: screens,
            items: items,
            ownIdentifiers: ["com.barlens.app"],
            notClassifiable: SectionModel.notClassifiable
        )
        XCTAssertEqual(hitPrimary, "com.raycast.macos")

        // Click below menu bar band (AppKit y = 800 -> distanceFromTop = 182) must return nil immediately
        let desktopClick = TopBarClickTracker.matchedOwnerBundleID(
            appKitClickPoint: CGPoint(x: 1132, y: 800),
            screens: screens,
            items: items,
            ownIdentifiers: ["com.barlens.app"],
            notClassifiable: SectionModel.notClassifiable
        )
        XCTAssertNil(desktopClick)

        // Click on BarLens own dot or MenuBarAgent must be ignored
        XCTAssertNil(TopBarClickTracker.matchedOwnerBundleID(
            appKitClickPoint: CGPoint(x: 1210, y: 970),
            screens: screens,
            items: items,
            ownIdentifiers: ["com.barlens.app"],
            notClassifiable: SectionModel.notClassifiable
        ))
        XCTAssertNil(TopBarClickTracker.matchedOwnerBundleID(
            appKitClickPoint: CGPoint(x: 1412, y: 970),
            screens: screens,
            items: items,
            ownIdentifiers: ["com.barlens.app"],
            notClassifiable: SectionModel.notClassifiable
        ))

        // Click on Slack on negative-X secondary display (screen maxY = 982; click y = 968 -> distanceFromTop = 14)
        let hitSecondary = TopBarClickTracker.matchedOwnerBundleID(
            appKitClickPoint: CGPoint(x: -408, y: 968),
            screens: screens,
            items: items,
            ownIdentifiers: ["com.barlens.app"],
            notClassifiable: SectionModel.notClassifiable
        )
        XCTAssertEqual(hitSecondary, "com.tinyspeck.slackmacgap")
    }

    // MARK: - 3. Zero-Capture Status Bubble-Up & Anti-Noise Filters

    func testStatusBubbleTrackerBaselinesSilentlyAndSurfacesUnreadAndWarnings() {
        var tracker = StatusBubbleTracker()
        let t0: TimeInterval = 1_750_200_000

        let initialUnread = ObservedSemanticSnapshot(
            unreadCount: 2,
            unreadOverflow: false,
            statusTone: .neutral,
            discreteStateSignature: nil,
            displaySummary: nil
        )
        // First observation must establish baseline silently without firing a bubble
        XCTAssertNil(tracker.observe(
            bundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            snapshot: initialUnread,
            allowBubbling: true,
            now: t0
        ))

        // Unread count grows 2 -> 5 -> must fire `.unreadIncreased("5")`
        let grownUnread = ObservedSemanticSnapshot(
            unreadCount: 5,
            unreadOverflow: false,
            statusTone: .neutral,
            discreteStateSignature: nil,
            displaySummary: nil
        )
        let event1 = tracker.observe(
            bundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            snapshot: grownUnread,
            allowBubbling: true,
            now: t0 + 4
        )
        XCTAssertEqual(event1?.reason, .unreadIncreased(badge: "5"))

        // Reading messages (5 -> 0) must NOT fire a bubble
        let clearedUnread = ObservedSemanticSnapshot(
            unreadCount: 0,
            unreadOverflow: false,
            statusTone: .neutral,
            discreteStateSignature: nil,
            displaySummary: nil
        )
        XCTAssertNil(tracker.observe(
            bundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            snapshot: clearedUnread,
            allowBubbling: true,
            now: t0 + 15
        ))

        // Subsequent new message after reading (0 -> 1) must bubble up again immediately
        let newSingleUnread = ObservedSemanticSnapshot(
            unreadCount: 1,
            unreadOverflow: false,
            statusTone: .neutral,
            discreteStateSignature: nil,
            displaySummary: nil
        )
        let eventAfterClear = tracker.observe(
            bundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            snapshot: newSingleUnread,
            allowBubbling: true,
            now: t0 + 19
        )
        XCTAssertEqual(eventAfterClear?.reason, .unreadIncreased(badge: "1"))

        // Clear unread again before testing warning escalation
        _ = tracker.observe(
            bundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            snapshot: clearedUnread,
            allowBubbling: true,
            now: t0 + 23
        )

        // Warning escalation (`neutral` -> `warning`) fires `.warningAlert`
        let warningSnap = ObservedSemanticSnapshot(
            unreadCount: 0,
            unreadOverflow: false,
            statusTone: .warning,
            discreteStateSignature: "sync failed",
            displaySummary: "Sync Failed"
        )
        let warnEvent = tracker.observe(
            bundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            snapshot: warningSnap,
            allowBubbling: true,
            now: t0 + 30
        )
        XCTAssertEqual(warnEvent?.reason, .warningAlert(summary: "Sync Failed"))
    }

    func testStatusBubbleTrackerSuppressesMetersClocksMediaAndChatteringLyricTickers() {
        // 1. Continuous meters, token counters, and clocks normalize to `nil`
        XCTAssertNil(StatusBubbleTracker.normalizeDiscreteState("↑ 1.4 MB/s · ↓ 820 KB/s"))
        XCTAssertNil(StatusBubbleTracker.normalizeDiscreteState("274M tokens · 1983 requests"))
        XCTAssertNil(StatusBubbleTracker.normalizeDiscreteState("42%"))
        XCTAssertNil(StatusBubbleTracker.normalizeDiscreteState("64°C"))
        XCTAssertNil(StatusBubbleTracker.normalizeDiscreteState("Wed 9:41 AM"))
        XCTAssertNil(StatusBubbleTracker.normalizeDiscreteState("周三 14:30"))

        // Meaningful discrete states survive normalization with numbers stripped
        XCTAssertEqual(StatusBubbleTracker.normalizeDiscreteState("Enhanced Mode"), "enhanced mode")
        XCTAssertEqual(StatusBubbleTracker.normalizeDiscreteState("Connected · 12 ms"), "connected ms")

        // 2. Music / media apps never bubble discrete text changes (e.g. track titles / lyrics)
        let musicTelemetry = LensTelemetry(
            unreadBadge: nil,
            shortChip: "晴天 - 周杰伦",
            fullSummary: "晴天 - 周杰伦",
            rows: [LensFactRow(value: "晴天 - 周杰伦", tone: .active)],
            interactiveControl: .mediaPlayback(nowPlayingHint: "晴天 - 周杰伦")
        )
        let musicSnap = StatusBubbleTracker.snapshot(from: musicTelemetry, categoryType: "public.app-category.music")
        XCTAssertNil(musicSnap.discreteStateSignature)

        // 3. Unknown non-categorized lyric helper chattering every 4s gets muted by the 36s chatter damper
        var tracker = StatusBubbleTracker()
        let base: TimeInterval = 1_750_300_000
        func makeLyricSnap(_ line: String) -> ObservedSemanticSnapshot {
            ObservedSemanticSnapshot(
                unreadCount: 0,
                unreadOverflow: false,
                statusTone: .neutral,
                discreteStateSignature: StatusBubbleTracker.normalizeDiscreteState(line),
                displaySummary: line
            )
        }

        // Baseline
        _ = tracker.observe(bundleID: "com.unknown.lyricbar", appName: "LyricBar", snapshot: makeLyricSnap("First line of song"), allowBubbling: false, now: base)
        // Mutation 1 during startup grace
        _ = tracker.observe(bundleID: "com.unknown.lyricbar", appName: "LyricBar", snapshot: makeLyricSnap("Second line of song"), allowBubbling: false, now: base + 2)
        // Mutation 2 during startup grace
        _ = tracker.observe(bundleID: "com.unknown.lyricbar", appName: "LyricBar", snapshot: makeLyricSnap("Third line of song"), allowBubbling: false, now: base + 4)
        // Mutation 3 after startup grace -> chatter damper recognizes >=2 prior mutations in 36s and mutes it!
        let muted = tracker.observe(
            bundleID: "com.unknown.lyricbar",
            appName: "LyricBar",
            snapshot: makeLyricSnap("Fourth line of song"),
            allowBubbling: true,
            now: base + 7
        )
        XCTAssertNil(muted, "Rapidly mutating text ticker must be muted by rolling chatter damper")
    }

    // MARK: - 4. Presentation Shield & Profile Serialization

    func testPresentationShieldPoliciesAndProfileRoundTrip() throws {
        let visibleApps: Set<String> = ["com.tencent.xinWeChat", "com.nssurge.surge-mac", "com.1password.1password"]
        let pinned: Set<String> = ["com.nssurge.surge-mac"]

        XCTAssertTrue(PresentationShieldEvaluator.shieldedBundleIDs(
            isActive: false,
            policy: .allThirdParty,
            visibleThirdPartyCandidates: visibleApps,
            pinnedExempt: pinned
        ).isEmpty)

        XCTAssertEqual(
            PresentationShieldEvaluator.shieldedBundleIDs(
                isActive: true,
                policy: .allThirdParty,
                visibleThirdPartyCandidates: visibleApps,
                pinnedExempt: pinned
            ),
            visibleApps
        )

        XCTAssertEqual(
            PresentationShieldEvaluator.shieldedBundleIDs(
                isActive: true,
                policy: .keepPinnedOnly,
                visibleThirdPartyCandidates: visibleApps,
                pinnedExempt: pinned
            ),
            ["com.tencent.xinWeChat", "com.1password.1password"]
        )

        let profile = BarLensProfile(
            visibleBundles: ["com.nssurge.surge-mac"],
            hiddenBundles: ["com.tencent.xinWeChat"],
            alwaysHiddenBundles: [],
            systemItemAssignments: [:],
            floatingBarOrder: [],
            alwaysHiddenEnabled: true,
            unclassifiedSection: "visible",
            newSystemItemSection: "visible",
            appearanceMode: "system",
            revealPresentationStyle: "floatingBar",
            floatingBarIconStyle: "appIcon",
            statusBarIconStyle: "eclipse",
            glassOpacity: 0.36,
            rimIntensity: 1.15,
            autoRehideInterval: 10,
            hoverRevealDelay: 0,
            appLanguage: "system",
            hotkeys: ["togglePresentationShield": Hotkey(keyCode: 35, carbonModifiers: 768, display: "⌥⌘P")],
            lensTelemetryEnabled: true,
            spatialBudgetPolicy: SpatialBudgetPolicy.notchGuard.rawValue,
            spatialExemptBundles: ["com.nssurge.surge-mac"],
            usageDecayPolicy: UsageDecayPolicy.days14.rawValue,
            statusBubbleMode: StatusBubbleMode.dotPulse.rawValue,
            statusBubbleDwell: StatusBubbleDwell.seconds15.rawValue,
            presentationShieldPolicy: PresentationShieldPolicy.keepPinnedOnly.rawValue,
            autoPresentationShieldOnMirroring: false
        )

        let data = try profile.encodedJSON()
        let decoded = try BarLensProfile.decode(from: data)
        XCTAssertEqual(decoded.usageDecayPolicy, UsageDecayPolicy.days14.rawValue)
        XCTAssertEqual(decoded.statusBubbleMode, StatusBubbleMode.dotPulse.rawValue)
        XCTAssertEqual(decoded.statusBubbleDwell, StatusBubbleDwell.seconds15.rawValue)
        XCTAssertEqual(decoded.presentationShieldPolicy, PresentationShieldPolicy.keepPinnedOnly.rawValue)
        XCTAssertEqual(decoded.autoPresentationShieldOnMirroring, false)
        XCTAssertEqual(decoded.hotkeys["togglePresentationShield"]?.display, "⌥⌘P")
    }

    func testConferencingScreenShareDetectionRejectsScreenshotsAndVoiceCalls() {
        var monitor = ScreenShareSessionMonitor(
            activationConfirmationTicks: 2,
            releaseGraceTicks: 3,
            minSampleInterval: 0.45,
            minimumSustainedDuration: 1.0
        )
        let pid: pid_t = 737
        let t0: TimeInterval = 1_750_300_000

        // 1. Idle / voice-only call baseline (`replayd` < 0.1 Mach syscalls/s, MenuBarAgent shows AudioVideoModule only)
        let s0 = ReplaydTelemetrySample(timestamp: t0, pid: pid, cpuNanoseconds: 5_000_000_000, machSyscalls: 4_000_000, contextSwitches: 3_500_000)
        XCTAssertFalse(monitor.ingestReplaydSample(s0))
        let voiceOnlyItem = MenuBarItem(
            ownerBundleID: "com.apple.MenuBarAgent",
            ownerPID: 687,
            frame: CGRect(x: 1900, y: 0, width: 32, height: 24),
            display: DisplayID(rawValue: 1, localizedName: "Main"),
            axIdentifier: "com.apple.menuextra.audiovideo",
            label: "音频和视频控制",
            indexInApp: 0,
            axTitle: nil,
            axDescription: "音频和视频控制"
        )
        XCTAssertFalse(DisplayMirrorDetector.hasControlCenterScreenShareIndicator(in: [voiceOnlyItem]))

        let s1Voice = ReplaydTelemetrySample(timestamp: t0 + 1.2, pid: pid, cpuNanoseconds: 5_000_010_000, machSyscalls: 4_000_001, contextSwitches: 3_500_001)
        XCTAssertFalse(monitor.ingestReplaydSample(s1Voice))
        XCTAssertNil(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        ), now: t0 + 1.2))

        // 2. Single-tick screenshot spike (`⌘⇧4` / WeChat `⌥A`) must NOT activate shield
        let s2Shot = ReplaydTelemetrySample(timestamp: t0 + 2.4, pid: pid, cpuNanoseconds: 5_004_500_000, machSyscalls: 4_000_120, contextSwitches: 3_500_090)
        XCTAssertTrue(monitor.ingestReplaydSample(s2Shot))
        XCTAssertNil(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: true,
            hasMenuBarIndicator: false
        ), now: t0 + 2.4))

        let s3AfterShot = ReplaydTelemetrySample(timestamp: t0 + 3.6, pid: pid, cpuNanoseconds: 5_004_502_000, machSyscalls: 4_000_121, contextSwitches: 3_500_091)
        XCTAssertFalse(monitor.ingestReplaydSample(s3AfterShot))
        XCTAssertNil(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        ), now: t0 + 3.6))

        // 3. Conferencing app starts screen sharing (`ScreenCaptureKit` / `CGDisplayStream`) -> activates on 2nd tick
        let s4Share1 = ReplaydTelemetrySample(timestamp: t0 + 4.8, pid: pid, cpuNanoseconds: 5_012_000_000, machSyscalls: 4_000_420, contextSwitches: 3_500_310)
        XCTAssertTrue(monitor.ingestReplaydSample(s4Share1))
        XCTAssertNil(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: true,
            isReplaydStreaming: true,
            hasMenuBarIndicator: false
        ), now: t0 + 4.8))

        // Back-to-back call 80ms later (e.g. from AX scan completion) must NOT reset or double-advance streak
        XCTAssertNil(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: true,
            isReplaydStreaming: true,
            hasMenuBarIndicator: false
        ), now: t0 + 4.88))

        let s5Share2 = ReplaydTelemetrySample(timestamp: t0 + 6.0, pid: pid, cpuNanoseconds: 5_020_000_000, machSyscalls: 4_000_780, contextSwitches: 3_500_590)
        XCTAssertTrue(monitor.ingestReplaydSample(s5Share2))
        XCTAssertEqual(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: true,
            isReplaydStreaming: true,
            hasMenuBarIndicator: false
        ), now: t0 + 6.0), .softwareScreenShare)

        // 4. Brief 2-tick quiet gap (e.g. switching shared window) holds steady via `releaseGraceTicks = 3`
        XCTAssertEqual(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        ), now: t0 + 7.2), .softwareScreenShare)
        XCTAssertEqual(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        ), now: t0 + 8.4), .softwareScreenShare)

        // 3rd inactive tick after stopping share releases cleanly
        XCTAssertNil(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        ), now: t0 + 9.6))

        // 5. ControlCenter screen-sharing menu bar indicator matches localized screen-capture labels
        let shareIndicatorItem = MenuBarItem(
            ownerBundleID: "com.apple.MenuBarAgent",
            ownerPID: 687,
            frame: CGRect(x: 1900, y: 0, width: 32, height: 24),
            display: DisplayID(rawValue: 1, localizedName: "Main"),
            axIdentifier: "com.apple.menuextra.audiovideo",
            label: "当前正在共享",
            indexInApp: 0,
            axTitle: nil,
            axDescription: "AOne会议正在捕捉你的屏幕。"
        )
        XCTAssertTrue(DisplayMirrorDetector.hasControlCenterScreenShareIndicator(in: [shareIndicatorItem]))

        // 6. Hardware display mirroring engages immediately on the first observation
        XCTAssertEqual(monitor.update(with: ScreenShareObservation(
            isHardwareMirrored: true,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        ), now: t0 + 11.0), .hardwareMirror)
    }

    func testDefaultScreenShareMonitorRejectsAppLaunchPreflightAndSharePickerThumbnails() {
        // Exercises exact production defaults (`0.25s` fast verification cadence,
        // `indicatorFastPathTicks = 2`, `activationConfirmationTicks = 7`, `minimumSustainedDuration = 1.85`)
        var monitor = ScreenShareSessionMonitor()
        let pickerBurstObs = ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: true,
            hasMenuBarIndicator: false
        )
        let confirmedPillObs = ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: true,
            hasMenuBarIndicator: true
        )
        let staticSlideHoldObs = ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: true
        )
        let idleObs = ScreenShareObservation(
            isHardwareMirrored: false,
            isScreenWatcherActive: false,
            isReplaydStreaming: false,
            hasMenuBarIndicator: false
        )
        let t0: TimeInterval = 1_750_500_000

        // 0. ControlCenter BentoBox sensor dot ("录屏" / "Screen Recording" from one-shot screenshots)
        //    must NOT count as an active screen-sharing session pill
        let bentoSensorDot = MenuBarItem(
            ownerBundleID: "com.apple.MenuBarAgent",
            ownerPID: 687,
            frame: CGRect(x: 1940, y: 0, width: 28, height: 24),
            display: DisplayID(rawValue: 1, localizedName: "Main"),
            axIdentifier: "com.apple.menuextra.controlcenter",
            label: "控制中心",
            indexInApp: 1,
            axTitle: "控制中心",
            axDescription: "录屏",
            axValue: "Screen Recording"
        )
        XCTAssertFalse(DisplayMirrorDetector.hasControlCenterScreenShareIndicator(in: [bentoSensorDot]))

        // 1. Opening "Start Share" picker (`approveOnScreenshot` ~1.50s across 6 fast 0.25s ticks, no share pill) must NOT trigger
        for step in 0..<6 {
            XCTAssertNil(monitor.update(with: pickerBurstObs, now: t0 + Double(step) * 0.25))
            XCTAssertTrue(monitor.hasPendingCandidate)
        }
        XCTAssertNil(monitor.update(with: idleObs, now: t0 + 1.50))
        XCTAssertFalse(monitor.hasPendingCandidate)

        // 2. Confirmed screen share with live MenuBarAgent pill ("当前正在共享") engages via fast-path in ~0.45s!
        XCTAssertNil(monitor.update(with: pickerBurstObs, now: t0 + 10.00))
        XCTAssertNil(monitor.update(with: pickerBurstObs, now: t0 + 10.25))
        // Async MenuBarAgent probe completes 20ms later -> promotes immediately without waiting for 1.85s!
        XCTAssertEqual(monitor.update(with: confirmedPillObs, now: t0 + 10.27), .softwareScreenShare)
        XCTAssertFalse(monitor.hasPendingCandidate)

        // 3. Static 0-fps shared slide/PDF holds steady as long as MenuBarAgent sharing pill remains active
        for step in 1...5 {
            XCTAssertEqual(monitor.update(with: staticSlideHoldObs, now: t0 + 10.27 + Double(step) * 0.55), .softwareScreenShare)
        }

        // 4. Stopping share clears both stream and pill -> releases cleanly after `releaseGraceTicks = 3` (~1.65s)
        XCTAssertEqual(monitor.update(with: idleObs, now: t0 + 14.00), .softwareScreenShare)
        XCTAssertEqual(monitor.update(with: idleObs, now: t0 + 14.55), .softwareScreenShare)
        XCTAssertNil(monitor.update(with: idleObs, now: t0 + 15.10))

        // 5. Fallback path (when MenuBarAgent pill is suppressed/unavailable) still confirms cleanly at >= 1.85s
        for step in 0..<7 {
            XCTAssertNil(monitor.update(with: pickerBurstObs, now: t0 + 20.00 + Double(step) * 0.25))
        }
        XCTAssertEqual(monitor.update(with: pickerBurstObs, now: t0 + 20.00 + 2.00), .softwareScreenShare)
    }

    func testStatusBubbleDwellPoliciesDistinguishActionableUnreadFromTransientStateFlips() {
        var tracker = StatusBubbleTracker()
        let t0: TimeInterval = 1_750_500_000

        // Baseline
        _ = tracker.observe(
            bundleID: "com.google.antigravity",
            appName: "Antigravity",
            snapshot: ObservedSemanticSnapshot(
                unreadCount: 0,
                unreadOverflow: false,
                statusTone: .neutral,
                discreteStateSignature: "idle",
                displaySummary: "Idle"
            ),
            allowBubbling: true,
            now: t0,
            dwell: .smart
        )

        // 1. Under `.smart`, a calm discrete state flip peeks for 10s (`awaitsHandling == false`)
        let stateFlipEvent = tracker.observe(
            bundleID: "com.google.antigravity",
            appName: "Antigravity",
            snapshot: ObservedSemanticSnapshot(
                unreadCount: 0,
                unreadOverflow: false,
                statusTone: .active,
                discreteStateSignature: "working",
                displaySummary: "Working"
            ),
            allowBubbling: true,
            now: t0 + 5,
            dwell: .smart
        )
        XCTAssertNotNil(stateFlipEvent)
        XCTAssertEqual(stateFlipEvent?.awaitsHandling, false)
        XCTAssertEqual(stateFlipEvent?.expiresAt ?? 0, t0 + 5 + 10.0, accuracy: 0.01)

        // 2. Under `.smart`, an unread increment stays surfaced awaiting handling (`awaitsHandling == true`)
        let unreadEvent = tracker.observe(
            bundleID: "com.google.antigravity",
            appName: "Antigravity",
            snapshot: ObservedSemanticSnapshot(
                unreadCount: 2,
                unreadOverflow: false,
                statusTone: .active,
                discreteStateSignature: "working",
                displaySummary: "Working"
            ),
            allowBubbling: true,
            now: t0 + 10,
            dwell: .smart
        )
        XCTAssertNotNil(unreadEvent)
        XCTAssertEqual(unreadEvent?.awaitsHandling, true)
        XCTAssertEqual(unreadEvent?.expiresAt ?? 0, t0 + 10 + StatusBubbleDwell.smartActionableCeiling, accuracy: 0.01)

        // 3. Under `.seconds6`, even unread increments use the strict 6s glance window
        let timedEvent = tracker.observe(
            bundleID: "com.google.antigravity",
            appName: "Antigravity",
            snapshot: ObservedSemanticSnapshot(
                unreadCount: 3,
                unreadOverflow: false,
                statusTone: .active,
                discreteStateSignature: "working",
                displaySummary: "Working"
            ),
            allowBubbling: true,
            now: t0 + 18,
            dwell: .seconds6
        )
        XCTAssertNotNil(timedEvent)
        XCTAssertEqual(timedEvent?.awaitsHandling, false)
        XCTAssertEqual(timedEvent?.expiresAt ?? 0, t0 + 18 + 6.0, accuracy: 0.01)

        // 4. Under `.untilHandled`, even state flips await explicit handling
        let untilHandledFlip = tracker.observe(
            bundleID: "com.google.antigravity",
            appName: "Antigravity",
            snapshot: ObservedSemanticSnapshot(
                unreadCount: 3,
                unreadOverflow: false,
                statusTone: .neutral,
                discreteStateSignature: "ready",
                displaySummary: "Ready"
            ),
            allowBubbling: true,
            now: t0 + 45,
            dwell: .untilHandled
        )
        XCTAssertNotNil(untilHandledFlip)
        XCTAssertEqual(untilHandledFlip?.awaitsHandling, true)
        XCTAssertEqual(untilHandledFlip?.expiresAt ?? 0, t0 + 45 + StatusBubbleDwell.untilHandledCeiling, accuracy: 0.01)
    }
}
