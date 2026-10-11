import Foundation
import Network

/// Если во время сессии «Работать закрытым» Wi-Fi без связи 60 с — подключаемся к хотспоту айфона.
/// Смотрим только на Wi-Fi-интерфейс, не на интернет: упавший VPN (Throne) не должен дёргать сеть.
/// Пароль не храним и не передаём (в argv его видно через ps): подключаемся только к сети,
/// которую macOS уже помнит, — пароль система берёт из своей связки ключей.
final class Hotspot {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var wifiUp = true
    private var downSince: Date?
    private var lastAttempt = Date.distantPast
    private lazy var device = Self.wifiDevice()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.update(path.status == .satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func update(_ up: Bool) {
        guard up != wifiUp else { return }
        wifiUp = up
        downSince = up ? nil : Date()
        log("Wi-Fi: \(up ? "есть связь" : "нет связи")")
    }

    /// Возвращает текст для уведомления, если что-то делали.
    func tick(active: Bool, config: Config) -> String? {
        let ssid = config.hotspotSSID.trimmingCharacters(in: .whitespaces)
        guard active, !ssid.isEmpty, let since = downSince,
              Date().timeIntervalSince(since) >= 60, Date().timeIntervalSince(lastAttempt) >= 120
        else { return nil }
        lastAttempt = Date()
        guard let device else { return tr("хотспот: не нашёл Wi-Fi-интерфейс", "hotspot: no Wi-Fi interface found") }
        guard Self.isRemembered(ssid, device: device) else {
            return tr("хотспот: мак не помнит сеть «\(ssid)» — один раз подключись к ней вручную",
                      "hotspot: the Mac doesn't know “\(ssid)” — join it manually once")
        }
        log("Wi-Fi без связи \(Int(Date().timeIntervalSince(since))) с — подключаюсь к «\(ssid)» на \(device)")
        let result = Power.run("/usr/sbin/networksetup", ["-setairportnetwork", device, ssid])
        let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // networksetup пишет ошибку в stdout и всё равно выходит с 0.
        if result.status == 0, out.isEmpty {
            return tr("Wi-Fi пропал — подключился к хотспоту «\(ssid)»", "Wi-Fi dropped — joined the hotspot “\(ssid)”")
        }
        let detail = out.isEmpty ? tr("код \(result.status)", "code \(result.status)") : out
        log("хотспот: не удалось подключиться к «\(ssid)»: \(detail)")
        return tr("не удалось подключиться к «\(ssid)»: \(detail)", "couldn't join “\(ssid)”: \(detail)")
    }

    static func wifiDevice() -> String? {
        let lines = Power.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output.split(separator: "\n")
        guard let i = lines.firstIndex(where: { $0.hasSuffix("Wi-Fi") || $0.hasSuffix("AirPort") }), i + 1 < lines.count else { return nil }
        return lines[i + 1].replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Есть ли сеть среди запомненных macOS (System Settings → Wi-Fi → Известные сети).
    static func isRemembered(_ ssid: String, device: String) -> Bool {
        Power.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device]).output
            .split(separator: "\n").dropFirst()
            .contains { $0.trimmingCharacters(in: .whitespaces) == ssid }
    }
}
