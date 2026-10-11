import AwakeCore
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

enum Power {
    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    static func battery() -> Battery? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return Battery(onBattery: onBattery, percent: current * 100 / maximum)
        }
        return nil
    }

    /// Создаёт или снимает assertion; id == 0 значит «не держим».
    static func set(_ id: inout IOPMAssertionID, type: String, on: Bool) {
        if on, id == 0 {
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Awake" as CFString, &id)
            log(r == kIOReturnSuccess ? "assertion \(type) взят" : "assertion \(type) не создан: IOReturn \(r)")
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
            log("assertion \(type) снят")
        }
    }

    static func readSleepDisabled() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        let line = out.split(separator: "\n").first { $0.contains("SleepDisabled") }
        return line?.split(whereSeparator: \.isWhitespace).last == "1"
    }

    /// Через sudoers-правило /etc/sudoers.d/awake. Возвращает true, если pmset подтвердил новое значение.
    static func setSleepDisabled(_ on: Bool) -> Bool {
        _ = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        return readSleepDisabled() == on
    }

    static func sudoersInstalled() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).status == 0
    }

    static func displaySleepNow() {
        _ = run("/usr/bin/pmset", ["displaysleepnow"])
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
