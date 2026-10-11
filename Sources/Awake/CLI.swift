import AwakeCore
import Foundation

private var usage: String { tr(usageRu, usageEn) }

private let usageRu = """
awake — не даёт Mac уснуть.

  awake [status] [--json]   текущее состояние
  awake on [DUR]            не спать, пока крышка открыта (без DUR — бессрочно)
  awake lid DUR             не спать и с закрытой крышкой, DUR обязателен
  awake add DUR             продлить текущую сессию
  awake off                 выключить ручную сессию
  awake history [N]         последние N сессий (по умолчанию 15)

Пока жив процесс (холды; снимаются сами, когда процесс умер):
  awake run [--awake] [DUR] -- CMD...   запустить CMD и не спать, пока он работает (по умолчанию lid)
  awake hold [--awake] [--pid PID] [--id ID] [--label TEXT] [DUR]
                            не спать, пока жив PID (по умолчанию — родительский шелл)
  awake release [--id ID | --pid PID | --all]
  awake hold --claude / awake release --claude
                            для хуков Claude Code: читают JSON хука из stdin, ничего не печатают

DUR: 90 (минуты), 45m, 2h, 1h30m, 1d.
Файлы: ~/Library/Application Support/Awake
Лог: ~/Library/Logs/Awake/awake.log (+ awake.log.1, stderr.log)
"""

private let usageEn = """
awake — keeps the Mac awake.

  awake [status] [--json]   current state
  awake on [DUR]            stay awake while the lid is open (no DUR = until turned off)
  awake lid DUR             stay awake with the lid closed too; DUR is required
  awake add DUR             extend the current session
  awake off                 stop the manual session
  awake history [N]         last N sessions (15 by default)

While a process lives (holds; dropped automatically when it exits):
  awake run [--awake] [DUR] -- CMD...   run CMD and stay awake while it runs (lid mode by default)
  awake hold [--awake] [--pid PID] [--id ID] [--label TEXT] [DUR]
                            stay awake while PID lives (default: the parent shell)
  awake release [--id ID | --pid PID | --all]
  awake hold --claude / awake release --claude
                            for Claude Code hooks: read the hook JSON from stdin, print nothing

DUR: 90 (minutes), 45m, 2h, 1h30m, 1d.
Files: ~/Library/Application Support/Awake
Log: ~/Library/Logs/Awake/awake.log (+ awake.log.1, stderr.log)
"""

private let launchdLabel = "com.mere1y.awake"

func runCLI(_ args: [String]) -> Int32 {
    Lang.current = Lang.resolve(Store.config().language)
    let command = args.first ?? "status"
    let rest = Array(args.dropFirst())

    switch command {
    case "status", "--json":
        return printStatus(json: args.contains("--json"))
    case "history":
        return printHistory(limit: rest.first.flatMap { Int($0) } ?? 15)
    case "hold":
        return rest.contains("--claude") ? claudeHook(hold: true) : hold(rest)
    case "release":
        return rest.contains("--claude") ? claudeHook(hold: false) : release(rest)
    case "run":
        return run(rest)
    case "help", "-h", "--help":
        print(usage)
        return 0
    default:
        break
    }

    let duration = rest.first.flatMap(parseDuration)
    if let raw = rest.first, duration == nil { return fail(tr("не понял длительность: \(raw)", "can't parse duration: \(raw)")) }

    let desired: Session
    switch command {
    case "on":
        desired = Session(mode: .awake, until: duration.map { Date() + $0 }, source: "cli")
    case "lid":
        guard let d = duration else { return fail(tr("нужна длительность: awake lid 3h", "duration required: awake lid 3h")) }
        guard Power.sudoersInstalled() else { return fail(noSudoers) }
        desired = Session(mode: .lid, until: Date() + d, source: "cli")
    case "add":
        guard let d = duration else { return fail(tr("нужна длительность: awake add 1h", "duration required: awake add 1h")) }
        var s = Store.session()
        guard s.mode != .off, let until = s.until else { return fail(tr("нет сессии с таймером, продлевать нечего", "no timed session to extend")) }
        s.until = until + d
        desired = s
    case "off":
        desired = .off
    default:
        return fail(tr("неизвестная команда: \(command)", "unknown command: \(command)") + "\n\n\(usage)")
    }

    log("cli: awake \(args.joined(separator: " "))")
    Store.write(session: desired)
    guard ensureRunning() else { return fail(notRunning) }
    // Ждём, пока движок применит (тик раз в секунду).
    waitForStatus { $0.mode == desired.mode && $0.until == desired.until }
    return printStatus(json: false)
}

private var noSudoers: String {
    tr("нет правила /etc/sudoers.d/awake — запусти scripts/install.sh и выполни sudo-команду, которую он покажет",
       "no /etc/sudoers.d/awake rule — run scripts/install.sh and the sudo command it prints")
}
private var notRunning: String {
    tr("Awake.app не запущен и launchctl kickstart не помог — запусти scripts/install.sh",
       "Awake.app isn't running and launchctl kickstart didn't help — run scripts/install.sh")
}

// MARK: холды

private struct HoldOptions {
    var mode: Mode = .lid
    var pid: Int32?
    var id: String?
    var label: String?
    var duration: TimeInterval?
    var command: [String] = []
}

private struct UsageError: Error { let message: String }

private func parseHoldOptions(_ args: [String]) -> Result<HoldOptions, UsageError> {
    var o = HoldOptions()
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        switch a {
        case "--":
            o.command = Array(args[(i + 1)...])
            return .success(o)
        case "--awake": o.mode = .awake
        case "--lid": o.mode = .lid
        case "--pid":
            guard let v = value(), let p = Int32(v) else { return .failure(UsageError(message: tr("--pid ждёт число", "--pid expects a number"))) }
            o.pid = p
            i += 1
        case "--id":
            guard let v = value() else { return .failure(UsageError(message: tr("--id ждёт значение", "--id expects a value"))) }
            o.id = v
            i += 1
        case "--label":
            guard let v = value() else { return .failure(UsageError(message: tr("--label ждёт значение", "--label expects a value"))) }
            o.label = v
            i += 1
        default:
            guard let d = parseDuration(a) else { return .failure(UsageError(message: tr("не понял аргумент: \(a)", "unknown argument: \(a)"))) }
            o.duration = d
        }
        i += 1
    }
    return .success(o)
}

private func addHold(_ h: Hold) {
    Store.updateHolds { list in
        list.removeAll { $0.id == h.id }
        list.append(h)
    }
}

private func hold(_ args: [String]) -> Int32 {
    let o: HoldOptions
    switch parseHoldOptions(args) {
    case .success(let v): o = v
    case .failure(let e): return fail(e.message)
    }
    if o.mode == .lid, !Power.sudoersInstalled() { return fail(noSudoers) }
    let pid = o.pid ?? getppid()
    guard kill(pid, 0) == 0 else { return fail(tr("процесса \(pid) нет", "no process \(pid)")) }
    let h = Hold(id: o.id ?? "pid:\(pid)", pid: pid, mode: o.mode, label: o.label ?? "\(processName(pid) ?? "pid") \(pid)",
                 since: Date(), until: o.duration.map { Date() + $0 })
    log("cli: hold \(h.id) (\(h.label), \(h.mode.rawValue))")
    addHold(h)
    guard ensureRunning() else { return fail(notRunning) }
    waitForStatus { $0.holds.contains(h.label) }
    return printStatus(json: false)
}

private func release(_ args: [String]) -> Int32 {
    var id: String?
    if let i = args.firstIndex(of: "--id"), i + 1 < args.count { id = args[i + 1] }
    if let i = args.firstIndex(of: "--pid"), i + 1 < args.count { id = "pid:\(args[i + 1])" }
    let all = args.contains("--all")
    if id == nil, !all { id = "pid:\(getppid())" }
    var removed = 0
    Store.updateHolds { list in
        let before = list.count
        list.removeAll { all || $0.id == id }
        removed = before - list.count
    }
    log("cli: release \(all ? "--all" : id!) — снято \(removed)")
    print(removed > 0 ? tr("снято холдов: \(removed)", "holds released: \(removed)") : tr("такого холда нет", "no such hold"))
    return 0
}

/// `awake run -- cmd`: холд на себя, запустить cmd с теми же stdin/stdout, вернуть его код.
/// Если awake убьют вместе с cmd (Ctrl-C), холд снимет движок: процесс умер.
private func run(_ args: [String]) -> Int32 {
    let o: HoldOptions
    switch parseHoldOptions(args) {
    case .success(let v): o = v
    case .failure(let e): return fail(e.message)
    }
    guard let exe = o.command.first else { return fail(tr("нечего запускать: awake run [--awake] [DUR] -- CMD...", "nothing to run: awake run [--awake] [DUR] -- CMD...")) }
    if o.mode == .lid, !Power.sudoersInstalled() { return fail(noSudoers) }

    let me = getpid()
    let h = Hold(id: "run:\(me)", pid: me, mode: o.mode, label: o.label ?? o.command.joined(separator: " ").prefix(40).description,
                 since: Date(), until: o.duration.map { Date() + $0 })
    log("cli: run \(o.command.joined(separator: " ")) (\(o.mode.rawValue))")
    addHold(h)
    _ = ensureRunning()

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = o.command
    do {
        try p.run()
    } catch {
        Store.updateHolds { $0.removeAll { $0.id == h.id } }
        return fail(tr("не удалось запустить \(exe): \(error.localizedDescription)", "couldn't start \(exe): \(error.localizedDescription)"))
    }
    p.waitUntilExit()
    Store.updateHolds { $0.removeAll { $0.id == h.id } }
    log("cli: run завершён с кодом \(p.terminationStatus): \(o.command.joined(separator: " "))")
    return p.terminationStatus
}

/// Хуки Claude Code: UserPromptSubmit → hold, Stop/StopFailure/SessionEnd → release.
/// Никакого вывода (stdout UserPromptSubmit уходит в контекст модели) и всегда код 0.
private func claudeHook(hold: Bool) -> Int32 {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    guard let session = json["session_id"] as? String else {
        log("хук claude: нет session_id во входе")
        return 0
    }
    let id = "claude:\(session)"
    guard hold else {
        Store.updateHolds { $0.removeAll { $0.id == id } }
        return 0
    }
    let config = Store.config()
    guard config.agentMode != .off else { return 0 }
    guard let pid = claudePid() else {
        log("хук claude: не нашёл процесс claude среди предков")
        return 0
    }
    let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
    addHold(Hold(id: id, pid: pid, mode: config.agentMode, label: "Claude · \(project)", since: Date(), until: nil))
    return 0
}

/// Ближайший предок с именем claude; иначе — родитель шелла, который запустил хук.
private func claudePid() -> Int32? {
    var pid = getppid()
    var chain: [Int32] = []
    for _ in 0..<8 {
        guard pid > 1, let (parent, name) = processInfo(pid) else { break }
        // Нативный Claude — это ~/.local/share/claude/versions/<версия>, имя процесса = версия.
        if name == "claude" || executablePath(pid)?.contains("/claude/versions/") == true { return pid }
        chain.append(pid)
        pid = parent
    }
    return chain.count >= 2 ? chain[1] : chain.first
}

private func processInfo(_ pid: Int32) -> (parent: Int32, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return (info.kp_eproc.e_ppid, name)
}

private func processName(_ pid: Int32) -> String? { processInfo(pid)?.name }

private func executablePath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

// MARK: вывод

private func appRunning() -> Bool {
    guard let s = Store.read(Status.self, Paths.status), s.pid != getpid() else { return false }
    return kill(s.pid, 0) == 0
}

private func ensureRunning() -> Bool {
    if appRunning() { return true }
    Power.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(launchdLabel)"])
    for _ in 0..<30 {
        if appRunning() { return true }
        usleep(100_000)
    }
    return false
}

private func waitForStatus(_ done: (Status) -> Bool) {
    for _ in 0..<30 {
        if let s = Store.read(Status.self, Paths.status), done(s) { return }
        usleep(100_000)
    }
}

private func modeText(_ m: Mode) -> String {
    switch m {
    case .off: return tr("выключено", "off")
    case .awake: return tr("экран не гаснет (пока крышка открыта)", "screen stays on (while the lid is open)")
    case .lid: return tr("работает с закрытой крышкой", "working with the lid closed")
    }
}

private func printStatus(json: Bool) -> Int32 {
    guard appRunning(), let s = Store.read(Status.self, Paths.status) else {
        if json { print(#"{"running":false}"#) } else { print(tr("Awake.app не запущен", "Awake.app isn't running")) }
        return 1
    }
    if json {
        print(String(decoding: (try? Data(contentsOf: Paths.status)) ?? Data(), as: UTF8.self))
        return 0
    }
    var head = modeText(s.effectiveMode)
    if s.mode != .off, let until = s.until {
        head += tr(" · ещё \(durationText(until.timeIntervalSinceNow)) (до \(timeText(until)))",
                   " · \(durationText(until.timeIntervalSinceNow)) left (until \(timeText(until)))")
    }
    print("Awake: \(head)")
    if !s.holds.isEmpty {
        let manual = s.mode == .off ? "" : tr(" · ручная сессия: ", " · manual session: ") + modeText(s.mode)
        print(tr("  холды: ", "  holds: ") + s.holds.joined(separator: ", ") + manual)
    }
    if let r = s.holdsSuppressed { print(tr("  ⚠ холды заглушены: ", "  ⚠ holds suppressed: ") + reasonText(r)) }
    let lid = s.lidClosed ? tr("крышка закрыта", "lid closed") : tr("крышка открыта", "lid open")
    print("  SleepDisabled: \(s.sleepDisabled ? 1 : 0) · \(lid) · " + tr("заморожено: ", "frozen: ") + "\(s.frozenPids.count)")
    if let p = s.batteryPercent {
        print(tr("  батарея: \(p)% (\(s.onBattery ? "от батареи" : "от сети"))", "  battery: \(p)% (\(s.onBattery ? "on battery" : "on AC"))"))
    }
    if let e = s.lastEnded, s.mode == .off { print(tr("  последняя сессия: ", "  last session: ") + reasonText(e)) }
    if let e = s.error { print("  ⚠ \(e)") }
    return 0
}

private func printHistory(limit: Int) -> Int32 {
    let entries = Store.history(limit: limit)
    if entries.isEmpty { print(tr("история пуста", "no history yet")) }
    for e in entries {
        let span = "\(timeText(e.start))–\(timeText(e.end))"
        let mode = e.mode.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
        let length = durationText(e.end.timeIntervalSince(e.start)).padding(toLength: 7, withPad: " ", startingAt: 0)
        print("\(dayText(e.start)) \(span)  \(mode) \(length) \(sourceText(e.source)) · \(reasonText(e.reason))")
    }
    return 0
}

private func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("awake: \(message)\n".utf8))
    return 1
}
