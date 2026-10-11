import AppKit
import AwakeCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private let model = PanelModel()
    private let popover = NSPopover()
    private var item: NSStatusItem!
    private var timer: Timer?
    private var sigterm: DispatchSourceSignal?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Без этого App Nap душит таймер, пока окон нет и крышка закрыта.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Awake engine")

        model.changed = { [weak self] in self?.refresh() }
        model.extend = { [engine] in engine.extendHour() }
        model.releaseHolds = { [engine] in engine.releaseAllHolds() }
        Lang.current = Lang.resolve(Store.config().language)
        model.quit = { [engine] in
            log("панель: выйти")
            Store.write(session: .off)
            engine.shutdown()
            exit(0)
        }
        let hosting = NSHostingController(rootView: PanelView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { [engine] in
            engine.shutdown()
            exit(0)
        }
        sigterm?.resume()

        let ws = NSWorkspace.shared.notificationCenter
        for (name, text) in [
            (NSWorkspace.willSleepNotification, "система засыпает"),
            (NSWorkspace.didWakeNotification, "система проснулась"),
            (NSWorkspace.screensDidSleepNotification, "экран погас"),
            (NSWorkspace.screensDidWakeNotification, "экран включился"),
            (NSWorkspace.willPowerOffNotification, "выключение / выход из системы"),
        ] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in log(text) }
        }

        Notifier.shared.onExtend = { [weak self] in
            self?.engine.extendHour()
            self?.refresh()
        }
        Notifier.shared.setup()
        Hotkeys.register(openPanel: { [weak self] in self?.togglePopover() }, toggleLid: { [weak self] in self?.toggleLid() })

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// ⌃⌥⌘L: ручная сессия «Работать закрытым» на выбранное в панели время (∞ → 3 ч) или выключить её.
    private func toggleLid() {
        if Store.session().mode == .lid {
            log("хоткей: выключить")
            Store.write(session: .off)
            Notifier.shared.send("Awake", tr("«Работать закрытым» выключено", "“Work with the lid closed” is off"), phone: false, config: model.config)
        } else {
            let duration = model.duration ?? 10800
            log("хоткей: lid на \(formatRemaining(duration))")
            Store.write(session: Session(mode: .lid, until: Date() + duration, source: "hotkey"))
            Notifier.shared.send("Awake", tr("Работать закрытым: \(durationText(duration))", "Work with the lid closed: \(durationText(duration))"),
                                 phone: false, config: model.config)
        }
        refresh()
    }

    private func refresh() {
        engine.tick()
        model.status = engine.status
        model.now = Date()
        guard let s = engine.status, let button = item.button else { return }
        let symbol: String
        switch s.effectiveMode {
        case .off: symbol = "moon.zzz"
        case .awake: symbol = "sun.max.fill"
        case .lid: symbol = "laptopcomputer"
        }
        button.image = NSImage(systemSymbolName: s.error == nil ? symbol : "exclamationmark.triangle", accessibilityDescription: "Awake")
        button.imagePosition = .imageLeading
        button.title = (s.mode == .off ? nil : s.until).map { " " + durationText($0.timeIntervalSinceNow) } ?? ""
    }
}
