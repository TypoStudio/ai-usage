import AIUsageCore
import Foundation

/// `--demo` 로 실행했을 때 보여 줄 가짜 계정 (README 스크린샷용, 실제 이메일이 찍히지 않게).
enum DemoData {
    static func make() -> ([AccountConfig], [String: AccountUsage]) {
        let now = Date()
        func limit(_ name: String, _ p: Double, _ hours: Double, _ ring: RingSlot?) -> Limit {
            Limit(name: name, percent: p, resetsAt: now.addingTimeInterval(hours * 3600), ring: ring)
        }
        let items: [AccountUsage] = [
            AccountUsage(id: "/demo/.claude-one", provider: .claude, label: "cld1", email: "alex@example.com", plan: "max",
                         limits: [limit("session", 23, 3.2, .outer), limit("weekly_all", 41, 110, .middle), limit("weekly/Fable", 36, 110, .inner)],
                         fetchedAt: now),
            AccountUsage(id: "/demo/.claude-two", provider: .claude, label: "cld2", email: "alex.work@example.com", plan: "max",
                         limits: [limit("session", 64, 1.5, .outer), limit("weekly_all", 72, 62, .middle), limit("weekly/Fable", 18, 62, .inner)],
                         fetchedAt: now),
            AccountUsage(id: "/demo/.claude-three", provider: .claude, label: "cld3", email: "alex.lab@example.com", plan: "pro",
                         limits: [limit("session", 94, 0.6, .outer), limit("weekly_all", 58, 140, .middle), limit("weekly/Fable", 81, 140, .inner)],
                         fetchedAt: now),
            AccountUsage(id: "/demo/.codex-one", provider: .codex, label: "cdx1", email: "alex@example.com", plan: "plus",
                         limits: [limit("5h", 12, 4.1, .outer), limit("7d", 47, 90, .middle)], fetchedAt: now),
            AccountUsage(id: "/demo/.codex-two", provider: .codex, label: "cdx2", email: "alex.work@example.com", plan: "team",
                         warning: "workspace_owner_credits_depleted",
                         limits: [limit("7d", 100, 52, .middle)], fetchedAt: now),
            AccountUsage(id: "/demo/.codex-three", provider: .codex, label: "cdx3", email: "alex.lab@example.com", plan: "pro",
                         limits: [limit("5h", 38, 2.3, .outer), limit("7d", 26, 150, .middle)], fetchedAt: now),
        ]
        let configs = items.map { AccountConfig(id: $0.id, provider: $0.provider, label: $0.label, enabled: true) }
        return (configs, Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }))
    }
}
