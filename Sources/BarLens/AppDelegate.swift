import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DividerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Releases the assertion, so every hidden item comes back. This also
        // happens for free if the process dies, since the restriction lives on
        // the XPC connection.
        controller.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
