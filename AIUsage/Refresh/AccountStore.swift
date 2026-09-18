import AIUsageCore
import Foundation

/// 설정에 저장되는 계정 하나. 배열 순서가 곧 표시·게이지 순서다.
struct AccountConfig: Codable, Identifiable, Hashable, Sendable {
    /// 설정 디렉토리 절대 경로
    var id: String
    var provider: ProviderKind
    var label: String
    var enabled: Bool
    /// `경로 추가…` 로 직접 넣은 것 — 탐지에서 사라져도 지우지 않는다
    var manual: Bool = false
}

enum Prefs {
    static let refreshMinutes = "refreshMinutes"      // 1/2/5/10, 기본 2
    static let threshold = "notifyThreshold"          // 기본 90
    static let notifyCredits = "notifyCredits"        // 기본 true
    static let notifyRefreshFailure = "notifyRefreshFailure"  // 기본 true
    static let claudePath = "claudePath"
    static let codexPath = "codexPath"
    static let accounts = "accounts"
    static let firedAlerts = "firedAlerts"
    static let launchAtLoginInitialized = "launchAtLoginInitialized"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshMinutes: 2, threshold: 90.0, notifyCredits: true, notifyRefreshFailure: true,
        ])
    }
}

enum AccountStore {
    static func load() -> [AccountConfig] {
        guard let d = UserDefaults.standard.data(forKey: Prefs.accounts),
              let a = try? JSONDecoder().decode([AccountConfig].self, from: d) else { return [] }
        return a
    }

    static func save(_ accounts: [AccountConfig]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Prefs.accounts)
    }

    /// 게이지에 들어가는 계정 수. 새로 탐지된 계정은 프로바이더별로 이 수까지만 켜진 채 들어온다.
    static let defaultEnabledPerProvider = 3

    /// 저장된 목록에 새로 탐지된 디렉토리를 뒤에 붙이고, 사라진 탐지 항목은 뺀다.
    static func merge(_ saved: [AccountConfig], discovered: [DiscoveredAccount]) -> [AccountConfig] {
        let found = Set(discovered.map(\.path))
        var result = saved.filter { $0.manual || found.contains($0.id) }
        let known = Set(result.map(\.id))
        for d in discovered where !known.contains(d.path) {
            let enabledCount = result.filter { $0.provider == d.provider && $0.enabled }.count
            result.append(AccountConfig(id: d.path, provider: d.provider,
                                        label: AccountDiscovery.defaultLabel(provider: d.provider, path: d.path),
                                        enabled: enabledCount < defaultEnabledPerProvider))
        }
        return result
    }
}
