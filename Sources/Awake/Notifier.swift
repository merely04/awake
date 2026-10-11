import AppKit
import UserNotifications

/// macOS-уведомления (с кнопкой «+1 ч» за 10 минут до конца) и пуш на телефон через ntfy.sh.
/// UserNotifications не пускает ad-hoc подписанное приложение («Notifications are not allowed»),
/// поэтому при отказе работаем через устаревший, но живой NSUserNotificationCenter.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onExtend: () -> Void = {}
    private var legacy = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let extend = UNNotificationAction(identifier: "extend", title: tr("+1 ч", "+1 h"))
        center.setNotificationCategories([UNNotificationCategory(identifier: "expiring", actions: [extend], intentIdentifiers: [])])
        NSUserNotificationCenter.default.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log("уведомления macOS: \(granted ? "разрешены" : "запрещены")\(error.map { " — \($0.localizedDescription)" } ?? "")"
                + (granted ? "" : " → NSUserNotificationCenter"))
            DispatchQueue.main.async { self.legacy = !granted }
        }
    }

    /// phone: false — только на экран мака (например, для подтверждения хоткея).
    func send(_ title: String, _ body: String, expiring: Bool = false, phone: Bool = true, config: Config) {
        log("уведомление: \(title) — \(body)")
        if legacy {
            let n = NSUserNotification()
            n.title = title
            n.informativeText = body
            n.hasActionButton = expiring
            if expiring {
                n.actionButtonTitle = tr("+1 ч", "+1 h")
                n.userInfo = ["expiring": true]
            }
            NSUserNotificationCenter.default.deliver(n)
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if expiring { content.categoryIdentifier = "expiring" }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if phone, config.ntfyEnabled, !config.ntfyTopic.isEmpty {
            ntfy(topic: config.ntfyTopic, title: title, body: body)
        }
    }

    func ntfy(topic: String, title: String, body: String) {
        // JSON, а не заголовки: в заголовках HTTP кириллица ломается.
        var request = URLRequest(url: URL(string: "https://ntfy.sh")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["topic": topic, "title": title, "message": body, "tags": ["computer"]])
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || code != 200 {
                log("ntfy не отправлен: \(error?.localizedDescription ?? "HTTP \(code)")")
            }
        }.resume()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "extend" {
            log("уведомление: нажато «+1 ч»")
            DispatchQueue.main.async { self.onExtend() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if notification.activationType == .actionButtonClicked, notification.userInfo?["expiring"] as? Bool == true {
            log("уведомление: нажато «+1 ч»")
            onExtend()
        }
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool { true }
}
