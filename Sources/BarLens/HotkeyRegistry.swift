import AppKit
import Carbon.HIToolbox

/// Registers global shortcuts with Carbon.
///
/// Carbon rather than a global `NSEvent` monitor because only Carbon can
/// *consume* the keystroke. A monitor would also let the shortcut through to
/// whatever is focused, so ⌃⌥H would both toggle the section and type into the
/// frontmost app.
final class HotkeyRegistry {

    /// Called on the main thread when a registered shortcut fires.
    var onFire: ((HotkeyAction) -> Void)?

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var actionForID: [UInt32: HotkeyAction] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    init() {
        installHandler()
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Register `hotkey` for `action`, replacing any previous one.
    /// Returns nil on success, or a message describing why it could not be used.
    func register(_ hotkey: Hotkey, for action: HotkeyAction) -> String? {
        unregister(action)

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D42_4456), // 'MBDV'
                                     id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode,
                                         hotkey.carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            // The common failure is that another app already owns the combo.
            return status == eventHotKeyExistsErr
                ? tr("这个组合键已经被别的 App 占用了。", "This shortcut is already in use by another application.")
                : tr("注册失败（错误码 \(status)）。", "Failed to register shortcut (error \(status)).")
        }
        refs[action] = ref
        actionForID[id] = action
        return nil
    }

    func unregister(_ action: HotkeyAction) {
        guard let ref = refs.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(ref)
        actionForID = actionForID.filter { $0.value != action }
    }

    func unregisterAll() {
        for action in HotkeyAction.allCases { unregister(action) }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = actionForID[id] else { return }
        onFire?(action)
    }

    private func installHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let registry = Unmanaged<HotkeyRegistry>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &id)
            if status == noErr {
                DispatchQueue.main.async { registry.fire(id.id) }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
