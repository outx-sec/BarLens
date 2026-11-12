import AppKit
import SwiftUI

/// Hosts the SwiftUI settings view in an ordinary window.
///
/// A window rather than a SwiftUI `Settings` scene: the app is built on an
/// AppKit `NSApplication` run loop so that it can own a status item, and mixing
/// scene-based settings into that is more trouble than a hosting controller.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let engine: DividerEngine
    private var hasPresentedOnce = false

    init(engine: DividerEngine) {
        self.engine = engine

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.title = "BarLens"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        let initialAppearance = engine.effectiveNSAppearance
        window.appearance = initialAppearance
        window.setContentSize(NSSize(width: 820, height: 600))
        window.setFrameAutosaveName("BarLens.settings")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func ensureContentViewController() {
        guard let window, window.contentViewController == nil else { return }
        let preservedFrame = window.frame
        let target = engine.effectiveNSAppearance
        let hosting = NSHostingController(rootView: SettingsView(engine: engine))
        hosting.sizingOptions = []
        hosting.view.appearance = target
        window.contentViewController = hosting
        if preservedFrame.width >= window.minSize.width,
           preservedFrame.height >= window.minSize.height {
            window.setFrame(preservedFrame, display: false)
        } else {
            window.setContentSize(NSSize(width: 820, height: 600))
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }

    func syncAppearance() {
        let target = engine.effectiveNSAppearance
        window?.appearance = target
        window?.contentView?.appearance = target
        window?.contentViewController?.view.appearance = target
    }

    /// Show the window, bringing it forward. The app has no Dock icon and is not
    /// the active application, so it has to ask for activation explicitly.
    func present(pane: SettingsPane? = nil) {
        if let pane {
            Defaults.settingsPane = pane.rawValue
            engine.requestedSettingsPane = pane
        }
        ensureContentViewController()
        syncAppearance()
        placeOnActiveScreenIfNeeded()
        hasPresentedOnce = true
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Put the window on the screen the pointer is on when opening on a
    /// different display or before any saved frame exists on that display.
    ///
    /// `NSWindow.center()` positions relative to `NSScreen.main`, which for an
    /// accessory app that has just been activated can be a different display
    /// from the one being looked at — the window then opens somewhere the user
    /// never sees.
    private func placeOnActiveScreenIfNeeded() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        if hasPresentedOnce && window.isVisible && visible.intersects(window.frame) {
            return
        }
        if visible.contains(NSPoint(x: window.frame.midX, y: window.frame.midY)),
           window.frame.origin != .zero {
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2))
    }
}
