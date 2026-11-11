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
}
