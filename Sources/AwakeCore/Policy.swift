import Foundation

/// off — сон как обычно; awake — не спать, пока крышка открыта (аналог caffeinate -di);
/// lid — не спать и с закрытой крышкой (pmset disablesleep 1).
public enum Mode: String, Codable, Sendable, Comparable {
    case off, awake, lid

    private var rank: Int {
        switch self {
        case .off: return 0
        case .awake: return 1
        case .lid: return 2
        }
    }

    public static func < (a: Mode, b: Mode) -> Bool { a.rank < b.rank }
}

/// Желаемое состояние. Пишут CLI и панель, движок только завершает его (таймер, батарея, перегрев).
public struct Session: Codable, Equatable, Sendable {
    public var mode: Mode
    public var until: Date?
    /// Код причины: time, battery:<проценты>, thermal:critical, thermal:serious. Текст — в приложении, на нужном языке.
    public var endedReason: String?
    /// Кто запустил: cli, panel, hotkey.
    public var source: String?

    public init(mode: Mode, until: Date? = nil, endedReason: String? = nil, source: String? = nil) {
        self.mode = mode
        // Целые секунды: в JSON дата пишется без долей, и сравнение после чтения должно сходиться.
        self.until = until.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) }
        self.endedReason = endedReason
        self.source = source
    }

    public static let off = Session(mode: .off)
}

public struct Battery: Equatable, Sendable {
    public var onBattery: Bool
    public var percent: Int

    public init(onBattery: Bool, percent: Int) {
        self.onBattery = onBattery
        self.percent = percent
    }
}

/// Что движок должен выставить в системе на этом тике.
public struct Plan: Equatable, Sendable {
    public var session: Session
    /// Итоговый режим: максимум из ручной сессии и холдов агентов.
    public var mode: Mode
    /// Холды есть, но батарея или перегрев их глушат — причина.
    public var holdsSuppressed: String?
    public var preventSystemSleep: Bool
    public var preventDisplaySleep: Bool
    public var disableSleep: Bool
    /// Действия закрытой крышки: заморозка, звук, подсветка, экран.
    public var lidActions: Bool
}

/// batteryFloor = 0 отключает защиту по батарее.
/// Перегрев: critical завершает всегда, serious — только при закрытой крышке (скорее всего, в сумке).
/// heldMode — максимальный режим живых холдов агентов. Батарея и перегрев их глушат,
/// но не удаляют: холд живёт, пока жив агент.
public func makePlan(
    session: Session, now: Date, lidClosed: Bool, battery: Battery?, batteryFloor: Int,
    thermal: ProcessInfo.ThermalState = .nominal, heldMode: Mode = .off
) -> Plan {
    var trip: String?
    if let b = battery, b.onBattery, b.percent <= batteryFloor {
        trip = "battery:\(b.percent)"
    } else if thermal == .critical {
        trip = "thermal:critical"
    } else if thermal == .serious, lidClosed {
        trip = "thermal:serious"
    }

    var s = session
    if s.mode != .off, let until = s.until, now >= until {
        s = Session(mode: .off, endedReason: "time")
    }
    if s.mode != .off, let trip {
        s = Session(mode: .off, endedReason: trip)
    }
    let held = trip == nil ? heldMode : .off
    let mode = max(s.mode, held)
    let on = mode != .off
    return Plan(
        session: s,
        mode: mode,
        holdsSuppressed: heldMode != .off ? trip : nil,
        preventSystemSleep: on,
        preventDisplaySleep: on && !lidClosed,
        disableSleep: mode == .lid,
        lidActions: mode == .lid && lidClosed
    )
}
