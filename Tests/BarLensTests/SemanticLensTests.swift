import AppKit
import SwiftUI
import XCTest
@testable import BarLens

final class SemanticLensTests: XCTestCase {

    func testExtractsClashVergeMultilineToolTipWithoutVersionHeader() {
        let telemetry = SemanticLensExtractor.extract(
            appName: "Clash Verge",
            bundleID: "io.github.clash-verge-rev.clash-verge-rev",
            items: [
                RawAXItemTelemetry(
                    title: "",
                    description: nil,
                    value: nil,
                    help: """
                    Clash Verge 2.5.8
                    系统代理: off
                    TUN: off
                    订阅: ◈ NIVA Network.yaml
                    """
                )
            ]
        )

        XCTAssertNil(telemetry.unreadBadge)
        XCTAssertEqual(telemetry.shortChip, "系统代理: off")
        XCTAssertEqual(telemetry.fullSummary, "系统代理: off · TUN: off · 订阅: ◈ NIVA Network.yaml")
        XCTAssertTrue(telemetry.hasLiveSignal)
    }

    func testExtractsMagpieTokenUsageAndCompactsParentheticalForChip() {
        let telemetry = SemanticLensExtractor.extract(
            appName: "magpie",
            bundleID: "com.yetone.magpie",
            items: [
                RawAXItemTelemetry(
                    title: nil,
                    description: nil,
                    value: nil,
                    help: """
                    magpie
                    Today: 180M tokens (12M in · 1.0M out · 167M cached)
                    ≈$152 · 1316 requests
                    """
                )
            ]
        )

        XCTAssertNil(telemetry.unreadBadge)
        XCTAssertEqual(telemetry.shortChip, "Today: 180M tokens")
        XCTAssertEqual(telemetry.fullSummary, "Today: 180M tokens · ≈$152 · 1316 requests")
        XCTAssertEqual(telemetry.rows, [
            LensFactRow(
                label: "Today",
                value: "180M tokens",
                detail: "12M in · 1.0M out · 167M cached",
                tone: .accent
            ),
            LensFactRow(
                label: nil,
                value: "≈$152 · 1316 requests",
                detail: nil,
                tone: .accent
            ),
        ])
    }

    func testSplitsLongParentheticalAndDashBreakdownsWhileKeepingShortInline() {
        let proxy = SemanticLensExtractor.extract(
            appName: "TunnelBox",
            bundleID: "com.example.tunnelbox",
            items: [
                RawAXItemTelemetry(
                    help: """
                    状态：已连接（香港 IEPL 01 · 延迟 18ms）
                    流量: ↑ 1.2 GB — Direct 64% · Proxy 36%
                    贴图: 0 [Default]
                    """,
                    menuEntries: [
                        AXMenuSnapshotEntry(
                            menuIndex: 0,
                            title: "Hong Kong BGP 01 (18 ms · IPLC)",
                            isEnabled: true,
                            markChar: "✓"
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(proxy.shortChip, "状态：已连接")
        XCTAssertEqual(proxy.rows, [
            LensFactRow(label: "状态", value: "已连接", detail: "香港 IEPL 01 · 延迟 18ms", tone: .active),
            LensFactRow(label: "流量", value: "↑ 1.2 GB", detail: "Direct 64% · Proxy 36%", tone: .accent),
            LensFactRow(label: "贴图", value: "0 [Default]", detail: nil, tone: .accent),
            LensFactRow(
                label: proxy.rows.last?.label,
                value: "Hong Kong BGP 01",
                detail: "18 ms · IPLC",
                tone: .active
            ),
        ])
    }

    func testExtractsUnreadNumericCounterFromTitle() {
        let telemetry = SemanticLensExtractor.extract(
            appName: "企业微信",
            bundleID: "com.tencent.WeWorkMac",
            items: [
                RawAXItemTelemetry(
                    title: "4",
                    description: nil,
                    value: nil,
                    help: "企业微信"
                )
            ]
        )

        XCTAssertEqual(telemetry.unreadBadge, "4")
        XCTAssertNil(telemetry.shortChip)
        XCTAssertNotNil(telemetry.fullSummary)
        XCTAssertTrue(telemetry.hasLiveSignal)
    }

    func testCapsLargeUnreadCountsAtNinetyNinePlus() {
        let telemetry = SemanticLensExtractor.extract(
            appName: "Mail",
            bundleID: "com.apple.mail",
            items: [
                RawAXItemTelemetry(title: "128", description: nil, value: nil, help: nil)
            ]
        )

        XCTAssertEqual(telemetry.unreadBadge, "99+")
    }

    func testFiltersStaticShortcutHintsAndEmptyColonValues() {
        let telemetry = SemanticLensExtractor.extract(
            appName: "Snipaste",
            bundleID: "com.Snipaste",
            items: [
                RawAXItemTelemetry(
                    title: "",
                    description: nil,
                    value: nil,
                    help: """
                    Snipaste 2.11.3 免费版
                    截屏快捷键: ⇧⌘4
                    贴图快捷键: 
                    贴图: 0 [Default]
                    """
                )
            ]
        )

        XCTAssertEqual(telemetry.shortChip, "贴图: 0 [Default]")
        XCTAssertEqual(telemetry.fullSummary, "贴图: 0 [Default]")
    }

    func testSuppressesRedundantAppNamesAndActionInstructions() {
        let chatGPT = SemanticLensExtractor.extract(
            appName: "ChatGPT",
            bundleID: "com.openai.codex",
            items: [
                RawAXItemTelemetry(title: "", description: "ChatGPT", value: nil, help: "ChatGPT")
            ]
        )
        XCTAssertEqual(chatGPT, .empty)
        XCTAssertFalse(chatGPT.hasLiveSignal)

        let droppy = SemanticLensExtractor.extract(
            appName: "Droppy",
            bundleID: "iordv.Droppy",
            items: [
                RawAXItemTelemetry(title: "Droppy", description: nil, value: nil, help: "打开 Command Center")
            ]
        )
        XCTAssertEqual(droppy, .empty)

        let commandX = SemanticLensExtractor.extract(
            appName: "Command X",
            bundleID: "com.sindresorhus.Command-X",
            items: [
                RawAXItemTelemetry(title: "Command", description: nil, value: nil, help: nil)
            ]
        )
        XCTAssertEqual(commandX, .empty)
    }

    func testExtractsWeatherDescriptionWhileSkippingTitleMatchingName() {
        let weather = SemanticLensExtractor.extract(
            appName: "天气",
            bundleID: "com.apple.menuextra.weather",
            items: [
                RawAXItemTelemetry(title: "天气", description: "大部多云 · 23°", value: nil, help: nil)
            ]
        )

        XCTAssertEqual(weather.shortChip, "大部多云 · 23°")
        XCTAssertEqual(weather.fullSummary, "大部多云 · 23°")
    }

    func testExtractsPassiveAXMenuStatusRowsAndDirectTunnelActions() {
        let chatGPT = SemanticLensExtractor.extract(
            appName: "ChatGPT",
            bundleID: "com.openai.codex",
            items: [
                RawAXItemTelemetry(
                    title: "",
                    description: "ChatGPT",
                    value: nil,
                    help: "ChatGPT",
                    menuEntries: [
                        AXMenuSnapshotEntry(
                            menuPath: [0],
                            titlePath: ["Computer Use"],
                            title: "Computer Use",
                            isEnabled: true,
                            children: [
                                AXMenuSnapshotEntry(
                                    menuPath: [0, 0],
                                    titlePath: ["Computer Use", "No Active Sessions"],
                                    title: "No Active Sessions",
                                    isEnabled: false
                                )
                            ]
                        ),
                        AXMenuSnapshotEntry(menuIndex: 2, title: "Running", isEnabled: false),
                        AXMenuSnapshotEntry(menuIndex: 3, title: "调研 InnerSec MCP Server 改造方案", isEnabled: true),
                        AXMenuSnapshotEntry(menuIndex: 5, title: "Quit ChatGPT", isEnabled: true),
                    ]
                )
            ]
        )

        XCTAssertEqual(chatGPT.shortChip, "Running")
        XCTAssertEqual(chatGPT.rows, [LensFactRow(label: nil, value: "Running", tone: .active)])
        XCTAssertEqual(chatGPT.tunnelActions.map(\.title), [
            "Computer Use",
            "调研 InnerSec MCP Server 改造方案",
        ])
        XCTAssertTrue(chatGPT.tunnelActions[0].hasSubmenu)
        XCTAssertEqual(chatGPT.tunnelActions[0].children.map(\.title), ["No Active Sessions"])
        XCTAssertFalse(chatGPT.tunnelActions[0].children[0].isEnabled)
        XCTAssertFalse(chatGPT.tunnelActions[1].hasSubmenu)
    }

    func testExtractsMultiIconModulesMusicTransportAndOpenWindows() {
        let multiIconMonitor = SemanticLensExtractor.extract(
            appName: "iStat Menus Menubar",
            bundleID: "com.bjango.istatmenus.status",
            items: [
                RawAXItemTelemetry(
                    indexInApp: 0,
                    identifier: "com.bjango.istatmenus.battery",
                    description: "iStat Menus Battery",
                    value: "98%"
                ),
                RawAXItemTelemetry(
                    indexInApp: 1,
                    identifier: "com.bjango.istatmenus.weather",
                    description: "iStat Menus Weather",
                    value: "24°"
                ),
            ]
        )
        XCTAssertEqual(multiIconMonitor.statusSubItems, [
            StatusSubItemOption(indexInApp: 0, title: "Battery"),
            StatusSubItemOption(indexInApp: 1, title: "Weather"),
        ])

        let musicPlayer = SemanticLensExtractor.extract(
            appName: "NetEaseMusic",
            bundleID: "com.netease.163music",
            items: [RawAXItemTelemetry(title: "NetEaseMusic")],
            categoryType: "public.app-category.music",
            openWindows: ["晴天 - 周杰伦", "NetEaseMusic"]
        )
        XCTAssertEqual(musicPlayer.openWindowTitles, ["晴天 - 周杰伦"])
        XCTAssertEqual(musicPlayer.interactiveControl, .mediaPlayback(nowPlayingHint: "晴天 - 周杰伦"))
    }

    func testParsesKeyValueRowsAndFusesDockUnreadBadges() {
        let clash = SemanticLensExtractor.extract(
            appName: "Clash Verge",
            bundleID: "io.github.clash-verge-rev.clash-verge-rev",
            items: [
                RawAXItemTelemetry(
                    help: """
                    Clash Verge 2.5.8
                    系统代理: on
                    TUN: off
                    订阅: ◈ NIVA Network.yaml
                    """
                )
            ]
        )
        XCTAssertEqual(clash.rows, [
            LensFactRow(label: "系统代理", value: "on", tone: .active),
            LensFactRow(label: "TUN", value: "off", tone: .neutral),
            LensFactRow(label: "订阅", value: "◈ NIVA Network", tone: .accent),
        ])

        let qq = SemanticLensExtractor.extract(
            appName: "QQ",
            bundleID: "com.tencent.qq",
            items: [RawAXItemTelemetry()],
            dockBadge: "1,646"
        )
        XCTAssertEqual(qq.unreadBadge, "99+")
        XCTAssertEqual(qq.rows.count, 1)

        let vitals = ProcessVitals(memoryBytes: 1_574 * 1_048_576, cpuPercent: 12.4)
        XCTAssertTrue(vitals.isHighMemory)
        XCTAssertEqual(vitals.formattedMemory, "1.54 GB")
        XCTAssertEqual(vitals.formattedCPU, "12%")
    }

    func testUniversalColonDisambiguationNounQualifiersAndSemicolonExpansion() {
        let universal = SemanticLensExtractor.extract(
            appName: "AnyUtility",
            bundleID: "com.example.anyutility",
            items: [
                RawAXItemTelemetry(
                    help: """
                    https://gateway.example.com:8443/health
                    Output: AirPods Pro (2nd generation)
                    Keychron Q1 Pro Wireless Mechanical Keyboard: 86%
                    Endpoint: https://api.example.com:8443/v1
                    """
                ),
                RawAXItemTelemetry(
                    description: "CPU: 14%; Memory: 62%"
                ),
            ]
        )

        // Bare URL must NOT split on 'https:' into label="https", value="//..."
        XCTAssertEqual(universal.rows[0], LensFactRow(
            label: nil,
            value: "https://gateway.example.com:8443/health",
            detail: nil,
            tone: .accent
        ))
        // Noun qualifier "(2nd generation)" stays inline with the device name rather than splitting
        XCTAssertEqual(universal.rows[1], LensFactRow(
            label: "Output",
            value: "AirPods Pro (2nd generation)",
            detail: nil,
            tone: .accent
        ))
        // Long hardware peripheral name before ':' is preserved as key
        XCTAssertEqual(universal.rows[2], LensFactRow(
            label: "Keychron Q1 Pro Wireless Mechanical Keyboard",
            value: "86%",
            detail: nil,
            tone: .accent
        ))
        // Key followed by a full URL keeps the entire URL intact in value
        XCTAssertEqual(universal.rows[3], LensFactRow(
            label: "Endpoint",
            value: "https://api.example.com:8443/v1",
            detail: nil,
            tone: .accent
        ))
        // Semicolon-delimited compact pairs expand cleanly
        XCTAssertEqual(universal.rows[4], LensFactRow(
            label: "CPU",
            value: "14%",
            detail: nil,
            tone: .accent
        ))
    }

    @MainActor
    func testGeometryDrivenLayoutsAdaptAcrossShortLongAndFacetedRows() {
        func measureHeight<V: View>(_ view: V, width: CGFloat = 258) -> CGFloat {
            let hosted = NSHostingView(rootView: view.frame(width: width))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }

        let shortRowHeight = measureHeight(
            AdaptiveKeyValueLayout {
                Text("Today").font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("274M tokens").font(.system(size: 11, weight: .semibold)).lineLimit(2)
            }
        )

        let longLabelCompactValueHeight = measureHeight(
            AdaptiveKeyValueLayout {
                Text("Keychron Q1 Pro Wireless Mechanical Keyboard")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("86%")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
            }
        )

        let longValueStackedHeight = measureHeight(
            AdaptiveKeyValueLayout {
                Text("Output Device").font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("MacBook Pro Built-in Speakers + External Apple Studio Display Audio")
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        )

        // Long label + short badge stays on 1 horizontal line; long value stacks vertically (> 1.8x height)
        XCTAssertEqual(shortRowHeight, longLabelCompactValueHeight, accuracy: 2.0)
        XCTAssertGreaterThan(longValueStackedHeight, shortRowHeight * 1.8)

        let singleLineFacetsHeight = measureHeight(
            FlowClauseLayout {
                Text("16M in").font(.system(size: 10)).lineLimit(1)
                Circle()
                Text("1.7M out").font(.system(size: 10)).lineLimit(1)
                Circle()
                Text("256M cached").font(.system(size: 10)).lineLimit(1)
            }
        )

        let wrappedFacetsHeight = measureHeight(
            FlowClauseLayout {
                Text("16M input tokens").font(.system(size: 10)).lineLimit(1)
                Circle()
                Text("1.7M output tokens").font(.system(size: 10)).lineLimit(1)
                Circle()
                Text("256M cached tokens").font(.system(size: 10)).lineLimit(1)
                Circle()
                Text("42M reasoning tokens").font(.system(size: 10)).lineLimit(1)
            }
        )

        XCTAssertGreaterThan(wrappedFacetsHeight, singleLineFacetsHeight * 1.7)
    }

    func testMultiLocaleMenuShortcutsHIGEllipsisAndDynamicLanguageSwitch() {
        // Japanese / German / custom locale menu entries using universal macOS shortcuts (⌘Q, ⌘H, ⌘,)
        let intlEntries = [
            AXMenuSnapshotEntry(
                statusItemIndex: 0, menuPath: [0], titlePath: ["設定…"],
                title: "設定…", isEnabled: true, markChar: nil, shortcutHint: "⌘,", children: []
            ),
            AXMenuSnapshotEntry(
                statusItemIndex: 0, menuPath: [1], titlePath: ["ダッシュボードを開く"],
                title: "ダッシュボードを開く", isEnabled: true, markChar: nil, shortcutHint: "⌘D", children: []
            ),
            AXMenuSnapshotEntry(
                statusItemIndex: 0, menuPath: [2], titlePath: ["App を隠す"],
                title: "App を隠す", isEnabled: true, markChar: nil, shortcutHint: "⌘H", children: []
            ),
            AXMenuSnapshotEntry(
                statusItemIndex: 0, menuPath: [3], titlePath: ["App を終了"],
                title: "App を終了", isEnabled: true, markChar: nil, shortcutHint: "⌘Q", children: []
            ),
        ]
        let distilled = SemanticLensExtractor.extract(
            appName: "SampleApp",
            bundleID: "jp.example.sample",
            items: [RawAXItemTelemetry(menuEntries: intlEntries)]
        )
        // ⌘Q and ⌘H are stripped universally; domain action precedes demoted ⌘, Settings!
        XCTAssertEqual(distilled.tunnelActions.map(\.title), ["ダッシュボードを開く", "設定…"])

        // HIG trailing ellipsis & ⌘, window-activation heuristics across locales
        XCTAssertTrue(DividerEngine.actionLikelyOpensWindow("Einstellungen", shortcutHint: "⌘,"))
        XCTAssertTrue(DividerEngine.actionLikelyOpensWindow("プロファイルを読み込む…"))
        XCTAssertTrue(DividerEngine.actionLikelyOpensWindow("Import Config..."))
        XCTAssertTrue(DividerEngine.actionLikelyOpensWindow("開啟主視窗"))
        XCTAssertFalse(DividerEngine.actionLikelyOpensWindow("Copy Public IP"))
        XCTAssertFalse(DividerEngine.actionLikelyOpensWindow("Pause Sync"))

        // Dynamic runtime language switch updates SystemTelemetryReader date formatting & cache immediately
        let savedLang = Defaults.appLanguage
        defer {
            Defaults.appLanguage = savedLang
            SystemTelemetryReader.shared.invalidate()
        }
        let clockItem = SystemItem(identifier: "com.apple.menuextra.clock", rawValue: 2)

        Defaults.appLanguage = .zhHans
        let zhClock = SystemTelemetryReader.shared.telemetry(for: clockItem)
        XCTAssertEqual(zhClock.rows.first?.label, "日期时间")
        XCTAssertTrue(zhClock.fullSummary?.contains("月") == true)

        Defaults.appLanguage = .en
        let enClock = SystemTelemetryReader.shared.telemetry(for: clockItem)
        XCTAssertEqual(enClock.rows.first?.label, "Date")
        XCTAssertFalse(enClock.fullSummary?.contains("月") == true)
    }

    @MainActor
    func testCappedProposalLayoutShrinksWhenCompactAndScrollsAtExactCapWhenOverflowing() {
        func findScrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let sv = view as? NSScrollView { found.append(sv) }
            for sub in view.subviews { found.append(contentsOf: findScrollViews(in: sub)) }
            return found
        }

        func buildCapsule(itemCount: Int, cap: CGFloat) -> some View {
            let items = HStack(spacing: 7) {
                ForEach(0..<itemCount, id: \.self) { _ in
                    Rectangle().fill(Color(nsColor: .red)).frame(width: 38, height: 38)
                }
            }
            return HStack(spacing: 7) {
                CappedProposalLayout(maxWidth: cap) {
                    ViewThatFits(in: .horizontal) {
                        items
                        ScrollView(.horizontal, showsIndicators: false) {
                            items
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Rectangle().fill(Color(nsColor: .blue)).frame(width: 1, height: 18)
                Rectangle().fill(Color(nsColor: .green)).frame(width: 36, height: 36)
            }
            .padding(10)
            .background(Color.white)
        }

        func measureHostedCapsule(itemCount: Int, cap: CGFloat) -> (size: NSSize, scrollViews: [NSScrollView]) {
            let hc = NSHostingController(rootView: buildCapsule(itemCount: itemCount, cap: cap))
            hc.sizingOptions = [.intrinsicContentSize]
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.contentViewController = hc
            panel.contentView?.layoutSubtreeIfNeeded()
            let fit = hc.view.fittingSize
            panel.setFrame(NSRect(origin: .zero, size: fit), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            return (fit, findScrollViews(in: hc.view))
        }

        // 1. Compact (3 items = 128pt inside a wide 2200pt screen cap):
        // Must shrink to 128 + 7 + 1 + 7 + 36 + 20 = 199pt, mount 0 NSScrollViews,
        // AND render all 3*38*38 = 4332 red icon pixels and 36*36 = 1296 green gear pixels in bounds!
        let compact = measureHostedCapsule(itemCount: 3, cap: 2200)
        XCTAssertEqual(compact.size.width, 199, accuracy: 2.0)
        XCTAssertEqual(compact.scrollViews.count, 0)

        let renderer = ImageRenderer(content: buildCapsule(itemCount: 3, cap: 2200))
        let cgImage = try? XCTUnwrap(renderer.cgImage)
        if let cgImage {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            var redPixels = 0
            var greenPixels = 0
            for y in 0..<cgImage.height {
                for x in 0..<cgImage.width {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        if c.redComponent > 0.8 && c.greenComponent < 0.2 { redPixels += 1 }
                        if c.greenComponent > 0.8 && c.redComponent < 0.2 { greenPixels += 1 }
                    }
                }
            }
            XCTAssertEqual(redPixels, 3 * 38 * 38)
            XCTAssertEqual(greenPixels, 36 * 36)
        }

        // 2. Overflow (20 items = 893pt > 420pt cap):
        // Must cap icons viewport at 420pt (total 420 + 7 + 1 + 7 + 36 + 20 = 491pt) and mount 1 NSScrollView
        // whose documentView spans the full 893pt!
        let overflow = measureHostedCapsule(itemCount: 20, cap: 420)
        XCTAssertEqual(overflow.size.width, 491, accuracy: 2.0)
        XCTAssertEqual(overflow.scrollViews.count, 1)
        if let sv = overflow.scrollViews.first {
            XCTAssertEqual(sv.frame.width, 420, accuracy: 2.0)
            XCTAssertEqual(sv.documentView?.frame.width ?? 0, 893, accuracy: 2.0)
        }
    }
}
