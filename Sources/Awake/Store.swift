import AwakeCore
import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/Awake")
    static let session = support.appendingPathComponent("session.json")
    static let status = support.appendingPathComponent("status.json")
    static let config = support.appendingPathComponent("config.json")
    static let holds = support.appendingPathComponent("holds.json")
    static let history = support.appendingPathComponent("history.jsonl")
    /// Что сделано при закрытии крышки (звук, подсветка) — чтобы вернуть после падения.
    static let lidState = support.appendingPathComponent("lidstate.json")
    static let lock = support.appendingPathComponent(".lock")
    /// Журнал замороженных pid — по одному на строку, его читает и backstop.sh.
    static let frozen = support.appendingPathComponent("frozen.pids")
    static let log = home.appendingPathComponent("Library/Logs/Awake/awake.log")
}

struct Config: Codable, Equatable {
    var batteryFloor = 15
    var freeze = ["ru.keepcoder.Telegram"]
    /// Режим, пока агент (Claude Code) работает; off — хуки ничего не делают.
    var agentMode: Mode = .lid
    var muteOnLid = true
    var keyboardOffOnLid = true
    var ntfyEnabled = true
    var ntfyTopic = "awake-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
    /// SSID хотспота; пароль берёт macOS из своей связки ключей.
    var hotspotSSID = ""
    /// auto / ru / en
    var language = "auto"

    init() {}

    /// Старый config.json без новых полей должен читаться, а не сбрасываться.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? d.batteryFloor
        freeze = try c.decodeIfPresent([String].self, forKey: .freeze) ?? d.freeze
        agentMode = try c.decodeIfPresent(Mode.self, forKey: .agentMode) ?? d.agentMode
        muteOnLid = try c.decodeIfPresent(Bool.self, forKey: .muteOnLid) ?? d.muteOnLid
        keyboardOffOnLid = try c.decodeIfPresent(Bool.self, forKey: .keyboardOffOnLid) ?? d.keyboardOffOnLid
        ntfyEnabled = try c.decodeIfPresent(Bool.self, forKey: .ntfyEnabled) ?? d.ntfyEnabled
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
    }
}

/// «Не спать, пока жив процесс». Ставят хуки Claude Code (`awake hold --claude`) и `awake run`.
struct Hold: Codable, Equatable {
    var id: String
    var pid: Int32
    var mode: Mode
    var label: String
    var since: Date
    var until: Date?
}

struct HistoryEntry: Codable {
    var start: Date
    var end: Date
    var mode: Mode
    /// cli / panel / hotkey / agent (в старых записях — по-русски)
    var source: String
    /// код причины, см. reasonText
    var reason: String
}

struct LidState: Codable {
    var muted = false
    var keyboard: Float?
}

/// Фактическое состояние, которое движок публикует для CLI и панели.
struct Status: Codable, Equatable {
    var pid: Int32
    /// Ручная сессия.
    var mode: Mode
    /// Итог с учётом холдов агентов.
    var effectiveMode: Mode
    var until: Date?
    var holds: [String]
    var holdsSuppressed: String?
    var lidClosed: Bool
    var sleepDisabled: Bool
    var frozenPids: [Int32]
    var batteryPercent: Int?
    var onBattery: Bool
    var error: String?
    var lastEnded: String?
}

enum Store {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ url: URL) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? encoder.encode(value).write(to: url, options: .atomic)
    }

    static func session() -> Session { read(Session.self, Paths.session) ?? .off }
    static func write(session: Session) { write(session, Paths.session) }

    static func config() -> Config {
        if let c = read(Config.self, Paths.config) {
            // Дописываем новые поля в старый файл, чтобы они были видны и в TextEdit.
            if let raw = try? Data(contentsOf: Paths.config), raw != (try? encoder.encode(c)) { write(c, Paths.config) }
            return c
        }
        let c = Config()
        if !FileManager.default.fileExists(atPath: Paths.config.path) { write(c, Paths.config) }
        return c
    }

    static func holds() -> [Hold] { read([Hold].self, Paths.holds) ?? [] }

    /// Чтение-изменение-запись холдов под flock: хуки нескольких Claude могут сработать одновременно.
    static func updateHolds(_ body: (inout [Hold]) -> Void) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        var list = holds()
        let before = list
        body(&list)
        if list != before { write(list, Paths.holds) }
    }

    static func appendHistory(_ entry: HistoryEntry) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard var line = try? e.encode(entry) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: Paths.history)
        }
    }

    /// Последние записи, новые сверху.
    static func history(limit: Int) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: Paths.history, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).reversed()
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }
}

private let logTime: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
}()

/// Локальное время; при 2 МБ текущий файл уезжает в awake.log.1 (один старый файл).
func log(_ message: String) {
    let line = "\(logTime.string(from: Date())) [\(getpid())] \(message)\n"
    let url = Paths.log
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
