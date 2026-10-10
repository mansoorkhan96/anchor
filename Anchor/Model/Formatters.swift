import Foundation

enum Format {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Decimal (Finder-style) byte count split into number and unit, e.g. ("3.8", "GB").
    static func byteParts(_ value: Int64) -> (value: String, unit: String) {
        var amount = Double(max(0, value))
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        if index == 0 { return ("\(Int(amount))", units[0]) }
        let text = amount < 100 ? String(format: "%.1f", amount) : String(format: "%.0f", amount)
        return (text, units[index])
    }

    static func bytes(_ value: Int64) -> String {
        let p = byteParts(value)
        return "\(p.value) \(p.unit)"
    }

    /// "2.1 of 3.8 GB" style, sharing the unit when both values use the same one.
    static func progress(_ received: Int64, of total: Int64?) -> String {
        guard let total, total > 0 else { return bytes(received) }
        let r = byteParts(received), t = byteParts(total)
        if r.unit == t.unit { return "\(r.value) of \(t.value) \(t.unit)" }
        return "\(bytes(received)) of \(bytes(total))"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func speedParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let p = byteParts(Int64(bytesPerSecond))
        return (p.value, p.unit + "/s")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }
}
