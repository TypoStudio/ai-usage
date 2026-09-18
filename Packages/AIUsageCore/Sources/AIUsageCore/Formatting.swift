import Foundation

public enum UsageFormat {
    /// 스크립트와 같은 형식: 하루 이상 `6d 11h`, 미만 `4h 54m`
    public static func remaining(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let d = max(0, Int(date.timeIntervalSince(now)))
        if d >= 86400 { return "\(d / 86400)d \(d % 86400 / 3600)h" }
        return String(format: "%dh %02dm", d / 3600, d % 3600 / 60)
    }

    public static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }
}
