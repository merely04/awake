import AppKit
import Darwin

/// SIGSTOP всем процессам из бандлов приложений, SIGCONT обратно.
/// pid пишутся в журнал до остановки, чтобы backstop.sh мог разморозить их без нас.
/// SIGCONT по переиспользованному pid безвреден: работающему процессу он ничего не делает.
enum Freezer {
    static func pids(bundleIDs: [String]) -> [pid_t] {
        let prefixes = bundleIDs
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .compactMap { $0.bundleURL?.path }
            .map { $0 + "/" }
        guard !prefixes.isEmpty else { return [] }

        var all = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096)
        return all.prefix(max(0, count)).filter { pid in
            guard pid > 0, pid != getpid(), proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let p = String(cString: path)
            return prefixes.contains { p.hasPrefix($0) }
        }
    }

    static func freeze(bundleIDs: [String]) -> [pid_t] {
        let list = pids(bundleIDs: bundleIDs)
        guard !list.isEmpty else {
            log("морозить нечего: не запущено ни одно из \(bundleIDs.joined(separator: ", "))")
            return []
        }
        let journal = list.map(String.init).joined(separator: "\n") + "\n"
        guard (try? journal.write(to: Paths.frozen, atomically: true, encoding: .utf8)) != nil else {
            log("заморозка пропущена: не удалось записать \(Paths.frozen.path)")
            return []
        }
        for pid in list { kill(pid, SIGSTOP) }
        log("заморожено \(list.count) процессов (\(bundleIDs.joined(separator: ", "))): pid \(list.map(String.init).joined(separator: " "))")
        return list
    }

    static func resume(_ list: [pid_t]) {
        for pid in list { kill(pid, SIGCONT) }
        try? FileManager.default.removeItem(at: Paths.frozen)
        log("разморожено \(list.count) процессов: pid \(list.map(String.init).joined(separator: " "))")
    }

    /// Остатки после падения: всё, что лежит в журнале.
    static func resumeLeftovers() {
        guard let text = try? String(contentsOf: Paths.frozen, encoding: .utf8) else { return }
        resume(text.split(separator: "\n").compactMap { pid_t($0) })
    }
}
