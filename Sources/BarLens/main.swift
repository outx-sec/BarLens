import AppKit

// BarLens — three sections in the menu bar with a second-row Liquid Glass
// floating bar. See README.md for what it does and what it cannot do.

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Accessory: menu bar only, no Dock icon, no main menu.
application.setActivationPolicy(.accessory)
application.run()
