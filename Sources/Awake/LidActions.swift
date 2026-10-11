import AppKit
import ObjectiveC

/// Звук и подсветка клавиатуры на время закрытой крышки.
/// Что сделано — пишется в lidstate.json до изменения, чтобы вернуть после падения.
enum LidActions {
    static func apply(config: Config) {
        var state = LidState()
        if config.muteOnLid, outputMuted() == false {
            state.muted = true
        }
        if config.keyboardOffOnLid, let level = Keyboard.brightness(), level > 0 {
            state.keyboard = level
        }
        Store.write(state, Paths.lidState)
        if state.muted {
            setOutputMuted(true)
            log("звук выключен")
        }
        if let level = state.keyboard {
            Keyboard.setBrightness(0)
            log("подсветка клавиатуры погашена (была \(String(format: "%.2f", level)))")
        }
    }

    /// Возвращает только то, что меняли сами. Вызывается и при старте — после падения.
    static func restore() {
        guard let state = Store.read(LidState.self, Paths.lidState) else { return }
        if state.muted {
            setOutputMuted(false)
            log("звук включён обратно")
        }
        if let level = state.keyboard {
            Keyboard.setBrightness(level)
            log("подсветка клавиатуры возвращена: \(String(format: "%.2f", level))")
        }
        try? FileManager.default.removeItem(at: Paths.lidState)
    }

    private static func outputMuted() -> Bool? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(&error)
        if let error { log("не удалось прочитать звук: \(error)") }
        return result.map { $0.booleanValue }
    }

    private static func setOutputMuted(_ muted: Bool) {
        var error: NSDictionary?
        NSAppleScript(source: "set volume output muted \(muted)")?.executeAndReturnError(&error)
        if let error { log("не удалось \(muted ? "выключить" : "включить") звук: \(error)") }
    }
}

/// Приватный KeyboardBrightnessClient из CoreBrightness. Проверено на macOS 15.7;
/// если класс или методы пропадут — тихо ничего не делаем (и пишем в лог один раз).
enum Keyboard {
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let client: (NSObject, UInt64)? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else {
            log("подсветка клавиатуры: KeyboardBrightnessClient недоступен")
            return nil
        }
        let c = cls.init()
        let needed = ["copyKeyboardBacklightIDs", "brightnessForKeyboard:", "setBrightness:forKeyboard:"]
        guard needed.allSatisfy({ c.responds(to: NSSelectorFromString($0)) }),
              let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              let id = ids.first
        else {
            log("подсветка клавиатуры: нет нужных методов или клавиатуры")
            return nil
        }
        return (c, id.uint64Value)
    }()

    static func brightness() -> Float? {
        guard let (c, id) = client else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        return unsafeBitCast(c.method(for: sel), to: Get.self)(c, sel, id)
    }

    static func setBrightness(_ value: Float) {
        guard let (c, id) = client else { return }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        _ = unsafeBitCast(c.method(for: sel), to: Set.self)(c, sel, value, id)
    }
}
