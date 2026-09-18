import AIUsageCore
import WidgetKit

struct UsageEntry: TimelineEntry {
    var date: Date
    var provider: ProviderKind
    var snapshot: Snapshot
    var selectedAccountID: String?

    var accounts: [AccountUsage] { snapshot.accounts(for: provider) }
    /// 앱이 갱신 주기보다 한참 오래 스냅샷을 안 썼으면 앱이 꺼진 것으로 본다
    var isStale: Bool { date.timeIntervalSince(snapshot.updatedAt) > snapshot.staleAfter }
    var selectedAccount: AccountUsage? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }
}

/// 위젯은 스냅샷 파일만 읽는다. 갱신은 앱의 `reloadAllTimelines()` 에 맡긴다.
struct UsageTimelineProvider<Intent: ProviderAccountIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), provider: Intent.provider, snapshot: .placeholder(Intent.provider))
    }

    func snapshot(for configuration: Intent, in context: Context) async -> UsageEntry {
        let s = SnapshotStore.load()
        let snap = context.isPreview && s.accounts(for: Intent.provider).isEmpty ? .placeholder(Intent.provider) : s
        return UsageEntry(date: Date(), provider: Intent.provider, snapshot: snap, selectedAccountID: configuration.accountID)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<UsageEntry> {
        let s = SnapshotStore.load()
        let now = Date()
        var entries = [UsageEntry(date: now, provider: Intent.provider, snapshot: s, selectedAccountID: configuration.accountID)]
        // 앱이 더 쓰지 않으면 이 시각에 `앱 실행 필요` 로 바뀐다
        let staleAt = s.updatedAt.addingTimeInterval(s.staleAfter + 1)
        if staleAt > now {
            entries.append(UsageEntry(date: staleAt, provider: Intent.provider, snapshot: s, selectedAccountID: configuration.accountID))
        }
        return Timeline(entries: entries, policy: .never)
    }
}

extension Snapshot {
    static func placeholder(_ p: ProviderKind) -> Snapshot {
        let names: [(String, RingSlot)] = p == .claude
            ? [("session", .outer), ("weekly_all", .middle), ("weekly/Fable", .inner)]
            : [("5h", .outer), ("7d", .middle)]
        let accounts = (1...3).map { i in
            AccountUsage(id: "placeholder-\(i)", provider: p, label: "\(p.labelPrefix)\(i)", email: "user\(i)@example.com",
                         limits: names.enumerated().map { j, n in
                             Limit(name: n.0, percent: Double(20 + i * 15 + j * 10), resetsAt: Date().addingTimeInterval(3600 * Double(4 + j * 40)), ring: n.1)
                         })
        }
        return Snapshot(updatedAt: Date(), accounts: accounts)
    }
}
