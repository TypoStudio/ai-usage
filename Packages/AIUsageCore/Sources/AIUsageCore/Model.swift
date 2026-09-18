import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
    /// 라벨 접두사 (`cld1`, `cdx1`)
    public var labelPrefix: String { self == .claude ? "cld" : "cdx" }
}

/// 게이지의 동심원 링 위치. 바깥 = 5시간, 가운데 = 주간 전체, 안쪽 = 주간 모델별(Fable).
public enum RingSlot: Int, Codable, Sendable, CaseIterable {
    case outer = 0, middle, inner
}

public struct Limit: Codable, Sendable, Hashable {
    /// 표시 이름 (`session`, `weekly_all`, `weekly/Fable`, `5h`, `7d`…)
    public var name: String
    public var percent: Double
    public var resetsAt: Date?
    /// Claude `severity` 가 normal 이 아닐 때만 채움
    public var severity: String?
    public var ring: RingSlot?

    public init(name: String, percent: Double, resetsAt: Date?, severity: String? = nil, ring: RingSlot? = nil) {
        self.name = name; self.percent = percent; self.resetsAt = resetsAt; self.severity = severity; self.ring = ring
    }
}

public enum AccountStatus: String, Codable, Sendable {
    case ok, refreshing, expired, error
}

/// 계정 하나의 조회 결과. 토큰은 절대 넣지 않는다 — 위젯과 공유되는 파일이다.
public struct AccountUsage: Codable, Sendable, Identifiable, Hashable {
    /// 설정 디렉토리 절대 경로
    public var id: String
    public var provider: ProviderKind
    public var label: String
    public var email: String?
    public var plan: String?
    /// 계정 전체 경고 (Codex `rate_limit_reached_type`)
    public var warning: String?
    /// Codex 워크스페이스 ID — 같은 워크스페이스의 크레딧 경고를 한 번만 묶는 데 쓴다
    public var workspaceID: String?
    public var limits: [Limit]
    public var status: AccountStatus
    public var error: String?
    public var fetchedAt: Date?

    public init(id: String, provider: ProviderKind, label: String, email: String? = nil, plan: String? = nil,
                warning: String? = nil, workspaceID: String? = nil, limits: [Limit] = [],
                status: AccountStatus = .ok, error: String? = nil, fetchedAt: Date? = nil) {
        self.id = id; self.provider = provider; self.label = label; self.email = email; self.plan = plan
        self.warning = warning; self.workspaceID = workspaceID; self.limits = limits
        self.status = status; self.error = error; self.fetchedAt = fetchedAt
    }

    public func limit(for slot: RingSlot) -> Limit? { limits.first { $0.ring == slot } }
    public var maxPercent: Double { limits.map(\.percent).max() ?? 0 }
}

public struct Snapshot: Codable, Sendable {
    public var updatedAt: Date
    /// 설정 순서대로, 켜진 계정만
    public var accounts: [AccountUsage]
    /// 앱 설정의 알림 임계치 — 위젯(샌드박스)은 앱 설정을 못 읽으므로 여기로 넘긴다
    public var threshold: Double?
    /// 앱의 갱신 주기(초) — 위젯의 `앱 실행 필요` 판정에 쓴다
    public var refreshInterval: Double?

    public init(updatedAt: Date, accounts: [AccountUsage], threshold: Double? = nil, refreshInterval: Double? = nil) {
        self.updatedAt = updatedAt; self.accounts = accounts; self.threshold = threshold; self.refreshInterval = refreshInterval
    }

    public var warnThreshold: Double { threshold ?? 90 }

    /// 다음 갱신이 한 번 밀려도 오판하지 않도록: max(10분, 주기×2 + 1분)
    public var staleAfter: TimeInterval { max(SnapshotStore.staleInterval, (refreshInterval ?? 0) * 2 + 60) }

    public static let empty = Snapshot(updatedAt: .distantPast, accounts: [])

    public func accounts(for provider: ProviderKind) -> [AccountUsage] {
        accounts.filter { $0.provider == provider }
    }
}
