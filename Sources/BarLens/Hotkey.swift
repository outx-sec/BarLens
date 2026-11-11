import AppKit
import Carbon.HIToolbox

/// A key combination, stored in the form Carbon wants.
///
/// `display` is captured when the user records the shortcut rather than derived
/// on demand: turning a key code back into a character needs the current
/// keyboard layout, and a stored string is what the user actually pressed.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    /// A shortcut with no modifier would swallow an ordinary keystroke, so the
    /// recorder refuses to produce one.
    static let requiredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection(Self.requiredModifiers).isEmpty else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = Self.carbonModifiers(from: flags)
        self.display = Self.describe(flags: flags, event: event)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option)  { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift)   { result |= UInt32(shiftKey) }
        return result
    }

    private static func describe(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option)  { text += "⌥" }
        if flags.contains(.shift)   { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        switch event.keyCode {
        case 49: text += "Space"
        case 36: text += "↩"
        case 48: text += "⇥"
        case 51: text += "⌫"
        case 53: text += "⎋"
        default: text += key.isEmpty ? "?" : key
        }
        return text
    }
}

/// The two things a shortcut can be bound to.
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case toggleHidden
    case toggleAlwaysHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleHidden:       return tr("显示 / 收起「可隐藏」段", "Toggle Hidden Section")
        case .toggleAlwaysHidden: return tr("显示 / 收起「永久隐藏」段", "Toggle Always-Hidden Section")
        }
    }
}
