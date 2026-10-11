import Carbon.HIToolbox

/// Глобальные хоткеи через Carbon RegisterEventHotKey — работает без прав Accessibility.
/// ⌃⌥⌘A — панель, ⌃⌥⌘L — «Работать закрытым» вкл/выкл.
enum Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]

    static func register(openPanel: @escaping () -> Void, toggleLid: @escaping () -> Void) {
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        add(id: 1, key: UInt32(kVK_ANSI_A), modifiers: modifiers, name: "⌃⌥⌘A", action: openPanel)
        add(id: 2, key: UInt32(kVK_ANSI_L), modifiers: modifiers, name: "⌃⌥⌘L", action: toggleLid)

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            Hotkeys.handlers[hotKey.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func add(id: UInt32, key: UInt32, modifiers: UInt32, name: String, action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: OSType(0x41574B45), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            handlers[id] = action
        } else {
            log("хоткей \(name) не зарегистрирован (занят?): OSStatus \(status)")
        }
    }
}
