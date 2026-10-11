import AwakeCore
import Foundation

/// Язык интерфейса: панель, уведомления, CLI. Лог всегда по-русски — он для отладки.
/// config.language: "auto" (первый язык системы: русский → ru, иначе en), "ru", "en".
enum Lang {
    case ru, en

    static var current = resolve("auto")

    static func resolve(_ setting: String) -> Lang {
        switch setting {
        case "ru": return .ru
        case "en": return .en
        default: return Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .ru : .en
        }
    }

    var locale: Locale { Locale(identifier: self == .ru ? "ru_RU" : "en_US") }
}

func tr(_ ru: String, _ en: String) -> String { Lang.current == .ru ? ru : en }

func timeText(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Lang.current.locale))
}

func dayText(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).locale(Lang.current.locale))
}

/// "1д3ч" / "1d3h" — компактно, для меню-бара и списков.
func durationText(_ interval: TimeInterval) -> String {
    let text = formatRemaining(interval)
    guard Lang.current == .en else { return text }
    return text.replacingOccurrences(of: "д", with: "d").replacingOccurrences(of: "ч", with: "h")
        .replacingOccurrences(of: "м", with: "m").replacingOccurrences(of: "с", with: "s")
}

/// Коды причин из AwakeCore и движка. Старые записи истории (русский текст) — как есть.
func reasonText(_ code: String) -> String {
    if code.hasPrefix("battery:") {
        let p = code.dropFirst("battery:".count)
        return tr("батарея \(p)%", "battery \(p)%")
    }
    switch code {
    case "time": return tr("время вышло", "time is up")
    case "thermal:critical": return tr("перегрев", "overheating")
    case "thermal:serious": return tr("перегрев при закрытой крышке", "overheating with the lid closed")
    case "off": return tr("выключено", "turned off")
    case "replaced": return tr("сменён режим", "mode changed")
    case "agent-done": return tr("агент закончил", "agent finished")
    default: return code
    }
}

func sourceText(_ code: String) -> String {
    switch code {
    case "cli": return "CLI"
    case "panel", "панель": return tr("панель", "panel")
    case "hotkey", "хоткей": return tr("хоткей", "hotkey")
    case "agent", "агент": return tr("агент", "agent")
    default: return code
    }
}

func isAgentSource(_ code: String) -> Bool { code == "agent" || code == "агент" }
