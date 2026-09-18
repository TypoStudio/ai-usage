import AIUsageCore
import Foundation
import UserNotifications

/// 임계치를 **넘는 순간** 1회 알리고, 내려가면(리셋) 다시 무장한다. 상태는 재실행에도 유지된다.
@MainActor
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func evaluate(_ usages: [AccountUsage]) {
        let d = UserDefaults.standard
        let threshold = d.double(forKey: Prefs.threshold)
        var fired = Set(d.stringArray(forKey: Prefs.firedAlerts) ?? [])
        var active = Set<String>()

        for u in usages {
            if u.status == .ok {
                for l in u.limits where l.percent >= threshold {
                    let key = "limit|\(u.id)|\(l.name)"
                    active.insert(key)
                    if !fired.contains(key) {
                        post(title: "\(u.label) · \(l.name) \(UsageFormat.percent(l.percent))",
                             body: String(localized: "리셋까지 \(UsageFormat.remaining(until: l.resetsAt))"))
                    }
                }
                // 같은 워크스페이스 계정은 크레딧 경고를 한 번만
                if let w = u.warning, d.bool(forKey: Prefs.notifyCredits) {
                    let key = "warn|\(u.workspaceID ?? u.id)|\(w)"
                    if !active.contains(key), !fired.contains(key) {
                        post(title: "\(u.provider.title) · \(w)", body: u.email ?? u.label)
                    }
                    active.insert(key)
                }
            }
            if u.status == .expired, d.bool(forKey: Prefs.notifyRefreshFailure) {
                let key = "expired|\(u.id)"
                active.insert(key)
                if !fired.contains(key) {
                    post(title: String(localized: "\(u.label) 토큰 갱신 실패"),
                         body: String(localized: "터미널에서 한 번 실행해 주세요: \(AccountCommand.command(for: u))"))
                }
            }
            // 값을 못 받은 계정(만료·오류·갱신 중)은 이전 한도·경고 키를 유지한다 — 복구 뒤 다시 알리지 않도록
            if u.status != .ok {
                let ws = u.workspaceID ?? u.id
                active.formUnion(fired.filter { $0.hasPrefix("limit|\(u.id)|") || $0.hasPrefix("warn|\(ws)|") })
            }
        }
        fired = active
        d.set(Array(fired), forKey: Prefs.firedAlerts)
    }

    private static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

enum AccountCommand {
    /// 별칭(cld2 등)에 기대지 않는 명령
    static func command(for u: AccountUsage) -> String {
        let dir = u.id.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return u.provider == .claude ? "CLAUDE_CONFIG_DIR=\(dir) claude" : "CODEX_HOME=\(dir) codex login"
    }
}
