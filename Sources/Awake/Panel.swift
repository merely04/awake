import AwakeCore
import SwiftUI
import UniformTypeIdentifiers

final class PanelModel: ObservableObject {
    @Published var status: Status?
    @Published var now = Date()
    @Published var config = Store.config()
    @Published var history: [HistoryEntry] = []
    @Published var hotspotSSID = ""
    /// nil — не проверяли (пустое имя или нет Wi-Fi-интерфейса).
    @Published var hotspotRemembered: Bool?
    /// nil — бессрочно. Помним последний выбор между запусками.
    @Published var duration: TimeInterval? = PanelModel.savedDuration() {
        didSet { UserDefaults.standard.set(duration ?? 0, forKey: "duration") }
    }

    var changed: () -> Void = {}
    var extend: () -> Void = {}
    var releaseHolds: () -> Void = {}
    var quit: () -> Void = {}

    static var presets: [(String, TimeInterval?)] {
        [(tr("30м", "30m"), 1800), (tr("1ч", "1h"), 3600), (tr("3ч", "3h"), 10800), (tr("8ч", "8h"), 28800), ("∞", nil)]
    }

    private static func savedDuration() -> TimeInterval? {
        guard UserDefaults.standard.object(forKey: "duration") != nil else { return 10800 }
        let d = UserDefaults.standard.double(forKey: "duration")
        return d > 0 ? d : nil
    }

    func start(_ mode: Mode) {
        log("панель: \(mode.rawValue) на \(duration.map(formatRemaining) ?? "∞")")
        Store.write(session: Session(mode: mode, until: duration.map { Date() + $0 }, source: "panel"))
        changed()
    }

    func addHour() {
        log("панель: +1 ч")
        extend()
    }

    func stop() {
        log("панель: выключить")
        Store.write(session: .off)
        changed()
    }

    func loadHistory() { history = Store.history(limit: 20) }

    // MARK: настройки — движок перечитывает config.json каждый тик

    func reloadConfig() {
        config = Store.config()
        hotspotSSID = config.hotspotSSID
        checkHotspot()
    }

    func update(_ what: String, _ body: (inout Config) -> Void) {
        body(&config)
        Store.write(config, Paths.config)
        log("настройки: \(what)")
    }

    func setBatteryFloor(_ value: Int) {
        update("порог батареи \(min(50, max(0, value)))%") { $0.batteryFloor = min(50, max(0, value)) }
    }

    func removeFreeze(_ id: String) {
        update("убрано из заморозки: \(id)") { $0.freeze.removeAll { $0 == id } }
    }

    func addFreeze() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = tr("Какие приложения ставить на паузу, пока крышка закрыта", "Which apps to pause while the lid is closed")
        panel.prompt = tr("Добавить", "Add")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { $0 != "com.mere1y.awake" && !config.freeze.contains($0) }
        guard !ids.isEmpty else { return }
        update("добавлено в заморозку: \(ids.joined(separator: ", "))") { $0.freeze += ids }
    }

    func saveHotspot() {
        let ssid = hotspotSSID.trimmingCharacters(in: .whitespaces)
        update("хотспот: «\(ssid)»") { $0.hotspotSSID = ssid }
        checkHotspot()
    }

    private func checkHotspot() {
        let ssid = config.hotspotSSID
        hotspotRemembered = ssid.isEmpty ? nil : Hotspot.wifiDevice().map { Hotspot.isRemembered(ssid, device: $0) }
    }

    func testNtfy() {
        Notifier.shared.ntfy(topic: config.ntfyTopic, title: tr("Awake: проверка", "Awake: test"),
                             body: tr("Уведомления с мака доходят", "Notifications from the Mac arrive"))
        log("настройки: тестовое уведомление ntfy")
    }

    /// auto / ru / en — применяется сразу, без перезапуска.
    func setLanguage(_ code: String) {
        update("язык: \(code)") { $0.language = code }
        Lang.current = Lang.resolve(code)
    }

    func copyTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.ntfyTopic, forType: .string)
    }

    func openConfigFile() {
        NSWorkspace.shared.open([Paths.config], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openLog() {
        NSWorkspace.shared.open([Paths.log], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

enum Page { case main, settings, history }

/// Только для оффскрин-рендера: ImageRenderer не рисует содержимое ScrollView.
var panelScrollEnabled = true

/// ScrollView с явной высотой: у поповера размер считается по идеальной высоте,
/// а у ScrollView её нет — без frame(height:) он схлопывается.
private struct Scroll<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if panelScrollEnabled {
            ScrollView { content }.frame(height: height)
        } else {
            content
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State var page = Page.main

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch page {
            case .settings:
                SettingsView(model: model) { page = .main }
            case .history:
                HistoryView(model: model) { page = .main }
            case .main:
                if let s = model.status, s.effectiveMode != .off {
                    ActiveView(model: model, status: s)
                } else {
                    IdleView(model: model)
                }
            }
            Divider()
            HStack(spacing: 4) {
                FooterButton(icon: "gearshape", title: tr("Настройки", "Settings")) {
                    model.reloadConfig()
                    page = page == .settings ? .main : .settings
                }
                FooterButton(icon: "clock.arrow.circlepath", title: tr("История", "History")) {
                    model.loadHistory()
                    page = page == .history ? .main : .history
                }
                FooterButton(icon: "doc.text", title: tr("Лог", "Log"), action: model.openLog)
                Spacer()
                FooterButton(icon: "power", title: nil, action: model.quit)
                    .help(tr("Выйти из Awake (сон вернётся)", "Quit Awake (sleep comes back)"))
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct IdleView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
            Text(tr("Мак спит как обычно", "Mac sleeps as usual")).font(.headline)
        }
        if let e = model.status?.lastEnded {
            Text(tr("Последняя сессия: ", "Last session: ") + reasonText(e)).font(.caption).foregroundStyle(.secondary)
        }
        if let e = model.status?.error {
            Text("⚠ \(e)").font(.caption).foregroundStyle(.orange)
        }
        if let r = model.status?.holdsSuppressed {
            Text(tr("⚠ Агент работает, но защита от сна выключена: ", "⚠ An agent is working, but sleep protection is off: ") + reasonText(r)).font(.caption).foregroundStyle(.orange)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text(tr("На сколько", "For how long")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(PanelModel.presets, id: \.0) { label, value in
                    Chip(title: label, selected: model.duration == value) { model.duration = value }
                }
            }
        }

        HStack(spacing: 10) {
            Tile(icon: "sun.max.fill", tint: .orange, title: tr("Экран не гаснет", "Screen stays on"),
                 subtitle: tr("Пока крышка открыта. Закроешь — уснёт", "While the lid is open. Close it and it sleeps"), enabled: true) { model.start(.awake) }
            Tile(icon: "laptopcomputer", tint: .indigo, title: tr("Работать закрытым", "Work lid closed"),
                 subtitle: model.duration == nil ? tr("Нужно время — выбери выше", "Needs a duration — pick one above")
                                                 : tr("Агенты работают, крышку можно закрыть", "Agents keep working, you can close the lid"),
                 enabled: model.duration != nil) { model.start(.lid) }
        }

        if model.config.agentMode != .off {
            Label(model.config.agentMode == .lid ? tr("Пока Claude отвечает, мак не уснёт и с закрытой крышкой", "While Claude answers, the Mac stays awake even with the lid closed")
                                                 : tr("Пока Claude отвечает, мак не уснёт", "While Claude answers, the Mac stays awake"),
                  systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActiveView: View {
    @ObservedObject var model: PanelModel
    let status: Status

    var body: some View {
        let lid = status.effectiveMode == .lid
        let manual = status.mode != .off
        HStack(spacing: 8) {
            Image(systemName: lid ? "laptopcomputer" : "sun.max.fill").foregroundStyle(lid ? Color.indigo : Color.orange)
            Text(lid ? tr("Работает с закрытой крышкой", "Working with the lid closed") : tr("Экран не гаснет", "Screen stays on")).font(.headline)
        }

        if manual {
            VStack(spacing: 2) {
                Text(status.until.map { clock($0.timeIntervalSince(model.now)) } ?? "∞")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(status.until.map { tr("до ", "until ") + timeText($0) } ?? tr("без ограничения", "no time limit"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                if status.until != nil {
                    ActionButton(title: tr("+1 ч", "+1 h"), fill: Color.primary.opacity(0.08), text: .primary, action: model.addHour)
                }
                ActionButton(title: tr("Выключить", "Stop"), fill: .red, text: .white, action: model.stop)
            }
        }

        if !status.holds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(manual ? tr("Ещё держат агенты", "Agents also holding") : tr("Пока работают агенты", "While these agents work")).font(.caption).foregroundStyle(.secondary)
                ForEach(status.holds, id: \.self) { label in
                    Label(label, systemImage: "sparkles").font(.callout)
                }
                if !manual {
                    Text(tr("Закончат — мак уснёт сам", "When they finish, the Mac sleeps")).font(.caption).foregroundStyle(.secondary)
                    ActionButton(title: tr("Отпустить сейчас", "Release now"), fill: Color.primary.opacity(0.08), text: .primary, action: model.releaseHolds)
                }
            }
        }

        HStack(spacing: 12) {
            if lid {
                Label(status.lidClosed ? tr("крышка закрыта", "lid closed") : tr("крышка открыта", "lid open"), systemImage: "laptopcomputer")
            }
            if !status.frozenPids.isEmpty {
                Label(tr("на паузе", "paused"), systemImage: "pause.circle")
            }
            if let p = status.batteryPercent {
                Label("\(p)%", systemImage: status.onBattery ? "battery.75percent" : "bolt.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if let e = status.error {
            Text("⚠ \(e)").font(.caption).foregroundStyle(.orange)
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: PanelModel
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FooterButton(icon: "chevron.left", title: nil, action: back)
            Text(tr("История", "History")).font(.headline)
        }
        if model.history.isEmpty {
            Text(tr("Пока пусто. Здесь появятся сессии и долгие ходы агентов.", "Nothing yet. Sessions and long agent runs show up here."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Scroll(height: min(CGFloat(model.history.count) * 46, 360)) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.history.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: isAgentSource(e.source) ? "sparkles" : e.mode == .lid ? "laptopcomputer" : "sun.max.fill")
                                .foregroundStyle(e.mode == .lid ? Color.indigo : Color.orange)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dayText(e.start)) · \(timeText(e.start))–\(timeText(e.end)) · \(durationText(e.end.timeIntervalSince(e.start)))")
                                    .font(.callout)
                                Text("\(sourceText(e.source)) · \(reasonText(e.reason))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: PanelModel
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FooterButton(icon: "chevron.left", title: nil, action: back)
            Text(tr("Настройки", "Settings")).font(.headline)
        }

        Scroll(height: 440) {
            VStack(alignment: .leading, spacing: 18) {
                Section(tr("Язык", "Language")) {
                    HStack(spacing: 6) {
                        Chip(title: tr("Как в системе", "System"), selected: model.config.language == "auto") { model.setLanguage("auto") }
                        Chip(title: "Русский", selected: model.config.language == "ru") { model.setLanguage("ru") }
                        Chip(title: "English", selected: model.config.language == "en") { model.setLanguage("en") }
                    }
                }

                Section(tr("Пока Claude Code отвечает", "While Claude Code answers")) {
                    HStack(spacing: 6) {
                        Chip(title: tr("Ничего", "Nothing"), selected: model.config.agentMode == .off) { model.update("агенты: off") { $0.agentMode = .off } }
                        Chip(title: tr("Экран", "Screen"), selected: model.config.agentMode == .awake) { model.update("агенты: awake") { $0.agentMode = .awake } }
                        Chip(title: tr("Закрытым", "Lid closed"), selected: model.config.agentMode == .lid) { model.update("агенты: lid") { $0.agentMode = .lid } }
                    }
                }

                Section(tr("Батарея", "Battery")) {
                    HStack {
                        Text(model.config.batteryFloor == 0 ? tr("Не выключать по батарее", "Don't stop on low battery")
                                                            : tr("Выключать ниже \(model.config.batteryFloor)%", "Stop below \(model.config.batteryFloor)%"))
                        Spacer()
                        RoundButton(icon: "minus", enabled: model.config.batteryFloor > 0) { model.setBatteryFloor(model.config.batteryFloor - 5) }
                        RoundButton(icon: "plus", enabled: model.config.batteryFloor < 50) { model.setBatteryFloor(model.config.batteryFloor + 5) }
                    }
                    .font(.callout)
                }

                Section(tr("Когда крышка закрыта", "When the lid is closed")) {
                    CheckRow(title: tr("Выключать звук", "Mute audio"), on: model.config.muteOnLid) {
                        model.update("звук на крышке: \(!model.config.muteOnLid)") { $0.muteOnLid.toggle() }
                    }
                    CheckRow(title: tr("Гасить подсветку клавиатуры", "Turn off keyboard backlight"), on: model.config.keyboardOffOnLid) {
                        model.update("подсветка на крышке: \(!model.config.keyboardOffOnLid)") { $0.keyboardOffOnLid.toggle() }
                    }
                    Text(tr("Ставить на паузу:", "Pause these apps:")).font(.callout).padding(.top, 4)
                    if model.config.freeze.isEmpty {
                        Text(tr("Ничего", "None")).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.config.freeze, id: \.self) { id in
                        AppRow(bundleID: id) { model.removeFreeze(id) }
                    }
                    ActionButton(title: tr("Добавить приложение…", "Add app…"), fill: Color.primary.opacity(0.08), text: .primary, action: model.addFreeze)
                }

                Section(tr("Уведомления на телефон (ntfy)", "Phone notifications (ntfy)")) {
                    CheckRow(title: tr("Слать на телефон", "Send to phone"), on: model.config.ntfyEnabled) {
                        model.update("ntfy: \(!model.config.ntfyEnabled)") { $0.ntfyEnabled.toggle() }
                    }
                    Text(tr("В приложении ntfy подпишись на топик:", "In the ntfy app, subscribe to the topic:")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(model.config.ntfyTopic).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        FooterButton(icon: "doc.on.doc", title: nil, action: model.copyTopic).help(tr("Скопировать", "Copy"))
                    }
                    ActionButton(title: tr("Отправить проверку", "Send a test"), fill: Color.primary.opacity(0.08), text: .primary, action: model.testNtfy)
                }

                Section(tr("Хотспот, если пропал Wi-Fi", "Hotspot when Wi-Fi drops")) {
                    TextField(tr("Имя сети айфона", "iPhone network name"), text: $model.hotspotSSID).textFieldStyle(.roundedBorder)
                    ActionButton(title: tr("Сохранить", "Save"), fill: Color.primary.opacity(0.08), text: .primary, action: model.saveHotspot)
                    if let remembered = model.hotspotRemembered {
                        Label(remembered ? tr("Мак помнит эту сеть и её пароль", "The Mac knows this network and its password")
                                         : tr("Мак не знает эту сеть — подключись к ней один раз вручную", "The Mac doesn't know this network — join it manually once"),
                              systemImage: remembered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(remembered ? Color.green : Color.orange)
                    }
                    Text(tr("Только в режиме «Работать закрытым»: Wi-Fi без связи 60 с → подключаюсь к этой сети. Пароль берёт macOS из своей связки ключей. На айфоне должен быть включён режим модема.",
                             "Only in “work lid closed” mode: Wi-Fi without a connection for 60 s → join this network. macOS supplies the password from its keychain. Personal Hotspot must be on."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section(tr("Хоткеи", "Hotkeys")) {
                    Text(tr("⌃⌥⌘A — панель · ⌃⌥⌘L — «Работать закрытым» вкл/выкл", "⌃⌥⌘A — panel · ⌃⌥⌘L — toggle “work lid closed”")).font(.callout)
                }

                FooterButton(icon: "doc.plaintext", title: tr("Открыть config.json в TextEdit", "Open config.json in TextEdit"), action: model.openConfigFile)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct AppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "questionmark.app").frame(width: 20, height: 20)
                Text(bundleID).foregroundStyle(.secondary)
            }
            Spacer()
            FooterButton(icon: "xmark", title: nil, action: remove).help(tr("Убрать", "Remove"))
        }
        .font(.callout)
    }
}

// MARK: кнопки — у всех одинаковая подсветка при наведении

/// Полупрозрачный слой поверх: темнит в светлой теме и светлит в тёмной.
private struct HoverHighlight: ViewModifier {
    var radius: CGFloat
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(hovering && enabled ? 0.09 : 0)))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

private extension View {
    func hoverHighlight(radius: CGFloat, enabled: Bool = true) -> some View {
        modifier(HoverHighlight(radius: radius, enabled: enabled))
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .hoverHighlight(radius: 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CheckRow: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer()
            }
            .font(.callout)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .hoverHighlight(radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Tile: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(tint)
                    .frame(height: 32)
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.14)))
            .hoverHighlight(radius: 12, enabled: enabled)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

private struct ActionButton: View {
    let title: String
    let fill: Color
    let text: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(fill))
                .hoverHighlight(radius: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RoundButton: View {
    let icon: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .hoverHighlight(radius: 13, enabled: enabled)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct FooterButton: View {
    let icon: String
    let title: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                if let title { Text(title) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .hoverHighlight(radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
