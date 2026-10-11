import Foundation

/// "90" (минуты), "90m", "2h", "1h30m", "1d", "45s".
public func parseDuration(_ text: String) -> TimeInterval? {
    let str = text.lowercased()
    if let minutes = Int(str) { return minutes > 0 ? TimeInterval(minutes * 60) : nil }
    var total = 0.0
    var num = ""
    for c in str {
        if c.isNumber { num.append(c); continue }
        guard let n = Double(num) else { return nil }
        switch c {
        case "d": total += n * 86400
        case "h": total += n * 3600
        case "m": total += n * 60
        case "s": total += n
        default: return nil
        }
        num = ""
    }
    return num.isEmpty && total > 0 ? total : nil
}

/// Компактно для меню-бара: "1д3ч", "2ч05м", "23м", "45с".
public func formatRemaining(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval.rounded(.up)))
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return "\(d)д\(h)ч" }
    if h > 0 { return String(format: "%dч%02dм", h, m) }
    if m > 0 { return "\(m)м" }
    return "\(s)с"
}
