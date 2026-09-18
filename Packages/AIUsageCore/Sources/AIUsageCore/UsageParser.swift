import Foundation

public enum UsageParseError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String { if case .invalid(let s) = self { return s }; return "" }
}

public struct ParsedUsage: Sendable, Equatable {
    public var plan: String?
    public var warning: String?
    public var workspaceID: String?
    public var limits: [Limit]
}

public enum UsageParser {
    /// `GET https://api.anthropic.com/api/oauth/usage` 응답
    public static func parseClaude(_ data: Data, subscriptionType: String?) throws -> ParsedUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.invalid(snippet(data))
        }
        guard let raw = obj["limits"] as? [[String: Any]] else {
            throw UsageParseError.invalid(errorMessage(obj) ?? snippet(data))
        }
        var limits: [Limit] = []
        var innerTaken = false
        for l in raw {
            let kind = l["kind"] as? String ?? "?"
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let name = model.map { "weekly/\($0)" } ?? kind
            let sev = (l["severity"] as? String).flatMap { $0 == "normal" ? nil : $0 }
            var ring: RingSlot?
            switch kind {
            case "session": ring = .outer
            case "weekly_all": ring = .middle
            default: break
            }
            limits.append(Limit(name: name, percent: number(l["percent"]) ?? 0,
                                resetsAt: (l["resets_at"] as? String).flatMap(parseISO), severity: sev, ring: ring))
            if kind == "weekly_scoped", model == "Fable", !innerTaken { limits[limits.count - 1].ring = .inner; innerTaken = true }
        }
        // Fable 한도가 없으면 첫 번째 모델별 주간 한도를 안쪽 링에
        if !innerTaken, let i = limits.firstIndex(where: { $0.name.hasPrefix("weekly/") }) { limits[i].ring = .inner }
        return ParsedUsage(plan: subscriptionType, warning: nil, workspaceID: nil, limits: limits)
    }

    /// `GET https://chatgpt.com/backend-api/wham/usage` 응답
    public static func parseCodex(_ data: Data, now: Date = Date()) throws -> ParsedUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.invalid(snippet(data))
        }
        guard let rl = obj["rate_limit"] as? [String: Any] else {
            throw UsageParseError.invalid(errorMessage(obj) ?? snippet(data))
        }
        var limits: [Limit] = []
        // primary/secondary 순서가 플랜마다 다르다(팀 플랜은 primary 가 7d) → 창 길이로 링을 정한다
        for key in rl.keys.sorted() {
            guard let w = rl[key] as? [String: Any], let secs = number(w["limit_window_seconds"]) else { continue }
            let name: String
            var ring: RingSlot?
            switch Int(secs) {
            case 18000: name = "5h"; ring = .outer
            case 604800: name = "7d"; ring = .middle
            default: name = Int(secs) >= 3600 ? "\(Int(secs) / 3600)h" : "\(Int(secs) / 60)m"
            }
            let reset: Date? = number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                ?? number(w["reset_after_seconds"]).map { now.addingTimeInterval($0) }
            limits.append(Limit(name: name, percent: number(w["used_percent"]) ?? 0, resetsAt: reset, ring: ring))
        }
        limits.sort { ($0.ring?.rawValue ?? 9) < ($1.ring?.rawValue ?? 9) }
        let warning = (obj["rate_limit_reached_type"] as? [String: Any])?["type"] as? String
        return ParsedUsage(plan: obj["plan_type"] as? String, warning: warning,
                           workspaceID: obj["account_id"] as? String, limits: limits)
    }

    /// JWT payload 의 `email`
    public static func emailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    public static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // 마이크로초(6자리)는 ISO8601DateFormatter 가 못 읽는다 → 밀리초로 자른다
        if let r = s.range(of: #"\.(\d+)"#, options: .regularExpression) {
            let frac = s[r].dropFirst().prefix(3)
            if let d = f.date(from: s.replacingCharacters(in: r, with: "." + frac)) { return d }
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func errorMessage(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let d = obj["detail"] as? String { return d }
        if let d = obj["detail"] as? [String: Any], let m = d["message"] as? String { return m }
        return nil
    }

    static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(120), as: UTF8.self)
    }
}
