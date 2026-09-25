import Foundation

public enum StatisticsFormatter {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 { amount /= 1024; unit += 1 }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", amount, units[unit])
    }
    public static func speed(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B/s" }
        return bytes(UInt64(min(value, Double(UInt64.max / 2)))) + "/s"
    }
    public static func duration(since: Date?, now: Date = Date()) -> String {
        guard let since else { return "—" }
        let seconds = Int(max(0, now.timeIntervalSince(since)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
