import AwakeCore
import Foundation
import IOKit.pwr_mgt

/// Раз в тик приводит систему к session.json + holds.json и публикует status.json.
final class Engine {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var sleepDisabled: Bool
    private var frozen: [pid_t] = []
    private var lidApplied = false
    private var lastLidClosed: Bool
    private var error: String?
    private var lastEnded: String?
    private var lastSession: Session?
    private var sessionStart = Date()
    private var holdsStart: Date?
    private var lastHoldCount = 0
    private var lastSuppressed: String?
    private var warnedUntil: Date?
    private var lastThermal: ProcessInfo.ThermalState?
    private var lastOnBattery: Bool?
    private var lastPercent: Int?
    private var lastHeartbeat = Date.distantPast
    private let hotspot = Hotspot()
    private(set) var status: Status?

    init() {
        Freezer.resumeLeftovers()
        LidActions.restore()
        sleepDisabled = Power.readSleepDisabled()
        lastLidClosed = Power.lidClosed()
        log("запуск: SleepDisabled=\(sleepDisabled), крышка \(lastLidClosed ? "закрыта" : "открыта")")
    }

    func tick() {
        let now = Date()
        let config = Store.config()
        Lang.current = Lang.resolve(config.language)
        let raw = Store.session()
        let lid = Power.lidClosed()
        let battery = Power.battery()
        let thermal = ProcessInfo.processInfo.thermalState
        let holds = liveHolds(now: now)
        var plan = makePlan(session: raw, now: now, lidClosed: lid, battery: battery, batteryFloor: config.batteryFloor,
                            thermal: thermal, heldMode: holds.map(\.mode).max() ?? .off)

        logChanges(raw: raw, thermal: thermal, battery: battery, active: plan.mode != .off)

        var session = plan.session
        if session != raw {
            lastEnded = session.endedReason
            log("сессия \(raw.mode.rawValue) завершена: \(lastEnded ?? "?")")
            Store.write(session: session)
            Notifier.shared.send(tr("Awake: сессия закончилась", "Awake: session ended"),
                                 tr("\(reasonText(lastEnded ?? "?")) — мак снова засыпает как обычно",
                                    "\(reasonText(lastEnded ?? "?")) — the Mac sleeps as usual again"), config: config)
        } else if session.mode != .off {
            lastEnded = nil
        }
        recordHistory(session: session, now: now)
        trackHolds(holds, plan: plan, lid: lid, now: now, config: config)

        // Сначала вернуть действия крышки, потом разрешать сон: с закрытой крышкой мак уснёт сразу
        // после disablesleep 0, и Telegram остался бы замороженным, а звук выключенным до пробуждения.
        if !plan.lidActions, lidApplied { restoreLid() }

        // Без sudoers режим крышки невозможен — понижаем ручную сессию до awake, а не крутим sudo каждую секунду.
        if plan.disableSleep != sleepDisabled {
            if Power.setSleepDisabled(plan.disableSleep) {
                sleepDisabled = plan.disableSleep
                error = nil
                log("pmset disablesleep \(sleepDisabled ? 1 : 0)")
            } else if plan.disableSleep {
                log("не удалось выставить disablesleep 1 — нет /etc/sudoers.d/awake?")
                error = tr("не удалось выставить disablesleep 1 — нет /etc/sudoers.d/awake?", "couldn't set disablesleep 1 — is /etc/sudoers.d/awake missing?")
                if session.mode == .lid {
                    session.mode = .awake
                    Store.write(session: session)
                }
                plan = makePlan(session: session, now: now, lidClosed: lid, battery: battery, batteryFloor: config.batteryFloor,
                                thermal: thermal, heldMode: min(holds.map(\.mode).max() ?? .off, .awake))
            } else {
                log("не удалось вернуть disablesleep 0")
                error = tr("не удалось вернуть disablesleep 0", "couldn't restore disablesleep 0")
            }
        }

        if !plan.lidActions, lidApplied { restoreLid() }
        Power.set(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, on: plan.preventSystemSleep)
        Power.set(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, on: plan.preventDisplaySleep)
        if plan.lidActions, !lidApplied {
            frozen = Freezer.freeze(bundleIDs: config.freeze)
            LidActions.apply(config: config)
            Power.displaySleepNow()
            lidApplied = true
        }
        if lid != lastLidClosed {
            log("крышка \(lid ? "закрыта" : "открыта")")
            lastLidClosed = lid
        }

        // За 10 минут до конца ручной сессии — с кнопкой «+1 ч».
        if session.mode != .off, let until = session.until, until.timeIntervalSince(now) <= 600, warnedUntil != until,
           until.timeIntervalSince(sessionStart) > 900 {
            warnedUntil = until
            Notifier.shared.send(tr("Awake: осталось 10 минут", "Awake: 10 minutes left"),
                                 tr("до \(timeText(until)), потом мак уснёт", "until \(timeText(until)), then the Mac sleeps"),
                                 expiring: true, config: config)
        }
        if let message = hotspot.tick(active: plan.mode == .lid, config: config) {
            Notifier.shared.send(tr("Awake: сеть", "Awake: network"), message, config: config)
        }

        // Пульс: по разрывам между строками видно, когда Mac на самом деле спал.
        if plan.mode != .off, now.timeIntervalSince(lastHeartbeat) >= 300 {
            lastHeartbeat = now
            log("пульс: \(describe(session)), холдов \(holds.count), режим \(plan.mode.rawValue), крышка \(lid ? "закрыта" : "открыта"), "
                + "SleepDisabled=\(sleepDisabled ? 1 : 0), заморожено \(frozen.count), "
                + "батарея \(battery.map { "\($0.percent)%\($0.onBattery ? "" : " (сеть)")" } ?? "нет"), температура \(name(thermal))")
        } else if plan.mode == .off {
            lastHeartbeat = .distantPast
        }

        let new = Status(
            pid: getpid(), mode: session.mode, effectiveMode: plan.mode, until: session.until,
            holds: holds.map(\.label), holdsSuppressed: plan.holdsSuppressed, lidClosed: lid,
            sleepDisabled: sleepDisabled, frozenPids: frozen, batteryPercent: battery?.percent,
            onBattery: battery?.onBattery ?? false, error: error, lastEnded: lastEnded
        )
        if new != status {
            status = new
            Store.write(new, Paths.status)
        }
    }

    private func restoreLid() {
        Freezer.resume(frozen)
        frozen = []
        LidActions.restore()
        lidApplied = false
    }

    func extendHour() {
        var s = Store.session()
        guard s.mode != .off, let until = s.until else { return }
        s.until = until + 3600
        Store.write(session: s)
        log("продлено на 1 ч: до \(s.until!.formatted(date: .omitted, time: .shortened))")
        tick()
    }

    func releaseAllHolds() {
        Store.updateHolds { $0.removeAll() }
        log("все холды сняты вручную")
        tick()
    }

    /// Выход приложения: всё вернуть. session.json не трогаем — решает вызывающий.
    func shutdown() {
        if lidApplied { restoreLid() }
        Power.set(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, on: false)
        Power.set(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, on: false)
        if sleepDisabled, Power.setSleepDisabled(false) { sleepDisabled = false }
        log("выход: SleepDisabled=\(sleepDisabled)")
        try? FileManager.default.removeItem(at: Paths.status)
    }

    // MARK: -

    /// Убирает холды умерших процессов и просроченные.
    private func liveHolds(now: Date) -> [Hold] {
        var alive: [Hold] = []
        Store.updateHolds { list in
            list.removeAll { h in
                let dead = kill(h.pid, 0) != 0 && errno == ESRCH
                let expired = h.until.map { now >= $0 } ?? false
                if dead || expired { log("холд снят: \(h.label) — \(dead ? "процесс \(h.pid) завершился" : "время вышло")") }
                return dead || expired
            }
            alive = list
        }
        return alive
    }

    private func trackHolds(_ holds: [Hold], plan: Plan, lid: Bool, now: Date, config: Config) {
        if holds.count != lastHoldCount {
            log("холдов: \(holds.count)\(holds.isEmpty ? "" : " — \(holds.map(\.label).joined(separator: ", "))")")
            if lastHoldCount == 0 {
                holdsStart = now
            } else if holds.isEmpty, let start = holdsStart {
                // Короткие ходы агента (меньше минуты) в историю не пишем — их десятки.
                if now.timeIntervalSince(start) >= 60 {
                    Store.appendHistory(HistoryEntry(start: start, end: now, mode: config.agentMode, source: "agent", reason: "agent-done"))
                    if lid {
                        let worked = durationText(now.timeIntervalSince(start))
                        Notifier.shared.send(tr("Awake: агент закончил", "Awake: agent finished"),
                                             tr("работал \(worked) — мак засыпает", "worked for \(worked) — the Mac is going to sleep"), config: config)
                    }
                }
                holdsStart = nil
            }
            lastHoldCount = holds.count
        }
        if plan.holdsSuppressed != lastSuppressed {
            if let reason = plan.holdsSuppressed {
                log("холды заглушены: \(reason)")
                Notifier.shared.send(tr("Awake: агент без защиты от сна", "Awake: agent no longer protected"),
                                     tr("\(reasonText(reason)) — мак может уснуть, пока агент работает",
                                        "\(reasonText(reason)) — the Mac may sleep while the agent works"), config: config)
            }
            lastSuppressed = plan.holdsSuppressed
        }
    }

    /// Запись в историю, когда ручная сессия кончилась или сменила режим (продление — та же сессия).
    private func recordHistory(session: Session, now: Date) {
        defer { lastSession = session }
        guard let prev = lastSession else {
            sessionStart = now
            return
        }
        guard prev.mode != session.mode else { return }
        if prev.mode != .off {
            Store.appendHistory(HistoryEntry(start: sessionStart, end: now, mode: prev.mode, source: prev.source ?? "?",
                                             reason: session.endedReason ?? (session.mode == .off ? "off" : "replaced")))
        }
        sessionStart = now
    }

    private func logChanges(raw: Session, thermal: ProcessInfo.ThermalState, battery: Battery?, active: Bool) {
        if raw != lastSession {
            log("сессия: \(describe(raw))\(raw.source.map { " (\($0))" } ?? "")")
        }
        if thermal != lastThermal {
            log("температура: \(name(thermal))")
            if active, thermal == .serious || thermal == .critical, let last = lastThermal, last != .serious, last != .critical {
                Notifier.shared.send(tr("Awake: мак греется", "Awake: the Mac is getting hot"),
                                     tr("температура: \(name(thermal))", "thermal state: \(name(thermal))"), config: Store.config())
            }
            lastThermal = thermal
        }
        if let b = battery {
            if b.onBattery != lastOnBattery {
                log("питание: \(b.onBattery ? "от батареи" : "от сети"), \(b.percent)%")
            } else if b.onBattery, active, b.percent != lastPercent {
                log("батарея: \(b.percent)%")
            }
            lastOnBattery = b.onBattery
            lastPercent = b.percent
        }
    }

    private func describe(_ s: Session) -> String {
        guard s.mode != .off else { return "off" }
        guard let until = s.until else { return "\(s.mode.rawValue) бессрочно" }
        return "\(s.mode.rawValue) до \(until.formatted(date: .omitted, time: .shortened)) (ещё \(formatRemaining(until.timeIntervalSinceNow)))"
    }

    private func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(t.rawValue))"
        }
    }
}
